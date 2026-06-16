// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IGimbalSimpleVault {
    function deposit() external payable returns (uint256);
    function redeem(uint256 shares) external;
    function buy_n(address series, uint256 amount, uint256 max_cost) external payable returns (uint256);
    function poke() external;
    function quote_buy_n(address series, uint256 amount) external view returns (uint256);
    function intrinsic_n(address series) external view returns (uint256);
    function nav() external view returns (uint256);
    function share_price() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function eth_buffer() external view returns (uint256);
    function p_held(address series) external view returns (uint256);
    function total_p_held() external view returns (uint256);
    function is_open(address series) external view returns (bool);
    function open_series_count() external view returns (uint256);
    function BASE_EDGE() external view returns (uint256);
}

interface ITracker {
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
    function ROLL_TRIGGER() external view returns (uint256);
}

interface ISeries {
    function P() external view returns (address);
    function N() external view returns (address);
    function STRIKE() external view returns (uint256);
    function MATURITY() external view returns (uint256);
    function settled() external view returns (bool);
    function payout_p() external view returns (uint256);
    function split() external payable;
}

interface IOracleHub {
    function latest_price(bytes32 asset) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork test of GimbalSimpleVault against LIVE Sepolia: the real spUSD TrackerDAO,
///         its current OptionSeries vintage, the OracleHub + live ETH/USD Chainlink feed.
///         Proves the minimal immutable ownerless house:
///           * deposit -> shares at NAV (+ DEAD_SHARES donation guard);
///           * buy_n   -> writes N on-chain-priced, keeps P, NAV rises by the spread;
///           * redeem  -> pro-rata buffered ETH + in-kind P, ORACLE-FREE (works while stale);
///           * poke    -> best-effort settle + harvest settled P back to ETH;
///           * guardrails: near-maturity, stale-oracle, size, written-cap, block-cap;
///           * NO owner/admin surface exists.
///
/// Run: forge test --match-path test/GimbalSimpleVault.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract GimbalSimpleVaultForkTest is Test {
    uint256 constant UNIT = 1e18;
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant HUB = 0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    bytes32 constant USD = bytes32(0);

    uint256 constant BASE_EDGE = 1e16; // 1%
    uint256 constant DESK_MAX_STALENESS = 3600;
    uint256 constant PRE_MATURITY_BUFFER = 2 days;
    uint256 constant OUTFLOW_WINDOW = 3600;
    uint256 constant BIG = type(uint128).max;

    IGimbalSimpleVault internal vault;
    address internal series;
    address internal pToken;
    address internal nToken;
    uint256 internal strikeProximity;

    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        series = ITracker(SPUSD).pending_series();
        if (series == address(0)) series = ITracker(SPUSD).active_series();
        require(series != address(0), "no series");
        if (ISeries(series).settled()) {
            vm.skip(true);
            return;
        }
        pToken = ISeries(series).P();
        nToken = ISeries(series).N();
        strikeProximity = ITracker(SPUSD).ROLL_TRIGGER();

        // make the live feed "fresh" relative to block time so the tight staleness gate
        // passes deterministically regardless of the fork block
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + 60);

        if (IOracleHub(HUB).latest_price(USD) <= ISeries(series).STRIKE() * strikeProximity / UNIT) {
            vm.skip(true);
            return;
        }
        if (block.timestamp + PRE_MATURITY_BUFFER >= ISeries(series).MATURITY()) {
            vm.skip(true);
            return;
        }

        vault = IGimbalSimpleVault(_deployVault(BIG, BIG, BIG));
        vm.deal(lp, 100 ether);
        vm.deal(lp2, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _deployVault(uint256 maxWritten, uint256 maxWritePerBlock, uint256 maxFill)
        internal
        returns (address)
    {
        return deployCode(
            "GimbalSimpleVault",
            abi.encode(
                SPUSD, // tracker
                HUB, // oracle hub
                USD, // asset (USD-only v1)
                BASE_EDGE,
                DESK_MAX_STALENESS,
                PRE_MATURITY_BUFFER,
                strikeProximity, // == ROLL_TRIGGER
                maxFill,
                maxWritten,
                OUTFLOW_WINDOW,
                BIG, // outflow_cap (unconstrained for these tests)
                maxWritePerBlock,
                BIG // total_deposit_cap
            )
        );
    }

    function _freshFeed() internal {
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + 60);
    }

    function _depositAs(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit{value: amt}();
    }

    function _buyAs(address who, uint256 amount) internal returns (uint256 cost) {
        cost = vault.quote_buy_n(series, amount);
        vm.prank(who);
        vault.buy_n{value: cost}(series, amount, cost);
    }

    // ---------------------------------------------------------------- deposit

    function test_deposit_mintsSharesWithDeadShareGuard() public {
        uint256 shares = _depositAs(lp, 1 ether);
        // first deposit: DEAD_SHARES (1e3) burned to 0xdead, rest to lp
        assertEq(shares, 1 ether - 1e3, "lp shares = value - DEAD_SHARES");
        assertEq(vault.totalSupply(), 1 ether, "supply == value");
        assertEq(vault.eth_buffer(), 1 ether, "buffer holds the deposit");
        assertEq(vault.share_price(), UNIT, "share price ~ 1 with only ETH held");
        // second LP prices in at NAV
        uint256 s2 = _depositAs(lp2, 1 ether);
        assertApproxEqAbs(s2, 1 ether, 1e3, "second deposit ~ pro-rata");
    }

    // ---------------------------------------------------------------- buy_n write path

    function test_buyN_writesKeepsP_navRisesBySpread() public {
        _depositAs(lp, 5 ether);
        uint256 amount = 0.1 ether;

        uint256 navBefore = vault.nav();
        uint256 bufBefore = vault.eth_buffer();
        uint256 intrinsic = vault.intrinsic_n(series);
        uint256 buyerNBefore = IERC20(nToken).balanceOf(buyer);

        uint256 cost = _buyAs(buyer, amount);

        // buyer got N; vault kept P, holds no leftover N
        assertEq(IERC20(nToken).balanceOf(buyer) - buyerNBefore, amount, "buyer received N");
        assertEq(vault.p_held(series), amount, "vault kept the P leg");
        assertEq(vault.total_p_held(), amount, "risk meter tracks P face");
        assertEq(IERC20(nToken).balanceOf(address(vault)), 0, "vault holds no leftover N");
        assertTrue(vault.is_open(series), "series registered open");
        assertEq(vault.open_series_count(), 1, "one open series");

        // buffer moved by (cost - amount): the house funded the split net of premium
        assertEq(vault.eth_buffer(), bufBefore + cost - amount, "buffer = +premium -faceSplit");

        // NAV rose by exactly the captured spread = amount*intrinsic*BASE_EDGE
        uint256 navAfter = vault.nav();
        assertGt(navAfter, navBefore, "NAV rose (spread captured)");
        uint256 expectedSpread = amount * intrinsic / UNIT * BASE_EDGE / UNIT;
        assertApproxEqAbs(navAfter - navBefore, expectedSpread, 1e9, "NAV delta == spread");
    }

    function test_quote_matchesFloorPrice() public view {
        uint256 amount = 0.05 ether;
        uint256 intrinsic = vault.intrinsic_n(series);
        uint256 expected = amount * (intrinsic * (UNIT + BASE_EDGE) / UNIT) / UNIT;
        assertEq(vault.quote_buy_n(series, amount), expected, "quote == intrinsic*(1+edge)");
    }

    // ---------------------------------------------------------------- redeem (oracle-free, in-kind)

    function test_redeem_proRataInKind_worksWhileOracleStale() public {
        _depositAs(lp, 4 ether);
        _buyAs(buyer, 0.2 ether); // create some held P

        uint256 supply = vault.totalSupply();
        uint256 bufBefore = vault.eth_buffer();
        uint256 pBefore = vault.p_held(series);
        uint256 lpShares = vault.balanceOf(lp);
        uint256 redeemShares = lpShares / 2;

        uint256 expEth = bufBefore * redeemShares / supply;
        uint256 expP = pBefore * redeemShares / supply;

        // push the oracle WELL past the staleness bound — redeem must still work (no oracle on exit)
        vm.warp(block.timestamp + 30 days);

        uint256 lpEthBefore = lp.balance;
        uint256 lpPBefore = IERC20(pToken).balanceOf(lp);
        vm.prank(lp);
        vault.redeem(redeemShares);

        assertEq(lp.balance - lpEthBefore, expEth, "pro-rata buffered ETH out");
        assertEq(IERC20(pToken).balanceOf(lp) - lpPBefore, expP, "pro-rata P in-kind");
        assertEq(vault.eth_buffer(), bufBefore - expEth, "buffer decremented");
        assertEq(vault.p_held(series), pBefore - expP, "p_held decremented");
        assertEq(vault.total_p_held(), pBefore - expP, "risk meter decremented");
    }

    function test_redeem_overBalanceReverts() public {
        _depositAs(lp, 1 ether);
        uint256 bal = vault.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert();
        vault.redeem(bal + 1);
    }

    // ---------------------------------------------------------------- poke / harvest

    function test_poke_harvestsSettledP() public {
        _depositAs(lp, 4 ether);
        _buyAs(buyer, 0.2 ether);
        uint256 pHeld = vault.p_held(series);
        assertGt(pHeld, 0, "has P to harvest");

        // jump past maturity and keep the feed fresh via a mock so settle() can succeed
        uint256 mat = ISeries(series).MATURITY();
        vm.warp(mat + 1);
        int256 answer;
        {
            (uint80 rid, int256 a, uint256 sa, , uint80 ai) = IAggregator(ETH_USD_FEED).latestRoundData();
            answer = a;
            vm.mockCall(
                ETH_USD_FEED,
                abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                abi.encode(rid, a, sa, block.timestamp, ai)
            );
        }

        uint256 bufBefore = vault.eth_buffer();
        vault.poke(); // permissionless

        assertTrue(ISeries(series).settled(), "series settled by poke");
        uint256 pp = ISeries(series).payout_p();
        assertEq(vault.p_held(series), 0, "P harvested");
        assertEq(vault.total_p_held(), 0, "risk meter cleared");
        assertEq(vault.open_series_count(), 0, "series dropped from open set");
        assertEq(vault.eth_buffer(), bufBefore + pHeld * pp / UNIT, "ETH recovered to buffer");
        vm.clearMockedCalls();
    }

    // ---------------------------------------------------------------- guardrails

    function test_buyN_staleOracleReverts() public {
        _depositAs(lp, 2 ether);
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + DESK_MAX_STALENESS + 1); // past tight bound, within hub heartbeat
        uint256 cost = vault.quote_buy_n(series, 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_n{value: cost}(series, 0.01 ether, cost);
    }

    function test_buyN_nearMaturityReverts() public {
        _depositAs(lp, 2 ether);
        uint256 mat = ISeries(series).MATURITY();
        vm.warp(mat - PRE_MATURITY_BUFFER + 1); // inside the buffer
        _freshFeed_at(mat - PRE_MATURITY_BUFFER + 1);
        uint256 cost = vault.quote_buy_n(series, 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_n{value: cost}(series, 0.01 ether, cost);
    }

    function test_buyN_badValueReverts() public {
        _depositAs(lp, 2 ether);
        uint256 cost = vault.quote_buy_n(series, 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy_n{value: cost - 1}(series, 0.01 ether, cost);
    }

    function test_buyN_sizeCapReverts() public {
        IGimbalSimpleVault v = IGimbalSimpleVault(_deployVault(BIG, BIG, 0.01 ether)); // MAX_FILL = 0.01
        vm.prank(lp);
        v.deposit{value: 2 ether}();
        uint256 cost = v.quote_buy_n(series, 0.02 ether);
        vm.prank(buyer);
        vm.expectRevert();
        v.buy_n{value: cost}(series, 0.02 ether, cost); // > MAX_FILL
    }

    function test_buyN_writtenCapReverts() public {
        IGimbalSimpleVault v = IGimbalSimpleVault(_deployVault(0.05 ether, BIG, BIG)); // MAX_WRITTEN = 0.05
        vm.prank(lp);
        v.deposit{value: 2 ether}();
        uint256 cost = v.quote_buy_n(series, 0.1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        v.buy_n{value: cost}(series, 0.1 ether, cost); // > MAX_WRITTEN
    }

    function test_buyN_blockCapReverts() public {
        IGimbalSimpleVault v = IGimbalSimpleVault(_deployVault(BIG, 0.05 ether, BIG)); // MAX_WRITE_PER_BLOCK = 0.05
        vm.prank(lp);
        v.deposit{value: 2 ether}();
        uint256 cost = v.quote_buy_n(series, 0.1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        v.buy_n{value: cost}(series, 0.1 ether, cost); // > per-block cap
    }

    // ---------------------------------------------------------------- no owner/admin surface

    function test_noAdminSurface_noFundExtraction() public {
        _depositAs(lp, 2 ether);
        _buyAs(buyer, 0.1 ether); // give the vault ETH + P to (try to) steal
        uint256 ethBalBefore = address(vault).balance;
        uint256 bufBefore = vault.eth_buffer();
        uint256 pBefore = IERC20(pToken).balanceOf(address(vault));

        // every admin/rug selector the operator desks carried — they don't exist here, so
        // each falls through to the INERT payable __default__: it "succeeds" but moves
        // nothing and changes no state. There is no callable path that extracts funds.
        address(vault).call(abi.encodeWithSignature("withdraw_eth(uint256)", 1 ether));
        address(vault).call(abi.encodeWithSignature("withdraw_token(address,uint256)", pToken, pBefore));
        address(vault).call(abi.encodeWithSignature("set_paused(bool)", true));
        address(vault).call(abi.encodeWithSignature("set_quoter(address)", address(this)));
        address(vault).call(abi.encodeWithSignature("set_caps(uint256,uint256,uint256,uint256)", 0, 0, 0, 0));
        address(vault).call(abi.encodeWithSignature("transfer_ownership(address)", address(this)));

        assertEq(address(vault).balance, ethBalBefore, "no ETH extracted");
        assertEq(vault.eth_buffer(), bufBefore, "buffer unchanged");
        assertEq(IERC20(pToken).balanceOf(address(vault)), pBefore, "no P extracted");
        // the only ETH outflow path is an LP redeeming its OWN shares
        uint256 lpShares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.redeem(lpShares); // succeeds — the sole, permissionless, self-only exit
    }

    // helper: warp to a specific time but keep the feed reported fresh
    function _freshFeed_at(uint256 ts) internal {
        vm.warp(ts);
        (uint80 rid, int256 a, uint256 sa, , uint80 ai) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(IAggregator.latestRoundData.selector),
            abi.encode(rid, a, sa, ts, ai)
        );
    }
}
