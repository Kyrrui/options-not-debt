// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract OracleHubTest is Base {
    function test_usdSentinel_priceIsEthUsd() public view {
        // ETH = $2500 -> x(USD) = 2500e18 (asset units per ETH)
        assertEq(hub.latest_price(address(0)), 2500e18);
    }

    function test_rwaPrice_combinesFeeds() public view {
        // ETH $2500, XAU $2500 -> 1 ETH = 1 XAU
        assertEq(hub.latest_price(address(xauFeed)), 1e18);
    }

    function test_rwaPrice_ratio() public {
        xauFeed.setAnswer(5000e8); // gold doubles
        assertEq(hub.latest_price(address(xauFeed)), 0.5e18);
        ethFeed.setAnswer(10000e8);
        assertEq(hub.latest_price(address(xauFeed)), 2e18);
    }

    function test_decimalsNormalization() public {
        MockV3Aggregator feed18 = new MockV3Aggregator(18, 1250e18); // NVDA $1250, 18 dec
        hub.register(address(feed18), 86400, "NVDA");
        assertEq(hub.latest_price(address(feed18)), 2e18); // 2500/1250

        MockV3Aggregator feed6 = new MockV3Aggregator(6, 25e6); // $25, 6 dec
        hub.register(address(feed6), 86400, "SLV");
        assertEq(hub.latest_price(address(feed6)), 100e18);
    }

    function test_isRegistered() public view {
        assertTrue(hub.is_registered(address(0))); // USD sentinel
        assertTrue(hub.is_registered(address(xauFeed)));
        assertFalse(hub.is_registered(address(0xBEEF)));
    }

    function test_register_revertsDouble() public {
        vm.expectRevert();
        hub.register(address(xauFeed), 86400, "XAU");
    }

    function test_register_revertsEthFeed() public {
        vm.expectRevert();
        hub.register(address(ethFeed), 3600, "ETH");
    }

    function test_register_revertsZero() public {
        vm.expectRevert();
        hub.register(address(0), 3600, "NIL");
    }

    function test_register_revertsBadHeartbeat() public {
        MockV3Aggregator f = new MockV3Aggregator(8, 100e8);
        vm.expectRevert();
        hub.register(address(f), 59, "FAST");
        vm.expectRevert();
        hub.register(address(f), 8 days, "SLOW");
    }

    function test_register_revertsNegativeAnswer() public {
        MockV3Aggregator f = new MockV3Aggregator(8, -1e8);
        vm.expectRevert();
        hub.register(address(f), 3600, "NEG");
    }

    function test_register_revertsStaleProbe() public {
        MockV3Aggregator f = new MockV3Aggregator(8, 100e8);
        f.setRaw(100e8, block.timestamp - 7200);
        vm.expectRevert();
        hub.register(address(f), 3600, "STALE");
    }

    function test_register_revertsTooManyDecimals() public {
        MockV3Aggregator f = new MockV3Aggregator(19, 100);
        vm.expectRevert();
        hub.register(address(f), 3600, "BIGDEC");
    }

    function test_price_revertsStaleEthFeed() public {
        vm.warp(block.timestamp + ETH_HEARTBEAT + 1);
        vm.expectRevert();
        hub.latest_price(address(0));
    }

    function test_price_revertsStaleAssetFeed() public {
        vm.warp(block.timestamp + XAU_HEARTBEAT + 1);
        ethFeed.setAnswer(2500e8); // ETH feed fresh, XAU stale
        vm.expectRevert();
        hub.latest_price(address(xauFeed));
    }

    function test_price_revertsUnregistered() public {
        vm.expectRevert();
        hub.latest_price(address(0xBEEF));
    }

    function test_price_revertsFutureUpdate() public {
        ethFeed.setRaw(2500e8, block.timestamp + 100);
        vm.expectRevert();
        hub.latest_price(address(0));
    }

    function testFuzz_priceMath(uint256 ethUsd, uint256 assetUsd) public {
        ethUsd = bound(ethUsd, 1, 1e12) * 1e8; // $1 .. $1e12, 8 dec
        assetUsd = bound(assetUsd, 1, 1e12) * 1e8;
        ethFeed.setAnswer(int256(ethUsd));
        xauFeed.setAnswer(int256(assetUsd));
        uint256 x = hub.latest_price(address(xauFeed));
        assertEq(x, (ethUsd * 1e10) * 1e18 / (assetUsd * 1e10));
    }
}
