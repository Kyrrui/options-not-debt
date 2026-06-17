# pragma version ==0.4.3
"""
@title GimbalShortVault — the immutable, ownerless crowd-house for debt-free leveraged SHORTS (Sepolia v1)
@notice The USDC/put MIRROR of GimbalSimpleVault. Crowd LPs deposit USDC into a pool that WRITES and
        SELLS the M (leveraged-short) leg of a fixed dated PutOptionSeries at an ON-CHAIN formulaic
        price, keeping the L (covered) leg. There is:

          * NO owner, NO admin, NO pause, NO upgrade, NO withdraw — every knob is a ctor immutable; the
            only USDC outflow is an LP redeeming its OWN shares (oracle-free, in-kind) or a settled-series
            harvest.
          * NO signer — the price is computed on-chain: intrinsic_m * (1 + BASE_EDGE), where
            intrinsic_m = max(0, 1 - p/K), p = ETH/USD. Wider/MEV-exposed vs a signer; the accepted cost
            of ownerlessness, bounded by tight staleness + per-block/per-window write caps.
          * NO roll machinery — a put series is standalone dated (it never rolls), so the vault writes ONE
            fixed SERIES until maturity, then poke() settles + harvests it. Much simpler than the call
            vault (single series, single l_held, no DynArray).

        The vault holds ONLY USDC + L, so its NAV (usdc_buffer + l_held*val_l) and oracle-free in-kind
        redeem are the same proven shapes as GimbalSimpleVault / TrackerDAO. It is "long L" = it has sold
        the leveraged short, so it PROFITS as ETH rises/holds and loses (capped, pre-funded, never
        liquidated) as ETH falls — the mirror of the call house.

@dev    Accounting: internal in 18-dec "stable units" (1e18 = 1 USDC). The external token is the stable's
        native decimals (USDC = 6). buffer is stored as buffer18 and ALWAYS equals (pool USDC) * SCALE
        where SCALE = 10**(18 - stable_decimals); every USDC movement is computed in native decimals,
        rounding DOWN on the way out, and the buffer adjusted by that * SCALE (so it never drifts from the
        real balance). Shares are SOULBOUND (mint/burn only).

        DELIBERATELY SIMPLIFIED FOR SEPOLIA (see docs/handoffs/short-series-spec.md + the call vault's
        MAINNET CHECKLIST): single dated series (no menu/roll); junior-only; live-NAV deposit (no epochs);
        write-only (M buyers exit via the series' redeem_m / merge, or a secondary market). Immutable BY
        CHOICE — a bug's only recourse is redeploy-v2 + LP migration via the always-open redeem().

        Sepolia testnet, research code, unaudited. Not a yield product; the house can lose principal
        (capped at deposit, never liquidated). Your counterparty is an immutable ownerless on-chain vault.
"""

from ethereum.ercs import IERC20

interface ISeries:
    def M() -> address: view
    def L() -> address: view
    def STRIKE() -> uint256: view
    def MATURITY() -> uint256: view
    def ASSET() -> bytes32: view
    def STABLE() -> address: view
    def settled() -> bool: view
    def payout_l() -> uint256: view
    def split(amount: uint256): nonpayable
    def redeem_l(amount: uint256): nonpayable

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
    def ETH_USD_FEED() -> address: view

interface AggregatorV3:
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

interface IERC20Detailed:
    def decimals() -> uint8: view


event Transfer:                          # share mint/burn (soulbound: from/to zero only)
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Deposited:
    account: indexed(address)
    usdc_in: uint256
    shares: uint256

event Redeemed:
    account: indexed(address)
    shares: uint256
    usdc_out: uint256
    l_out: uint256

event BoughtM:
    buyer: indexed(address)
    m_amount: uint256
    usdc_cost: uint256
    intrinsic_m: uint256

event Harvested:
    l_amount: uint256
    usdc_out: uint256


UNIT: constant(uint256) = 10**18
DEAD: constant(address) = 0x000000000000000000000000000000000000dEaD
DEAD_SHARES: constant(uint256) = 10**3
MAX_MIN_EDGE: constant(uint256) = 10**18 // 5     # 20% sanity ceiling on BASE_EDGE
MIN_STALENESS: constant(uint256) = 30
MAX_STALENESS: constant(uint256) = 3600
SP_FLOOR: constant(uint256) = 10**18 // 2         # strike_proximity floor (flipped band is a sub-UNIT ceiling)

NAME: public(constant(String[32])) = "Gimbal Short House Share"
SYMBOL: public(constant(String[16])) = "hsSHORT"
DECIMALS: public(constant(uint8)) = 18

SERIES: public(immutable(address))                # the fixed dated PutOptionSeries this house writes
HUB: public(immutable(address))
STABLE: public(immutable(address))                # collateral (USDC v1)
SCALE: public(immutable(uint256))                 # 10**(18 - stable_decimals); 1e12 for USDC
M_TOKEN: public(immutable(address))               # SERIES.M() cached
L_TOKEN: public(immutable(address))               # SERIES.L() cached
STRIKE: public(immutable(uint256))                # K = ETH/USD, cached from SERIES
BASE_EDGE: public(immutable(uint256))             # spread over intrinsic_m the house sells at
DESK_MAX_STALENESS: public(immutable(uint256))    # tight ETH/USD freshness bound (s)
PRE_MATURITY_BUFFER: public(immutable(uint256))   # refuse writes within this of MATURITY
STRIKE_PROXIMITY: public(immutable(uint256))      # FLIPPED band: refuse p >= K*STRIKE_PROXIMITY/1e18 (sub-UNIT)
MAX_FILL: public(immutable(uint256))              # per-fill M-units cap (1e18)
MAX_WRITTEN: public(immutable(uint256))           # cap on l_held (face) = capital-at-risk bound
OUTFLOW_WINDOW: public(immutable(uint256))
OUTFLOW_CAP: public(immutable(uint256))           # max M-face written per window
MAX_WRITE_PER_BLOCK: public(immutable(uint256))
TOTAL_DEPOSIT_CAP: public(immutable(uint256))     # gross deposit cap (18-dec units)

# ---- soulbound shares ----
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])

# ---- pools ----
buffer: public(uint256)                           # free USDC, 18-dec normalized (== pool USDC * SCALE)
l_held: public(uint256)                           # L units held for SERIES (18-dec) = the risk meter
total_deposited: public(uint256)                  # gross deposited, 18-dec (for the cap)

# ---- write throttles ----
window_start: uint256
window_spent: uint256
last_write_block: uint256
block_spent: uint256


@deploy
def __init__(
    series: address,
    hub: address,
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
    assert series != empty(address), "zero series"
    assert hub != empty(address), "zero hub"
    assert staticcall ISeries(series).ASSET() == empty(bytes32), "v1 USD-only"
    assert not (staticcall ISeries(series).settled()), "settled series"
    assert staticcall ISeries(series).MATURITY() > block.timestamp, "matured series"
    stable: address = staticcall ISeries(series).STABLE()
    dec: uint256 = convert(staticcall IERC20Detailed(stable).decimals(), uint256)
    assert dec <= 18, "decimals"
    assert base_edge > 0 and base_edge <= MAX_MIN_EDGE, "base_edge"
    assert desk_max_staleness >= MIN_STALENESS and desk_max_staleness <= MAX_STALENESS, "staleness"
    assert pre_maturity_buffer > 0, "buffer"
    # FLIPPED band: M is worthless at/above K, so the no-trade band is a sub-UNIT CEILING (refuse p>=K*prox)
    assert strike_proximity >= SP_FLOOR and strike_proximity < UNIT, "proximity"
    assert outflow_window > 0, "window"
    assert max_fill > 0, "max_fill"
    assert max_written > 0, "max_written"
    assert outflow_cap > 0, "outflow_cap"
    assert max_write_per_block > 0, "block cap"
    assert total_deposit_cap > 0, "deposit cap"

    SERIES = series
    HUB = hub
    STABLE = stable
    SCALE = 10 ** (18 - dec)
    M_TOKEN = staticcall ISeries(series).M()
    L_TOKEN = staticcall ISeries(series).L()
    STRIKE = staticcall ISeries(series).STRIKE()
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
    self.balanceOf[owner] -= amount
    self.totalSupply -= amount
    log Transfer(sender=owner, receiver=empty(address), value=amount)


# ------------------------------------------------------------------ pricing / NAV

@view
@internal
def _val_l(p: uint256) -> uint256:
    """Value of 1e18 units of L, 1e18-scaled stable: payout_l once settled, else min(1, p/K)."""
    if staticcall ISeries(SERIES).settled():
        return staticcall ISeries(SERIES).payout_l()
    return min(UNIT, p * UNIT // STRIKE)


@view
@internal
def _nav(p: uint256) -> uint256:
    """House NAV in 18-dec stable units (usdc_buffer + held-L marked at oracle/payout)."""
    total: uint256 = self.buffer
    if self.l_held > 0:
        total += self.l_held * self._val_l(p) // UNIT
    return total


@view
@external
def nav() -> uint256:
    """NAV in 18-dec stable units (1e18 = 1 USDC). Divide by SCALE for USDC display."""
    return self._nav(staticcall IOracleHub(HUB).latest_price(empty(bytes32)))


@view
@external
def share_price() -> uint256:
    """18-dec NAV per share, 1e18-scaled."""
    supply: uint256 = self.totalSupply
    if supply == 0:
        return UNIT
    return self._nav(staticcall IOracleHub(HUB).latest_price(empty(bytes32))) * UNIT // supply


@view
@external
def intrinsic_m() -> uint256:
    """Live M intrinsic (1e18-scaled stable per 1e18 M), 0 at/above strike."""
    p: uint256 = staticcall IOracleHub(HUB).latest_price(empty(bytes32))
    if p >= STRIKE:
        return 0
    return UNIT - p * UNIT // STRIKE


@view
@external
def quote_buy_m(amount: uint256) -> uint256:
    """On-chain price preview: USDC (native decimals) cost to buy `amount` M (1e18 units)."""
    p: uint256 = staticcall IOracleHub(HUB).latest_price(empty(bytes32))
    if p >= STRIKE:
        return 0
    intrinsic: uint256 = UNIT - p * UNIT // STRIKE
    price: uint256 = intrinsic * (UNIT + BASE_EDGE) // UNIT
    return amount * price // UNIT // SCALE


@view
@internal
def _assert_fresh():
    # tight ETH/USD freshness, copied from SignedQuoteFiller._assert_fresh (incl. F5 round-completeness).
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
@nonreentrant
def deposit(amount: uint256) -> uint256:
    """
    @notice Deposit `amount` USDC (native 6-dec), receive house shares at live NAV. Approve USDC first.
            The USDC sits as free buffer until a buyer's buy_m splits it into a written covered position.
    """
    assert amount > 0, "zero value"
    amt18: uint256 = amount * SCALE
    assert self.total_deposited + amt18 <= TOTAL_DEPOSIT_CAP, "deposit cap"
    p: uint256 = staticcall IOracleHub(HUB).latest_price(empty(bytes32))
    self._assert_fresh()                              # mark held L at a fresh oracle
    nav_before: uint256 = self._nav(p)

    # pull the USDC (interaction), then credit (CEI is preserved: shares are computed off nav_before)
    assert extcall IERC20(STABLE).transferFrom(msg.sender, self, amount), "pull"
    self.total_deposited += amt18
    self.buffer += amt18

    shares: uint256 = 0
    if self.totalSupply == 0:
        assert amt18 > DEAD_SHARES, "initial deposit too small"
        self._mint(DEAD, DEAD_SHARES)
        shares = amt18 - DEAD_SHARES
    else:
        assert nav_before > 0, "zero nav"
        shares = amt18 * self.totalSupply // nav_before
    assert shares > 0, "zero shares"
    self._mint(msg.sender, shares)
    log Deposited(account=msg.sender, usdc_in=amount, shares=shares)
    return shares


@external
@nonreentrant
def redeem(shares: uint256):
    """
    @notice Burn shares for a strict pro-rata slice of buffered USDC plus held L tokens transferred
            IN-KIND. No oracle on this path — never trapped or mispriced. The exiting LP settles/merges
            the received L at their own pace. This is simultaneously the normal exit and force_redeem.
    """
    assert shares > 0, "zero shares"
    supply: uint256 = self.totalSupply
    self._burn(msg.sender, shares)                    # effects first (CEI)

    out6: uint256 = (self.buffer * shares // supply) // SCALE
    la: uint256 = self.l_held * shares // supply
    if la > 0:
        self.l_held -= la
        assert extcall IERC20(L_TOKEN).transfer(msg.sender, la), "l transfer"
    if out6 > 0:
        self.buffer -= out6 * SCALE
        assert extcall IERC20(STABLE).transfer(msg.sender, out6), "usdc transfer"
    log Redeemed(account=msg.sender, shares=shares, usdc_out=out6, l_out=la)


# ------------------------------------------------------------------ the write/sell path

@external
@nonreentrant
def buy_m(series: address, amount: uint256, max_cost: uint256) -> uint256:
    """
    @notice Buy `amount` M (1e18 units, the leveraged short) of this house's series. Approve the vault
            for the quoted USDC cost first. The house funds the split from its buffer net of the premium,
            keeps the L leg, and ships the M to the buyer. WRITE-ONLY (no buy-back / sell-M warehouse).
    """
    assert amount > 0 and amount <= MAX_FILL, "size"
    assert series == SERIES, "wrong series"
    assert not (staticcall ISeries(SERIES).settled()), "settled"
    assert block.timestamp + PRE_MATURITY_BUFFER < staticcall ISeries(SERIES).MATURITY(), "near maturity"

    p: uint256 = staticcall IOracleHub(HUB).latest_price(empty(bytes32))
    self._assert_fresh()
    # FLIPPED near-strike band: M is worthless at/above K; refuse the at/above-K end (sub-UNIT proximity)
    assert p < STRIKE * STRIKE_PROXIMITY // UNIT, "near strike"
    intrinsic: uint256 = UNIT - p * UNIT // STRIKE    # > 0 by the band above
    price: uint256 = intrinsic * (UNIT + BASE_EDGE) // UNIT
    cost6: uint256 = amount * price // UNIT // SCALE
    assert cost6 > 0, "dust"
    assert cost6 <= max_cost, "slippage"

    split_cost6: uint256 = amount // SCALE             # == SERIES._to_stable(amount), the USDC the series locks
    assert split_cost6 > 0, "dust"                     # don't attempt a 0-collateral split (the series would revert)

    # caps + funding (EFFECTS before the external calls — strict CEI)
    assert self.l_held + amount <= MAX_WRITTEN, "written cap"
    self._charge_outflow(amount)
    self._charge_block(amount)
    # pool USDC (buffer//SCALE) plus the incoming premium must cover the full face split
    assert self.buffer // SCALE + cost6 >= split_cost6, "underfunded"

    self.l_held += amount
    self.buffer = self.buffer + cost6 * SCALE - split_cost6 * SCALE

    # INTERACTIONS last
    assert extcall IERC20(STABLE).transferFrom(msg.sender, self, cost6), "pull premium"
    assert extcall IERC20(STABLE).approve(SERIES, split_cost6), "approve"
    extcall ISeries(SERIES).split(amount)             # pulls split_cost6 USDC -> amount L + amount M to self
    assert extcall IERC20(M_TOKEN).transfer(msg.sender, amount), "m transfer"

    log BoughtM(buyer=msg.sender, m_amount=amount, usdc_cost=cost6, intrinsic_m=intrinsic)
    return cost6


# ------------------------------------------------------------------ permissionless keeper

@external
@nonreentrant
def poke():
    """
    @notice Permissionless maintenance, zero privilege over value. Once the series matures: best-effort
            settle it (skipped if the feed is stale — never reverts the whole call), then if settled,
            redeem the held L for USDC into the buffer. If nobody calls this, anyone can settle the series
            directly and redeem() still pays oracle-free from the buffer + in-kind L.
    """
    is_settled: bool = staticcall ISeries(SERIES).settled()
    if not is_settled and block.timestamp >= staticcall ISeries(SERIES).MATURITY():
        ok: bool = raw_call(SERIES, method_id("settle()", output_type=Bytes[4]), revert_on_failure=False)
        if ok:
            is_settled = staticcall ISeries(SERIES).settled()
    la: uint256 = self.l_held
    if is_settled and la > 0:
        pl: uint256 = staticcall ISeries(SERIES).payout_l()
        got6: uint256 = (la * pl // UNIT) // SCALE     # == SERIES._to_stable(la*payout_l//UNIT)
        self.l_held = 0                                # effects before redeem_l (CEI)
        extcall ISeries(SERIES).redeem_l(la)           # USDC -> self
        self.buffer += got6 * SCALE
        log Harvested(l_amount=la, usdc_out=got6)
