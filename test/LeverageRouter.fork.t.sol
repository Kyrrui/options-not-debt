// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface ILeverageRouter {
    function open_leverage(uint256 minEthOut)
        external
        payable
        returns (address nToken, uint256 nAmount, uint256 ethReturned);
}

interface ITrackerView {
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
    function symbol() external view returns (string memory);
}

interface ISeriesView {
    function N() external view returns (address);
    function P() external view returns (address);
}

/// @notice End-to-end fork test of the LeverageRouter against the LIVE
///         Sepolia deployment: the real spUSD TrackerDAO and the real
///         Uniswap v3 spUSD/WETH pool. Validates the whole atomic flow
///         (deposit -> swap -> unwrap -> return N + ETH).
///
/// Run: forge test --match-path test/LeverageRouter.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract LeverageRouterForkTest is Test {
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    uint24 constant FEE = 3000;

    ILeverageRouter internal router;
    address internal user = makeAddr("leverageUser");

    function setUp() public {
        // only runs when forked to Sepolia; a normal `forge test` (chainid
        // 31337) or CI skips it, so it never breaks the default suite
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        router = ILeverageRouter(
            deployCode("LeverageRouter", abi.encode(SPUSD, SWAP_ROUTER, WETH, FEE))
        );
    }

    function test_openLeverage_returnsNandEth() public {
        address series = ITrackerView(SPUSD).active_series();
        require(series != address(0), "spUSD not initialized on this fork");
        address nToken = ISeriesView(series).N();
        address pToken = ISeriesView(series).P();

        vm.deal(user, 1 ether);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        (address gotN, uint256 nAmt, uint256 ethBack) =
            router.open_leverage{value: 0.02 ether}(0); // minOut 0: test only

        // 1. the caller received the N (leverage) leg of the active series
        assertEq(gotN, nToken, "wrong N token");
        assertEq(nAmt, 0.02 ether, "N amount = deposit (1 N per wei)");
        assertEq(IERC20(nToken).balanceOf(user), 0.02 ether, "user holds N");

        // 2. the caller is PURE N: holds no P and no sp shares
        assertEq(IERC20(pToken).balanceOf(user), 0, "user must hold no P");
        assertEq(IERC20(SPUSD).balanceOf(user), 0, "user must hold no shares");

        // 3. the caller got ETH back from the pool (P-sink), and the
        //    accounting closes exactly: final = start - deposit + recovered.
        //    (net premium = deposit - recovered can be NEGATIVE here because
        //    this pool is currently priced well above spUSD's ~$1 NAV, so
        //    selling shares into it overpays — a real arb, not a router bug.)
        assertGt(ethBack, 0, "should recover ETH from the pool");
        assertEq(user.balance, ethBefore - 0.02 ether + ethBack, "accounting consistent");

        // 4. the router is stateless: holds nothing afterwards
        assertEq(address(router).balance, 0, "router holds no ETH");
        assertEq(IERC20(SPUSD).balanceOf(address(router)), 0, "router holds no shares");
        assertEq(IERC20(nToken).balanceOf(address(router)), 0, "router holds no N");

        emit log_named_uint("deposited (wei)", 0.02 ether);
        emit log_named_uint("ETH recovered from pool (wei)", ethBack);
        emit log_named_int("net premium paid (wei, neg = pool overpaid)",
            int256(0.02 ether) - int256(ethBack));
        emit log_named_uint("N leverage leg held (wei)", nAmt);
    }

    /// @notice slippage floor is enforced: an unreachable min reverts
    function test_openLeverage_respectsMinOut() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        router.open_leverage{value: 0.02 ether}(100 ether); // impossible minOut
    }
}
