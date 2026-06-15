# pragma version ==0.4.3
"""
@title FlashLeverageRouter — "send exactly your premium" leverage via a flash loan
@notice Periphery helper (NOT core protocol). Same economics as LeverageRouter
        (ETH -> a pure N leveraged-ETH leg; the P leg is sold into the
        spToken/WETH pool), but the caller sends ONLY the premium they want at
        risk. The P-side working capital is flash-borrowed from the Balancer v2
        vault and repaid from the P sale in the same tx. Net result:

          msg.value == your premium == your max loss == "what's on the long"

        and you can deploy your whole wallet as premium in one tx (no change
        coming back). Per-unit economics match LeverageRouter (same split, same
        pool, same option price), but for a GIVEN premium this sells a LARGER P
        position (premium + flash, not just premium), so it takes MORE pool
        slippage / MEV than the baseline — the cost of deploying your full
        premium at once. It also adds a trust + callback dependency on the
        Balancer vault that the baseline does not have.

@dev    Flow:
          1. open_leverage(flash_amount, min_eth_out){value: premium}
          2. -> vault.flashLoan(self, [WETH], [flash_amount])
          3. -> receiveFlashLoan: unwrap WETH, deposit (premium + flash) into the
                tracker -> sp shares + N; sell the shares into the pool for WETH;
                repay the flash; unwrap the residual; stash the N.
          4. back in open_leverage: send the caller their N + residual ETH.

        Stateless across calls (only transient flow vars; holds no funds, no
        admin). receiveFlashLoan is double-guarded: callable only by the vault
        AND only while a flash WE initiated is in flight, so a third party
        cannot force a flash onto the router. Worst case a bug reverts the
        caller's own tx.
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

interface IBalancerVault:
    def flashLoan(
        recipient: address,
        tokens: DynArray[address, 1],
        amounts: DynArray[uint256, 1],
        user_data: Bytes[32],
    ): nonpayable

event LeverageOpened:
    account: indexed(address)
    series: indexed(address)
    premium_in: uint256
    flash_amount: uint256
    n_token: address
    n_amount: uint256
    eth_returned: uint256

TRACKER: public(immutable(address))     # the spToken TrackerDAO (also the share ERC20)
SWAP_ROUTER: public(immutable(address)) # Uniswap v3 SwapRouter02
WETH: public(immutable(address))        # WETH9 the pool is paired against
POOL_FEE: public(immutable(uint24))     # pool fee tier (e.g. 3000)
VAULT: public(immutable(address))       # Balancer v2 vault (flash source)

# transient flow state — set within a single call, auto-cleared each tx
_flashing: transient(bool)
_min_eth_out: transient(uint256)
_series: transient(address)
_n_token: transient(address)
_n_amount: transient(uint256)


@deploy
def __init__(tracker: address, swap_router: address, weth: address, pool_fee: uint24, vault: address):
    assert tracker != empty(address), "zero tracker"
    assert swap_router != empty(address), "zero router"
    assert weth != empty(address), "zero weth"
    assert vault != empty(address), "zero vault"
    TRACKER = tracker
    SWAP_ROUTER = swap_router
    WETH = weth
    POOL_FEE = pool_fee
    VAULT = vault


@external
@payable
@nonreentrant
def open_leverage(flash_amount: uint256, min_eth_out: uint256) -> (address, uint256, uint256):
    """
    @notice Spend msg.value ETH as the premium (your max loss). Flash-borrow
            `flash_amount` WETH for the P-side, split into N, sell the P into the
            pool, repay the flash, and keep the N. You receive the N leg plus any
            small residual ETH.
    @param flash_amount WETH to flash for the P-side. The frontend sizes this
            from a quote so the residual is ~0; it sets the position size
            (~ msg.value + flash_amount of ETH split).
    @param min_eth_out slippage floor on the P sale. MUST be >= flash_amount or
            the repay can fail; never pass 0 in production.
    @return (n_token, n_amount, eth_returned)
    """
    assert msg.value > 0, "zero premium"
    assert flash_amount > 0, "zero flash"
    # the P sale must recover at least the flash to repay it; the slippage floor
    # is therefore bounded below by the borrow (Balancer fee is 0; any non-zero
    # fee is still caught by the in-callback repay check)
    assert min_eth_out >= flash_amount, "min below flash"

    self._flashing = True
    self._min_eth_out = min_eth_out

    tokens: DynArray[address, 1] = [WETH]
    amounts: DynArray[uint256, 1] = [flash_amount]
    extcall IBalancerVault(VAULT).flashLoan(self, tokens, amounts, b"")

    # flash fully settled; the router now holds the N leg + any residual ETH
    self._flashing = False
    n_token: address = self._n_token
    n_amount: uint256 = self._n_amount
    series: address = self._series
    eth_out: uint256 = self.balance

    assert extcall IERC20(n_token).transfer(msg.sender, n_amount), "n transfer"
    if eth_out > 0:
        raw_call(msg.sender, b"", value=eth_out)

    log LeverageOpened(
        account=msg.sender,
        series=series,
        premium_in=msg.value,
        flash_amount=amounts[0],
        n_token=n_token,
        n_amount=n_amount,
        eth_returned=eth_out,
    )
    return (n_token, n_amount, eth_out)


@external
def receiveFlashLoan(
    tokens: DynArray[address, 1],
    amounts: DynArray[uint256, 1],
    fee_amounts: DynArray[uint256, 1],
    user_data: Bytes[32],
):
    """
    @notice Balancer flash callback. Guarded so only the vault can call it, and
            only while a flash we initiated is in flight.
    """
    assert msg.sender == VAULT, "not vault"
    assert self._flashing, "no flash in flight"
    assert len(tokens) == 1 and len(amounts) == 1 and len(fee_amounts) == 1, "bad flash"
    assert tokens[0] == WETH, "bad token"
    borrowed: uint256 = amounts[0]
    owed: uint256 = borrowed + fee_amounts[0]

    # 1. unwrap the flashed WETH -> ETH; combine with the caller's premium so the
    #    full split notional (premium + flash) is in ETH
    extcall IWETH(WETH).withdraw(borrowed)
    total: uint256 = self.balance

    # 2. split: deposit the whole notional into the tracker -> sp shares + N
    shares: uint256 = extcall ITracker(TRACKER).deposit(value=total)
    target: address = staticcall ITracker(TRACKER).pending_series()
    if target == empty(address):
        target = staticcall ITracker(TRACKER).active_series()
    n_token: address = staticcall ISeries(target).N()
    n_amount: uint256 = staticcall IERC20(n_token).balanceOf(self)

    # 3. sell the P (sp shares) into the pool for WETH
    assert extcall IERC20(TRACKER).approve(SWAP_ROUTER, shares), "approve"
    params: ExactInputSingleParams = ExactInputSingleParams(
        tokenIn=TRACKER,
        tokenOut=WETH,
        fee=POOL_FEE,
        recipient=self,
        amountIn=shares,
        amountOutMinimum=self._min_eth_out,
        sqrtPriceLimitX96=0,
    )
    recovered: uint256 = extcall ISwapRouter(SWAP_ROUTER).exactInputSingle(params)
    assert recovered >= self._min_eth_out, "slippage"

    # 4. repay the flash (Balancer requires the owed amount transferred back)
    assert staticcall IERC20(WETH).balanceOf(self) >= owed, "cannot repay"
    assert extcall IERC20(WETH).transfer(VAULT, owed), "repay"

    # 5. unwrap any residual WETH -> ETH; stash the N for the initiator to send
    residual: uint256 = staticcall IERC20(WETH).balanceOf(self)
    if residual > 0:
        extcall IWETH(WETH).withdraw(residual)
    self._series = target
    self._n_token = n_token
    self._n_amount = n_amount


@external
@payable
def __default__():
    # accepts ETH from WETH.withdraw. Undecorated so the WETH callback doesn't
    # contend with the nonreentrant lock held by open_leverage.
    pass
