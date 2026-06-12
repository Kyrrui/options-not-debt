# pragma version ==0.4.3
"""
@title OptionSeries — the P/N option pair primitive (options, not debt)
@notice Implements the base building block from ethresear.ch t/25036
        "Building index-tracking assets on top of options instead of debt":

        * split:  lock 1 wei ETH  -> mint 1 wei-unit P + 1 wei-unit N
        * merge:  burn 1 P + 1 N  -> unlock 1 wei ETH   (any time)
        * settle: at/after maturity M, pull the index x ONCE from the
                  oracle hub (x = ETH price in asset units):
                      P is owed  min(1, S/x)      ETH per unit
                      N is owed  1 - min(1, S/x)  ETH per unit
        * redeem: burn P or N for its settled ETH share

        P + N == 1 ETH always, so the system is fully collateralized by
        construction and there is NO liquidation anywhere. A deep
        in-the-money P (S far below x) is worth ~S asset units: the
        index-tracking leg. N is the leveraged-long-ETH leg.
@dev    Settlement is lazy and one-shot ("slow oracle"): anyone may call
        settle() once block.timestamp >= MATURITY; the call succeeds only
        while the Chainlink feeds are fresh, and the first valid call
        fixes the settlement index forever.
"""

struct FeedConfig:
    aggregator: address
    heartbeat: uint256
    symbol: String[32]

interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
    def feeds(asset: bytes32) -> FeedConfig: view

interface IOptionToken:
    def mint(to: address, amount: uint256): nonpayable
    def burn(owner: address, amount: uint256): nonpayable

event Split:
    account: indexed(address)
    amount: uint256

event Merge:
    account: indexed(address)
    amount: uint256

event Settled:
    index: uint256
    payout_p: uint256

event Redeem:
    account: indexed(address)
    is_p: bool
    amount: uint256
    eth_out: uint256

UNIT: constant(uint256) = 10**18

HUB: public(immutable(address))
ASSET: public(immutable(bytes32))         # OracleHub asset id; empty(bytes32) = USD
STRIKE: public(immutable(uint256))        # asset units per ETH, 1e18-scaled
MATURITY: public(immutable(uint256))      # unix timestamp
P: public(immutable(address))             # tracking leg token
N: public(immutable(address))             # leveraged-ETH leg token

settled: public(bool)
settlement_index: public(uint256)         # x at settlement, 1e18-scaled
payout_p: public(uint256)                 # wei owed per 1e18 units of P


@deploy
def __init__(hub: address, asset: bytes32, strike: uint256, maturity: uint256, token_blueprint: address):
    assert hub != empty(address), "zero hub"
    assert strike > 0, "zero strike"
    assert maturity > block.timestamp, "past maturity"
    HUB = hub
    ASSET = asset
    STRIKE = strike
    MATURITY = maturity
    # trader-legible symbology: each leg's wallet symbol carries its full
    # contract terms (leg, asset, strike, expiry as YYMMDD), e.g.
    # "P-USD-1250-260710" — vintages from different rolls never collide
    sym: String[32] = "USD"
    if asset != empty(bytes32):
        cfg: FeedConfig = staticcall IOracleHub(hub).feeds(asset)
        if len(cfg.symbol) != 0:
            sym = cfg.symbol
        else:
            sym = "ASSET"
    terms: String[512] = concat(sym, "-", self._strike_str(strike), "-", self._date_str(maturity))
    P = create_from_blueprint(
        token_blueprint,
        concat("Tracking P ", terms),
        concat("P-", terms),
        self,
        code_offset=3,
    )
    N = create_from_blueprint(
        token_blueprint,
        concat("Leverage N ", terms),
        concat("N-", terms),
        self,
        code_offset=3,
    )


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
    """Strike (1e18-scaled asset units per ETH) with trader-grade precision:
    integers above 100, three decimals below."""
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
@payable
@nonreentrant
def split():
    """
    @notice Lock msg.value ETH, mint msg.value of P and msg.value of N
            to the caller. Only before maturity.
    """
    assert msg.value > 0, "zero value"
    assert block.timestamp < MATURITY, "matured"
    extcall IOptionToken(P).mint(msg.sender, msg.value)
    extcall IOptionToken(N).mint(msg.sender, msg.value)
    log Split(account=msg.sender, amount=msg.value)


@external
@nonreentrant
def merge(amount: uint256):
    """
    @notice Burn `amount` P and `amount` N, receive `amount` ETH back.
            Allowed at ANY time (P + N == 1 ETH by construction, before
            and after settlement), so exit never depends on an oracle.
    """
    assert amount > 0, "zero amount"
    extcall IOptionToken(P).burn(msg.sender, amount)
    extcall IOptionToken(N).burn(msg.sender, amount)
    raw_call(msg.sender, b"", value=amount)
    log Merge(account=msg.sender, amount=amount)


@external
@nonreentrant
def settle():
    """
    @notice One-shot lazy settlement. Callable by anyone at/after maturity
            while the oracle feeds are fresh. Fixes:
                payout_p = min(1e18, STRIKE * 1e18 / x)   [wei per 1e18 P]
            N's payout is the exact remainder, so conservation holds with
            zero drift: payout_p + payout_n == 1e18.
    """
    assert block.timestamp >= MATURITY, "not matured"
    assert not self.settled, "already settled"
    x: uint256 = staticcall IOracleHub(HUB).latest_price(ASSET)
    assert x > 0, "zero index"
    pp: uint256 = UNIT
    if x > STRIKE:
        pp = STRIKE * UNIT // x
    self.settlement_index = x
    self.payout_p = pp
    self.settled = True
    log Settled(index=x, payout_p=pp)


@external
@nonreentrant
def redeem_p(amount: uint256):
    """@notice Burn P after settlement for amount * payout_p / 1e18 wei."""
    assert self.settled, "not settled"
    assert amount > 0, "zero amount"
    extcall IOptionToken(P).burn(msg.sender, amount)
    eth_out: uint256 = amount * self.payout_p // UNIT
    if eth_out > 0:
        raw_call(msg.sender, b"", value=eth_out)
    log Redeem(account=msg.sender, is_p=True, amount=amount, eth_out=eth_out)


@external
@nonreentrant
def redeem_n(amount: uint256):
    """@notice Burn N after settlement for amount * (1e18 - payout_p) / 1e18 wei."""
    assert self.settled, "not settled"
    assert amount > 0, "zero amount"
    extcall IOptionToken(N).burn(msg.sender, amount)
    eth_out: uint256 = amount * (UNIT - self.payout_p) // UNIT
    if eth_out > 0:
        raw_call(msg.sender, b"", value=eth_out)
    log Redeem(account=msg.sender, is_p=False, amount=amount, eth_out=eth_out)
