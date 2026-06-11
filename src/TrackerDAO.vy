# pragma version ==0.4.3
"""
@title TrackerDAO — fully-automated wrapper offering an on-chain soft peg
@notice The "wrapper DAO" from ethresear.ch t/25036: a fully-automated
        onchain DAO — ALL RULES, NO VOTING, NO AI — that wraps the P/N
        option system and issues an ERC20 share token soft-pegged to one
        unit of the tracked RWA (USD, XAU, equities... anything with a
        Chainlink USD feed). The backing collateral is always, only, ETH.

        The DAO holds exclusively the index-tracking P leg (deep
        in-the-money short-put payoff). It NEVER holds the leveraged N
        leg: per the post, speculators and market makers hold N.

        Rules (all parameterized at deploy, immutable forever):

        * deposit():   ETH in -> split at the current target series. The
                       DAO keeps P (minting shares at NAV), and hands the
                       freshly minted N straight back to the depositor —
                       the depositor keeps or sells the leverage leg.
        * redeem():    burn shares -> exact pro-rata slice of the DAO's P
                       tokens and buffered ETH. No oracle on the exit
                       path, so exits cannot be oracle-griefed.
        * sync():      keeper entry point, callable by anyone. Creates
                       the initial series; starts a roll when the index
                       nears the strike (x*1e18 < S*ROLL_TRIGGER) or
                       maturity is near; opportunistically settles;
                       harvests settled series back to ETH; finalizes
                       completed rolls.
        * fill_roll(): gradual rotation auction (Czar102's "predictable
                       rolling"): arbitrageurs deliver new-series P and
                       take old-series P at a rate that improves linearly
                       with time, bounded by MAX_EDGE. One-sided market
                       making — no AMM slippage spiral.
        * sell_p():    the re-entry auction: anyone sells target-series P
                       to the DAO for buffered ETH at oracle intrinsic
                       value, with the DAO's bid ramping from a discount
                       to a premium over AUCTION_DUR. This is how
                       harvested ETH rotates back into P exposure.

        Worst case (roll never filled): the old series settles via the
        slow one-shot oracle and sync() harvests it to ETH — tracking
        drift, never bad debt, never liquidation.
"""

from ethereum.ercs import IERC20

implements: IERC20

interface ISeries:
    def STRIKE() -> uint256: view
    def MATURITY() -> uint256: view
    def P() -> address: view
    def N() -> address: view
    def settled() -> bool: view
    def payout_p() -> uint256: view
    def split(): payable
    def settle(): nonpayable
    def redeem_p(amount: uint256): nonpayable

interface IOracleHub:
    def latest_price(asset: address) -> uint256: view

interface IFactory:
    def create_series(asset: address, strike: uint256, maturity: uint256) -> address: nonpayable

# ---------------------------------------------------------------- ERC20 ----

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

# ------------------------------------------------------------------ DAO ----

event Deposit:
    account: indexed(address)
    series: indexed(address)
    eth_in: uint256
    shares: uint256

event Withdraw:
    account: indexed(address)
    shares: uint256
    eth_out: uint256

event RollStarted:
    old_series: indexed(address)
    new_series: indexed(address)
    new_strike: uint256
    new_maturity: uint256

event RollFilled:
    filler: indexed(address)
    old_p_out: uint256
    new_p_in: uint256

event RollFinalized:
    series: indexed(address)

event Harvested:
    series: indexed(address)
    eth_out: uint256

event PBought:
    seller: indexed(address)
    series: indexed(address)
    amount: uint256
    eth_paid: uint256

UNIT: constant(uint256) = 10**18
DEAD: constant(address) = 0x000000000000000000000000000000000000dEaD
DEAD_SHARES: constant(uint256) = 10**3

NAME: public(immutable(String[64]))
SYMBOL: public(immutable(String[32]))
DECIMALS: public(constant(uint8)) = 18

HUB: public(immutable(address))
FACTORY: public(immutable(address))
ASSET: public(immutable(address))           # Chainlink feed id; address(0) = USD

TERM: public(immutable(uint256))            # lifetime of each series
ROLL_WINDOW: public(immutable(uint256))     # roll this long before maturity
ROLL_TRIGGER: public(immutable(uint256))    # roll when x*1e18 < S*ROLL_TRIGGER (e.g. 1.5e18)
STRIKE_RATIO: public(immutable(uint256))    # new strike = x * STRIKE_RATIO / 1e18 (e.g. 0.5e18)
AUCTION_DUR: public(immutable(uint256))     # ramp time for both auctions
MAX_EDGE: public(immutable(uint256))        # 1e18-scaled max counterparty edge at ramp end

totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

active_series: public(address)
pending_series: public(address)
roll_started: public(uint256)

eth_buffer: public(uint256)                 # tracked ETH (donations don't count)
p_bal: public(HashMap[address, uint256])    # tracked P per series
buy_started: public(uint256)                # sell_p auction ramp anchor


@deploy
def __init__(
    name: String[64],
    symbol: String[32],
    hub: address,
    factory: address,
    asset: address,
    term: uint256,
    roll_window: uint256,
    roll_trigger: uint256,
    strike_ratio: uint256,
    auction_dur: uint256,
    max_edge: uint256,
):
    assert hub != empty(address) and factory != empty(address), "zero address"
    assert term > roll_window and roll_window > 0, "bad term"
    assert term >= 2 * 3600, "term too short"
    assert roll_trigger >= UNIT and roll_trigger <= 4 * UNIT, "bad trigger"
    assert strike_ratio > 0 and strike_ratio < UNIT, "bad ratio"
    assert auction_dur >= 600 and auction_dur <= 30 * 24 * 3600, "bad auction"
    assert max_edge < UNIT // 5, "bad edge"
    NAME = name
    SYMBOL = symbol
    HUB = hub
    FACTORY = factory
    ASSET = asset
    TERM = term
    ROLL_WINDOW = roll_window
    ROLL_TRIGGER = roll_trigger
    STRIKE_RATIO = strike_ratio
    AUCTION_DUR = auction_dur
    MAX_EDGE = max_edge


# --------------------------------------------------------------- ERC20 -----


@external
def transfer(to: address, amount: uint256) -> bool:
    assert to != empty(address), "zero receiver"
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[to] += amount
    log Transfer(sender=msg.sender, receiver=to, value=amount)
    return True


@external
def transferFrom(owner: address, to: address, amount: uint256) -> bool:
    assert to != empty(address), "zero receiver"
    allowed: uint256 = self.allowance[owner][msg.sender]
    if allowed != max_value(uint256):
        self.allowance[owner][msg.sender] = allowed - amount
    self.balanceOf[owner] -= amount
    self.balanceOf[to] += amount
    log Transfer(sender=owner, receiver=to, value=amount)
    return True


@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    log Approval(owner=msg.sender, spender=spender, value=amount)
    return True


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


# ------------------------------------------------------------- pricing -----


@view
@internal
def _x() -> uint256:
    return staticcall IOracleHub(HUB).latest_price(ASSET)


@view
@internal
def _val_p(series: address, x: uint256) -> uint256:
    """Intrinsic value of 1e18 units of P, in asset units (1e18-scaled)."""
    if staticcall ISeries(series).settled():
        return (staticcall ISeries(series).payout_p()) * x // UNIT
    return min(x, staticcall ISeries(series).STRIKE())


@view
@internal
def _nav(x: uint256) -> uint256:
    """Total DAO value in asset units (1e18-scaled)."""
    total: uint256 = self.eth_buffer * x // UNIT
    a: address = self.active_series
    p: address = self.pending_series
    for s: address in [a, p]:
        if s != empty(address):
            total += self.p_bal[s] * self._val_p(s, x) // UNIT
    return total


@view
@external
def nav() -> uint256:
    return self._nav(self._x())


@view
@external
def share_price() -> uint256:
    """Asset units per share, 1e18-scaled. Soft peg target: 1e18."""
    supply: uint256 = self.totalSupply
    if supply == 0:
        return UNIT
    return self._nav(self._x()) * UNIT // supply


@view
@internal
def _needs_roll(series: address, x: uint256) -> bool:
    s: uint256 = staticcall ISeries(series).STRIKE()
    m: uint256 = staticcall ISeries(series).MATURITY()
    return x * UNIT < s * ROLL_TRIGGER or block.timestamp + ROLL_WINDOW >= m


@view
@internal
def _target() -> address:
    """Series new exposure flows into: pending during a roll, else active."""
    p: address = self.pending_series
    if p != empty(address):
        return p
    return self.active_series


# ------------------------------------------------------------ deposits -----


@external
@payable
@nonreentrant
def deposit() -> uint256:
    """
    @notice Deposit ETH, receive soft-peg shares at NAV. The ETH is split
            at the target series; the DAO keeps P, and the leveraged N
            leg is transferred straight back to the depositor.
    """
    assert msg.value > 0, "zero value"
    self._ensure_active()
    x: uint256 = self._x()
    target: address = self._target()
    if self.pending_series == empty(address):
        assert not self._needs_roll(target, x), "sync required"

    nav_before: uint256 = self._nav(x)
    extcall ISeries(target).split(value=msg.value)
    self.p_bal[target] += msg.value
    assert extcall IERC20(staticcall ISeries(target).N()).transfer(msg.sender, msg.value), "n transfer"

    value_in: uint256 = msg.value * self._val_p(target, x) // UNIT
    shares: uint256 = 0
    if self.totalSupply == 0:
        assert value_in > DEAD_SHARES, "initial deposit too small"
        self._mint(DEAD, DEAD_SHARES)
        shares = value_in - DEAD_SHARES
    else:
        assert nav_before > 0, "zero nav"
        shares = value_in * self.totalSupply // nav_before
    assert shares > 0, "zero shares"
    self._mint(msg.sender, shares)
    log Deposit(account=msg.sender, series=target, eth_in=msg.value, shares=shares)
    return shares


@external
@nonreentrant
def redeem(shares: uint256):
    """
    @notice Burn shares for an exact pro-rata slice of all holdings
            (P tokens of each live series, plus buffered ETH).
            No oracle anywhere on this path.
    """
    assert shares > 0, "zero shares"
    supply: uint256 = self.totalSupply
    self._burn(msg.sender, shares)

    eth_out: uint256 = self.eth_buffer * shares // supply
    a: address = self.active_series
    p: address = self.pending_series
    for s: address in [a, p]:
        if s != empty(address):
            pa: uint256 = self.p_bal[s] * shares // supply
            if pa > 0:
                self.p_bal[s] -= pa
                assert extcall IERC20(staticcall ISeries(s).P()).transfer(msg.sender, pa), "p transfer"
    if eth_out > 0:
        self.eth_buffer -= eth_out
        raw_call(msg.sender, b"", value=eth_out)
    log Withdraw(account=msg.sender, shares=shares, eth_out=eth_out)


# ---------------------------------------------------------------- sync -----


@internal
def _ensure_active():
    if self.active_series == empty(address):
        x: uint256 = self._x()
        strike: uint256 = x * STRIKE_RATIO // UNIT
        assert strike > 0, "zero strike"
        series: address = extcall IFactory(FACTORY).create_series(ASSET, strike, block.timestamp + TERM)
        self.active_series = series


@external
@nonreentrant
def sync():
    """
    @notice Keeper entry point — anyone may call, the rules decide:
            1. create the initial series if none exists
            2. opportunistically settle a matured active series
            3. start a roll when the rule triggers
            4. harvest a settled old series to ETH; finalize the roll
               once the old series is fully unwound
            5. (re)anchor the sell_p auction ramp
    """
    self._ensure_active()
    x: uint256 = self._x()
    a: address = self.active_series
    p: address = self.pending_series

    # opportunistic one-shot settlement of a matured active series
    if block.timestamp >= staticcall ISeries(a).MATURITY() and not staticcall ISeries(a).settled():
        extcall ISeries(a).settle()

    if p == empty(address) and self._needs_roll(a, x):
        new_strike: uint256 = x * STRIKE_RATIO // UNIT
        assert new_strike > 0, "zero strike"
        new_maturity: uint256 = block.timestamp + TERM
        p = extcall IFactory(FACTORY).create_series(ASSET, new_strike, new_maturity)
        assert p != a, "roll into self"
        self.pending_series = p
        self.roll_started = block.timestamp
        log RollStarted(old_series=a, new_series=p, new_strike=new_strike, new_maturity=new_maturity)

    if p != empty(address):
        if staticcall ISeries(a).settled():
            self._harvest(a)
        if self.p_bal[a] == 0:
            self.active_series = p
            self.pending_series = empty(address)
            self.roll_started = 0
            log RollFinalized(series=p)

    # anchor the buy-side auction whenever there is ETH waiting to rotate
    if self.eth_buffer > 0:
        if self.buy_started == 0:
            self.buy_started = block.timestamp
    else:
        self.buy_started = 0


@internal
def _harvest(series: address):
    pa: uint256 = self.p_bal[series]
    got: uint256 = 0
    if pa > 0:
        pp: uint256 = staticcall ISeries(series).payout_p()
        self.p_bal[series] = 0
        extcall ISeries(series).redeem_p(pa)
        got = pa * pp // UNIT
        self.eth_buffer += got
    log Harvested(series=series, eth_out=got)


# ------------------------------------------------------------- auctions ----


@view
@internal
def _roll_quote(amount_old: uint256, x: uint256) -> uint256:
    """New-series P required to take `amount_old` old-series P."""
    a: address = self.active_series
    p: address = self.pending_series
    val_old: uint256 = self._val_p(a, x)
    val_new: uint256 = self._val_p(p, x)
    assert val_new > 0, "worthless new leg"
    elapsed: uint256 = min(block.timestamp - self.roll_started, AUCTION_DUR)
    edge: uint256 = MAX_EDGE * elapsed // AUCTION_DUR
    return amount_old * val_old // val_new * (UNIT - edge) // UNIT


@view
@external
def roll_quote(amount_old: uint256) -> uint256:
    assert self.pending_series != empty(address), "no roll"
    return self._roll_quote(amount_old, self._x())


@external
@nonreentrant
def fill_roll(amount_old: uint256):
    """
    @notice Gradual rotation auction. Deliver new-series P (approve
            first), receive old-series P. The rate starts oracle-fair and
            improves linearly for fillers up to MAX_EDGE over AUCTION_DUR.
            Fillers source new P by splitting ETH at the new series,
            keeping the leveraged N leg for themselves.
    """
    p: address = self.pending_series
    assert p != empty(address), "no roll"
    a: address = self.active_series
    assert not staticcall ISeries(a).settled(), "settled: use sync"
    assert amount_old > 0 and amount_old <= self.p_bal[a], "bad amount"

    x: uint256 = self._x()
    required_new: uint256 = self._roll_quote(amount_old, x)
    assert required_new > 0, "dust"

    self.p_bal[p] += required_new
    self.p_bal[a] -= amount_old
    assert extcall IERC20(staticcall ISeries(p).P()).transferFrom(msg.sender, self, required_new), "pull failed"
    assert extcall IERC20(staticcall ISeries(a).P()).transfer(msg.sender, amount_old), "push failed"
    log RollFilled(filler=msg.sender, old_p_out=amount_old, new_p_in=required_new)

    if self.p_bal[a] == 0:
        self.active_series = p
        self.pending_series = empty(address)
        self.roll_started = 0
        log RollFinalized(series=p)


@view
@internal
def _p_quote(series: address, amount: uint256, x: uint256) -> uint256:
    """ETH the DAO pays for `amount` of target-series P."""
    strike: uint256 = staticcall ISeries(series).STRIKE()
    pp: uint256 = UNIT  # intrinsic wei per 1e18 P
    if x > strike:
        pp = strike * UNIT // x
    started: uint256 = self.buy_started
    assert started > 0, "no auction"
    elapsed: uint256 = min(block.timestamp - started, AUCTION_DUR)
    # DAO's bid ramps from (1 - MAX_EDGE) to (1 + MAX_EDGE) around intrinsic
    mult: uint256 = UNIT - MAX_EDGE + 2 * MAX_EDGE * elapsed // AUCTION_DUR
    return amount * pp // UNIT * mult // UNIT


@view
@external
def p_quote(amount: uint256) -> uint256:
    return self._p_quote(self._target(), amount, self._x())


@external
@nonreentrant
def sell_p(amount: uint256):
    """
    @notice Re-entry auction: sell target-series P to the DAO for its
            buffered ETH (harvest proceeds rotating back into the peg).
            The DAO's bid ramps from a MAX_EDGE discount to a MAX_EDGE
            premium around oracle intrinsic value over AUCTION_DUR.
    """
    assert amount > 0, "zero amount"
    target: address = self._target()
    assert target != empty(address), "no series"
    assert not staticcall ISeries(target).settled(), "settled"
    assert block.timestamp < staticcall ISeries(target).MATURITY(), "matured"

    x: uint256 = self._x()
    eth_paid: uint256 = self._p_quote(target, amount, x)
    assert eth_paid > 0, "dust"
    assert eth_paid <= self.eth_buffer, "buffer too small"

    self.eth_buffer -= eth_paid
    if self.eth_buffer == 0:
        self.buy_started = 0
    self.p_bal[target] += amount
    assert extcall IERC20(staticcall ISeries(target).P()).transferFrom(msg.sender, self, amount), "pull failed"
    raw_call(msg.sender, b"", value=eth_paid)
    log PBought(seller=msg.sender, series=target, amount=amount, eth_paid=eth_paid)


@external
@payable
def __default__():
    # accepts ETH sent by series contracts on redeem/harvest;
    # stray donations are simply never counted in NAV
    pass
