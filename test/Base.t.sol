// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Blueprint} from "./utils/Blueprint.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {IOptionToken, IOracleHub, IOptionSeries, ISeriesFactory, ITrackerDAO} from "./Interfaces.sol";

abstract contract Base is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant ETH_HEARTBEAT = 3600;
    uint256 internal constant XAU_HEARTBEAT = 86400;

    address internal tokenBlueprint;
    address internal seriesBlueprint;
    IOracleHub internal hub;
    ISeriesFactory internal factory;
    MockV3Aggregator internal ethFeed; // ETH/USD, 8 decimals
    MockV3Aggregator internal xauFeed; // XAU/USD, 8 decimals
    bytes32 internal constant USD = bytes32(0);
    bytes32 internal xauId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.warp(1_780_000_000);
        ethFeed = new MockV3Aggregator(8, 2500e8); // ETH = $2500
        xauFeed = new MockV3Aggregator(8, 2500e8); // XAU = $2500 -> x(XAU) = 1e18

        tokenBlueprint = Blueprint.deployBlueprint(vm.getCode("OptionToken"));
        seriesBlueprint = Blueprint.deployBlueprint(vm.getCode("OptionSeries"));

        hub = IOracleHub(deployCode("OracleHub", abi.encode(address(ethFeed), ETH_HEARTBEAT)));
        factory = ISeriesFactory(
            deployCode("SeriesFactory", abi.encode(address(hub), seriesBlueprint, tokenBlueprint))
        );
        xauId = hub.register(address(xauFeed), XAU_HEARTBEAT, "XAU");

        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        vm.deal(carol, 1_000_000 ether);
    }

    /// @dev refresh mock feeds at the current timestamp (after vm.warp)
    function refreshFeeds() internal {
        ethFeed.setAnswer(ethFeed.answer());
        xauFeed.setAnswer(xauFeed.answer());
    }

    /// @dev USD series helper: asset = bytes32(0)
    function newUsdSeries(uint256 strike, uint256 term) internal returns (IOptionSeries) {
        return IOptionSeries(factory.create_series(USD, strike, block.timestamp + term));
    }

    function newDao(bytes32 asset, string memory name, string memory symbol)
        internal
        returns (ITrackerDAO)
    {
        return ITrackerDAO(
            deployCode(
                "TrackerDAO",
                abi.encode(
                    name,
                    symbol,
                    address(hub),
                    address(factory),
                    asset,
                    uint256(28 days),   // TERM
                    uint256(7 days),    // ROLL_WINDOW
                    uint256(1.5e18),    // ROLL_TRIGGER
                    uint256(0.5e18),    // STRIKE_RATIO
                    uint256(1 days),    // AUCTION_DUR
                    uint256(0.02e18)    // MAX_EDGE
                )
            )
        );
    }
}
