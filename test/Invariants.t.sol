// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {IOptionToken, IOptionSeries, ITrackerDAO} from "./Interfaces.sol";

/// @notice Random sequences of user actions against one series; checks the
///         fundamental theorem of the design after every sequence:
///         the locked ETH always exactly covers P + N (no liquidations,
///         no bad debt, ever).
contract SeriesHandler is Test {
    IOptionSeries public series;
    IOptionToken public P;
    IOptionToken public N;
    MockV3Aggregator public ethFeed;

    address[3] public actors;

    constructor(IOptionSeries series_, MockV3Aggregator ethFeed_) {
        series = series_;
        ethFeed = ethFeed_;
        P = IOptionToken(series.P());
        N = IOptionToken(series.N());
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA501);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function split(uint256 seed, uint96 amount) public {
        if (series.settled() || block.timestamp >= series.MATURITY()) return;
        address a = _actor(seed);
        uint256 amt = bound(uint256(amount), 1, 1000 ether);
        vm.deal(a, amt);
        vm.prank(a);
        series.split{value: amt}();
    }

    function merge(uint256 seed, uint96 amount) public {
        address a = _actor(seed);
        uint256 maxAmt = P.balanceOf(a) < N.balanceOf(a) ? P.balanceOf(a) : N.balanceOf(a);
        if (maxAmt == 0) return;
        uint256 amt = bound(uint256(amount), 1, maxAmt);
        vm.prank(a);
        series.merge(amt);
    }

    function transferLegs(uint256 seed, uint96 amount) public {
        address from = _actor(seed);
        address to = _actor(seed + 1);
        uint256 pBal = P.balanceOf(from);
        if (pBal > 0) {
            vm.prank(from);
            P.transfer(to, bound(uint256(amount), 1, pBal));
        }
    }

    function movePrice(uint96 newPrice) public {
        // $1 .. $1,000,000 — including crashes far through the strike
        ethFeed.setAnswer(int256(bound(uint256(newPrice), 1, 1_000_000)) * 1e8);
    }

    function timeJump(uint32 dt) public {
        vm.warp(block.timestamp + bound(uint256(dt), 1 hours, 10 days));
        ethFeed.setAnswer(ethFeed.answer()); // oracle keeps reporting
    }

    function settle() public {
        if (series.settled() || block.timestamp < series.MATURITY()) return;
        series.settle();
    }

    function redeemP(uint256 seed, uint96 amount) public {
        if (!series.settled()) return;
        address a = _actor(seed);
        uint256 bal = P.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        series.redeem_p(bound(uint256(amount), 1, bal));
    }

    function redeemN(uint256 seed, uint96 amount) public {
        if (!series.settled()) return;
        address a = _actor(seed);
        uint256 bal = N.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        series.redeem_n(bound(uint256(amount), 1, bal));
    }
}

contract SeriesInvariantTest is Base {
    SeriesHandler internal handler;
    IOptionSeries internal series;
    IOptionToken internal P;
    IOptionToken internal N;

    function setUp() public override {
        super.setUp();
        series = newUsdSeries(1250e18, 28 days);
        P = IOptionToken(series.P());
        N = IOptionToken(series.N());
        handler = new SeriesHandler(series, ethFeed);
        targetContract(address(handler));
    }

    /// @notice Pre-settlement: locked ETH == P supply == N supply (exact).
    ///         Post-settlement: locked ETH covers every outstanding claim.
    function invariant_fullCollateralization() public view {
        uint256 locked = address(series).balance;
        if (!series.settled()) {
            assertEq(P.totalSupply(), N.totalSupply(), "leg supplies diverged");
            assertEq(locked, P.totalSupply(), "collateral mismatch");
        } else {
            uint256 pp = series.payout_p();
            uint256 owed =
                P.totalSupply() * pp / 1e18 + N.totalSupply() * (1e18 - pp) / 1e18;
            assertGe(locked, owed, "insolvent after settlement");
        }
    }

    /// @notice payout never exceeds 1 ETH per unit, in any reachable state
    function invariant_payoutBounded() public view {
        assertLe(series.payout_p(), 1e18);
    }
}

/// @notice Random user/keeper/market action sequences against the wrapper
///         DAO; checks it stays solvent and never holds the leveraged leg.
contract DaoHandler is Test {
    ITrackerDAO public dao;
    MockV3Aggregator public ethFeed;
    address[3] public actors;

    constructor(ITrackerDAO dao_, MockV3Aggregator ethFeed_) {
        dao = dao_;
        ethFeed = ethFeed_;
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA501);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function deposit(uint256 seed, uint96 amount) public {
        address a = _actor(seed);
        uint256 amt = bound(uint256(amount), 0.01 ether, 1000 ether);
        vm.deal(a, amt);
        vm.prank(a);
        try dao.deposit{value: amt}() {} catch {}
    }

    function redeem(uint256 seed, uint96 fraction) public {
        address a = _actor(seed);
        uint256 bal = dao.balanceOf(a);
        if (bal == 0) return;
        vm.prank(a);
        dao.redeem(bound(uint256(fraction), 1, bal));
    }

    function sync() public {
        try dao.sync() {} catch {}
    }

    function movePrice(uint96 bps) public {
        // drift -20%..+20% per step
        uint256 cur = uint256(ethFeed.answer());
        uint256 factor = bound(uint256(bps), 8000, 12000);
        uint256 next = cur * factor / 10000;
        if (next == 0) next = 1e8;
        ethFeed.setAnswer(int256(next));
    }

    function timeJump(uint32 dt) public {
        vm.warp(block.timestamp + bound(uint256(dt), 1 hours, 5 days));
        ethFeed.setAnswer(ethFeed.answer());
    }

    function fillRoll(uint256 seed, uint96 fraction) public {
        address p = dao.pending_series();
        address a0 = dao.active_series();
        if (p == address(0)) return;
        address actor = _actor(seed);
        uint256 oldBal = dao.p_bal(a0);
        if (oldBal == 0) return;
        uint256 amt = bound(uint256(fraction), 1, oldBal);
        uint256 required;
        try dao.roll_quote(amt) returns (uint256 r) {
            required = r;
        } catch {
            return;
        }
        if (required == 0) return;
        vm.deal(actor, required);
        vm.startPrank(actor);
        try IOptionSeries(p).split{value: required}() {
            IOptionToken(IOptionSeries(p).P()).approve(address(dao), required);
            try dao.fill_roll(amt) {} catch {}
        } catch {}
        vm.stopPrank();
    }

    function sellP(uint256 seed, uint96 amount) public {
        address t = dao.pending_series();
        if (t == address(0)) t = dao.active_series();
        if (t == address(0) || dao.eth_buffer() == 0) return;
        address actor = _actor(seed);
        uint256 amt = bound(uint256(amount), 0.001 ether, 100 ether);
        vm.deal(actor, amt);
        vm.startPrank(actor);
        try IOptionSeries(t).split{value: amt}() {
            IOptionToken(IOptionSeries(t).P()).approve(address(dao), amt);
            try dao.sell_p(amt) {} catch {}
        } catch {}
        vm.stopPrank();
    }
}

contract DaoInvariantTest is Base {
    DaoHandler internal handler;
    ITrackerDAO internal dao;

    function setUp() public override {
        super.setUp();
        dao = newDao(USD, "Soft Peg USD", "spUSD");
        handler = new DaoHandler(dao, ethFeed);
        targetContract(address(handler));
    }

    /// @notice tracked accounting never exceeds what the DAO actually holds
    function invariant_daoSolvent() public view {
        assertGe(address(dao).balance, dao.eth_buffer(), "eth buffer phantom");
        address a = dao.active_series();
        address p = dao.pending_series();
        if (a != address(0)) {
            assertGe(
                IOptionToken(IOptionSeries(a).P()).balanceOf(address(dao)),
                dao.p_bal(a),
                "active P phantom"
            );
        }
        if (p != address(0)) {
            assertGe(
                IOptionToken(IOptionSeries(p).P()).balanceOf(address(dao)),
                dao.p_bal(p),
                "pending P phantom"
            );
        }
    }

    /// @notice the DAO never accumulates the leveraged N leg
    function invariant_daoNeverHoldsN() public view {
        address a = dao.active_series();
        address p = dao.pending_series();
        if (a != address(0)) {
            assertEq(IOptionToken(IOptionSeries(a).N()).balanceOf(address(dao)), 0);
        }
        if (p != address(0)) {
            assertEq(IOptionToken(IOptionSeries(p).N()).balanceOf(address(dao)), 0);
        }
    }

    /// @notice share supply only exists against real holdings
    function invariant_sharesBacked() public view {
        if (dao.totalSupply() == 0) return;
        address a = dao.active_series();
        address p = dao.pending_series();
        uint256 holdings = dao.eth_buffer();
        if (a != address(0)) holdings += dao.p_bal(a);
        if (p != address(0)) holdings += dao.p_bal(p);
        assertGt(holdings, 0, "shares with no backing");
    }
}
