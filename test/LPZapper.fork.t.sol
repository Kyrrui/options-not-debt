// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface ILPZapper {
    function add_liquidity(
        uint256 ethToDeposit,
        uint256 amountSpMin,
        uint256 amountWethMin,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint256 liquidity, uint256 spUsed, uint256 wethUsed);
}

interface ITrackerView {
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
}

interface ISeriesView {
    function N() external view returns (address);
    function P() external view returns (address);
}

interface IPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice End-to-end fork test of the LPZapper against the LIVE Sepolia
///         deployment: the real spUSD TrackerDAO, the real Uniswap v3
///         NonfungiblePositionManager, and the real spUSD/WETH pool.
///         Validates the whole atomic flow (deposit -> wrap -> mint full-range
///         position to caller -> forward N + refund leftovers).
///
/// Run: forge test --match-path test/LPZapper.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract LPZapperForkTest is Test {
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52; // Uniswap v3 NonfungiblePositionManager (Sepolia)
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    ILPZapper internal zapper;
    address internal user = makeAddr("lpUser");

    function setUp() public {
        // only runs when forked to Sepolia; a normal `forge test` (chainid
        // 31337) or CI skips it, so it never breaks the default suite
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        zapper = ILPZapper(
            deployCode("LPZapper", abi.encode(SPUSD, NPM, WETH, FEE, TICK_SPACING))
        );
        // the deterministic CREATE address holds residual ETH on the live
        // fork; a freshly deployed zapper starts at 0 in production. Zero it so
        // the ETH accounting below reflects only what the flow itself moves.
        // (The contract intentionally sweeps its full balance to the caller —
        // any stray/donated ETH goes to the next caller, same as LeverageRouter.)
        vm.deal(address(zapper), 0);
    }

    function test_addLiquidity_mintsPositionAndForwardsN() public {
        address series = ITrackerView(SPUSD).active_series();
        require(series != address(0), "spUSD not initialized on this fork");
        address nToken = ISeriesView(series).N();
        address pToken = ISeriesView(series).P();

        vm.deal(user, 1 ether);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        (uint256 tokenId, uint256 liquidity, uint256 spUsed, uint256 wethUsed) =
            zapper.add_liquidity{value: 0.02 ether}(0.01 ether, 0, 0, block.timestamp + 300);

        // 1. a real, non-empty LP position NFT was minted straight to the user
        assertGt(tokenId, 0, "no tokenId");
        assertGt(liquidity, 0, "no liquidity");
        assertEq(IPositionManager(NPM).ownerOf(tokenId), user, "user must own the NFT");
        assertGe(IPositionManager(NPM).balanceOf(user), 1, "user holds the position");

        // 2. the user received the N (leverage) leg of the deposit: 1 N per wei
        assertEq(IERC20(nToken).balanceOf(user), 0.01 ether, "user holds N = eth_to_deposit");

        // 3. the zapper is stateless: holds NOTHING afterwards
        assertEq(address(zapper).balance, 0, "zapper holds no ETH");
        assertEq(IERC20(SPUSD).balanceOf(address(zapper)), 0, "zapper holds no shares");
        assertEq(IERC20(WETH).balanceOf(address(zapper)), 0, "zapper holds no WETH");
        assertEq(IERC20(nToken).balanceOf(address(zapper)), 0, "zapper holds no N");
        assertEq(IERC20(pToken).balanceOf(address(zapper)), 0, "zapper holds no P");
        assertEq(IPositionManager(NPM).balanceOf(address(zapper)), 0, "zapper holds no NFT");

        // 4. the user spent real ETH (deposit leg + WETH actually LP'd) and got
        //    the unused remainder back — net spend is within the 0.02 sent
        assertLt(user.balance, ethBefore, "must have spent some ETH");
        assertGe(user.balance, ethBefore - 0.02 ether, "spent at most msg.value");

        emit log_named_uint("position tokenId", tokenId);
        emit log_named_uint("liquidity", liquidity);
        emit log_named_uint("sp shares used", spUsed);
        emit log_named_uint("WETH used (wei)", wethUsed);
        emit log_named_uint("N leverage leg held (wei)", IERC20(nToken).balanceOf(user));
        emit log_named_uint("sp shares refunded (wei)", IERC20(SPUSD).balanceOf(user));
        emit log_named_uint("ETH spent net (wei)", ethBefore - user.balance);
    }

    /// @notice slippage floor is enforced: an unreachable WETH min reverts the
    ///         whole tx (the caller is protected against a bad/thin pool)
    function test_addLiquidity_respectsMinOut() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        zapper.add_liquidity{value: 0.02 ether}(0.01 ether, 0, 100 ether, block.timestamp + 300);
    }

    /// @notice a bad split (deposit >= msg.value) reverts cleanly
    function test_addLiquidity_rejectsBadSplit() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        zapper.add_liquidity{value: 0.02 ether}(0.02 ether, 0, 0, block.timestamp + 300);
    }
}
