// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {IOptionToken, IOptionSeries, ITrackerDAO} from "./Interfaces.sol";

contract TrackerDAOTest is Base {
    ITrackerDAO internal dao;

    function setUp() public override {
        super.setUp();
        dao = newDao(USD, "Soft Peg USD", "spUSD"); // ETH-backed USD tracker
    }

    function _active() internal view returns (IOptionSeries) {
        return IOptionSeries(dao.active_series());
    }

    function _pending() internal view returns (IOptionSeries) {
        return IOptionSeries(dao.pending_series());
    }

    // --------------------------------------------------------- deposits ----

    function test_firstDeposit_createsDeepItmSeriesAndPegs() public {
        vm.prank(bob);
        uint256 shares = dao.deposit{value: 10 ether}();

        IOptionSeries s = _active();
        assertEq(s.STRIKE(), 1250e18); // x * 0.5
        assertEq(s.MATURITY(), block.timestamp + 28 days);

        // DAO keeps P only; bob got the N leg back
        assertEq(IOptionToken(s.P()).balanceOf(address(dao)), 10 ether);
        assertEq(IOptionToken(s.N()).balanceOf(address(dao)), 0);
        assertEq(IOptionToken(s.N()).balanceOf(bob), 10 ether);

        // 10 ETH * min(x,S)=1250 -> 12500 asset units; dead shares carved out
        assertEq(shares, 12500e18 - 1000);
        assertEq(dao.totalSupply(), 12500e18);
        assertEq(dao.nav(), 12500e18);
        assertEq(dao.share_price(), 1e18); // the soft peg
    }

    function test_peg_holdsWhenEthRallies() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        ethFeed.setAnswer(5000e8); // ETH doubles
        assertEq(dao.share_price(), 1e18); // P is capped at S: still 1 USD/share
        ethFeed.setAnswer(100_000e8);
        assertEq(dao.share_price(), 1e18);
    }

    function test_peg_driftsOnlyBelowStrike() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        ethFeed.setAnswer(2000e8); // still above 1250 strike
        assertEq(dao.share_price(), 1e18);
        ethFeed.setAnswer(1000e8); // crash through the strike
        assertEq(dao.share_price(), 0.8e18); // 1000/1250: bounded drift, no default
    }

    function test_secondDepositor_fairShares() public {
        vm.prank(bob);
        uint256 sBob = dao.deposit{value: 10 ether}();
        vm.prank(carol);
        uint256 sCarol = dao.deposit{value: 10 ether}();
        assertEq(sCarol, sBob + 1000); // bob paid the dead-share carve-out
        assertEq(dao.nav(), 25000e18);
        assertEq(dao.share_price(), 1e18);
    }

    function test_deposit_revertsZero() public {
        vm.prank(bob);
        vm.expectRevert();
        dao.deposit{value: 0}();
    }

    function test_deposit_revertsWhenRollNeeded() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        ethFeed.setAnswer(1850e8); // x < 1.5 * S -> roll required first
        vm.prank(carol);
        vm.expectRevert();
        dao.deposit{value: 1 ether}();
        dao.sync(); // starts the roll; deposits flow to pending now
        vm.prank(carol);
        dao.deposit{value: 1 ether}();
        assertEq(dao.p_bal(dao.pending_series()), 1 ether);
    }

    // ----------------------------------------------------------- redeem ----

    function test_redeem_proRataP() public {
        vm.prank(bob);
        uint256 shares = dao.deposit{value: 10 ether}();
        IOptionToken P = IOptionToken(_active().P());

        vm.prank(bob);
        dao.redeem(shares / 2);
        // bob held all-but-dead shares; half of them ~ half the P
        assertApproxEqAbs(P.balanceOf(bob), 5 ether, 1e15);
        assertApproxEqAbs(P.balanceOf(address(dao)), 5 ether, 1e15);
    }

    function test_redeem_oracleFree() public {
        vm.prank(bob);
        uint256 shares = dao.deposit{value: 10 ether}();
        // oracle goes completely stale: exits still work
        vm.warp(block.timestamp + 30 days);
        vm.prank(bob);
        dao.redeem(shares);
        assertGt(IOptionToken(_active().P()).balanceOf(bob), 0);
    }

    function test_redeem_revertsOverBalance() public {
        vm.prank(bob);
        uint256 shares = dao.deposit{value: 10 ether}();
        vm.prank(bob);
        vm.expectRevert();
        dao.redeem(shares + 1);
    }

    // ------------------------------------------------------------- roll ----

    function test_sync_startsRollOnPriceDrop() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        address old = dao.active_series();

        ethFeed.setAnswer(1850e8); // 1850 < 1.5*1250=1875 -> trigger
        dao.sync();

        assertEq(dao.active_series(), old);
        assertTrue(dao.pending_series() != address(0));
        assertEq(_pending().STRIKE(), 925e18); // x * 0.5
        assertEq(dao.roll_started(), block.timestamp);
    }

    function test_sync_startsRollNearMaturity() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        vm.warp(block.timestamp + 21 days); // 7d window of 28d term
        refreshFeeds();
        dao.sync();
        assertTrue(dao.pending_series() != address(0));
    }

    function test_fillRoll_rotatesAtOracleFairRate() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        ethFeed.setAnswer(1850e8);
        dao.sync();

        IOptionSeries oldS = _active();
        IOptionSeries newS = _pending();

        // expected: 10e18 * val_old(1250) / val_new(925), zero edge at t0
        uint256 required = dao.roll_quote(10 ether);
        assertEq(required, uint256(10 ether) * 1250 / 925);

        // carol sources new P by splitting ETH (keeps the N leverage leg)
        vm.startPrank(carol);
        newS.split{value: 14 ether}();
        IOptionToken(newS.P()).approve(address(dao), type(uint256).max);
        dao.fill_roll(10 ether);
        vm.stopPrank();

        // roll finalized: carol holds all old P, DAO holds required new P
        assertEq(dao.active_series(), address(newS));
        assertEq(dao.pending_series(), address(0));
        assertEq(IOptionToken(oldS.P()).balanceOf(carol), 10 ether);
        assertEq(dao.p_bal(address(newS)), required);

        // NAV preserved through the roll (zero-edge fill): still ~12500 USD
        assertApproxEqRel(dao.nav(), 12500e18, 1e12);
        assertApproxEqRel(dao.share_price(), 1e18, 1e12);
    }

    function test_fillRoll_edgeRampsLinearly() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        ethFeed.setAnswer(1850e8);
        dao.sync();

        uint256 q0 = dao.roll_quote(10 ether);
        vm.warp(block.timestamp + 12 hours); // half of AUCTION_DUR
        refreshFeeds();
        uint256 qHalf = dao.roll_quote(10 ether);
        vm.warp(block.timestamp + 12 hours);
        refreshFeeds();
        uint256 qFull = dao.roll_quote(10 ether);
        vm.warp(block.timestamp + 5 days); // capped at MAX_EDGE
        refreshFeeds();
        uint256 qLate = dao.roll_quote(10 ether);

        assertEq(qHalf, q0 * 99 / 100); // 1% at half ramp
        assertEq(qFull, q0 * 98 / 100); // MAX_EDGE = 2%
        assertEq(qLate, qFull);
    }

    function test_rollFallback_settleAndHarvest() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        address old = dao.active_series();

        // nobody fills the roll; old series matures and settles via slow oracle
        vm.warp(block.timestamp + 21 days);
        refreshFeeds();
        dao.sync(); // starts roll
        assertTrue(dao.pending_series() != address(0));
        address pend = dao.pending_series();

        vm.warp(block.timestamp + 8 days); // past maturity
        refreshFeeds();
        dao.sync(); // settles, harvests, finalizes

        assertEq(dao.active_series(), pend);
        assertEq(dao.pending_series(), address(0));
        assertEq(dao.p_bal(old), 0);
        // payout_p = 1250/2500 = 0.5 -> harvested 5 ETH
        assertEq(dao.eth_buffer(), 5 ether);
        assertEq(dao.buy_started(), block.timestamp);
        // NAV: 5 ETH * 2500 = 12500 USD -> peg held through the fallback
        assertEq(dao.nav(), 12500e18);
    }

    function test_sellP_rotatesHarvestBackIntoPeg() public {
        // reach harvested state (5 ETH buffer, fresh active series)
        test_rollFallback_settleAndHarvest();
        IOptionSeries s = _active();

        // carol mints P at the live series and sells it to the DAO
        vm.startPrank(carol);
        s.split{value: 4 ether}();
        IOptionToken(s.P()).approve(address(dao), type(uint256).max);
        uint256 quote = dao.p_quote(4 ether);
        uint256 before = carol.balance;
        dao.sell_p(4 ether);
        vm.stopPrank();

        // t0 bid: intrinsic 0.5 ETH/P * (1 - MAX_EDGE)
        assertEq(quote, uint256(4 ether) * 5 / 10 * 98 / 100);
        assertEq(carol.balance, before + quote);
        assertEq(dao.p_bal(address(s)), 4 ether);
        assertEq(dao.eth_buffer(), 5 ether - quote);
    }

    function test_sellP_revertsOverBuffer() public {
        test_rollFallback_settleAndHarvest();
        IOptionSeries s = _active();
        vm.startPrank(carol);
        s.split{value: 50 ether}();
        IOptionToken(s.P()).approve(address(dao), type(uint256).max);
        vm.expectRevert();
        dao.sell_p(50 ether); // would cost more than the buffer holds
        vm.stopPrank();
    }

    // ------------------------------------------------------ manipulation ----

    function test_donations_dontMoveNav() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        uint256 nav0 = dao.nav();

        // donate ETH + P tokens directly
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(dao).call{value: 5 ether}("");
        assertTrue(ok);
        IOptionSeries s = _active();
        vm.startPrank(carol);
        s.split{value: 3 ether}();
        IOptionToken(s.P()).transfer(address(dao), 3 ether);
        vm.stopPrank();

        assertEq(dao.nav(), nav0); // tracked accounting only
    }

    function test_daoNeverHoldsN() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        assertEq(IOptionToken(_active().N()).balanceOf(address(dao)), 0);
        vm.prank(carol);
        dao.deposit{value: 3 ether}();
        assertEq(IOptionToken(_active().N()).balanceOf(address(dao)), 0);
    }

    // ------------------------------------------------------------- RWA -----

    function test_rwaTracker_gold() public {
        ITrackerDAO gold = newDao(xauId, "Soft Peg Gold", "spXAU");
        vm.prank(bob);
        gold.deposit{value: 10 ether}(); // x(XAU) = 1e18: 1 ETH = 1 oz

        IOptionSeries s = IOptionSeries(gold.active_series());
        assertEq(s.STRIKE(), 0.5e18);
        assertEq(gold.nav(), 5e18); // 10 ETH * 0.5 oz strike = 5 oz
        assertEq(gold.share_price(), 1e18); // 1 share ~= 1 oz

        // gold price doubles in USD: x halves; ETH rallies: peg holds
        ethFeed.setAnswer(10000e8); // x = 10000/2500 = 4e18 > strike
        assertEq(gold.share_price(), 1e18);
    }

    function testFuzz_pegInvariantAboveStrike(uint64 px) public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();
        uint256 strike = _active().STRIKE() / 1e18; // 1250
        uint256 p = bound(uint256(px), strike, 1_000_000); // any price >= strike
        ethFeed.setAnswer(int256(p) * 1e8);
        assertEq(dao.share_price(), 1e18, "peg must hold above strike");
    }

    // --------------------------------------------- review regressions ------

    /// @notice constructor must reject configs where the roll rule already
    ///         covers a freshly created series (genesis self-roll brick)
    function deployBrickConfig() external {
        deployCode(
            "TrackerDAO",
            abi.encode(
                "Brick", "BRK", address(hub), address(factory), USD,
                uint256(28 days), uint256(7 days),
                uint256(3e18),   // ROLL_TRIGGER
                uint256(0.5e18), // STRIKE_RATIO: 0.5 * 3 = 1.5 > 0.95 -> brick
                uint256(1 days), uint256(0.02e18)
            )
        );
    }

    function test_constructor_revertsGenesisSelfRoll() public {
        vm.expectRevert();
        this.deployBrickConfig();
    }

    /// @notice the sell_p ramp must restart at the discount end on every
    ///         fresh harvest — a 1-wei leftover buffer must not let later
    ///         harvests be bought instantly at max premium
    function test_sellP_rampRestartsOnSecondHarvest() public {
        test_rollFallback_settleAndHarvest(); // harvest #1: 5 ETH buffer
        IOptionSeries s = _active();

        // drain most (not all) of the buffer at the saturated-ramp price
        vm.warp(block.timestamp + 2 days); // ramp fully saturated
        refreshFeeds();
        vm.startPrank(carol);
        s.split{value: 4 ether}();
        IOptionToken(s.P()).approve(address(dao), type(uint256).max);
        dao.sell_p(4 ether);
        vm.stopPrank();
        assertGt(dao.eth_buffer(), 0, "buffer must stay nonzero");

        // saturated quote pays the max premium: intrinsic * (1 + MAX_EDGE)
        assertEq(dao.p_quote(1 ether), uint256(1 ether) * 5 / 10 * 102 / 100);

        // jump past the active series' maturity with the buffer still >0:
        // one sync settles it, harvests (#2), rolls, and finalizes
        vm.warp(block.timestamp + 21 days);
        refreshFeeds();
        dao.sync();

        // immediately after the harvest the DAO bids the DISCOUNT end again;
        // without the re-anchor it would still quote the saturated premium
        assertEq(dao.p_quote(1 ether), uint256(1 ether) * 5 / 10 * 98 / 100);
    }

    /// @notice audit (completeness critic, LOW): deposits must be blocked
    ///         when the target series itself needs rolling — including a
    ///         pending series that deteriorated while a roll stalled, which
    ///         sync cannot start a nested roll for
    function test_deposit_blockedWhenStalledPendingNeedsRoll() public {
        vm.prank(bob);
        dao.deposit{value: 10 ether}();

        // trigger a roll (x falls within 1.5x of the 1250 strike)
        ethFeed.setAnswer(1850e8);
        dao.sync();
        IOptionSeries pending = _pending();
        assertTrue(address(pending) != address(0));
        // a healthy fresh pending series still accepts deposits
        vm.prank(carol);
        dao.deposit{value: 1 ether}();

        // roll stalls (nobody fills); price falls through the PENDING
        // strike's own trigger (pending strike = 1850*0.5 = 925; trips at
        // x < 925*1.5 = 1387.5)
        ethFeed.setAnswer(1300e8);
        vm.expectRevert(); // "sync required" — pending now needs rolling too
        vm.prank(carol);
        dao.deposit{value: 1 ether}();
    }

    /// @notice cross-function reentrancy: reentering deposit() from the ETH
    ///         send inside redeem() must be blocked by the global lock
    function test_reentrancy_redeemToDeposit_blocked() public {
        test_rollFallback_settleAndHarvest(); // gives the DAO an ETH buffer

        Reenterer attacker = new Reenterer(dao);
        vm.deal(address(attacker), 2 ether);
        attacker.depositFor{value: 1 ether}();

        attacker.arm();
        vm.expectRevert(); // raw_call bubbles the blocked reentrant deposit
        attacker.redeemAll();

        attacker.disarm();
        attacker.redeemAll(); // sanity: works when not attacking
    }
}

contract Reenterer {
    ITrackerDAO internal dao;
    bool internal attack;

    constructor(ITrackerDAO dao_) {
        dao = dao_;
    }

    function depositFor() external payable {
        dao.deposit{value: msg.value}();
    }

    function arm() external {
        attack = true;
    }

    function disarm() external {
        attack = false;
    }

    function redeemAll() external {
        dao.redeem(dao.balanceOf(address(this)));
    }

    receive() external payable {
        if (attack) {
            dao.deposit{value: msg.value}();
        }
    }
}
