// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IPeripheryFactory {
    function deploy_periphery(address tracker, uint24 fee)
        external
        returns (address router, address zapper, address flash);
    function get_router(address tracker, uint24 fee) external view returns (address);
    function get_zapper(address tracker, uint24 fee) external view returns (address);
    function get_flash(address tracker, uint24 fee) external view returns (address);
    function get_pool(address tracker, uint24 fee) external view returns (address);
    function is_deployed(address tracker, uint24 fee) external view returns (bool);
    function is_router(address a) external view returns (bool);
    function is_zapper(address a) external view returns (bool);
    function is_flash(address a) external view returns (bool);
    function entry_count() external view returns (uint256);
    function entry_tracker(uint256 i) external view returns (address);
    function entry_fee(uint256 i) external view returns (uint24);
}

interface ILeverageRouterView {
    function TRACKER() external view returns (address);
    function SWAP_ROUTER() external view returns (address);
    function WETH() external view returns (address);
    function POOL_FEE() external view returns (uint24);
}

interface ILPZapperView {
    function TRACKER() external view returns (address);
    function NPM() external view returns (address);
    function WETH() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
}

interface IFlashView {
    function TRACKER() external view returns (address);
    function WETH() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function VAULT() external view returns (address);
}

interface ILPZapper {
    function add_liquidity(uint256 ethToDeposit, uint256 spMin, uint256 wethMin, uint256 deadline)
        external
        payable
        returns (uint256 tokenId, uint256 liquidity, uint256 spUsed, uint256 wethUsed);
}

interface IPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IUniV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

/// @notice Fork test of PeripheryFactory against LIVE Sepolia: the real
///         TrackerFactory, spUSD, Uniswap v3 factory/NPM, the spUSD/WETH pool,
///         and the on-chain LeverageRouter + LPZapper blueprints. Proves the
///         factory deploys correctly-wired periphery, registers them
///         enumerably, gates bad inputs, and that a BLUEPRINT-deployed zapper
///         actually mints a position end-to-end.
///
/// Run: forge test --match-path test/PeripheryFactory.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract PeripheryFactoryForkTest is Test {
    address constant TRACKER_FACTORY = 0x7C87799cad38576ddB03881570bd62e7ac1daf49;
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant UNIV3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address constant NPM = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address constant SWAP_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    // blueprints deployed to Sepolia for this factory
    address constant LEV_BP = 0xFA6a16cE35Cdaaa611a85E1670aecc226898AA60;
    address constant ZAP_BP = 0x528D055A0ecB7566d56c3EEb31dae6412cF491a7;
    address constant FLASH_BP = 0xCeA3AE530cb7FB8b10bb44C2D175Af8631B107A7;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    IPeripheryFactory internal factory;
    address internal user = makeAddr("pegUser");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        factory = IPeripheryFactory(
            deployCode(
                "PeripheryFactory",
                abi.encode(TRACKER_FACTORY, LEV_BP, ZAP_BP, FLASH_BP, UNIV3_FACTORY, NPM, SWAP_ROUTER, WETH, BALANCER_VAULT)
            )
        );
    }

    function test_deployPeriphery_wiresAndRegisters() public {
        (address router, address zapper, address flash) = factory.deploy_periphery(SPUSD, FEE);

        // deployed, non-zero, distinct
        assertTrue(router != address(0) && zapper != address(0) && flash != address(0), "zero periphery");
        assertTrue(router != zapper && router != flash && zapper != flash, "periphery collide");

        // router wired to spUSD + Uniswap
        assertEq(ILeverageRouterView(router).TRACKER(), SPUSD, "router tracker");
        assertEq(ILeverageRouterView(router).SWAP_ROUTER(), SWAP_ROUTER, "router swaprouter");
        assertEq(ILeverageRouterView(router).WETH(), WETH, "router weth");
        assertEq(ILeverageRouterView(router).POOL_FEE(), FEE, "router fee");

        // zapper wired to spUSD + Uniswap + full-range spacing (read from the
        // pool itself, not the caller — must equal the 3000-tier spacing of 60)
        assertEq(ILPZapperView(zapper).TRACKER(), SPUSD, "zapper tracker");
        assertEq(ILPZapperView(zapper).NPM(), NPM, "zapper npm");
        assertEq(ILPZapperView(zapper).WETH(), WETH, "zapper weth");
        assertEq(ILPZapperView(zapper).POOL_FEE(), FEE, "zapper fee");
        assertEq(ILPZapperView(zapper).TICK_SPACING(), TICK_SPACING, "zapper spacing from pool");

        // flash router wired to spUSD + the Balancer vault
        assertEq(IFlashView(flash).TRACKER(), SPUSD, "flash tracker");
        assertEq(IFlashView(flash).WETH(), WETH, "flash weth");
        assertEq(IFlashView(flash).POOL_FEE(), FEE, "flash fee");
        assertEq(IFlashView(flash).VAULT(), BALANCER_VAULT, "flash vault");

        // registry: forward, pool, reverse, enumeration (keyed by tracker+fee)
        assertEq(factory.get_router(SPUSD, FEE), router, "get_router");
        assertEq(factory.get_zapper(SPUSD, FEE), zapper, "get_zapper");
        assertEq(factory.get_flash(SPUSD, FEE), flash, "get_flash");
        assertEq(factory.get_pool(SPUSD, FEE), IUniV3Factory(UNIV3_FACTORY).getPool(SPUSD, WETH, FEE), "get_pool");
        assertTrue(factory.is_deployed(SPUSD, FEE), "is_deployed");
        assertTrue(factory.is_router(router), "is_router");
        assertTrue(factory.is_zapper(zapper), "is_zapper");
        assertTrue(factory.is_flash(flash), "is_flash");
        assertEq(factory.entry_count(), 1, "entry_count");
        assertEq(factory.entry_tracker(0), SPUSD, "entry_tracker[0]");
        assertEq(factory.entry_fee(0), FEE, "entry_fee[0]");
        // a different fee tier is independently unset (no first-caller lock)
        assertFalse(factory.is_deployed(SPUSD, 500), "other tier must be free");

        emit log_named_address("factory router", router);
        emit log_named_address("factory zapper", zapper);
    }

    /// @notice a blueprint-deployed zapper is fully functional: it mints a real
    ///         full-range LP position to the caller
    function test_deployPeriphery_endToEnd() public {
        (, address zapper,) = factory.deploy_periphery(SPUSD, FEE);
        vm.deal(zapper, 0); // ignore any residual at the deterministic address

        vm.deal(user, 1 ether);
        vm.prank(user);
        (uint256 tokenId, uint256 liquidity,,) =
            ILPZapper(zapper).add_liquidity{value: 0.02 ether}(0.01 ether, 0, 0, block.timestamp + 300);

        assertGt(tokenId, 0, "no tokenId");
        assertGt(liquidity, 0, "no liquidity");
        assertEq(IPositionManager(NPM).ownerOf(tokenId), user, "user owns position");
        // blueprint-deployed zapper is stateless too
        assertEq(address(zapper).balance, 0, "zapper holds no ETH");
        assertEq(IERC20(SPUSD).balanceOf(zapper), 0, "zapper holds no shares");
        assertEq(IERC20(WETH).balanceOf(zapper), 0, "zapper holds no WETH");
    }

    function test_deployPeriphery_rejectsUnknownTracker() public {
        // WETH is not a TrackerFactory tracker
        vm.expectRevert();
        factory.deploy_periphery(WETH, FEE);
    }

    function test_deployPeriphery_rejectsDuplicate() public {
        factory.deploy_periphery(SPUSD, FEE);
        vm.expectRevert();
        factory.deploy_periphery(SPUSD, FEE);
    }
}
