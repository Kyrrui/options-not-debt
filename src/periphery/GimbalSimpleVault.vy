# pragma version ==0.4.3
"""
@title GimbalSimpleVault — the minimal immutable, ownerless, crowd-funded house (Sepolia v1)
@notice Periphery (NOT core). The smallest honest cut of the crowd-owned autonomous house
        (docs/handoffs/autonomous-vault-spec.md), collapsed to what is safe to FREEZE on a
        testnet: crowd LPs deposit ETH into a pool that WRITES and SELLS the N (leverage) leg
        of the live spUSD TrackerDAO's CURRENT (~2x) series at an ON-CHAIN formulaic price,
        keeping the P leg (a covered-call house). There is:

          * NO owner, NO admin, NO pause, NO upgrade, NO withdraw — every knob is a ctor
            immutable; the only ETH outflow is an LP redeeming its OWN shares (oracle-free,
            in-kind) or a settled-series harvest. The withdraw_eth / set_* / quoter rug
            surfaces the operator desks carried simply do not exist here.
          * NO signer. The price is computed on-chain: intrinsic * (1 + BASE_EDGE). The
            accepted cost of ownerlessness is a wider, MEV/oracle-tick-exposed quote, bounded
            by tight staleness + per-block / per-window write caps (TrackerDAO.sync precedent).
          * NO new market machinery. It rides the ALREADY-DEPLOYED TrackerDAO: it writes only
            the tracker's roll-safe current vintage (pending else active), and the tracker's own
            permissionless sync() creates / rolls / settles series. So there is no strike menu,
            no factory, no roll logic, no keeper race here.

        It holds ONLY ETH + P, exactly like TrackerDAO, so its NAV (eth_buffer + Sum p_held*val_p)
        and its oracle-free in-kind redeem are that contract's tested, Halmos-proven shapes.

@dev    DELIBERATELY SIMPLIFIED FOR SEPOLIA. Single ~2x series (no leverage menu); live-NAV
        deposit pricing (no epochs — a documented JIT-NAV arb); junior-only (no senior tranche);
        ETH/N only (no shorts); write-only (N buyers exit via the series' permissionless
        oracle-free redeem_n / merge, or a secondary market). EVERY simplification is a mainnet
        gate — see docs/handoffs/simple-vault-sepolia-spec.md "MAINNET CHECKLIST". Do NOT deploy
        this as-is to mainnet.

        Shares are SOULBOUND in v1 (mint/burn only; no transfer/approve surface).

        Sepolia testnet, research code, unaudited. Not a yield product; the house can lose
        principal (capped at deposit, never liquidated). Immutable BY CHOICE — a bug's only
        recourse is redeploy-v2 + LP migration via the always-open redeem().
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
    def payout_p() -> uint256: view
    def split(): payable
    def redeem_p(amount: uint256): nonpayable

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
    def ETH_USD_FEED() -> address: view

interface AggregatorV3:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view


event Transfer:                          # share mint/burn (soulbound: from/to zero only)
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Deposited:
    account: indexed(address)
    eth_in: uint256
    shares: uint256

event Redeemed:
    account: indexed(address)
    shares: uint256
    eth_out: uint256

event BoughtN:
    buyer: indexed(address)
    series: indexed(address)
    n_amount: uint256
    eth_cost: uint256
    intrinsic_n: uint256

event Harvested:
    series: indexed(address)
    p_amount: uint256
    eth_out: uint256


UNIT: constant(uint256) = 10**18
DEAD: constant(address) = 0x000000000000000000000000000000000000dEaD
DEAD_SHARES: constant(uint256) = 10**3
MAX_MIN_EDGE: constant(uint256) = 10**18 // 5     # 20% sanity ceiling on BASE_EDGE
MIN_STALENESS: constant(uint256) = 30
MAX_STALENESS: constant(uint256) = 3600
MAX_OPEN: constant(uint256) = 8                   # bounds the redeem / poke / nav loops

NAME: public(constant(String[32])) = "Gimbal House Share"
SYMBOL: public(constant(String[16])) = "hsETH"
DECIMALS: public(constant(uint8)) = 18

TRACKER: public(immutable(address))               # the live spUSD TrackerDAO (current-series source)
HUB: public(immutable(address))                   # OracleHub
ASSET: public(immutable(bytes32))                 # empty(bytes32) = USD (v1 requires this)
BASE_EDGE: public(immutable(uint256))             # 1e18-scaled spread over intrinsic the house sells at
DESK_MAX_STALENESS: public(immutable(uint256))    # tight ETH/USD freshness bound (s), independent of the hub heartbeat
PRE_MATURITY_BUFFER: public(immutable(uint256))   # refuse writes within this of MATURITY (settle-race buffer)
STRIKE_PROXIMITY: public(immutable(uint256))      # no-trade band: require x > STRIKE*STRIKE_PROXIMITY/1e18 (>= roll_trigger)
MAX_FILL: public(immutable(uint256))              # per-fill N-units cap
MAX_WRITTEN: public(immutable(uint256))           # cap on Sum p_held (face) = capital-at-risk bound
OUTFLOW_WINDOW: public(immutable(uint256))        # tumbling-window length (s) for written-face throttle
OUTFLOW_CAP: public(immutable(uint256))           # max N-face written per window
MAX_WRITE_PER_BLOCK: public(immutable(uint256))   # max N-face written per block (atomic-extraction bound)
TOTAL_DEPOSIT_CAP: public(immutable(uint256))     # gross deposit blast-radius bound

# ---- soulbound shares ----
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])

# ---- pools / inventory ----
eth_buffer: public(uint256)                       # tracked free ETH (donations uncounted)
p_held: public(HashMap[address, uint256])         # P units held per series vintage
is_open: public(HashMap[address, bool])           # membership flag for open_series
open_series: public(DynArray[address, MAX_OPEN])
total_p_held: public(uint256)                     # Sum p_held over open series (the risk meter)
total_deposited: public(uint256)                  # gross ETH ever deposited (for the cap)

# ---- write throttles ----
window_start: uint256
window_spent: uint256
last_write_block: uint256
block_spent: uint256


@deploy
def __init__(
    tracker: address,
    hub: address,
    asset: bytes32,
    base_edge: uint256,
    desk_max_staleness: uint256,
    pre_maturity_buffer: uint256,
    strike_proximity: uint256,
    max_fill: uint256,
    max_written: uint256,
    outflow_window: uint256,
    outflow_cap: uint256,
    max_write_per_block: uint256,
    total_deposit_cap: uint256,
):
    assert tracker != empty(address), "zero tracker"
    assert hub != empty(address), "zero hub"
    assert asset == empty(bytes32), "v1 USD-only"
    assert base_edge > 0 and base_edge <= MAX_MIN_EDGE, "base_edge"
    assert desk_max_staleness >= MIN_STALENESS and desk_max_staleness <= MAX_STALENESS, "staleness"
    assert pre_maturity_buffer > 0, "buffer"
    # bind the no-trade band to the tracker's own roll trigger (>= UNIT) so a deploy cannot
    # degenerate it to bare `x > STRIKE` and re-open the near-strike degenerate-floor corner
    roll_trigger: uint256 = staticcall ITracker(tracker).ROLL_TRIGGER()
    assert strike_proximity >= roll_trigger, "proximity < roll_trigger"
    assert outflow_window > 0, "window"
    assert max_fill > 0, "max_fill"
    assert max_written > 0, "max_written"
    assert outflow_cap > 0, "outflow_cap"
    assert max_write_per_block > 0, "block cap"
    assert total_deposit_cap > 0, "deposit cap"

    TRACKER = tracker
    HUB = hub
    ASSET = asset
    BASE_EDGE = base_edge
    DESK_MAX_STALENESS = desk_max_staleness
    PRE_MATURITY_BUFFER = pre_maturity_buffer
    STRIKE_PROXIMITY = strike_proximity
    MAX_FILL = max_fill
    MAX_WRITTEN = max_written
    OUTFLOW_WINDOW = outflow_window
    OUTFLOW_CAP = outflow_cap
    MAX_WRITE_PER_BLOCK = max_write_per_block
    TOTAL_DEPOSIT_CAP = total_deposit_cap


# ------------------------------------------------------------------ shares (soulbound)

@internal
def _mint(to: address, amount: uint256):
    self.totalSupply += amount
    self.balanceOf[to] += amount
    log Transfer(sender=empty(address), receiver=to, value=amount)


@internal
def _burn(owner: address, amount: uint256):
    self.balanceOf[owner] -= amount      # underflow reverts on over-redeem
    self.totalSupply -= amount
    log Transfer(sender=owner, receiver=empty(address), value=amount)


# ------------------------------------------------------------------ pricing / NAV

@view
@internal
def _val_p_eth(series: address, x: uint256) -> uint256:
    """ETH wei per 1e18 units of P: payout_p once settled, else live intrinsic min(1, S/x)."""
    if staticcall ISeries(series).settled():
        return staticcall ISeries(series).payout_p()
    return min(UNIT, staticcall ISeries(series).STRIKE() * UNIT // x)


@view
@internal
def _nav(x: uint256) -> uint256:
    total: uint256 = self.eth_buffer
    cur: DynArray[address, MAX_OPEN] = self.open_series
    for s: address in cur:
        ph: uint256 = self.p_held[s]
        if ph > 0:
            total += ph * self._val_p_eth(s, x) // UNIT
    return total


@view
@external
def nav() -> uint256:
    """House NAV in ETH wei (eth_buffer + held P marked at oracle intrinsic / payout)."""
    return self._nav(staticcall IOracleHub(HUB).latest_price(ASSET))


@view
@external
def share_price() -> uint256:
    """ETH-wei NAV per share, 1e18-scaled."""
    supply: uint256 = self.totalSupply
    if supply == 0:
        return UNIT
    return self._nav(staticcall IOracleHub(HUB).latest_price(ASSET)) * UNIT // supply


@view
@external
def intrinsic_n(series: address) -> uint256:
    """Live N intrinsic (ETH wei per 1e18 units), 0 at/below strike."""
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    strike: uint256 = staticcall ISeries(series).STRIKE()
    if x <= strike:
        return 0
    return UNIT - strike * UNIT // x


@view
@external
def quote_buy_n(series: address, amount: uint256) -> uint256:
    """On-chain price preview: ETH cost to buy `amount` N (replaces the off-chain quoter)."""
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    strike: uint256 = staticcall ISeries(series).STRIKE()
    if x <= strike:
        return 0
    intrinsic: uint256 = UNIT - strike * UNIT // x
    price: uint256 = intrinsic * (UNIT + BASE_EDGE) // UNIT
    return amount * price // UNIT


@view
@external
def open_series_count() -> uint256:
    return len(self.open_series)


@view
@internal
def _assert_fresh():
    # Independent, TIGHT freshness on the ETH/USD aggregator (copied from
    # SignedQuoteFiller._assert_fresh). v1 is USD-only, so x = ETH/USD and this single
    # feed fully determines freshness. With no owner to pause, this gate is the only
    # thing between a stale print and a leverage-amplified mis-price.
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


# ------------------------------------------------------------------ write throttles

@internal
def _charge_outflow(amount: uint256):
    if block.timestamp >= self.window_start + OUTFLOW_WINDOW:
        self.window_start = block.timestamp
        self.window_spent = 0
    assert self.window_spent + amount <= OUTFLOW_CAP, "outflow cap"
    self.window_spent += amount


@internal
def _charge_block(amount: uint256):
    if block.number != self.last_write_block:
        self.last_write_block = block.number
        self.block_spent = 0
    assert self.block_spent + amount <= MAX_WRITE_PER_BLOCK, "block cap"
    self.block_spent += amount


# ------------------------------------------------------------------ LP deposit / redeem

@external
@payable
@nonreentrant
def deposit() -> uint256:
    """
    @notice Deposit ETH, receive house shares at live NAV. The ETH sits as free buffer
            until a buyer's buy_n splits it into a written covered position.
    """
    assert msg.value > 0, "zero value"
    assert self.total_deposited + msg.value <= TOTAL_DEPOSIT_CAP, "deposit cap"
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    self._assert_fresh()                              # mark held P at a fresh oracle
    nav_before: uint256 = self._nav(x)
    self.total_deposited += msg.value
    self.eth_buffer += msg.value

    shares: uint256 = 0
    if self.totalSupply == 0:
        assert msg.value > DEAD_SHARES, "initial deposit too small"
        self._mint(DEAD, DEAD_SHARES)                 # donation-immune NAV/share
        shares = msg.value - DEAD_SHARES
    else:
        assert nav_before > 0, "zero nav"
        shares = msg.value * self.totalSupply // nav_before
    assert shares > 0, "zero shares"
    self._mint(msg.sender, shares)
    log Deposited(account=msg.sender, eth_in=msg.value, shares=shares)
    return shares


@external
@nonreentrant
def redeem(shares: uint256):
    """
    @notice Burn shares for an exact pro-rata slice of all holdings: buffered ETH plus
            each open series' P tokens transferred IN-KIND. No oracle anywhere on this
            path, so the exit can never be trapped, mispriced, or griefed; this is
            simultaneously the normal exit and the master spec's force_redeem. The exiting
            LP settles/merges the received P at their own pace.
    """
    assert shares > 0, "zero shares"
    supply: uint256 = self.totalSupply
    self._burn(msg.sender, shares)                    # effects first (CEI)

    eth_out: uint256 = self.eth_buffer * shares // supply
    cur: DynArray[address, MAX_OPEN] = self.open_series
    for s: address in cur:
        pa: uint256 = self.p_held[s] * shares // supply
        if pa > 0:
            self.p_held[s] -= pa
            self.total_p_held -= pa
            assert extcall IERC20(staticcall ISeries(s).P()).transfer(msg.sender, pa), "p transfer"
    if eth_out > 0:
        self.eth_buffer -= eth_out
        raw_call(msg.sender, b"", value=eth_out)
    log Redeemed(account=msg.sender, shares=shares, eth_out=eth_out)


# ------------------------------------------------------------------ the write/sell path

@external
@payable
@nonreentrant
def buy_n(series: address, amount: uint256, max_cost: uint256) -> uint256:
    """
    @notice Buy `amount` N of the tracker's current series. Send exactly the on-chain
            quoted cost (== quote_buy_n). The house funds the split from its buffer net
            of the premium, keeps the P leg, and ships the N to the buyer. WRITE-ONLY:
            there is no buy-back / sell-N warehouse (F-SELLN). msg.value must equal cost
            exactly (no change returned).
    """
    assert amount > 0 and amount <= MAX_FILL, "size"

    # roll-safe vintage: the tracker's pending (during a roll) else active series
    target: address = staticcall ITracker(TRACKER).pending_series()
    if target == empty(address):
        target = staticcall ITracker(TRACKER).active_series()
    assert series == target, "stale series"
    assert not staticcall ISeries(series).settled(), "settled"
    assert block.timestamp + PRE_MATURITY_BUFFER < staticcall ISeries(series).MATURITY(), "near maturity"
    assert staticcall ISeries(series).ASSET() == ASSET, "asset mismatch"

    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    self._assert_fresh()
    strike: uint256 = staticcall ISeries(series).STRIKE()
    assert x > strike * STRIKE_PROXIMITY // UNIT, "near strike"
    intrinsic: uint256 = UNIT - strike * UNIT // x    # > 0 by the band above
    price: uint256 = intrinsic * (UNIT + BASE_EDGE) // UNIT
    cost: uint256 = amount * price // UNIT
    assert cost <= max_cost, "slippage"
    assert msg.value == cost, "bad value"

    # caps + funding (EFFECTS before the external split — strict CEI)
    assert self.total_p_held + amount <= MAX_WRITTEN, "written cap"
    self._charge_outflow(amount)
    self._charge_block(amount)
    # buffer + the just-received premium must cover the full face split
    assert self.eth_buffer + cost >= amount, "underfunded"

    if not self.is_open[series]:
        assert len(self.open_series) < MAX_OPEN, "too many open"
        self.open_series.append(series)
        self.is_open[series] = True
    self.p_held[series] += amount
    self.total_p_held += amount
    self.eth_buffer = self.eth_buffer + cost - amount

    # INTERACTIONS last
    n_token: address = staticcall ISeries(series).N()
    extcall ISeries(series).split(value=amount)       # locks `amount` ETH -> amount P + amount N to self
    assert extcall IERC20(n_token).transfer(msg.sender, amount), "n transfer"

    log BoughtN(buyer=msg.sender, series=series, n_amount=amount, eth_cost=cost, intrinsic_n=intrinsic)
    return cost


# ------------------------------------------------------------------ permissionless keeper

@external
@nonreentrant
def poke():
    """
    @notice Permissionless maintenance, zero privilege over value. For each held series:
            best-effort settle it once matured (skipped if the feed is stale — never
            reverts the whole call), then if settled, redeem the held P for ETH into the
            buffer and drop the series. Bounded by MAX_OPEN. If nobody ever calls this,
            anyone can settle the series directly and redeem() still pays oracle-free from
            the buffer + in-kind P.
    """
    cur: DynArray[address, MAX_OPEN] = self.open_series
    kept: DynArray[address, MAX_OPEN] = []
    for s: address in cur:
        is_settled: bool = staticcall ISeries(s).settled()
        if not is_settled and block.timestamp >= staticcall ISeries(s).MATURITY():
            ok: bool = raw_call(s, method_id("settle()", output_type=Bytes[4]), revert_on_failure=False)
            if ok:
                is_settled = staticcall ISeries(s).settled()
        pa: uint256 = self.p_held[s]
        if is_settled and pa > 0:
            pp: uint256 = staticcall ISeries(s).payout_p()
            self.p_held[s] = 0                        # effects before redeem_p (CEI)
            self.total_p_held -= pa
            extcall ISeries(s).redeem_p(pa)           # ETH -> self via __default__
            got: uint256 = pa * pp // UNIT
            self.eth_buffer += got
            log Harvested(series=s, p_amount=pa, eth_out=got)
            pa = 0
        if pa > 0:
            kept.append(s)
        else:
            self.is_open[s] = False
    self.open_series = kept


@external
@payable
def __default__():
    # accepts ETH from a series' redeem_p callback. Undecorated so the callback does not
    # contend with the @nonreentrant lock held by poke()/redeem() in flight (TrackerDAO pattern).
    pass
