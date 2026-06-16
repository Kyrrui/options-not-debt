# pragma version ==0.4.3
"""
@title StableQuoteFiller — a single-operator, self-funded RFQ desk for the spUSD leg
@notice Periphery helper (NOT core protocol). SIBLING to the N-leg SignedQuoteFiller
        — same signed-quote + on-chain-floor safety skeleton, applied to the
        P/dollar (spUSD) leg, which is the POSITIVE-CARRY side (it collects the
        premium the decaying N leg pays; spUSD NAV accretes via the DAO's harvest).
        ONE operator funds it with their OWN ETH + spUSD inventory; ONLY EIP-712
        quotes signed by the operator's quoter key fill; every fill is bounded
        on-chain by a directional, NAV-anchored edge floor that survives a stolen
        quoter key. See docs/handoffs/stable-rfq-spec.md.

        THE ONE TRAP IT MUST DODGE — never mint-to-sell. To sell spUSD the desk
        needs spUSD; if it minted via TrackerDAO.deposit() the DAO would hand it the
        N leg (the orphan-N handout), recreating the short-theta bleed this desk
        exists to avoid. So the desk is strictly INVENTORY-BASED: it sells only
        spUSD it previously bought/was funded, and goes one-sided (buy-only) when
        inventory hits MIN_SPUSD_FLOAT. There is NO deposit()/split() path anywhere.

@dev    Trades the single spUSD token (TrackerDAO IS the spUSD ERC20 — `TRACKER`
        and the token are the same address; no per-series vintage, no roll-safety
        surface):

          * fill_buy_spusd  — TAKER buys spUSD == DESK SELLS from INVENTORY ONLY,
                              at price >= fair*(1+min_edge). No JIT mint.
          * fill_sell_spusd — TAKER sells spUSD == DESK BUYS, warehouses it as
                              positive-carry inventory, pays ETH, at price
                              <= fair*(1-min_edge).

        fair = share_price() * 1e18 // x   (NAV/share in USD -> ETH via the oracle;
        x = OracleHub.latest_price(ASSET) = USD per ETH). The oracle is on the floor
        path -> the same TIGHT DESK_MAX_STALENESS gate as the N desk, read off
        ETH_USD_FEED (independent of the hub's up-to-7-day heartbeat). v1 is USD-only
        (ASSET == empty(bytes32)) by construction, and __init__ asserts the tracker's
        own oracle wiring matches, so the single-feed freshness gate transitively
        covers share_price()'s internal oracle read (F6).

        KNOWN RESIDUAL (low, phase-2 hardening — mirrors the N desk's deferred x_sign):
        share_price() is nudgeable within a single tx via the DAO's sell_p/fill_roll/
        sync auctions, bounded by MAX_EDGE (<20%) and the cost of round-tripping them.
        A quoter-signed sp_sign deviation bound (assert |sp_fill - sp_sign| <= max_dev)
        is the planned fix; v1 leans on the directional min_edge floor + short quote TTL,
        which bound the per-fill erosion.

        Recycling is OFF the hot path: operator_redeem() -> TrackerDAO.redeem() is
        oracle-free and returns pro-rata eth_buffer ETH + P of each live series. The
        ETH share is recovered capital; the P share is mostly-illiquid and must be
        disposed of separately (operator_redeem_p after settlement, or sold near
        NAV). The "oracle-free redeem floor" is only the eth_buffer pro-rata slice
        (typically a small % of NAV) — exit-side defense-in-depth, NOT an entry
        clamp, and NOT better-protected than the N desk's merge.

        Reentrancy: every fill + ETH-out path is @nonreentrant; __default__ is
        UNDECORATED payable so redeem/redeem_p ETH-callbacks don't contend with the
        lock. Effects (nonce, net_spusd, outflow window) precede external calls
        (CEI); takers are paid last.

        Sepolia testnet, research code, unaudited. The operator's own capped
        capital, not a yield product, not a pooled fund.
"""

from ethereum.ercs import IERC20


interface ITracker:
    def share_price() -> uint256: view
    def HUB() -> address: view
    def ASSET() -> bytes32: view
    def active_series() -> address: view
    def pending_series() -> address: view
    def eth_buffer() -> uint256: view
    def redeem(shares: uint256): nonpayable

interface ISeries:
    def settled() -> bool: view
    def redeem_p(amount: uint256): nonpayable

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
    def ETH_USD_FEED() -> address: view

interface AggregatorV3:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view


struct Quote:
    side: uint8          # SIDE_BUY_SPUSD (desk buys) | SIDE_SELL_SPUSD (desk sells)
    taker: address       # empty(address) = open; else only this taker may fill
    amount: uint256      # spUSD units (1e18-scaled)
    price: uint256       # ETH wei per 1e18 spUSD
    min_edge: uint256    # 1e18-scaled desk-favorable floor the quoter commits to (>= MIN_EDGE)
    nonce: uint256       # single-use
    deadline: uint256    # unix; fill must land at/before


event Filled:
    taker: indexed(address)
    desk_buys_spusd: bool
    amount: uint256
    eth_amount: uint256
    fair: uint256
    net_spusd_after: uint256

event Funded:
    from_: indexed(address)
    eth_amount: uint256

event QuoterChanged:
    quoter: indexed(address)

event PausedSet:
    paused: bool

event CapsSet:
    max_fill: uint256
    max_net_spusd: uint256
    min_eth_float: uint256
    min_spusd_float: uint256
    outflow_cap: uint256

event OwnershipTransferStarted:
    pending_owner: indexed(address)

event OwnershipAccepted:
    owner: indexed(address)


UNIT: constant(uint256) = 10**18
MAX_MIN_EDGE: constant(uint256) = 10**18 // 5    # 20% ceiling on the per-fill edge (DAO MAX_EDGE posture)
MIN_STALENESS: constant(uint256) = 30            # desk freshness bound floor (s)
MAX_STALENESS: constant(uint256) = 3600          # desk freshness bound ceiling (s) — far below the hub's 7d heartbeat
SIDE_BUY_SPUSD: constant(uint8) = 0              # desk BUYS spUSD (taker sells) -> fill_sell_spusd
SIDE_SELL_SPUSD: constant(uint8) = 1             # desk SELLS spUSD (taker buys) -> fill_buy_spusd

DOMAIN_TYPEHASH: constant(bytes32) = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
QUOTE_TYPEHASH: constant(bytes32) = keccak256(
    "Quote(uint8 side,address taker,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)"
)
# DISTINCT from the N desk's "Gimbal Solo RFQ Desk" (F-DOMAIN) — belt-and-suspenders
# on top of the distinct verifyingContract + 7-field typehash already separating them.
NAME_HASH: constant(bytes32) = keccak256("Gimbal Solo RFQ Stable Desk")
VERSION_HASH: constant(bytes32) = keccak256("1")

TRACKER: public(immutable(address))             # the spUSD TrackerDAO (also the spUSD ERC20)
HUB: public(immutable(address))                 # OracleHub
ASSET: public(immutable(bytes32))               # asset id; empty(bytes32) = USD (v1 requires this)
MIN_EDGE: public(immutable(uint256))            # immutable hard floor on q.min_edge — never loosened
DESK_MAX_STALENESS: public(immutable(uint256))  # tight ETH/USD freshness bound (s), independent of the hub heartbeat
OUTFLOW_WINDOW: public(immutable(uint256))      # fixed/tumbling window (s); worst case up to 2x outflow_cap across a boundary
DOMAIN_SEPARATOR: public(immutable(bytes32))    # deploy-time cached; _digest recomputes if chain.id changes (fork-safe)
CACHED_CHAIN_ID: immutable(uint256)             # chain.id at deploy — guards post-deploy fork replay

owner: public(address)                          # the operator (2-step transferable)
pending_owner: public(address)
quoter: public(address)                         # the approved quote-signing key (rotatable kill switch)
paused: public(bool)
net_spusd: public(uint256)                      # spUSD units the desk holds as inventory (never short — sells only inventory)
used_nonce: public(HashMap[uint256, bool])
max_fill: public(uint256)                       # per-fill spUSD-units cap
max_net_spusd: public(uint256)                  # cap on net-long spUSD inventory in UNITS (~USD notional ~1x short-ETH); ORACLE-INVARIANT (an ETH-mark cap would loosen on an ETH rise — the adverse direction)
min_eth_float: public(uint256)                  # liquid ETH the buy side may not eat into
min_spusd_float: public(uint256)                # spUSD inventory the sell side may not eat into (the no-mint-to-sell rule)
outflow_cap: public(uint256)                    # max ETH paid out per OUTFLOW_WINDOW
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
    outflow_window: uint256,
    max_fill: uint256,
    max_net_spusd: uint256,
    min_eth_float: uint256,
    min_spusd_float: uint256,
    outflow_cap: uint256,
):
    assert owner != empty(address), "zero owner"
    assert tracker != empty(address), "zero tracker"
    assert hub != empty(address), "zero hub"
    assert asset == empty(bytes32), "v1 USD-only"          # F6: single-feed freshness only
    assert quoter != empty(address), "zero quoter"
    assert min_edge > 0 and min_edge <= MAX_MIN_EDGE, "min_edge"
    assert desk_max_staleness >= MIN_STALENESS and desk_max_staleness <= MAX_STALENESS, "staleness"
    assert outflow_window > 0, "window"
    # F6: enforce on-chain the "same single feed" invariant the tight gate relies on —
    # the tracker's own oracle wiring must match the desk's, so _assert_fresh on
    # ETH_USD_FEED transitively covers share_price()'s internal oracle read.
    assert staticcall ITracker(tracker).HUB() == hub, "tracker hub mismatch"
    assert staticcall ITracker(tracker).ASSET() == asset, "tracker asset mismatch"

    TRACKER = tracker
    HUB = hub
    ASSET = asset
    MIN_EDGE = min_edge
    DESK_MAX_STALENESS = desk_max_staleness
    OUTFLOW_WINDOW = outflow_window
    DOMAIN_SEPARATOR = keccak256(abi_encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chain.id, self))
    CACHED_CHAIN_ID = chain.id

    self.owner = owner
    self.quoter = quoter
    self.max_fill = max_fill
    self.max_net_spusd = max_net_spusd
    self.min_eth_float = min_eth_float
    self.min_spusd_float = min_spusd_float
    self.outflow_cap = outflow_cap


# ------------------------------------------------------------------ views

@view
@external
def fair_price() -> uint256:
    """@notice Live spUSD fair value (ETH wei per 1e18 spUSD) = NAV/share via the oracle. Display only; no freshness assert."""
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    sp: uint256 = staticcall ITracker(TRACKER).share_price()
    return sp * UNIT // x


@view
@external
def redeem_floor_eth(amount: uint256) -> uint256:
    """
    @notice The ORACLE-FREE recoverable ETH for `amount` spUSD = the eth_buffer
            pro-rata slice ONLY (typically a small % of NAV, often ~0 — sell_p
            rotates the buffer back into P). The rest of redeem() is P that still
            needs the oracle. Honest exit-side hint; NOT an entry-price clamp (F-FLOOR).
    """
    supply: uint256 = staticcall IERC20(TRACKER).totalSupply()
    if supply == 0:
        return 0
    return staticcall ITracker(TRACKER).eth_buffer() * amount // supply


@view
@external
def quote_digest(q: Quote) -> bytes32:
    return self._digest(q)


# ------------------------------------------------------------------ internal

@view
@internal
def _digest(q: Quote) -> bytes32:
    struct_hash: bytes32 = keccak256(
        abi_encode(QUOTE_TYPEHASH, q.side, q.taker, q.amount, q.price, q.min_edge, q.nonce, q.deadline)
    )
    ds: bytes32 = DOMAIN_SEPARATOR
    if chain.id != CACHED_CHAIN_ID:
        ds = keccak256(abi_encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chain.id, self))
    return keccak256(concat(b"\x19\x01", ds, struct_hash))


@view
@internal
def _assert_fresh():
    # Independent TIGHT freshness on the ETH/USD aggregator (the hub only enforces its
    # registered up-to-7-day heartbeat). USD-only v1 ⇒ x depends on this single feed,
    # and the __init__ tracker-wiring asserts make this transitively cover share_price().
    feed: address = staticcall IOracleHub(HUB).ETH_USD_FEED()
    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in: uint80 = 0
    (round_id, answer, started_at, updated_at, answered_in) = staticcall AggregatorV3(feed).latestRoundData()
    assert answer > 0, "bad answer"
    assert answered_in >= round_id, "incomplete round"
    assert updated_at <= block.timestamp, "future update"
    assert block.timestamp - updated_at <= DESK_MAX_STALENESS, "desk-stale"


@view
@internal
def _fair() -> uint256:
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    self._assert_fresh()
    sp: uint256 = staticcall ITracker(TRACKER).share_price()
    fair: uint256 = sp * UNIT // x
    assert fair > 0, "fair degenerate"
    return fair


@internal
def _verify_and_guard(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    assert not self.paused, "paused"

    # G1 — signature is the only authority to fill
    signer: address = ecrecover(self._digest(q), convert(v, uint256), convert(r, uint256), convert(s, uint256))
    assert signer != empty(address) and signer == self.quoter, "bad sig"

    # G2 — replay / freshness / taker binding; consume the nonce as an effect (CEI)
    assert not self.used_nonce[q.nonce], "nonce used"
    assert block.timestamp <= q.deadline, "expired"
    assert q.taker == empty(address) or q.taker == msg.sender, "wrong taker"
    self.used_nonce[q.nonce] = True

    # G3 — (DELETED): spUSD is a single token, no vintage / roll-safety surface

    # G4 — live NAV fair + TIGHT desk freshness (inside _fair)
    fair: uint256 = self._fair()

    # G5 — directional NAV floor (no near-strike band; spUSD has no strike)
    assert q.min_edge >= MIN_EDGE and q.min_edge <= MAX_MIN_EDGE, "min_edge"
    assert fair * q.min_edge // UNIT > 0, "edge degenerate"
    if q.side == SIDE_SELL_SPUSD:
        # desk SELLS spUSD -> sell dear
        assert q.price >= fair * (UNIT + q.min_edge) // UNIT, "below floor"
    else:
        assert q.side == SIDE_BUY_SPUSD, "bad side"
        # desk BUYS spUSD -> buy cheap
        assert q.price <= fair * (UNIT - q.min_edge) // UNIT, "above floor"

    # G6 (size) — inventory / outflow / float handled per-entrypoint
    assert q.amount > 0 and q.amount <= self.max_fill, "size"

    return fair


@internal
def _charge_outflow(out: uint256):
    # F3-analog: bound the ETH the desk pays out per window regardless of how many
    # nonces a (possibly stolen) quoter signs. Fixed/TUMBLING window (worst case up to
    # 2x outflow_cap straddling a boundary — size outflow_cap for 2x).
    if block.timestamp >= self.window_start + OUTFLOW_WINDOW:
        self.window_start = block.timestamp
        self.window_spent = 0
    assert self.window_spent + out <= self.outflow_cap, "outflow cap"
    self.window_spent += out


# ------------------------------------------------------------------ fills

@external
@payable
@nonreentrant
def fill_buy_spusd(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    """
    @notice TAKER BUYS spUSD == DESK SELLS from INVENTORY ONLY. Send exactly
            amount*price/1e18 ETH; receive `amount` spUSD. NO mint-to-sell: reverts
            (and the desk goes buy-only) when inventory would fall below the float.
    @dev q.side must be SIDE_SELL_SPUSD.
    """
    assert q.side == SIDE_SELL_SPUSD, "side"
    fair: uint256 = self._verify_and_guard(q, v, r, s)

    cost: uint256 = q.amount * q.price // UNIT
    assert msg.value == cost, "bad value"
    # *** the inventory rule — never mint to sell ***
    assert self.net_spusd >= q.amount + self.min_spusd_float, "insufficient inventory"

    self.net_spusd -= q.amount
    assert extcall IERC20(TRACKER).transfer(msg.sender, q.amount), "spusd transfer"

    log Filled(
        taker=msg.sender, desk_buys_spusd=False,
        amount=q.amount, eth_amount=cost, fair=fair, net_spusd_after=self.net_spusd,
    )
    return q.amount


@external
@nonreentrant
def fill_sell_spusd(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256:
    """
    @notice TAKER SELLS spUSD == DESK BUYS and warehouses it (positive carry).
            Approve `amount` spUSD to this contract first; receive amount*price/1e18 ETH.
    @dev q.side must be SIDE_BUY_SPUSD.
    """
    assert q.side == SIDE_BUY_SPUSD, "side"
    fair: uint256 = self._verify_and_guard(q, v, r, s)

    proceeds: uint256 = q.amount * q.price // UNIT
    assert proceeds <= self.balance, "insufficient eth"
    # net-long-spUSD cap in UNITS (the 1x short-ETH axis). Capping the ETH-mark
    # (net_spusd * fair) would LOOSEN as ETH rises — the adverse direction — letting the
    # USD-notional bet run past the intended size during a rally; units are oracle-invariant.
    assert self.net_spusd + q.amount <= self.max_net_spusd, "nav cap"
    assert self.balance - proceeds >= self.min_eth_float, "float floor"
    self._charge_outflow(proceeds)

    # effects then interactions; pull the taker's spUSD before paying (CEI)
    self.net_spusd += q.amount
    assert extcall IERC20(TRACKER).transferFrom(msg.sender, self, q.amount), "spusd pull"
    raw_call(msg.sender, b"", value=proceeds)

    log Filled(
        taker=msg.sender, desk_buys_spusd=True,
        amount=q.amount, eth_amount=proceeds, fair=fair, net_spusd_after=self.net_spusd,
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
def fund_spusd(amount: uint256):
    """@notice Operator seeds spUSD inventory (approve spUSD first). The primary,
       safe inventory source — the inverse of the N desk, where funding the leg was
       forbidden; here spUSD is the guarded side. NO deposit()/mint path exists (F-ORPHAN)."""
    assert msg.sender == self.owner, "not owner"
    assert extcall IERC20(TRACKER).transferFrom(msg.sender, self, amount), "pull"
    self.net_spusd += amount


@external
def resync_spusd():
    """@notice Adopt any spUSD held but un-booked (a direct transfer/donation) into
       inventory. Safe — the desk is never short, so net_spusd should equal the held balance."""
    assert msg.sender == self.owner, "not owner"
    self.net_spusd = staticcall IERC20(TRACKER).balanceOf(self)


@external
@nonreentrant
def operator_redeem(shares: uint256):
    """
    @notice Owner wind-down: redeem `shares` spUSD -> oracle-free pro-rata
            eth_buffer ETH + P of each live series. Returns mostly-illiquid P; the
            ETH share is recovered capital (F-PBAG). Reverts during a roll so the
            operator does not unknowingly accumulate a second vintage (F-ROLL).
    """
    assert msg.sender == self.owner, "not owner"
    assert staticcall ITracker(TRACKER).pending_series() == empty(address), "roll open"
    extcall ITracker(TRACKER).redeem(shares)
    self.net_spusd -= min(shares, self.net_spusd)   # saturating: a valid burn must never brick on book<balance (donations)


@external
@nonreentrant
def operator_redeem_p(series: address, amount: uint256):
    """@notice Owner wind-down of old-vintage P -> ETH after it settles (F-ROLL)."""
    assert msg.sender == self.owner, "not owner"
    assert staticcall ISeries(series).settled(), "not settled"
    extcall ISeries(series).redeem_p(amount)


@external
@nonreentrant
def withdraw_eth(amount: uint256):
    assert msg.sender == self.owner, "not owner"
    raw_call(msg.sender, b"", value=amount)


@external
def withdraw_token(token: address, amount: uint256):
    """@dev Withdrawing spUSD decrements net_spusd to keep the inventory book honest."""
    assert msg.sender == self.owner, "not owner"
    if token == TRACKER:
        self.net_spusd -= min(amount, self.net_spusd)   # saturating (donations can make real balance > book)
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
def set_caps(max_fill: uint256, max_net_spusd: uint256, min_eth_float: uint256, min_spusd_float: uint256, outflow_cap: uint256):
    assert msg.sender == self.owner, "not owner"
    self.max_fill = max_fill
    self.max_net_spusd = max_net_spusd
    self.min_eth_float = min_eth_float
    self.min_spusd_float = min_spusd_float
    self.outflow_cap = outflow_cap
    log CapsSet(
        max_fill=max_fill, max_net_spusd=max_net_spusd, min_eth_float=min_eth_float,
        min_spusd_float=min_spusd_float, outflow_cap=outflow_cap,
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
    # accepts ETH from redeem/redeem_p callbacks. Undecorated so those callbacks
    # don't contend with the @nonreentrant lock held by the operator wind-down call.
    pass
