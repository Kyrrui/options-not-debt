# pragma version ==0.4.3
"""
@title PutOptionSeries — the stable-collateralized SHORT (put) primitive: the mirror of OptionSeries
@notice The debt-free leveraged SHORT from docs/handoffs/short-series-spec.md (P1). It is the
        algebraic MIRROR of the deployed call primitive OptionSeries.vy, with two substitutions:
        collateral is an ERC20 stable (USDC v1) instead of native ETH, and the settle comparison is
        flipped so the leveraged leg gains as ETH FALLS.

        * split:  lock 1 stable unit -> mint 1 unit L + 1 unit M
        * merge:  burn 1 L + 1 M     -> unlock 1 stable unit   (any time, oracle-free)
        * settle: at/after maturity, read p = ETH/USD ONCE from the hub:
                      L is owed  min(1, p/K)      stable per unit  (capped / covered-long leg)
                      M is owed  1 - min(1, p/K)  stable per unit  (leveraged SHORT leg)
        * redeem: burn L or M for its settled stable share

        M + L == 1 stable always (payout_m = 1e18 - payout_l, the EXACT remainder), so the system is
        fully collateralized by construction: NO liquidation, NO margin, max loss = premium. M gains
        as ETH falls (a leveraged short), maxing at the full locked stable at p = 0.

@dev    Why stable (not ETH) collateral: a short pays out as ETH falls, so ETH collateral would shrink
        exactly as the obligation grows (the debt/liquidation spiral "options not debt" avoids). A
        non-correlated stable stays fully collateralized to the unit on every path.

        Decimals: legs are 18-dec OptionTokens; the stable may be 6-dec (USDC). split/merge/redeem scale
        on the boundary via _to_stable, ALWAYS rounding DOWN so the contract never pays out more stable
        than was locked (short-series-spec F-DEC). Fee-on-transfer / rebasing collateral is UNSUPPORTED
        (it would break M+L==amount) — deploy only against a plain stable.

        No payable __default__ / no ETH path (F-DEFAULT): collateral is an ERC20, there is no ETH
        callback to accept. Every entrypoint is @nonreentrant with strict CEI (a stable with transfer
        hooks could otherwise re-enter).

        Sepolia testnet, research code, unaudited. The M+L==1 conservation must be Halmos-proved (mirror
        of the P+N==1 chain) before any non-testnet use.
"""

from ethereum.ercs import IERC20

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view

interface IOptionToken:
    def mint(to: address, amount: uint256): nonpayable
    def burn(owner: address, amount: uint256): nonpayable

interface IERC20Detailed:
    def decimals() -> uint8: view

event Split:
    account: indexed(address)
    amount: uint256
    stable_in: uint256

event Merge:
    account: indexed(address)
    amount: uint256
    stable_out: uint256

event Settled:
    price: uint256
    payout_l: uint256

event Redeem:
    account: indexed(address)
    is_l: bool
    amount: uint256
    stable_out: uint256

UNIT: constant(uint256) = 10**18

HUB: public(immutable(address))
ASSET: public(immutable(bytes32))            # OracleHub asset id; empty(bytes32) = USD (v1 requires this)
STABLE: public(immutable(address))           # locked collateral ERC20 (USDC v1)
STABLE_DECIMALS: public(immutable(uint256))  # cached; asserted <= 18
STRIKE: public(immutable(uint256))           # K = ETH/USD, 1e18-scaled (USD per ETH)
MATURITY: public(immutable(uint256))         # unix timestamp
L: public(immutable(address))                # covered / capped-long leg token
M: public(immutable(address))                # leveraged SHORT leg token

settled: public(bool)
settlement_price: public(uint256)            # p at settlement, 1e18-scaled
payout_l: public(uint256)                     # stable wei (1e18-scaled, leg units) owed per 1e18 L


@deploy
def __init__(hub: address, stable: address, strike_k: uint256, maturity: uint256, token_blueprint: address):
    assert hub != empty(address), "zero hub"
    assert stable != empty(address), "zero stable"
    assert strike_k > 0, "zero strike"
    assert maturity > block.timestamp, "past maturity"
    dec: uint256 = convert(staticcall IERC20Detailed(stable).decimals(), uint256)
    assert dec <= 18, "decimals"
    HUB = hub
    ASSET = empty(bytes32)                    # USD-only v1 (single ETH/USD feed)
    STABLE = stable
    STABLE_DECIMALS = dec
    STRIKE = strike_k
    MATURITY = maturity
    # symbology mirrors OptionSeries: "M-USD-2000-260710" / "L-USD-2000-260710"
    terms: String[512] = concat("USD-", self._strike_str(strike_k), "-", self._date_str(maturity))
    L = create_from_blueprint(
        token_blueprint, concat("Covered L ", terms), concat("L-", terms), self, code_offset=3
    )
    M = create_from_blueprint(
        token_blueprint, concat("Short M ", terms), concat("M-", terms), self, code_offset=3
    )


@internal
@view
def _to_stable(legs: uint256) -> uint256:
    """1e18 leg units -> stable token units, rounding DOWN (contract never overpays; F-DEC)."""
    return legs * 10**STABLE_DECIMALS // UNIT


@internal
@pure
def _pad2(x: uint256) -> String[79]:
    if x < 10:
        return concat("0", uint2str(x))
    return uint2str(x)


@internal
@pure
def _date_str(ts: uint256) -> String[240]:
    """YYMMDD from a unix timestamp (Howard Hinnant's civil-from-days)."""
    z: uint256 = ts // 86400 + 719468
    era: uint256 = z // 146097
    doe: uint256 = z % 146097
    yoe: uint256 = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y: uint256 = yoe + era * 400
    doy: uint256 = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp: uint256 = (5 * doy + 2) // 153
    d: uint256 = doy - (153 * mp + 2) // 5 + 1
    m: uint256 = mp + 3
    if mp >= 10:
        m = mp - 9
    if m <= 2:
        y += 1
    return concat(self._pad2(y % 100), self._pad2(m), self._pad2(d))


@internal
@pure
def _strike_str(s: uint256) -> String[160]:
    """Strike (1e18-scaled) with trader-grade precision: integers above 100, three decimals below."""
    ip: uint256 = s // 10**18
    if ip >= 100:
        return uint2str(ip)
    frac: uint256 = (s % 10**18) // 10**15
    if frac < 10:
        return concat(uint2str(ip), ".00", uint2str(frac))
    if frac < 100:
        return concat(uint2str(ip), ".0", uint2str(frac))
    return concat(uint2str(ip), ".", uint2str(frac))


@external
@nonreentrant
def split(amount: uint256):
    """
    @notice Lock _to_stable(amount) of the stable, mint `amount` L and `amount` M to the caller.
            Caller must approve the stable first. Only before maturity.
    """
    assert amount > 0, "zero amount"
    assert block.timestamp < MATURITY, "matured"
    stable_in: uint256 = self._to_stable(amount)
    assert stable_in > 0, "dust"                          # don't mint legs for 0 locked stable
    assert extcall IERC20(STABLE).transferFrom(msg.sender, self, stable_in), "pull"
    extcall IOptionToken(L).mint(msg.sender, amount)
    extcall IOptionToken(M).mint(msg.sender, amount)
    log Split(account=msg.sender, amount=amount, stable_in=stable_in)


@external
@nonreentrant
def merge(amount: uint256):
    """
    @notice Burn `amount` L and `amount` M, receive _to_stable(amount) of the stable back.
            Allowed at ANY time (M + L == 1 stable before and after settlement), oracle-free.
    """
    assert amount > 0, "zero amount"
    stable_out: uint256 = self._to_stable(amount)
    assert stable_out > 0, "dust"                         # symmetric with split; never burn legs for 0 stable
    extcall IOptionToken(L).burn(msg.sender, amount)      # effects (burns) before the transfer (CEI)
    extcall IOptionToken(M).burn(msg.sender, amount)
    assert extcall IERC20(STABLE).transfer(msg.sender, stable_out), "transfer"
    log Merge(account=msg.sender, amount=amount, stable_out=stable_out)


@external
@nonreentrant
def settle():
    """
    @notice One-shot lazy settlement. Callable by anyone at/after MATURITY while the feed is fresh.
            Pins the CAPPED leg L (worth 1 when ETH at/above K) and gives M the exact remainder:
                payout_l = min(1e18, p*1e18/K)   [stable-leg-units per 1e18 L]
                payout_m = 1e18 - payout_l        (read in redeem_m)
            so payout_m + payout_l == 1e18 with zero drift (no bad debt).
    """
    assert block.timestamp >= MATURITY, "not matured"
    assert not self.settled, "already settled"
    p: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    assert p > 0, "zero price"
    pl: uint256 = UNIT
    if p < STRIKE:
        pl = p * UNIT // STRIKE
    self.settlement_price = p
    self.payout_l = pl
    self.settled = True
    log Settled(price=p, payout_l=pl)


@external
@nonreentrant
def redeem_l(amount: uint256):
    """@notice Burn L after settlement for _to_stable(amount * payout_l / 1e18) of the stable."""
    assert self.settled, "not settled"
    assert amount > 0, "zero amount"
    extcall IOptionToken(L).burn(msg.sender, amount)
    stable_out: uint256 = self._to_stable(amount * self.payout_l // UNIT)
    if stable_out > 0:
        assert extcall IERC20(STABLE).transfer(msg.sender, stable_out), "transfer"
    log Redeem(account=msg.sender, is_l=True, amount=amount, stable_out=stable_out)


@external
@nonreentrant
def redeem_m(amount: uint256):
    """@notice Burn M after settlement for _to_stable(amount * (1e18 - payout_l) / 1e18) of the stable."""
    assert self.settled, "not settled"
    assert amount > 0, "zero amount"
    extcall IOptionToken(M).burn(msg.sender, amount)
    stable_out: uint256 = self._to_stable(amount * (UNIT - self.payout_l) // UNIT)
    if stable_out > 0:
        assert extcall IERC20(STABLE).transfer(msg.sender, stable_out), "transfer"
    log Redeem(account=msg.sender, is_l=False, amount=amount, stable_out=stable_out)
