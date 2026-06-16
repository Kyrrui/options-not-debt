// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev mirrors the Vyper `struct Quote` (7 fields — NO series, unlike the N desk).
struct Quote {
    uint8 side;
    address taker;
    uint256 amount;
    uint256 price;
    uint256 min_edge;
    uint256 nonce;
    uint256 deadline;
}

interface IStableQuoteFiller {
    function fill_buy_spusd(Quote calldata q, uint8 v, bytes32 r, bytes32 s) external payable returns (uint256);
    function fill_sell_spusd(Quote calldata q, uint8 v, bytes32 r, bytes32 s) external returns (uint256);
    function quote_digest(Quote calldata q) external view returns (bytes32);
    function fair_price() external view returns (uint256);
    function net_spusd() external view returns (uint256);
    function fund() external payable;
    function fund_spusd(uint256 amount) external;
    function set_paused(bool p) external;
    function set_caps(uint256 max_fill, uint256 max_net_spusd, uint256 min_eth_float, uint256 min_spusd_float, uint256 outflow_cap) external;
    function quoter() external view returns (address);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ISpUSD {
    function deposit() external payable returns (uint256);
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork test of StableQuoteFiller against LIVE Sepolia: the real spUSD
///         TrackerDAO (which IS the spUSD ERC20), the OracleHub + live ETH/USD feed.
///         Proves the stable desk: verifies an independently-reconstructed EIP-712
///         quote; rejects a quote signed under the N desk's domain name (cross-desk
///         replay separation); sells spUSD from inventory only (NO mint-to-sell);
///         buys + warehouses spUSD; and enforces the directional NAV floor, the
///         units NAV cap, nonce-replay, pause, taker-binding, bad-sig, stale-oracle.
///
/// Needs viaIR (enabled in foundry.toml). Run:
///   forge test --match-path test/StableQuoteFiller.fork.t.sol \
///     --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract StableQuoteFillerForkTest is Test {
    uint256 constant UNIT = 1e18;
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant HUB = 0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    bytes32 constant USD = bytes32(0);

    uint256 constant MIN_EDGE = 1e16; // 1%
    uint256 constant DESK_MAX_STALENESS = 3600;
    uint256 constant OUTFLOW_WINDOW = 3600;

    IStableQuoteFiller internal filler;
    uint256 internal quoterPk = 0xB0B;
    address internal quoter;
    address internal taker = makeAddr("stableTaker");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        // spUSD must be in a tradeable (non-roll) state for deposit() to work
        if (ISpUSD(SPUSD).active_series() == address(0)) {
            vm.skip(true);
            return;
        }
        quoter = vm.addr(quoterPk);

        filler = IStableQuoteFiller(
            deployCode(
                "StableQuoteFiller",
                abi.encode(
                    address(this), // owner
                    SPUSD, // tracker (= spUSD ERC20)
                    HUB,
                    USD, // asset (USD-only v1)
                    quoter,
                    MIN_EDGE,
                    DESK_MAX_STALENESS,
                    OUTFLOW_WINDOW,
                    type(uint128).max, // max_fill
                    type(uint128).max, // max_net_spusd (UNITS)
                    uint256(0), // min_eth_float
                    uint256(0), // min_spusd_float
                    type(uint128).max // outflow_cap
                )
            )
        );

        // fresh feed so the tight staleness gate passes deterministically
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + 60);

        vm.deal(address(this), 20 ether);
        vm.deal(address(filler), 5 ether); // desk ETH for the buy side
        vm.deal(taker, 5 ether);

        // acquire a spUSD stash (deposit ETH -> shares + N), seed the desk's inventory,
        // and keep some to hand the taker for the sell-side test
        uint256 got = ISpUSD(SPUSD).deposit{value: 0.4 ether}();
        require(got > 2e18, "deposit too small to test");
        IERC20(SPUSD).approve(address(filler), got);
        filler.fund_spusd(got / 2);
        IERC20(SPUSD).transfer(taker, got / 4); // give the taker spUSD to sell
    }

    // ---- EIP-712 ----

    function _domainSeparator(bytes32 nameHash) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                nameHash,
                keccak256("1"),
                block.chainid,
                address(filler)
            )
        );
    }

    function _structHash(Quote memory q) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "Quote(uint8 side,address taker,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)"
                ),
                q.side,
                q.taker,
                q.amount,
                q.price,
                q.min_edge,
                q.nonce,
                q.deadline
            )
        );
    }

    function _digestName(Quote memory q, bytes32 nameHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(nameHash), _structHash(q)));
    }

    function _digest(Quote memory q) internal view returns (bytes32) {
        return _digestName(q, keccak256("Gimbal Solo RFQ Stable Desk"));
    }

    // SIDE_SELL_SPUSD = 1 (desk sells / taker buys), priced at the sell-dear floor
    function _quoteSell(uint256 amount, uint256 nonce) internal view returns (Quote memory q) {
        q = Quote({
            side: 1,
            taker: address(0),
            amount: amount,
            price: filler.fair_price() * (UNIT + MIN_EDGE) / UNIT,
            min_edge: MIN_EDGE,
            nonce: nonce,
            deadline: block.timestamp + 2 days
        });
    }

    // SIDE_BUY_SPUSD = 0 (desk buys / taker sells), priced at the buy-cheap floor
    function _quoteBuy(uint256 amount, uint256 nonce) internal view returns (Quote memory q) {
        q = Quote({
            side: 0,
            taker: address(0),
            amount: amount,
            price: filler.fair_price() * (UNIT - MIN_EDGE) / UNIT,
            min_edge: MIN_EDGE,
            nonce: nonce,
            deadline: block.timestamp + 2 days
        });
    }

    function _sellBuy(Quote memory q) internal returns (uint256) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        return filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function _sellToDesk(Quote memory q) internal returns (uint256) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        return filler.fill_sell_spusd(q, v, r, s);
    }

    function test_eip712_digestParity() public view {
        Quote memory q = _quoteSell(1e18, 1);
        assertEq(filler.quote_digest(q), _digest(q), "digest must match independent EIP-712");
    }

    // cross-desk separation: a quote signed under the N desk's domain NAME must be rejected
    function test_domainSeparation_wrongNameReverts() public {
        Quote memory q = _quoteSell(1e18, 2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digestName(q, keccak256("Gimbal Solo RFQ Desk")));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    // ---- happy paths ----

    function test_fillBuySpusd_deskSellsFromInventory() public {
        Quote memory q = _quoteSell(1e18, 3);
        uint256 takerBefore = IERC20(SPUSD).balanceOf(taker);
        uint256 netBefore = filler.net_spusd();

        vm.prank(taker);
        uint256 out = _sellBuy(q);

        assertEq(out, q.amount, "returned amount");
        assertEq(IERC20(SPUSD).balanceOf(taker) - takerBefore, q.amount, "taker received spUSD");
        assertEq(filler.net_spusd(), netBefore - q.amount, "inventory drawn down");
    }

    function test_fillSellSpusd_deskBuysAndWarehouses() public {
        Quote memory q = _quoteBuy(1e18, 4);
        uint256 proceeds = q.amount * q.price / UNIT;
        uint256 takerEthBefore = taker.balance;
        uint256 netBefore = filler.net_spusd();

        vm.prank(taker);
        IERC20(SPUSD).approve(address(filler), q.amount);
        vm.prank(taker);
        uint256 outEth = _sellToDesk(q);

        assertEq(outEth, proceeds, "returned proceeds");
        assertEq(taker.balance - takerEthBefore, proceeds, "taker received ETH");
        assertEq(filler.net_spusd(), netBefore + q.amount, "desk warehoused spUSD");
    }

    // ---- guardrails ----

    function test_noMintToSell_insufficientInventoryReverts() public {
        // sell more than the desk holds -> revert (it must NEVER mint to cover)
        uint256 tooMuch = filler.net_spusd() + 1e18;
        Quote memory q = _quoteSell(tooMuch, 5);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_belowFloorReverts() public {
        Quote memory q = _quoteSell(1e18, 6);
        q.price = q.price - 1; // one wei under the sell-dear floor
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_navCapUnitsReverts() public {
        // pin the units cap at the current inventory; any desk-buy must then revert
        filler.set_caps(type(uint128).max, filler.net_spusd(), 0, 0, type(uint128).max);
        Quote memory q = _quoteBuy(1e18, 7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        IERC20(SPUSD).approve(address(filler), q.amount);
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_sell_spusd(q, v, r, s);
    }

    function test_nonceReplayReverts() public {
        Quote memory q = _quoteSell(1e18, 8);
        vm.prank(taker);
        _sellBuy(q);
        vm.prank(taker);
        vm.expectRevert();
        _sellBuy(q);
    }

    function test_pausedReverts() public {
        filler.set_paused(true);
        Quote memory q = _quoteSell(1e18, 9);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_wrongTakerReverts() public {
        Quote memory q = _quoteSell(1e18, 10);
        q.taker = address(0xBEEF);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_badSignatureReverts() public {
        Quote memory q = _quoteSell(1e18, 11);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBAD), _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_staleOracleReverts() public {
        Quote memory q = _quoteSell(1e18, 12); // 2-day deadline so it is not "expired" after the warp
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + DESK_MAX_STALENESS + 1);
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_spusd{value: q.amount * q.price / UNIT}(q, v, r, s);
    }
}
