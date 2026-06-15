# pragma version ==0.4.3
"""
@title SignedQuoteFiller — a single-operator, self-funded RFQ desk for the legs
@notice Periphery helper (NOT core protocol). The first and only venue where an N
        holder can actually SELL the leverage leg, and a quote-driven place to buy
        it. ONE operator funds this contract with their OWN ETH + P inventory; ONLY
        EIP-712 quotes signed by the operator's quoter key can fill; every fill is
        bounded on-chain by a DIRECTIONAL, vault-favorable edge floor that survives
        a stolen quoter key. See docs/handoffs/solo-rfq-spec.md.

        It is the provably-clean residual of the killed crowd-vault
        (docs/handoffs/mm-vault-spec.md): the one good mechanism is KEPT (directional floor +
        signed quotes), and the two structural problems are DELETED by making the
        capital and the risk the operator's OWN —

          * NO public deposits, NO vault shares, NO NAV-per-share. There is nothing
            to deposit into and nothing to sandwich (kills the vault's deposit/
            withdraw oracle + JIT arb entirely).
          * the net-long-N / short-theta exposure is the operator's own knowing,
            capped, withdrawable bet on expendable capital — never retail's bag.

@dev    Trades two legs of the tracker's CURRENT OptionSeries vintage:

          * fill_buy_n  — TAKER buys N  == DESK SELLS N (q.side == SIDE_SELL_N).
                          Desk delivers N from inventory or JIT-mints via split()
                          (keeps the P), at price >= intrinsic*(1+min_edge).
          * fill_sell_n — TAKER sells N == DESK BUYS N  (q.side == SIDE_BUY_N).
                          Desk pays ETH, pairs the bought N with inventory P of the
                          same series and merge()s -> ETH oracle-free, at price
                          <= intrinsic*(1-min_edge). This is the value-add.

        intrinsic_n(x) = max(0, 1e18 - STRIKE*1e18//x) matches OptionSeries.settle()
        exactly. x and its freshness are read live per fill; the desk additionally
        enforces a TIGHT staleness bound on the ETH/USD aggregator (independent of
        the hub's up-to-7-day heartbeat), which is the load-bearing guard.

        v1 is USD-only (ASSET == empty(bytes32)) by construction: x then depends on a
        single feed (ETH/USD), so single-feed freshness is sound. Non-USD (two-feed)
        desks are phase 2 (they need a combined-freshness / skew bound).

        Reentrancy: every fill + ETH-out path is @nonreentrant; __default__ is
        UNDECORATED payable so the series' merge/redeem ETH-callback to this contract
        does not contend with the lock (mirrors FlashLeverageRouter). Effects (nonce,
        net_n, outflow window) precede all external calls (CEI); takers are paid last.

        Sepolia testnet, research code, unaudited. The operator's own expendable
        bootstrap capital, not a yield product, not a pooled fund.
"""

from ethereum.ercs import IERC20


interface ITracker:
    def active_series() -> address: view
    def pending_series() -> address: view
    def ROLL_TRIGGER() -> uint256: view

interface ISeries:
    def P() -> address: view
    def N() -> address: view
    def STRIKE() -> uint256: view
    def MATURITY() -> uint256: view
    def ASSET() -> bytes32: view
    def settled() -> bool: view
    def split(): payable
    def merge(amount: uint256): nonpayable
    def redeem_n(amount: uint256): nonpayable

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
    def ETH_USD_FEED() -> address: view

interface AggregatorV3:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view


struct Quote:
    side: uint8          # SIDE_BUY_N (desk buys N) | SIDE_SELL_N (desk sells N)
    taker: address       # empty(address) = open; else only this taker may fill
    series: address      # exact OptionSeries vintage priced (roll-safe; bound into the sig)
    amount: uint256      # N units (1e18-scaled)
    price: uint256       # ETH wei per 1e18 units of N
    min_edge: uint256    # 1e18-scaled vault-favorable floor the quoter commits to (>= MIN_EDGE)
    nonce: uint256       # single-use
    deadline: uint256    # unix; fill must land at/before


event Filled:
    taker: indexed(address)
    series: indexed(address)
    desk_buys_n: bool
    n_amount: uint256
    eth_amount: uint256
    intrinsic_n: uint256
    net_n_after: int256

event Funded:
    from_: indexed(address)
    eth_amount: uint256

event QuoterChanged:
    quoter: indexed(address)

event PausedSet:
    paused: bool

event CapsSet:
    max_fill: uint256
    max_nav_at_risk: uint256
    min_eth_float: uint256
    outflow_cap: uint256

event OwnershipTransferStarted:
    pending_owner: indexed(address)

event OwnershipAccepted:
    owner: indexed(address)


UNIT: constant(uint256) = 10**18
MAX_MIN_EDGE: constant(uint256) = 10**18 // 5    # 20% ceiling on the per-fill edge (matches the DAO's MAX_EDGE posture)
MIN_STALENESS: constant(uint256) = 30            # desk freshness bound floor (s)
MAX_STALENESS: constant(uint256) = 3600          # desk freshness bound ceiling (s) — far below the hub's 7d heartbeat
SIDE_BUY_N: constant(uint8) = 0                  # desk BUYS N  (taker sells N) -> fill_sell_n
SIDE_SELL_N: constant(uint8) = 1                 # desk SELLS N (taker buys N)  -> fill_buy_n

DOMAIN_TYPEHASH: constant(bytes32) = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
QUOTE_TYPEHASH: constant(bytes32) = keccak256(
    "Quote(uint8 side,address taker,address series,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)"
)
NAME_HASH: constant(bytes32) = keccak256("Gimbal Solo RFQ Desk")
VERSION_HASH: constant(bytes32) = keccak256("1")

TRACKER: public(immutable(address))             # the spToken TrackerDAO (current-series source)
HUB: public(immutable(address))                 # OracleHub
ASSET: public(immutable(bytes32))               # asset id; empty(bytes32) = USD (v1 requires this)
MIN_EDGE: public(immutable(uint256))            # immutable hard floor on q.min_edge — can never be loosened
DESK_MAX_STALENESS: public(immutable(uint256))  # tight ETH/USD freshness bound (s), independent of the hub heartbeat
PRE_MATURITY_BUFFER: public(immutable(uint256)) # refuse fills within this of MATURITY (settle-race buffer)
STRIKE_PROXIMITY: public(immutable(uint256))    # no-trade band: require x > STRIKE*STRIKE_PROXIMITY/1e18 (>= roll_trigger)
OUTFLOW_WINDOW: public(immutable(uint256))      # fixed/tumbling-window length (s); worst case up to 2x outflow_cap across a boundary
DOMAIN_SEPARATOR: public(immutable(bytes32))    # deploy-time cached; _digest recomputes if chain.id changes (fork-safe)
CACHED_CHAIN_ID: immutable(uint256)             # chain.id at deploy — guards against post-deploy fork replay

owner: public(address)                          # the operator (2-step transferable)
pending_owner: public(address)
quoter: public(address)                         # the approved quote-signing key (rotatable kill switch)
paused: public(bool)
net_n: public(HashMap[address, int256])         # units of N net-long(+)/short(-), PER SERIES vintage (no cross-vintage drift)
used_nonce: public(HashMap[uint256, bool])
max_fill: public(uint256)                       # per-fill N-units cap
max_nav_at_risk: public(uint256)                # cap on ETH lost if x -> STRIKE (net-long-N axis)
min_eth_float: public(uint256)                  # liquid ETH that JIT-splits may not eat into
outflow_cap: public(uint256)                    # max liquid ETH committed per OUTFLOW_WINDOW
window_start: uint256
window_spent: uint256


@deploy
def __init__(
    owner: address,
    tracker: address,
    hub: address,
    asset: bytes32,
    quoter: address,
    min_edge: uint256,
    desk_max_staleness: uint256,
    pre_maturity_buffer: uint256,
    strike_proximity: uint256,
    outflow_window: uint256,
    max_fill: uint256,
    max_nav_at_risk: uint256,
    min_eth_float: uint256,
    outflow_cap: uint256,
):
    assert owner != empty(address), "zero owner"
    assert tracker != empty(address), "zero tracker"
    assert hub != empty(address), "zero hub"
    assert asset == empty(bytes32), "v1 USD-only"    # F6: single-feed freshness only
    assert quoter != empty(address), "zero quoter"
    assert min_edge > 0 and min_edge <= MAX_MIN_EDGE, "min_edge"
    assert desk_max_staleness >= MIN_STALENESS and desk_max_staleness <= MAX_STALENESS, "staleness"
    assert pre_maturity_buffer > 0, "buffer"
    # F7/G5: the hard no-trade band must exclude the WHOLE roll danger zone, not just
    # x<=STRIKE. Bind it on-chain to the tracker's own roll trigger (itself >= UNIT) so a
    # deploy cannot silently degenerate the band to bare `x > STRIKE` and re-open the
    # near-strike degenerate-floor corner.
    roll_trigger: uint256 = staticcall ITracker(tracker).ROLL_TRIGGER()
    assert strike_proximity >= roll_trigger, "proximity < roll_trigger"
    assert outflow_window > 0, "window"

    TRACKER = tracker
    HUB = hub
    ASSET = asset
    MIN_EDGE = min_edge
    DESK_MAX_STALENESS = desk_max_staleness
    PRE_MATURITY_BUFFER = pre_maturity_buffer
    STRIKE_PROXIMITY = strike_proximity
    OUTFLOW_WINDOW = outflow_window
    DOMAIN_SEPARATOR = keccak256(abi_encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chain.id, self))
    CACHED_CHAIN_ID = chain.id

    self.owner = owner
    self.quoter = quoter
    self.max_fill = max_fill
    self.max_nav_at_risk = max_nav_at_risk
    self.min_eth_float = min_eth_float
    self.outflow_cap = outflow_cap


# ------------------------------------------------------------------ views

@view
@external
def intrinsic_n(series: address) -> uint256:
    """@notice Live N intrinsic (ETH wei per 1e18 units) for `series`, 0 at/below strike."""
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    strike: uint256 = staticcall ISeries(series).STRIKE()
    if x <= strike:
        return 0
    return UNIT - strike * UNIT // x


@view
@external
def quote_digest(q: Quote) -> bytes32:
    """@notice The EIP-712 digest a quoter signs for `q` (for off-chain tooling/tests)."""
    return self._digest(q)


# ------------------------------------------------------------------ internal guards

@view
@internal
def _digest(q: Quote) -> bytes32:
    struct_hash: bytes32 = keccak256(
        abi_encode(
            QUOTE_TYPEHASH, q.side, q.taker, q.series, q.amount, q.price, q.min_edge, q.nonce, q.deadline
        )
    )
    # fork-safe: use the cached separator on the common path, recompute only if the
    # chain forked after deploy (chain.id changed) so EIP-712 chainId replay protection holds
    ds: bytes32 = DOMAIN_SEPARATOR
    if chain.id != CACHED_CHAIN_ID:
        ds = keccak256(abi_encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chain.id, self))
    return keccak256(concat(b"\x19\x01", ds, struct_hash))


@view
@internal
def _assert_fresh():
    # Independent, TIGHT freshness on the ETH/USD aggregator — the hub only enforces
    # its registered (up-to-7-day) heartbeat, which is the F1/F15 hole. v1 is USD-only,
    # so x = ETH/USD and this single feed fully determines freshness.
    feed: address = staticcall IOracleHub(HUB).ETH_USD_FEED()
    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in: uint80 = 0
    (round_id, answer, started_at, updated_at, answered_in) = staticcall AggregatorV3(feed).latestRoundData()
    assert answer > 0, "bad answer"
    assert answered_in >= round_id, "incomplete round"   # F5: reject carried-over rounds
    assert updated_at <= block.timestamp, "future update"
    assert block.timestamp - updated_at <= DESK_MAX_STALENESS, "desk-stale"


@internal
def _verify_and_guard(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    """
    @notice G1-G5 + per-fill size cap. Marks the nonce used BEFORE any external call.
            Returns the live N intrinsic so the caller can apply the NAV-at-risk cap.
            Inventory / outflow / float caps (the rest of G6) are applied per-entrypoint
            where the branch (split vs payout) and post-fill net_n are known.
    """
    assert not self.paused, "paused"

    # G1 — signature is the only authority to fill
    signer: address = ecrecover(self._digest(q), convert(v, uint256), convert(r, uint256), convert(s, uint256))
    assert signer != empty(address) and signer == self.quoter, "bad sig"

    # G2 — replay / freshness / taker binding; consume the nonce as an effect (CEI)
    assert not self.used_nonce[q.nonce], "nonce used"
    assert block.timestamp <= q.deadline, "expired"
    assert q.taker == empty(address) or q.taker == msg.sender, "wrong taker"
    self.used_nonce[q.nonce] = True

    # G3 — roll-safe vintage (the signed series must be the tracker's current target),
    #      not settled, a buffered cutoff before maturity, and the expected asset
    target: address = staticcall ITracker(TRACKER).pending_series()
    if target == empty(address):
        target = staticcall ITracker(TRACKER).active_series()
    assert q.series == target, "stale series"
    is_settled: bool = staticcall ISeries(q.series).settled()
    assert not is_settled, "settled"
    maturity: uint256 = staticcall ISeries(q.series).MATURITY()
    assert block.timestamp + PRE_MATURITY_BUFFER < maturity, "near maturity"
    series_asset: bytes32 = staticcall ISeries(q.series).ASSET()
    assert series_asset == ASSET, "asset mismatch"

    # G4 — live index + TIGHT desk freshness (independent of the hub heartbeat).
    # The signed-x deviation layer (quoter signs x_sign; assert |x_fill-x_sign|<=max_dev)
    # is deferred to phase 2: it is genuinely redundant for SOLO desk safety, because the
    # directional floor (G5) re-clamps to the FRESH fill-time intrinsic — a quote priced at
    # a now-stale x is either re-bounded by the live floor or reverts. v1 leans on this tight
    # staleness window + the short quote TTL; the floor + caps already bound the per-fill loss.
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    self._assert_fresh()

    # G5 — hard no-trade band near strike, then the directional vault-favorable floor
    strike: uint256 = staticcall ISeries(q.series).STRIKE()
    assert x > strike * STRIKE_PROXIMITY // UNIT, "near strike"   # F7: refuse the roll/settle danger zone
    intrinsic: uint256 = UNIT - strike * UNIT // x                # > 0 by the band above
    assert q.min_edge >= MIN_EDGE and q.min_edge <= MAX_MIN_EDGE, "min_edge"
    assert intrinsic * q.min_edge // UNIT > 0, "edge degenerate"  # F7: edge must be enforceable
    if q.side == SIDE_SELL_N:
        # desk SELLS N -> sell dear
        assert q.price >= intrinsic * (UNIT + q.min_edge) // UNIT, "below floor"
    else:
        assert q.side == SIDE_BUY_N, "bad side"
        # desk BUYS N -> buy cheap
        assert q.price <= intrinsic * (UNIT - q.min_edge) // UNIT, "above floor"

    # G6 (size) — the rest of G6 (inventory / outflow / float) is per-entrypoint
    assert q.amount > 0 and q.amount <= self.max_fill, "size"

    return intrinsic


@internal
def _charge_outflow(out: uint256):
    # F3: bound the liquid ETH the desk commits per window, regardless of how many nonces a
    # (possibly stolen) quoter ever signs. This is a fixed/TUMBLING window (reset on first
    # fill at/after the boundary), so the worst case is up to 2x outflow_cap straddling a
    # boundary — size outflow_cap so 2x stays within the operating reserve. The residual is
    # self-funded griefing-of-liquidity (pausable via set_paused/set_quoter), not theft.
    if block.timestamp >= self.window_start + OUTFLOW_WINDOW:
        self.window_start = block.timestamp
        self.window_spent = 0
    assert self.window_spent + out <= self.outflow_cap, "outflow cap"
    self.window_spent += out


# ------------------------------------------------------------------ fills

@external
@payable
@nonreentrant
def fill_buy_n(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    """
    @notice TAKER BUYS N == DESK SELLS N. Send exactly amount*price/1e18 ETH; receive
            `amount` N. The desk delivers from inventory or JIT-mints via split()
            (keeping the P for later merge-recycling).
    @dev q.side must be SIDE_SELL_N.
    """
    assert q.side == SIDE_SELL_N, "side"
    intrinsic: uint256 = self._verify_and_guard(q, v, r, s)

    cost: uint256 = q.amount * q.price // UNIT
    assert msg.value == cost, "bad value"

    # NAV-at-risk cap on the net-long-N axis for THIS vintage (selling reduces it; checked for safety)
    proj_net: int256 = self.net_n[q.series] - convert(q.amount, int256)
    if proj_net > 0:
        assert convert(proj_net, uint256) * intrinsic // UNIT <= self.max_nav_at_risk, "nav cap"

    n_token: address = staticcall ISeries(q.series).N()
    held: uint256 = staticcall IERC20(n_token).balanceOf(self)
    if held < q.amount:
        need: uint256 = q.amount - held
        # F14: own ETH must cover the split (self.balance already holds msg.value==cost; cost < need)
        assert self.balance >= need, "underfunded for split"
        # F2: JIT-minting may not eat the liquid float reserved for sell-N (desk-buys) payouts
        assert self.balance - need >= self.min_eth_float, "float floor"
        self._charge_outflow(need)                       # split-funded ETH counts against the window
        extcall ISeries(q.series).split(value=need)      # mints `need` P + `need` N to self; keeps P

    self.net_n[q.series] -= convert(q.amount, int256)
    assert extcall IERC20(n_token).transfer(msg.sender, q.amount), "n transfer"

    log Filled(
        taker=msg.sender, series=q.series, desk_buys_n=False,
        n_amount=q.amount, eth_amount=cost, intrinsic_n=intrinsic, net_n_after=self.net_n[q.series],
    )
    return q.amount


@external
@nonreentrant
def fill_sell_n(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    """
    @notice TAKER SELLS N == DESK BUYS N — the value-add (selling N is impossible
            anywhere else). Approve `amount` N to this contract first; receive
            amount*price/1e18 ETH. The desk pairs the bought N with inventory P of the
            same series and merge()s -> ETH oracle-free, holding net_n near flat.
    @dev q.side must be SIDE_BUY_N.
    """
    assert q.side == SIDE_BUY_N, "side"
    intrinsic: uint256 = self._verify_and_guard(q, v, r, s)

    proceeds: uint256 = q.amount * q.price // UNIT
    assert proceeds <= self.balance, "insufficient eth"   # payable from current liquid alone

    p_token: address = staticcall ISeries(q.series).P()
    n_token: address = staticcall ISeries(q.series).N()
    p_held: uint256 = staticcall IERC20(p_token).balanceOf(self)
    mergeable: uint256 = min(p_held, q.amount)

    # NAV-at-risk cap on the projected net-long-N position for THIS vintage, AFTER the immediate merge
    proj_net: int256 = self.net_n[q.series] + convert(q.amount, int256) - convert(mergeable, int256)
    if proj_net > 0:
        assert convert(proj_net, uint256) * intrinsic // UNIT <= self.max_nav_at_risk, "nav cap"

    self._charge_outflow(proceeds)                        # ETH paid out counts against the window

    # effects then interactions; pull the taker's N before paying them (CEI)
    self.net_n[q.series] += convert(q.amount, int256)
    assert extcall IERC20(n_token).transferFrom(msg.sender, self, q.amount), "n pull"

    if mergeable > 0:
        extcall ISeries(q.series).merge(mergeable)        # burns mergeable P + N from self -> ETH back
        self.net_n[q.series] -= convert(mergeable, int256)

    raw_call(msg.sender, b"", value=proceeds)

    log Filled(
        taker=msg.sender, series=q.series, desk_buys_n=True,
        n_amount=q.amount, eth_amount=proceeds, intrinsic_n=intrinsic, net_n_after=self.net_n[q.series],
    )
    return proceeds


# ------------------------------------------------------------------ operator (owner-only)

@external
@payable
def fund():
    """@notice Operator tops up the desk's ETH inventory."""
    assert msg.sender == self.owner, "not owner"
    log Funded(from_=msg.sender, eth_amount=msg.value)


@external
def fund_p(series: address, amount: uint256):
    """
    @notice Operator seeds mergeable P inventory of `series` (approve P first).
    @dev P is not tracked in net_n (it is the merge counterpart), so no net_n change.
         Funding N directly is intentionally NOT supported — it would desync net_n
         on the unsafe (permissive) side; the desk acquires N only via fills.
    """
    assert msg.sender == self.owner, "not owner"
    p_token: address = staticcall ISeries(series).P()
    assert extcall IERC20(p_token).transferFrom(msg.sender, self, amount), "pull"


@external
@nonreentrant
def operator_merge(series: address, amount: uint256):
    """@notice Owner wind-down: merge `amount` P+N of `series` -> ETH (F13)."""
    assert msg.sender == self.owner, "not owner"
    extcall ISeries(series).merge(amount)
    self.net_n[series] -= convert(amount, int256)


@external
@nonreentrant
def operator_redeem_n(series: address, amount: uint256):
    """@notice Owner wind-down: redeem settled N of an old vintage -> ETH (F12/F13)."""
    assert msg.sender == self.owner, "not owner"
    is_settled: bool = staticcall ISeries(series).settled()
    assert is_settled, "not settled"
    extcall ISeries(series).redeem_n(amount)
    self.net_n[series] -= convert(amount, int256)


@external
@nonreentrant
def withdraw_eth(amount: uint256):
    assert msg.sender == self.owner, "not owner"
    raw_call(msg.sender, b"", value=amount)


@external
def withdraw_token(token: address, amount: uint256):
    """@dev Withdrawing N leaves net_n unchanged (conservatively high) — safe; use at wind-down."""
    assert msg.sender == self.owner, "not owner"
    assert extcall IERC20(token).transfer(msg.sender, amount), "transfer"


@external
def set_paused(p: bool):
    assert msg.sender == self.owner, "not owner"
    self.paused = p
    log PausedSet(paused=p)


@external
def set_quoter(new_quoter: address):
    """@notice Rotate the quote-signing key — the instant kill switch after a key leak."""
    assert msg.sender == self.owner, "not owner"
    assert new_quoter != empty(address), "zero quoter"
    self.quoter = new_quoter
    log QuoterChanged(quoter=new_quoter)


@external
def set_caps(max_fill: uint256, max_nav_at_risk: uint256, min_eth_float: uint256, outflow_cap: uint256):
    assert msg.sender == self.owner, "not owner"
    self.max_fill = max_fill
    self.max_nav_at_risk = max_nav_at_risk
    self.min_eth_float = min_eth_float
    self.outflow_cap = outflow_cap
    log CapsSet(
        max_fill=max_fill, max_nav_at_risk=max_nav_at_risk,
        min_eth_float=min_eth_float, outflow_cap=outflow_cap,
    )


@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "not owner"
    self.pending_owner = new_owner
    log OwnershipTransferStarted(pending_owner=new_owner)


@external
def accept_ownership():
    assert msg.sender == self.pending_owner, "not pending"
    self.owner = msg.sender
    self.pending_owner = empty(address)
    log OwnershipAccepted(owner=msg.sender)


@external
@payable
def __default__():
    # accepts ETH from the series' merge/redeem_n callbacks. Undecorated so those
    # callbacks don't contend with the @nonreentrant lock held by the fill in flight.
    pass
