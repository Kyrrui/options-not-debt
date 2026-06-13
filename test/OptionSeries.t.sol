// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {IOptionToken, IOptionSeries} from "./Interfaces.sol";

contract OptionSeriesTest is Base {
    IOptionSeries internal series;
    IOptionToken internal P;
    IOptionToken internal N;

    function setUp() public override {
        super.setUp();
        // USD series: x = 2500e18, deep ITM strike 1250e18, 28d term
        series = newUsdSeries(1250e18, 28 days);
        P = IOptionToken(series.P());
        N = IOptionToken(series.N());
    }

    // -------------------------------------------------------- symbology ----

    /// @notice every leg's wallet symbol carries its full contract terms
    ///         (leg, asset, strike, expiry) so vintages never collide
    function test_tokenSymbology() public {
        // setUp series: USD, strike 1250e18, maturity 2026-06-25
        assertEq(P.SYMBOL(), "P-USD-1250-260625");
        assertEq(N.SYMBOL(), "N-USD-1250-260625");
        assertEq(P.NAME(), "Tracking P USD-1250-260625");
        assertEq(N.NAME(), "Leverage N USD-1250-260625");
        // standard lowercase ERC-20 metadata (what wallets/DEXes call)
        assertEq(P.symbol(), "P-USD-1250-260625");
        assertEq(P.name(), "Tracking P USD-1250-260625");
        assertEq(P.decimals(), 18);

        // fractional strike + registered asset symbol from the hub
        IOptionSeries xau = IOptionSeries(
            factory.create_series(xauId, 0.5e18, block.timestamp + 14 days)
        );
        assertEq(IOptionToken(xau.P()).SYMBOL(), "P-XAU-0.500-260611");
        assertEq(IOptionToken(xau.N()).SYMBOL(), "N-XAU-0.500-260611");

        // sub-unit strike with leading zero padding
        IOptionSeries tiny = IOptionSeries(
            factory.create_series(USD, 0.001e18, block.timestamp + 14 days)
        );
        assertEq(IOptionToken(tiny.P()).SYMBOL(), "P-USD-0.001-260611");
    }

    // ------------------------------------------------------------ split ----

    function test_split_mintsEqualLegs() public {
        vm.prank(alice);
        series.split{value: 10 ether}();
        assertEq(P.balanceOf(alice), 10 ether);
        assertEq(N.balanceOf(alice), 10 ether);
        assertEq(address(series).balance, 10 ether);
    }

    function test_split_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert();
        series.split{value: 0}();
    }

    function test_split_revertsAfterMaturity() public {
        vm.warp(series.MATURITY());
        vm.prank(alice);
        vm.expectRevert();
        series.split{value: 1 ether}();
    }

    function test_tokenMintBurn_onlySeries() public {
        vm.prank(alice);
        vm.expectRevert();
        P.mint(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        P.burn(alice, 1 ether);
    }

    // ------------------------------------------------------------ merge ----

    function test_merge_roundTrip() public {
        vm.startPrank(alice);
        series.split{value: 10 ether}();
        uint256 before = alice.balance;
        series.merge(4 ether);
        vm.stopPrank();
        assertEq(alice.balance, before + 4 ether);
        assertEq(P.balanceOf(alice), 6 ether);
        assertEq(N.balanceOf(alice), 6 ether);
        assertEq(address(series).balance, 6 ether);
    }

    function test_merge_worksAfterSettlement() public {
        vm.prank(alice);
        series.split{value: 10 ether}();
        vm.warp(series.MATURITY());
        refreshFeeds();
        series.settle();
        uint256 before = alice.balance;
        vm.prank(alice);
        series.merge(10 ether);
        assertEq(alice.balance, before + 10 ether);
    }

    function test_merge_revertsWithoutBothLegs() public {
        vm.prank(alice);
        series.split{value: 1 ether}();
        vm.prank(alice);
        P.transfer(bob, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        series.merge(1 ether);
    }

    // ----------------------------------------------------------- settle ----

    function test_settle_aboveStrike() public {
        // x = 2500 > S = 1250 -> P gets S/x = 0.5 ETH per unit
        vm.warp(series.MATURITY());
        refreshFeeds();
        series.settle();
        assertTrue(series.settled());
        assertEq(series.settlement_index(), 2500e18);
        assertEq(series.payout_p(), 0.5e18);
    }

    function test_settle_belowStrike_pCapped() public {
        ethFeed.setAnswer(1000e8); // x = 1000 < S = 1250 -> P gets all
        vm.warp(series.MATURITY());
        refreshFeeds();
        series.settle();
        assertEq(series.payout_p(), 1e18);
    }

    function test_settle_revertsEarly() public {
        vm.expectRevert();
        series.settle();
    }

    function test_settle_revertsDouble() public {
        vm.warp(series.MATURITY());
        refreshFeeds();
        series.settle();
        vm.expectRevert();
        series.settle();
    }

    function test_settle_revertsStaleOracle() public {
        vm.warp(series.MATURITY() + ETH_HEARTBEAT + 1);
        // feeds not refreshed -> stale -> lazy settlement waits
        vm.expectRevert();
        series.settle();
        // once the oracle updates again, settlement succeeds (lazy/slow oracle)
        refreshFeeds();
        series.settle();
        assertTrue(series.settled());
    }

    // ----------------------------------------------------------- redeem ----

    function test_redeem_splitsCollateralExactly() public {
        vm.prank(alice);
        series.split{value: 10 ether}();
        vm.prank(alice);
        P.transfer(bob, 10 ether); // bob holds the tracking leg

        vm.warp(series.MATURITY());
        refreshFeeds();
        series.settle(); // payout_p = 0.5e18

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        series.redeem_p(10 ether);
        assertEq(bob.balance, bobBefore + 5 ether); // 10 * 0.5

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        series.redeem_n(10 ether);
        assertEq(alice.balance, aliceBefore + 5 ether);
        assertEq(address(series).balance, 0);
    }

    function test_redeem_revertsBeforeSettle() public {
        vm.prank(alice);
        series.split{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert();
        series.redeem_p(1 ether);
    }

    function test_pTracksAsset_deepITM() public {
        // soft peg sanity: P_1250 with x=2500 settles worth exactly
        // 1250 USD per 1e18 P, i.e. min(S, x) asset units
        vm.prank(alice);
        series.split{value: 1 ether}();
        vm.warp(series.MATURITY());
        ethFeed.setAnswer(3300e8); // ETH rallies; P should still be $1250
        refreshFeeds();
        series.settle();
        uint256 before = alice.balance;
        vm.prank(alice);
        series.redeem_p(1 ether);
        uint256 got = alice.balance - before; // wei
        // value in USD = got * 3300 / 1e18, expected 1250
        assertApproxEqAbs(got * 3300 / 1e18, 1250, 1);
    }

    // ------------------------------------------------------------- fuzz ----

    /// @notice conservation: for any settlement index and any amount,
    ///         P-payout + N-payout never exceeds locked ETH and the
    ///         rounding shortfall is < 2 wei per redemption pair.
    function testFuzz_conservation(uint96 amount, uint64 ethUsd) public {
        uint256 amt = bound(uint256(amount), 1, 1_000_000 ether);
        uint256 px = bound(uint256(ethUsd), 1, 1e10); // $1e-8 .. $100/1e-8... wide
        vm.deal(alice, amt);
        vm.prank(alice);
        series.split{value: amt}();

        vm.warp(series.MATURITY());
        ethFeed.setAnswer(int256(px * 1e8 / 1e2)); // scatter decimals a bit
        if (ethFeed.answer() == 0) ethFeed.setAnswer(1);
        refreshFeeds();
        series.settle();

        uint256 pp = series.payout_p();
        assertLe(pp, UNIT);

        uint256 before = alice.balance;
        vm.startPrank(alice);
        series.redeem_p(amt);
        series.redeem_n(amt);
        vm.stopPrank();
        uint256 got = alice.balance - before;

        assertLe(got, amt, "overpaid");
        assertLt(amt - got, 2, "dust too large");
    }

    /// @notice payout formula: payout_p == min(1e18, S*1e18/x)
    function testFuzz_payoutFormula(uint128 strike, uint128 ethUsd) public {
        uint256 S = bound(uint256(strike), 1e6, 1e30);
        uint256 px = bound(uint256(ethUsd), 1, 1e12); // USD, 0 dec
        IOptionSeries s2 = newUsdSeries(S, 14 days);
        ethFeed.setAnswer(int256(px) * 1e8);
        vm.warp(s2.MATURITY());
        refreshFeeds();
        s2.settle();
        uint256 x = px * 1e18;
        uint256 expected = x > S ? S * UNIT / x : UNIT;
        assertEq(s2.payout_p(), expected);
    }

    /// @notice merge is value-exact for any state
    function testFuzz_mergeExact(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1, 100_000 ether);
        vm.deal(alice, amt);
        vm.startPrank(alice);
        series.split{value: amt}();
        uint256 before = alice.balance;
        series.merge(amt);
        vm.stopPrank();
        assertEq(alice.balance, before + amt);
        assertEq(address(series).balance, 0);
    }
}
