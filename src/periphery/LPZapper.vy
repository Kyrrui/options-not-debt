# pragma version ==0.4.3
"""
@title LPZapper — one-tx "ETH -> spToken/WETH Uniswap v3 LP position"
@notice Periphery helper (NOT core protocol). Turns ETH into a full-range
        Uniswap v3 liquidity position in a tracker's spToken/WETH pool in a
        single transaction — the "Provide" / market-maker side of the
        protocol, mirroring the LeverageRouter on the "Leverage" side:

          1. deposit part of the ETH into the TrackerDAO -> sp shares + N
          2. wrap the rest of the ETH -> WETH
          3. mint a full-range v3 position (sp shares + WETH) via the
             NonfungiblePositionManager, NFT minted straight to the caller
          4. forward the caller their N leg + refund every leftover
             (unused sp shares, unused WETH unwrapped back to ETH)

        The split between the deposit leg and the WETH leg is supplied by the
        caller (`eth_to_deposit`), because the right ratio is the *pool's*
        market price, which the frontend already reads — keeping this contract
        free of any on-chain price math. Whatever the mint doesn't consume is
        refunded, so an imperfect split costs the caller a small refund, never
        a stuck balance.

        The N leg the deposit mints is handed back to the caller: it is the
        leverage inventory the LeverageRouter's customers buy. Providing
        liquidity here also leaves the caller long N — that, plus impermanent
        loss on a volatile pair, is the real risk of the role (the upside is
        swap fees).

@dev    Stateless and trustless: holds no funds between calls, has no admin,
        no upgrade, and the core contracts grant it nothing. The position NFT
        is minted directly to the caller (recipient=msg.sender), so the router
        never custodies it and needs no ERC-721 receiver hook. Worst case a
        bug here loses only the in-flight caller's tx (it reverts). One zapper
        instance serves one (tracker, pool) pair.
"""

from ethereum.ercs import IERC20

interface ITracker:
    def deposit() -> uint256: payable
    def active_series() -> address: view
    def pending_series() -> address: view

interface ISeries:
    def N() -> address: view

interface IWETH:
    def deposit(): payable
    def withdraw(amount: uint256): nonpayable

struct MintParams:
    token0: address
    token1: address
    fee: uint24
    tickLower: int24
    tickUpper: int24
    amount0Desired: uint256
    amount1Desired: uint256
    amount0Min: uint256
    amount1Min: uint256
    recipient: address
    deadline: uint256

interface INonfungiblePositionManager:
    def mint(params: MintParams) -> (uint256, uint128, uint256, uint256): payable

event LiquidityAdded:
    account: indexed(address)
    series: indexed(address)
    token_id: uint256
    liquidity: uint256
    sp_used: uint256
    weth_used: uint256
    n_token: address
    n_amount: uint256

# Uniswap v3 tick bound; usable extremes are this rounded to tick spacing
MAX_TICK: constant(int24) = 887272

TRACKER: public(immutable(address))         # the spToken TrackerDAO (also the share ERC20)
NPM: public(immutable(address))             # Uniswap v3 NonfungiblePositionManager
WETH: public(immutable(address))            # WETH9 the pool is paired against
POOL_FEE: public(immutable(uint24))         # pool fee tier (e.g. 3000)
TICK_SPACING: public(immutable(int24))      # tick spacing for the fee tier (e.g. 60)
TICK_LOWER: public(immutable(int24))        # full-range lower tick (spacing-aligned)
TICK_UPPER: public(immutable(int24))        # full-range upper tick (spacing-aligned)


@deploy
def __init__(tracker: address, position_manager: address, weth: address, pool_fee: uint24, tick_spacing: int24):
    assert tracker != empty(address), "zero tracker"
    assert position_manager != empty(address), "zero npm"
    assert weth != empty(address), "zero weth"
    # tick_spacing > MAX_TICK would make the usable range collapse to [0, 0]
    # and silently brick every mint; reject it at deploy (real v3 spacings <= 200)
    assert tick_spacing > 0 and tick_spacing <= MAX_TICK, "bad spacing"
    TRACKER = tracker
    NPM = position_manager
    WETH = weth
    POOL_FEE = pool_fee
    TICK_SPACING = tick_spacing
    usable: int24 = (MAX_TICK // tick_spacing) * tick_spacing
    TICK_UPPER = usable
    TICK_LOWER = -usable


@external
@payable
@nonreentrant
def add_liquidity(
    eth_to_deposit: uint256,
    amount_sp_min: uint256,
    amount_weth_min: uint256,
    deadline: uint256,
) -> (uint256, uint256, uint256, uint256):
    """
    @notice Spend msg.value ETH; receive a full-range spToken/WETH v3 LP
            position (NFT minted to you) plus the N leverage leg, with any
            unused side refunded.
    @param eth_to_deposit ETH routed into the DAO to mint sp shares; the
            remainder (msg.value - eth_to_deposit) becomes the WETH side.
            Choose it off the pool's current price; leftovers are refunded.
    @param amount_sp_min slippage floor on sp shares actually deposited into
            the position (never pass 0 in production).
    @param amount_weth_min slippage floor on WETH actually deposited into the
            position (never pass 0 in production).
    @param deadline unix timestamp after which the mint reverts.
    @return (token_id, liquidity, sp_used, weth_used)
    """
    assert msg.value > 0, "zero value"
    assert eth_to_deposit > 0 and eth_to_deposit < msg.value, "bad split"

    # 1. mint spToken via the DAO; router receives sp shares (to self) and the
    #    N leg (to self)
    shares: uint256 = extcall ITracker(TRACKER).deposit(value=eth_to_deposit)

    # the N belongs to the series the deposit split into (pending during a
    # roll, else active); deposit does not start a roll, so this is stable
    target: address = staticcall ITracker(TRACKER).pending_series()
    if target == empty(address):
        target = staticcall ITracker(TRACKER).active_series()
    n_token: address = staticcall ISeries(target).N()
    n_amount: uint256 = staticcall IERC20(n_token).balanceOf(self)

    # 2. wrap the remaining ETH into WETH for the pair
    weth_amount: uint256 = msg.value - eth_to_deposit
    extcall IWETH(WETH).deposit(value=weth_amount)

    # 3. approve the position manager to pull both sides
    assert extcall IERC20(TRACKER).approve(NPM, shares), "approve sp"
    assert extcall IERC20(WETH).approve(NPM, weth_amount), "approve weth"

    # 4. order tokens the way Uniswap does (ascending address) and mint a
    #    full-range position straight to the caller
    sp_is_0: bool = convert(TRACKER, uint256) < convert(WETH, uint256)
    token0: address = WETH
    token1: address = TRACKER
    amount0_des: uint256 = weth_amount
    amount1_des: uint256 = shares
    amount0_min: uint256 = amount_weth_min
    amount1_min: uint256 = amount_sp_min
    if sp_is_0:
        token0 = TRACKER
        token1 = WETH
        amount0_des = shares
        amount1_des = weth_amount
        amount0_min = amount_sp_min
        amount1_min = amount_weth_min

    params: MintParams = MintParams(
        token0=token0,
        token1=token1,
        fee=POOL_FEE,
        tickLower=TICK_LOWER,
        tickUpper=TICK_UPPER,
        amount0Desired=amount0_des,
        amount1Desired=amount1_des,
        amount0Min=amount0_min,
        amount1Min=amount1_min,
        recipient=msg.sender,
        deadline=deadline,
    )
    token_id: uint256 = 0
    liq: uint128 = 0
    used0: uint256 = 0
    used1: uint256 = 0
    (token_id, liq, used0, used1) = extcall INonfungiblePositionManager(NPM).mint(params)

    sp_used: uint256 = used1
    weth_used: uint256 = used0
    if sp_is_0:
        sp_used = used0
        weth_used = used1

    # 5. drop the approvals (router holds nothing, but leave no dangling allowance)
    extcall IERC20(TRACKER).approve(NPM, 0)
    extcall IERC20(WETH).approve(NPM, 0)

    # 6. refund every leftover: unused sp shares, unused WETH (unwrapped),
    #    and forward the N leverage leg
    sp_left: uint256 = staticcall IERC20(TRACKER).balanceOf(self)
    if sp_left > 0:
        assert extcall IERC20(TRACKER).transfer(msg.sender, sp_left), "sp refund"

    weth_left: uint256 = staticcall IERC20(WETH).balanceOf(self)
    if weth_left > 0:
        extcall IWETH(WETH).withdraw(weth_left)

    assert extcall IERC20(n_token).transfer(msg.sender, n_amount), "n transfer"

    eth_left: uint256 = self.balance
    if eth_left > 0:
        raw_call(msg.sender, b"", value=eth_left)

    log LiquidityAdded(
        account=msg.sender,
        series=target,
        token_id=token_id,
        liquidity=convert(liq, uint256),
        sp_used=sp_used,
        weth_used=weth_used,
        n_token=n_token,
        n_amount=n_amount,
    )
    return (token_id, convert(liq, uint256), sp_used, weth_used)


@external
@payable
def __default__():
    # accepts ETH from WETH.withdraw during add_liquidity. Undecorated on
    # purpose: it must not take the nonreentrant lock or the unwrap reverts.
    pass
