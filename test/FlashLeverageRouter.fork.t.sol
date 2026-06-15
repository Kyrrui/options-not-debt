// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IFlashRecipient {
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external;
}

/// @notice Minimal stand-in for the Balancer v2 vault flash: transfers the token
///         to the recipient, calls back, and requires it to be repaid. Lets us
///         test the router's flash accounting deterministically without relying
///         on live Balancer WETH liquidity on Sepolia. Zero fee, like Balancer.
contract MockBalancerVault {
    function flashLoan(
        address recipient,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata userData
    ) external {
        uint256 pre = IERC20(tokens[0]).balanceOf(address(this));
        uint256[] memory fees = new uint256[](amounts.length);
        require(IERC20(tokens[0]).transfer(recipient, amounts[0]), "fund");
        IFlashRecipient(recipient).receiveFlashLoan(tokens, amounts, fees, userData);
        require(IERC20(tokens[0]).balanceOf(address(this)) >= pre, "not repaid");
    }
}

interface IFlashLeverageRouter {
    function open_leverage(uint256 flashAmount, uint256 minEthOut)
        external
        payable
        returns (address nToken, uint256 nAmount, uint256 ethReturned);
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external;
}

interface ITrackerView {
    function active_series() external view returns (address);
}

interface ISeriesView {
    function N() external view returns (address);
    function P() external view returns (address);
}

/// @notice Fork test of FlashLeverageRouter against the LIVE Sepolia spUSD
///         TrackerDAO + spUSD/WETH pool, with a mock Balancer vault as the flash
///         source. Validates flash -> split -> sell -> repay -> deliver N, the
///         "caller only sends the premium" property, statelessness, and the
///         callback guards.
///
/// Run: forge test --match-path test/FlashLeverageRouter.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract FlashLeverageRouterForkTest is Test {
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    uint24 constant FEE = 3000;

    MockBalancerVault internal vault;
    IFlashLeverageRouter internal router;
    address internal user = makeAddr("flashLevUser");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        vault = new MockBalancerVault();
        deal(WETH, address(vault), 100 ether); // flash liquidity
        router = IFlashLeverageRouter(
            deployCode("FlashLeverageRouter", abi.encode(SPUSD, SWAP_ROUTER, WETH, FEE, address(vault)))
        );
        vm.deal(address(router), 0); // ignore residual at the deterministic address
    }

    function test_openLeverage_sendsOnlyPremium() public {
        address series = ITrackerView(SPUSD).active_series();
        require(series != address(0), "spUSD not initialized");
        address nToken = ISeriesView(series).N();
        address pToken = ISeriesView(series).P();

        uint256 premium = 0.02 ether; // what the caller sends == their max loss
        uint256 flashAmount = 0.008 ether; // P-side, sized conservatively below recovery
        uint256 minEthOut = 0.008 ether; // >= flashAmount so the repay is guaranteed

        vm.deal(user, 1 ether);
        uint256 ethBefore = user.balance;
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(address(vault));

        vm.prank(user);
        (address gotN, uint256 nAmt, uint256 ethBack) =
            router.open_leverage{value: premium}(flashAmount, minEthOut);

        // 1. the position = premium + flash split into N (1 N per wei)
        assertEq(gotN, nToken, "wrong N");
        assertEq(nAmt, premium + flashAmount, "N = premium + flash");
        assertEq(IERC20(nToken).balanceOf(user), premium + flashAmount, "user holds N");

        // 2. caller is pure N: no P, no shares
        assertEq(IERC20(pToken).balanceOf(user), 0, "no P");
        assertEq(IERC20(SPUSD).balanceOf(user), 0, "no shares");

        // 3. caller sent only the premium; net spend <= premium, residual returned
        assertLe(user.balance, ethBefore, "cannot gain");
        assertGe(user.balance, ethBefore - premium, "spent at most the premium");
        assertEq(user.balance, ethBefore - premium + ethBack, "accounting closes");

        // 4. flash fully repaid (vault made whole)
        assertGe(IERC20(WETH).balanceOf(address(vault)), vaultWethBefore, "flash repaid");

        // 5. router is stateless: holds nothing
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no WETH");
        assertEq(IERC20(SPUSD).balanceOf(address(router)), 0, "router holds no shares");
        assertEq(IERC20(nToken).balanceOf(address(router)), 0, "router holds no N");

        emit log_named_uint("premium sent (wei)", premium);
        emit log_named_uint("flash borrowed (wei)", flashAmount);
        emit log_named_uint("N position (wei)", nAmt);
        emit log_named_uint("residual returned (wei)", ethBack);
        emit log_named_uint("net premium paid (wei)", premium - ethBack);
    }

    /// @notice end-to-end against the REAL Balancer v2 vault on Sepolia (it
    ///         holds ~4 WETH), not the mock — proves live flash compatibility
    function test_realBalancerVault_works() public {
        address series = ITrackerView(SPUSD).active_series();
        require(series != address(0), "spUSD not initialized");
        address nToken = ISeriesView(series).N();

        IFlashLeverageRouter realRouter = IFlashLeverageRouter(
            deployCode("FlashLeverageRouter", abi.encode(SPUSD, SWAP_ROUTER, WETH, FEE, BALANCER_VAULT))
        );
        vm.deal(address(realRouter), 0);

        uint256 premium = 0.02 ether;
        uint256 flashAmount = 0.008 ether; // << the vault's ~4 WETH
        uint256 minEthOut = 0.008 ether;

        vm.deal(user, 1 ether);
        vm.prank(user);
        (address gotN, uint256 nAmt,) =
            realRouter.open_leverage{value: premium}(flashAmount, minEthOut);

        assertEq(gotN, nToken, "wrong N");
        assertEq(nAmt, premium + flashAmount, "N = premium + flash");
        assertEq(IERC20(nToken).balanceOf(user), premium + flashAmount, "user holds N");
        assertEq(address(realRouter).balance, 0, "router holds no ETH");
        assertEq(IERC20(WETH).balanceOf(address(realRouter)), 0, "router holds no WETH");
        emit log_named_uint("flashed from real Balancer vault (wei)", flashAmount);
    }

    /// @notice the flash callback cannot be called by anyone but the vault
    function test_receiveFlashLoan_onlyVault() public {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        uint256[] memory fees = new uint256[](1);
        vm.expectRevert();
        router.receiveFlashLoan(tokens, amounts, fees, "");
    }

    /// @notice even the vault cannot trigger the callback outside an in-flight flash
    function test_receiveFlashLoan_requiresInFlight() public {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        uint256[] memory fees = new uint256[](1);
        vm.prank(address(vault));
        vm.expectRevert();
        router.receiveFlashLoan(tokens, amounts, fees, "");
    }
}
