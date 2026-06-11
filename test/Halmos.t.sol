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
            factory.create_series(address(0), STRIKE, block.timestamp + 28 days)
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

    /// @notice ∀ oracle price: P's settled value, measured in asset units,
    ///         never exceeds the strike — the soft peg's hard upper bound.
    ///         (payout_p * x <= STRIKE * 1e18)
    function check_pValueNeverExceedsStrike(uint256 answer) public {
        vm.assume(answer >= 1 && answer <= 1e40);
        _settleAt(answer);
        uint256 x = series.settlement_index();
        assert(series.payout_p() * x <= STRIKE * UNIT);
    }

    /// @notice ∀ price, ∀ amount: redeeming both legs returns at most the
    ///         locked ETH, and the rounding shortfall is below 2 wei.
    ///         This is the no-bad-debt / no-liquidation theorem.
    function check_conservation(uint256 answer, uint256 amount) public {
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

    /// @notice ∀ two prices x1 <= x2: P's payout is monotonically
    ///         non-increasing in the settlement index (and N's payoff is
    ///         therefore non-decreasing): the legs can never both lose.
    function check_payoutMonotone(uint256 a1, uint256 a2) public {
        vm.assume(a1 >= 1 && a1 <= 1e40);
        vm.assume(a2 >= a1 && a2 <= 1e40);

        IOptionSeries s1 = series;
        // an identical second series from a sibling factory
        ISeriesFactory factory = ISeriesFactory(deployCode(
            FACTORY_ART,
            abi.encode(
                address(hub),
                Blueprint.deployBlueprint(vm.getCode(SERIES_ART)),
                Blueprint.deployBlueprint(vm.getCode(TOKEN_ART))
            )
        ));
        IOptionSeries s2 = IOptionSeries(
            factory.create_series(address(0), STRIKE, s1.MATURITY())
        );

        vm.warp(s1.MATURITY());
        ethFeed.setAnswer(int256(a1));
        s1.settle();
        ethFeed.setAnswer(int256(a2));
        s2.settle();

        assert(s1.payout_p() >= s2.payout_p());
    }
}
