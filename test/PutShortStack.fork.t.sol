// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IMockUSDC {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IPutSeries {
    function split(uint256 amount) external;
    function merge(uint256 amount) external;
    function settle() external;
    function redeem_l(uint256 amount) external;
    function redeem_m(uint256 amount) external;
    function M() external view returns (address);
    function L() external view returns (address);
    function STRIKE() external view returns (uint256);
    function MATURITY() external view returns (uint256);
    function STABLE() external view returns (address);
    function ASSET() external view returns (bytes32);
    function settled() external view returns (bool);
    function payout_l() external view returns (uint256);
}

interface IShortVault {
    function deposit(uint256 amount) external returns (uint256);
    function redeem(uint256 shares) external;
    function buy_m(address series, uint256 amount, uint256 max_cost) external returns (uint256);
    function poke() external;
    function quote_buy_m(uint256 amount) external view returns (uint256);
    function intrinsic_m() external view returns (uint256);
    function nav() external view returns (uint256);
    function share_price() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function buffer() external view returns (uint256);
    function l_held() external view returns (uint256);
    function SCALE() external view returns (uint256);
}

interface IOracleHub {
    function latest_price(bytes32 asset) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork test of the P1 debt-free SHORT stack against live Sepolia (OracleHub + ETH/USD feed),
///         with a locally-deployed MockUSDC as the 6-dec collateral:
///           * PutOptionSeries — split/merge value-exact, flipped settle (M gains as ETH falls),
///             M+L==1 conservation, 6-dec round-down never overpays;
///           * GimbalShortVault — deposit USDC -> shares, buy_m writes M + keeps L + NAV up by spread,
///             in-kind oracle-free redeem, poke settle+harvest, flipped near-strike band + caps,
///             no admin/fund-extraction surface.
/// Run: forge test --match-path test/PutShortStack.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract PutShortStackForkTest is Test {
    uint256 constant UNIT = 1e18;
    address constant HUB = 0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant TOKEN_BLUEPRINT = 0x360b1f203f82F06709c5d7c9Ec9D86993A3034c4;
    bytes32 constant USD = bytes32(0);

    uint256 constant BASE_EDGE = 2e16; // 2%
    uint256 constant DESK_MAX_STALENESS = 3600;
    uint256 constant PRE_MATURITY_BUFFER = 2 days;
    uint256 constant STRIKE_PROXIMITY = 95e16; // 0.95 (flipped: sub-UNIT ceiling)
    uint256 constant OUTFLOW_WINDOW = 3600;
    uint256 constant BIG = type(uint128).max;

    IMockUSDC internal usdc;
    IPutSeries internal series;
    IShortVault internal vault;
    address internal mToken;
    address internal lToken;
    uint256 internal K;
    uint256 internal p0;

    address internal lp = makeAddr("lp");
    address internal buyer = makeAddr("buyer");
    address internal user = makeAddr("user");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        _freshFeed();
        p0 = IOracleHub(HUB).latest_price(USD);
        require(p0 > 0, "no price");
        K = p0 * 5 / 4; // strike 25% above spot -> 4x short tier, p < K (tradeable)

        usdc = IMockUSDC(deployCode("MockUSDC"));
        series = IPutSeries(
            deployCode("PutOptionSeries", abi.encode(HUB, address(usdc), K, block.timestamp + 30 days, TOKEN_BLUEPRINT))
        );
        mToken = series.M();
        lToken = series.L();
        vault = IShortVault(_deployVault(BIG, BIG, BIG));

        usdc.mint(lp, 1_000_000e6);
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(user, 1_000_000e6);
    }

    function _deployVault(uint256 maxWritten, uint256 maxWritePerBlock, uint256 maxFill) internal returns (address) {
        return deployCode(
            "GimbalShortVault",
            abi.encode(
                address(series), HUB, BASE_EDGE, DESK_MAX_STALENESS, PRE_MATURITY_BUFFER, STRIKE_PROXIMITY,
                maxFill, maxWritten, OUTFLOW_WINDOW, BIG, maxWritePerBlock, BIG
            )
        );
    }

    function _freshFeed() internal {
        (,,, uint256 updatedAt,) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + 60);
    }

    // mock the feed to (real answer * num / den) at timestamp ts (fresh)
    function _mockFeed(uint256 num, uint256 den, uint256 ts) internal {
        (uint80 rid, int256 a, uint256 sa,, uint80 ai) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            ETH_USD_FEED, abi.encodeWithSelector(IAggregator.latestRoundData.selector),
            abi.encode(rid, a * int256(num) / int256(den), sa, ts, ai)
        );
    }

    function _usdcApprove(address who, address spender, uint256 amt) internal {
        vm.prank(who);
        IERC20(address(usdc)).approve(spender, amt);
    }

    // ============================================================ PutOptionSeries

    function test_series_splitMergeExact() public {
        uint256 before = usdc.balanceOf(user);
        _usdcApprove(user, address(series), 100e6);
        vm.prank(user);
        series.split(100e18); // locks 100 USDC, mints 100 L + 100 M
        assertEq(before - usdc.balanceOf(user), 100e6, "locked 100 USDC");
        assertEq(IERC20(lToken).balanceOf(user), 100e18, "100 L");
        assertEq(IERC20(mToken).balanceOf(user), 100e18, "100 M");

        vm.prank(user);
        series.merge(40e18); // burn 40 L + 40 M -> 40 USDC back
        assertEq(IERC20(lToken).balanceOf(user), 60e18, "60 L left");
        assertEq(usdc.balanceOf(user), before - 60e6, "got 40 USDC back");
    }

    function test_series_settleConservation_andRoundDown() public {
        _usdcApprove(user, address(series), 100e6);
        vm.prank(user);
        series.split(100e18);

        vm.warp(series.MATURITY() + 1);
        _mockFeed(1, 1, block.timestamp); // settle at the live price (p == p0)
        series.settle();

        uint256 pl = series.payout_l();
        uint256 pm = UNIT - pl;
        assertApproxEqAbs(pl, p0 * UNIT / K, 2, "payout_l = p/K"); // ~0.8e18
        assertEq(pl + pm, UNIT, "M+L conservation == 1");

        uint256 before = usdc.balanceOf(user);
        vm.startPrank(user);
        series.redeem_l(100e18);
        series.redeem_m(100e18);
        vm.stopPrank();
        // redeem pair for the full 100 of each returns <= the 100 USDC locked (round-down, dust kept)
        uint256 got = usdc.balanceOf(user) - before;
        assertLe(got, 100e6, "never returns more than locked");
        assertGe(got, 100e6 - 2, "within 2 wei dust");
    }

    function test_series_shortPaysMoreWhenEthLower() public {
        _usdcApprove(user, address(series), 100e6);
        vm.prank(user);
        series.split(100e18);

        vm.warp(series.MATURITY() + 1);
        _mockFeed(1, 2, block.timestamp); // settle at HALF the price -> deeper short payoff
        series.settle();

        uint256 pm = UNIT - series.payout_l();
        // p/2 over K=1.25*p -> p/K = 0.4 -> payout_l 0.4, payout_m 0.6 (vs 0.2 at full price)
        assertApproxEqAbs(pm, UNIT - (p0 / 2) * UNIT / K, 2, "M pays 0.6 at half price");
        assertGt(pm, 2e17, "M pays much more than the 0.2 at-spot value");
    }

    // ============================================================ GimbalShortVault

    function _depositLP(uint256 amt6) internal returns (uint256) {
        _usdcApprove(lp, address(vault), amt6);
        vm.prank(lp);
        return vault.deposit(amt6);
    }

    function _buyM(address who, uint256 amount) internal returns (uint256 cost) {
        cost = vault.quote_buy_m(amount);
        _usdcApprove(who, address(vault), cost);
        vm.prank(who);
        vault.buy_m(address(series), amount, cost);
    }

    function test_vault_depositMintsShares() public {
        uint256 shares = _depositLP(10_000e6);
        // internal NAV is 18-dec: 10_000 USDC -> 10_000e18 units; first deposit burns DEAD_SHARES
        assertEq(shares, 10_000e18 - 1e3, "shares = value18 - DEAD_SHARES");
        assertEq(vault.totalSupply(), 10_000e18, "supply");
        assertEq(vault.buffer(), 10_000e18, "buffer = deposit*SCALE");
        assertEq(vault.share_price(), UNIT, "share price ~1 with only USDC held");
    }

    function test_vault_buyMWritesKeepsL_navUpBySpread() public {
        _depositLP(10_000e6);
        uint256 amount = 100e18;

        uint256 navBefore = vault.nav();
        uint256 bufBefore = vault.buffer();
        uint256 intrinsic = vault.intrinsic_m();
        uint256 buyerMBefore = IERC20(mToken).balanceOf(buyer);

        uint256 cost = _buyM(buyer, amount);

        assertEq(IERC20(mToken).balanceOf(buyer) - buyerMBefore, amount, "buyer got M");
        assertEq(vault.l_held(), amount, "vault kept L");
        assertEq(IERC20(mToken).balanceOf(address(vault)), 0, "vault holds no leftover M");

        // buffer moved by (premium - faceSplit) in 18-dec; premium=cost*SCALE, split=amount
        uint256 scale = vault.SCALE();
        assertEq(vault.buffer(), bufBefore + cost * scale - amount, "buffer = +premium -faceSplit");

        uint256 navAfter = vault.nav();
        assertGt(navAfter, navBefore, "NAV rose by the captured spread");
    }

    function test_vault_redeemInKindOracleFree() public {
        _depositLP(10_000e6);
        _buyM(buyer, 200e18); // create held L

        uint256 supply = vault.totalSupply();
        uint256 bufBefore = vault.buffer();
        uint256 lBefore = vault.l_held();
        uint256 lpShares = vault.balanceOf(lp);
        uint256 redeemShares = lpShares / 2;
        uint256 scale = vault.SCALE();

        uint256 expUsdc = (bufBefore * redeemShares / supply) / scale;
        uint256 expL = lBefore * redeemShares / supply;

        vm.warp(block.timestamp + 30 days); // oracle now stale — redeem must still work

        uint256 lpUsdcBefore = usdc.balanceOf(lp);
        uint256 lpLBefore = IERC20(lToken).balanceOf(lp);
        vm.prank(lp);
        vault.redeem(redeemShares);

        assertEq(usdc.balanceOf(lp) - lpUsdcBefore, expUsdc, "pro-rata USDC out");
        assertEq(IERC20(lToken).balanceOf(lp) - lpLBefore, expL, "pro-rata L in-kind");
        assertEq(vault.l_held(), lBefore - expL, "l_held decremented");
    }

    function test_vault_pokeHarvests() public {
        _depositLP(10_000e6);
        _buyM(buyer, 200e18);
        uint256 lHeld = vault.l_held();
        assertGt(lHeld, 0, "has L to harvest");

        vm.warp(series.MATURITY() + 1);
        _mockFeed(1, 1, block.timestamp); // keep feed fresh so settle() succeeds
        uint256 bufBefore = vault.buffer();
        vault.poke();
        vm.clearMockedCalls();

        assertTrue(series.settled(), "series settled by poke");
        assertEq(vault.l_held(), 0, "L harvested");
        uint256 pl = series.payout_l();
        uint256 scale = vault.SCALE();
        uint256 expGot6 = (lHeld * pl / UNIT) / scale;
        assertEq(vault.buffer(), bufBefore + expGot6 * scale, "USDC recovered to buffer");
    }

    // ---- guardrails ----

    function test_vault_nearStrikeFlippedReverts() public {
        _depositLP(10_000e6);
        // push ETH up to 1.2x spot: p=1.2*p0 >= K*0.95 (=1.1875*p0) -> "near strike" (band is flipped)
        _mockFeed(12, 10, block.timestamp);
        uint256 cost = vault.quote_buy_m(10e18);
        _usdcApprove(buyer, address(vault), cost == 0 ? 1e6 : cost);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_m(address(series), 10e18, type(uint256).max);
        vm.clearMockedCalls();
    }

    function test_vault_staleOracleReverts() public {
        _depositLP(10_000e6);
        (,,, uint256 updatedAt,) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + DESK_MAX_STALENESS + 1);
        uint256 cost = vault.quote_buy_m(10e18);
        _usdcApprove(buyer, address(vault), cost);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_m(address(series), 10e18, type(uint256).max);
    }

    function test_vault_sizeCapReverts() public {
        IShortVault v = IShortVault(_deployVault(BIG, BIG, 1e18)); // MAX_FILL = 1 M unit
        _usdcApprove(lp, address(v), 10_000e6);
        vm.prank(lp);
        v.deposit(10_000e6);
        _usdcApprove(buyer, address(v), 1_000e6);
        vm.prank(buyer);
        vm.expectRevert();
        v.buy_m(address(series), 2e18, type(uint256).max); // > MAX_FILL
    }

    function test_vault_writtenCapReverts() public {
        IShortVault v = IShortVault(_deployVault(50e18, BIG, BIG)); // MAX_WRITTEN = 50 face
        _usdcApprove(lp, address(v), 10_000e6);
        vm.prank(lp);
        v.deposit(10_000e6);
        _usdcApprove(buyer, address(v), 1_000e6);
        vm.prank(buyer);
        vm.expectRevert();
        v.buy_m(address(series), 100e18, type(uint256).max); // > MAX_WRITTEN
    }

    function test_vault_dustReverts() public {
        _depositLP(10_000e6);
        // 1 wei of M: cost = 1*price//1e18//SCALE rounds to 0 -> "dust"
        assertEq(vault.quote_buy_m(1), 0, "dust quote rounds to 0");
        _usdcApprove(buyer, address(vault), 1e6);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_m(address(series), 1, type(uint256).max);
    }

    function test_vault_noAdminSurface_noFundExtraction() public {
        _depositLP(10_000e6);
        _buyM(buyer, 100e18);
        uint256 usdcBefore = usdc.balanceOf(address(vault));
        uint256 bufBefore = vault.buffer();
        uint256 lBefore = IERC20(lToken).balanceOf(address(vault));

        address(vault).call(abi.encodeWithSignature("withdraw(uint256)", 1));
        address(vault).call(abi.encodeWithSignature("withdraw_token(address,uint256)", lToken, lBefore));
        address(vault).call(abi.encodeWithSignature("set_paused(bool)", true));
        address(vault).call(abi.encodeWithSignature("transfer_ownership(address)", address(this)));

        assertEq(usdc.balanceOf(address(vault)), usdcBefore, "no USDC extracted");
        assertEq(vault.buffer(), bufBefore, "buffer unchanged");
        assertEq(IERC20(lToken).balanceOf(address(vault)), lBefore, "no L extracted");
        uint256 lpShares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.redeem(lpShares); // the only exit works
    }
}
