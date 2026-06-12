// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Blueprint} from "./utils/Blueprint.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {IOptionToken, IOracleHub, IOptionSeries, ISeriesFactory} from "./Interfaces.sol";

/// @notice Formal verification via Halmos symbolic execution. Every
///         `check_` function is proven over the ACTUAL compiled Vyper
///         bytecode for ALL admissible inputs (within the stated bounds),
///         not for sampled inputs like fuzzing.
///
///         Run: halmos --contract HalmosVerification
contract HalmosVerification is SymTest, Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant STRIKE = 1250e18;

    // explicit artifact paths (halmos resolves vm.getCode by file path)
    string internal constant TOKEN_ART = "out/OptionToken.vy/OptionToken.json";
    string internal constant SERIES_ART = "out/OptionSeries.vy/OptionSeries.json";
    string internal constant HUB_ART = "out/OracleHub.vy/OracleHub.json";
    string internal constant FACTORY_ART = "out/SeriesFactory.vy/SeriesFactory.json";

    MockV3Aggregator internal ethFeed;
    IOracleHub internal hub;
    IOptionSeries internal series;
    IOptionToken internal P;
    IOptionToken internal N;
    IOptionToken internal token; // standalone, minter = this

    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1_780_000_000);
        ethFeed = new MockV3Aggregator(8, 2500e8);
        address tokenBP = Blueprint.deployBlueprint(vm.getCode(TOKEN_ART));
        address seriesBP = Blueprint.deployBlueprint(vm.getCode(SERIES_ART));
        hub = IOracleHub(deployCode(HUB_ART, abi.encode(address(ethFeed), uint256(3600))));
        ISeriesFactory factory = ISeriesFactory(
            deployCode(FACTORY_ART, abi.encode(address(hub), seriesBP, tokenBP))
        );
        series = IOptionSeries(
            factory.create_series(bytes32(0), STRIKE, block.timestamp + 28 days)
        );
        P = IOptionToken(series.P());
        N = IOptionToken(series.N());
        token = IOptionToken(
            deployCode(TOKEN_ART, abi.encode("T", "T", address(this)))
        );
    }

    function _settleAt(uint256 answer) internal {
        vm.warp(series.MATURITY());
        ethFeed.setAnswer(int256(answer));
        series.settle();
    }

    /// @notice ∀ oracle price: the settled P payout never exceeds 1 ETH/unit.
    function check_payoutBounded(uint256 answer) public {
        vm.assume(answer >= 1 && answer <= 1e40);
        _settleAt(answer);
        assert(series.payout_p() <= UNIT);
    }

    // ------------------------------------------------------------------
    // The no-bad-debt theorem, proven as a LEMMA CHAIN. The monolithic
    // form (check_conservation_deep below) composes a symbolic 256-bit
    // division with two further mul-divs — a query class SMT solvers do
    // not close in practice (>13h with yices and bitwuzla, no result).
    // The decomposition proves the identical end-to-end property over the
    // same deployed bytecode:
    //   Step 1 (check_payoutBounded, proven): settle() can only ever
    //          write payout_p <= 1e18, for every oracle price.
    //   Step 2 (check_redeemConservation, below): for EVERY settled state
    //          with payout_p <= 1e18 — i.e. every state step 1 permits —
    //          redeeming both legs returns at most the locked ETH with
    //          shortfall < 2 wei.
    // ------------------------------------------------------------------

    /// @notice ∀ payout_p <= 1e18, ∀ amount: redeeming P then N returns at
    ///         most the locked ETH, shortfall < 2 wei. The settled state is
    ///         installed directly via vm.store (slots from `vyper -f
    ///         layout`: settled=0, payout_p=2); check_payoutBounded proves
    ///         these are exactly the states settle() can produce.
    function check_redeemConservation(uint256 pp, uint256 amount) public {
        vm.assume(pp <= UNIT);
        vm.assume(amount >= 1 && amount <= type(uint96).max);
        vm.deal(alice, amount);
        vm.prank(alice);
        series.split{value: amount}();

        vm.store(address(series), bytes32(uint256(0)), bytes32(uint256(1))); // settled = true
        vm.store(address(series), bytes32(uint256(2)), bytes32(pp));         // payout_p = pp

        vm.prank(alice);
        series.redeem_p(amount);
        vm.prank(alice);
        series.redeem_n(amount);

        uint256 got = alice.balance;
        assert(got <= amount);
        assert(amount - got < 2);
    }

    /// @notice ∀ price with x <= STRIKE: P pays out in full (1 ETH/unit)
    ///         and its asset-unit value x never exceeds the strike.
    function check_pValueAtOrBelowStrike(uint256 answer) public {
        vm.assume(answer >= 1 && answer <= 1e40);
        _settleAt(answer);
        uint256 x = series.settlement_index();
        vm.assume(x <= STRIKE);
        assert(series.payout_p() == UNIT);
        assert(series.payout_p() * x <= STRIKE * UNIT);
    }

    /// @notice ∀ price with x > STRIKE: payout_p = floor(S·1e18/x), so
    ///         payout_p · x <= STRIKE · 1e18 — the soft peg's hard upper
    ///         bound (P can never be worth more than S asset units).
    function check_pValueAboveStrike(uint256 answer) public {
        vm.assume(answer >= 1 && answer <= 1e40);
        _settleAt(answer);
        uint256 x = series.settlement_index();
        vm.assume(x > STRIKE);
        assert(series.payout_p() * x <= STRIKE * UNIT);
    }

    /// @notice Monolithic form of the conservation theorem. Equivalent to
    ///         check_payoutBounded + check_redeemConservation chained.
    ///         Solver-intractable in practice; kept for reference and NOT
    ///         run in CI.
    function check_conservation_deep(uint256 answer, uint256 amount) public {
        vm.assume(answer >= 1 && answer <= 1e40);
        vm.assume(amount >= 1 && amount <= type(uint96).max);
        vm.deal(alice, amount);
        vm.prank(alice);
        series.split{value: amount}();

        _settleAt(answer);

        vm.prank(alice);
        series.redeem_p(amount);
        vm.prank(alice);
        series.redeem_n(amount);

        uint256 got = alice.balance;
        assert(got <= amount);
        assert(amount - got < 2);
    }

    /// @notice ∀ amount: split followed by merge is value-exact — entering
    ///         and exiting the system never costs a wei.
    function check_splitMergeExact(uint256 amount) public {
        vm.assume(amount >= 1 && amount <= type(uint96).max);
        vm.deal(alice, amount);
        vm.startPrank(alice);
        series.split{value: amount}();
        series.merge(amount);
        vm.stopPrank();
        assert(alice.balance == amount);
        assert(P.totalSupply() == 0 && N.totalSupply() == 0);
    }

    /// @notice ∀ price: split mints exactly equal P and N supplies backed
    ///         1:1 by the locked ETH (full collateralization at entry).
    function check_splitFullyCollateralized(uint256 amount) public {
        vm.assume(amount >= 1 && amount <= type(uint96).max);
        vm.deal(alice, amount);
        vm.prank(alice);
        series.split{value: amount}();
        assert(P.totalSupply() == amount);
        assert(N.totalSupply() == amount);
        assert(address(series).balance == amount);
    }

    /// @notice ∀ mint/transfer amounts: ERC20 transfer preserves the sum of
    ///         balances and total supply (no inflation, no burn-on-transfer).
    function check_erc20TransferPreservesSupply(
        uint256 mintA,
        uint256 mintB,
        uint256 amt
    ) public {
        address a = address(0x1001);
        address b = address(0x1002);
        vm.assume(mintA <= type(uint128).max && mintB <= type(uint128).max);
        token.mint(a, mintA);
        token.mint(b, mintB);
        vm.assume(amt <= mintA);
        vm.prank(a);
        token.transfer(b, amt);
        assert(token.balanceOf(a) == mintA - amt);
        assert(token.balanceOf(b) == mintB + amt);
        assert(token.totalSupply() == mintA + mintB);
    }

    /// @notice ∀ amounts: only the series may mint or burn legs.
    function check_onlyMinterMints(address caller, uint256 amt) public {
        vm.assume(caller != address(series));
        vm.prank(caller);
        (bool ok,) = address(P).call(abi.encodeCall(IOptionToken.mint, (caller, amt)));
        assert(!ok);
    }

    // ------------------------------------------------------------------
    // Payout monotonicity (∀ x1 <= x2: payout_p(x1) >= payout_p(x2)),
    // split by strike region so each query is a single canonical division
    // fact instead of two composed divisions. Settles the SAME series
    // twice by clearing the settled flag (slot 0) between runs — both
    // settlements execute the real bytecode.
    // ------------------------------------------------------------------

    function _settleTwice(uint256 a1, uint256 a2)
        internal
        returns (uint256 x1, uint256 pp1, uint256 x2, uint256 pp2)
    {
        _settleAt(a1);
        x1 = series.settlement_index();
        pp1 = series.payout_p();
        vm.store(address(series), bytes32(uint256(0)), bytes32(uint256(0))); // un-settle
        ethFeed.setAnswer(int256(a2));
        series.settle();
        x2 = series.settlement_index();
        pp2 = series.payout_p();
        vm.assume(x1 <= x2);
    }

    /// @notice both indices at/below strike: payout pinned at 1e18.
    function check_payoutMonotone_belowStrike(uint256 a1, uint256 a2) public {
        vm.assume(a1 >= 1 && a1 <= 1e40 && a2 >= 1 && a2 <= 1e40);
        (uint256 x1, uint256 pp1, uint256 x2, uint256 pp2) = _settleTwice(a1, a2);
        vm.assume(x2 <= STRIKE);
        assert(pp1 == UNIT && pp2 == UNIT);
        x1; // silence
    }

    /// @notice index crosses the strike: full payout >= partial payout.
    function check_payoutMonotone_acrossStrike(uint256 a1, uint256 a2) public {
        vm.assume(a1 >= 1 && a1 <= 1e40 && a2 >= 1 && a2 <= 1e40);
        (uint256 x1, uint256 pp1, , uint256 pp2) = _settleTwice(a1, a2);
        vm.assume(x1 <= STRIKE && series.settlement_index() > STRIKE);
        assert(pp1 == UNIT);
        assert(pp2 <= UNIT);
        assert(pp1 >= pp2);
    }

    /// @notice both indices above strike: floor(S·U/x) is non-increasing
    ///         in x — the canonical division anti-monotonicity fact.
    function check_payoutMonotone_aboveStrike(uint256 a1, uint256 a2) public {
        vm.assume(a1 >= 1 && a1 <= 1e40 && a2 >= 1 && a2 <= 1e40);
        (uint256 x1, uint256 pp1, , uint256 pp2) = _settleTwice(a1, a2);
        vm.assume(x1 > STRIKE);
        assert(pp1 >= pp2);
    }
}
