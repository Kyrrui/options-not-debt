// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {Blueprint} from "./utils/Blueprint.sol";
import {IOptionToken, IOptionSeries, ITrackerDAO, ITrackerFactory} from "./Interfaces.sol";

contract TrackerFactoryTest is Base {
    ITrackerFactory internal trackerFactory;

    uint256 internal constant TERM = 28 days;
    uint256 internal constant WINDOW = 7 days;
    uint256 internal constant TRIGGER = 1.5e18;
    uint256 internal constant RATIO = 0.5e18;
    uint256 internal constant AUCTION = 1 days;
    uint256 internal constant EDGE = 0.02e18;

    function setUp() public override {
        super.setUp();
        address trackerBlueprint = Blueprint.deployBlueprint(vm.getCode("TrackerDAO"));
        trackerFactory = ITrackerFactory(
            deployCode(
                "TrackerFactory",
                abi.encode(address(hub), address(factory), trackerBlueprint)
            )
        );
    }

    function _create(bytes32 asset, string memory name, string memory symbol)
        internal
        returns (ITrackerDAO)
    {
        return ITrackerDAO(
            trackerFactory.create_tracker(
                name, symbol, asset, TERM, WINDOW, TRIGGER, RATIO, AUCTION, EDGE
            )
        );
    }

    function test_create_registersAndWires() public {
        ITrackerDAO usd = _create(USD, "Soft Peg USD", "spUSD");
        ITrackerDAO xau = _create(xauId, "Soft Peg Gold", "spXAU");

        assertEq(trackerFactory.tracker_count(), 2);
        assertEq(trackerFactory.tracker_list(0), address(usd));
        assertEq(trackerFactory.tracker_list(1), address(xau));
        assertTrue(trackerFactory.is_tracker(address(usd)));
        assertTrue(trackerFactory.is_tracker(address(xau)));

        // constructor wiring: hub/factory injected by the factory, params land
        assertEq(usd.HUB(), address(hub));
        assertEq(usd.FACTORY(), address(factory));
        assertEq(usd.ASSET(), USD);
        assertEq(xau.ASSET(), xauId);
        assertEq(usd.TERM(), TERM);
        assertEq(usd.ROLL_WINDOW(), WINDOW);
        assertEq(usd.ROLL_TRIGGER(), TRIGGER);
        assertEq(usd.STRIKE_RATIO(), RATIO);
        assertEq(usd.AUCTION_DUR(), AUCTION);
        assertEq(usd.MAX_EDGE(), EDGE);
        assertEq(usd.NAME(), "Soft Peg USD");
        assertEq(usd.SYMBOL(), "spUSD");
    }

    function test_create_dedupesOnParamsNotNames() public {
        ITrackerDAO a = _create(USD, "Soft Peg USD", "spUSD");
        ITrackerDAO b = _create(USD, "Different Name", "OTHER");
        assertEq(address(a), address(b)); // cosmetic fields excluded from key
        assertEq(trackerFactory.tracker_count(), 1);

        ITrackerDAO c = ITrackerDAO(
            trackerFactory.create_tracker(
                "Soft Peg USD", "spUSD", USD, TERM + 1, WINDOW, TRIGGER, RATIO, AUCTION, EDGE
            )
        );
        assertTrue(address(c) != address(a)); // any param change = new tracker
        assertEq(trackerFactory.tracker_count(), 2);
    }

    function test_create_revertsUnregisteredAsset() public {
        vm.expectRevert();
        trackerFactory.create_tracker(
            "Nope", "NOPE", keccak256("unregistered"), TERM, WINDOW, TRIGGER, RATIO, AUCTION, EDGE
        );
    }

    function test_create_revertsTermBeyondSeriesFactoryBounds() public {
        vm.expectRevert();
        trackerFactory.create_tracker(
            "Long", "LONG", USD, 6 * 365 days, WINDOW, TRIGGER, RATIO, AUCTION, EDGE
        );
    }

    function test_create_bubblesConstructorValidation() public {
        // genesis self-roll brick config must still be rejected by the
        // TrackerDAO constructor through the blueprint deploy
        vm.expectRevert();
        trackerFactory.create_tracker(
            "Brick", "BRK", USD, TERM, WINDOW, 3e18, 0.5e18, AUCTION, EDGE
        );
    }

    function test_createdTracker_isFullyFunctional() public {
        ITrackerDAO gold = _create(xauId, "Soft Peg Gold", "spXAU");

        vm.prank(bob);
        uint256 shares = gold.deposit{value: 10 ether}();

        IOptionSeries s = IOptionSeries(gold.active_series());
        assertEq(s.STRIKE(), 0.5e18); // x(XAU)=1e18 at setUp prices
        assertEq(gold.share_price(), 1e18); // pegged from the first deposit
        assertEq(IOptionToken(s.N()).balanceOf(bob), 10 ether); // N returned
        assertGt(shares, 0);

        vm.prank(bob);
        gold.redeem(shares); // exit works
        assertGt(IOptionToken(s.P()).balanceOf(bob), 0);
    }

    function test_create_usdSentinelAllowed() public {
        ITrackerDAO usd = _create(USD, "Soft Peg USD", "spUSD");
        vm.prank(carol);
        usd.deposit{value: 1 ether}();
        assertEq(usd.share_price(), 1e18);
    }
}
