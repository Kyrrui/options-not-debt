# pragma version ==0.4.3
"""
@title LeverageRouter — one-click "ETH -> pure N leverage" via a soft-peg pool
@notice Periphery helper (NOT core protocol). Turns ETH into a pure
        leveraged-N position in a single transaction by using a tracker's
        spToken/WETH Uniswap v3 pool as the P-sink:

          1. deposit ETH into the TrackerDAO  -> router gets sp shares + N
          2. swap the sp shares -> WETH        (the pool absorbs the P value)
          3. unwrap WETH -> ETH
          4. send the caller their N leg + the recovered ETH

        Net: the caller spends ~the option premium and keeps the leveraged
        N leg with no leftover P. The "P-sink" is the pool's WETH-side
        liquidity; depth and the NAV-vs-market spread are the pool's, not
        the router's.

@dev    Stateless and trustless: holds no funds between calls, has no admin,
        no upgrade, and the core contracts grant it nothing. Worst case a
        bug here loses only the in-flight caller's tx (it reverts). One
        router instance serves one (tracker, pool) pair.
"""

from ethereum.ercs import IERC20

interface ITracker:
    def deposit() -> uint256: payable
    def active_series() -> address: view
    def pending_series() -> address: view

interface ISeries:
    def N() -> address: view

interface IWETH:
    def withdraw(amount: uint256): nonpayable

struct ExactInputSingleParams:
    tokenIn: address
    tokenOut: address
    fee: uint24
    recipient: address
    amountIn: uint256
    amountOutMinimum: uint256
    sqrtPriceLimitX96: uint160

interface ISwapRouter:
    def exactInputSingle(params: ExactInputSingleParams) -> uint256: payable

event LeverageOpened:
    account: indexed(address)
    series: indexed(address)
    eth_in: uint256
    n_token: address
    n_amount: uint256
    eth_returned: uint256

TRACKER: public(immutable(address))     # the spToken TrackerDAO (also the share ERC20)
SWAP_ROUTER: public(immutable(address)) # Uniswap v3 SwapRouter02
WETH: public(immutable(address))        # WETH9 the pool is paired against
POOL_FEE: public(immutable(uint24))     # pool fee tier (e.g. 3000)


@deploy
def __init__(tracker: address, swap_router: address, weth: address, pool_fee: uint24):
    assert tracker != empty(address), "zero tracker"
    assert swap_router != empty(address), "zero router"
    assert weth != empty(address), "zero weth"
    TRACKER = tracker
    SWAP_ROUTER = swap_router
    WETH = weth
    POOL_FEE = pool_fee


@external
@payable
@nonreentrant
def open_leverage(min_eth_out: uint256) -> (address, uint256, uint256):
    """
    @notice Spend msg.value ETH; receive a pure N leverage position plus the
            ETH recovered from selling the sp shares into the pool.
    @param min_eth_out slippage floor on the ETH recovered from the swap
            (the pool can be thin / off-NAV; never pass 0 in production).
    @return (n_token, n_amount, eth_returned)
    """
    assert msg.value > 0, "zero value"

    # 1. deposit -> router receives sp shares (minted to self) and N (to self)
    shares: uint256 = extcall ITracker(TRACKER).deposit(value=msg.value)

    # the N belongs to the series the deposit split into (pending during a
    # roll, else active); deposit does not start a roll, so this is stable
    target: address = staticcall ITracker(TRACKER).pending_series()
    if target == empty(address):
        target = staticcall ITracker(TRACKER).active_series()
    n_token: address = staticcall ISeries(target).N()
    n_amount: uint256 = staticcall IERC20(n_token).balanceOf(self)

    # 2. swap sp shares -> WETH (the P-sink absorbs the stable-leg value)
    assert extcall IERC20(TRACKER).approve(SWAP_ROUTER, shares), "approve"
    params: ExactInputSingleParams = ExactInputSingleParams(
        tokenIn=TRACKER,
        tokenOut=WETH,
        fee=POOL_FEE,
        recipient=self,
        amountIn=shares,
        amountOutMinimum=min_eth_out,
        sqrtPriceLimitX96=0,
    )
    weth_out: uint256 = extcall ISwapRouter(SWAP_ROUTER).exactInputSingle(params)
    assert weth_out >= min_eth_out, "slippage"

    # 3. unwrap the router's FULL WETH balance -> ETH (sweep, don't trust a
    #    single reported amount)
    weth_bal: uint256 = staticcall IERC20(WETH).balanceOf(self)
    extcall IWETH(WETH).withdraw(weth_bal)

    # 4. hand the caller the leverage leg + the router's FULL ETH balance
    eth_out: uint256 = self.balance
    assert extcall IERC20(n_token).transfer(msg.sender, n_amount), "n transfer"
    raw_call(msg.sender, b"", value=eth_out)

    log LeverageOpened(
        account=msg.sender,
        series=target,
        eth_in=msg.value,
        n_token=n_token,
        n_amount=n_amount,
        eth_returned=eth_out,
    )
    return (n_token, n_amount, eth_out)


@external
@payable
def __default__():
    # accepts ETH from WETH.withdraw during open_leverage. Undecorated on
    # purpose: it must not take the nonreentrant lock or the unwrap reverts.
    pass
