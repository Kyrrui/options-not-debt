// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {IOptionSeries} from "./Interfaces.sol";

contract SeriesFactoryTest is Base {
    function test_create_usdAndRwa() public {
        address usd = factory.create_series(address(0), 1250e18, block.timestamp + 28 days);
        address xau = factory.create_series(address(xauFeed), 0.5e18, block.timestamp + 28 days);
        assertTrue(factory.is_series(usd));
        assertTrue(factory.is_series(xau));
        assertEq(factory.series_count(), 2);
        assertEq(factory.series_list(0), usd);
        assertEq(factory.series_list(1), xau);
        assertEq(IOptionSeries(usd).ASSET(), address(0));
        assertEq(IOptionSeries(xau).ASSET(), address(xauFeed));
    }

    function test_create_dedupes() public {
        uint256 m = block.timestamp + 28 days;
        address a = factory.create_series(address(0), 1250e18, m);
        address b = factory.create_series(address(0), 1250e18, m);
        assertEq(a, b);
        assertEq(factory.series_count(), 1);
    }

    function test_create_distinctParamsDistinctSeries() public {
        uint256 m = block.timestamp + 28 days;
        address a = factory.create_series(address(0), 1250e18, m);
        address b = factory.create_series(address(0), 1251e18, m);
        address c = factory.create_series(address(0), 1250e18, m + 1);
        assertTrue(a != b && b != c && a != c);
    }

    function test_create_revertsUnregistered() public {
        vm.expectRevert();
        factory.create_series(address(0xBEEF), 1e18, block.timestamp + 28 days);
    }

    function test_create_revertsBadTerm() public {
        vm.expectRevert();
        factory.create_series(address(0), 1e18, block.timestamp + 30 minutes);
        vm.expectRevert();
        factory.create_series(address(0), 1e18, block.timestamp + 6 * 365 days);
    }

    function test_create_revertsZeroStrike() public {
        vm.expectRevert();
        factory.create_series(address(0), 0, block.timestamp + 28 days);
    }

    function test_seriesTokensWiredCorrectly() public {
        IOptionSeries s = IOptionSeries(
            factory.create_series(address(xauFeed), 0.5e18, block.timestamp + 28 days)
        );
        assertEq(s.HUB(), address(hub));
        assertEq(s.STRIKE(), 0.5e18);
        assertTrue(s.P() != s.N());
    }
}
