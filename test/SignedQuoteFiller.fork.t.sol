// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev mirrors the Vyper `struct Quote` field order exactly (ABI tuple).
struct Quote {
    uint8 side;
    address taker;
    address series;
    uint256 amount;
    uint256 price;
    uint256 min_edge;
    uint256 nonce;
    uint256 deadline;
}

interface ISignedQuoteFiller {
    function fill_buy_n(Quote calldata q, uint8 v, bytes32 r, bytes32 s) external payable returns (uint256);
    function fill_sell_n(Quote calldata q, uint8 v, bytes32 r, bytes32 s) external returns (uint256);
    function quote_digest(Quote calldata q) external view returns (bytes32);
    function intrinsic_n(address series) external view returns (uint256);
    function net_n(address series) external view returns (int256);
    function fund() external payable;
    function fund_p(address series, uint256 amount) external;
    function set_paused(bool p) external;
    function set_caps(uint256 max_fill, uint256 max_nav_at_risk, uint256 min_eth_float, uint256 outflow_cap) external;
    function quoter() external view returns (address);
    function owner() external view returns (address);
}

interface ITracker {
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
    function ROLL_TRIGGER() external view returns (uint256);
}

interface ISeries {
    function P() external view returns (address);
    function N() external view returns (address);
    function STRIKE() external view returns (uint256);
    function MATURITY() external view returns (uint256);
    function settled() external view returns (bool);
    function split() external payable;
    function merge(uint256 amount) external;
}

interface IOracleHub {
    function latest_price(bytes32 asset) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork test of SignedQuoteFiller against LIVE Sepolia: the real spUSD
///         TrackerDAO, its current OptionSeries vintage, the OracleHub + live
///         ETH/USD Chainlink feed. Proves the solo RFQ desk:
///           * verifies an INDEPENDENTLY-reconstructed EIP-712 signed quote;
///           * sells N (taker buys; desk JIT-mints via split and keeps the P);
///           * buys N (taker sells — the value-add — desk pairs with inventory P
///             and merges -> ETH oracle-free);
///           * enforces the directional floor, nonce-replay, pause, taker-binding,
///             bad-signature, the tight oracle-staleness gate, and the NAV cap.
///
/// Needs viaIR (enabled in foundry.toml) — the 8-field Quote struct encode for the
/// desk's external calls overflows legacy codegen.
/// Run: forge test --match-path test/SignedQuoteFiller.fork.t.sol \
///        --fork-url https://ethereum-sepolia-rpc.publicnode.com -vv
contract SignedQuoteFillerForkTest is Test {
    uint256 constant UNIT = 1e18;
    address constant SPUSD = 0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE;
    address constant HUB = 0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62;
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    bytes32 constant USD = bytes32(0);

    uint256 constant MIN_EDGE = 2e16; // 2%
    uint256 constant DESK_MAX_STALENESS = 3600;
    uint256 constant PRE_MATURITY_BUFFER = 2 days;
    uint256 constant OUTFLOW_WINDOW = 3600;

    ISignedQuoteFiller internal filler;
    address internal series;
    address internal pToken;
    address internal nToken;
    uint256 internal strikeProximity;

    uint256 internal quoterPk = 0xA11CE;
    address internal quoter;
    address internal taker = makeAddr("taker");

    function setUp() public {
        if (block.chainid != 11155111) {
            vm.skip(true);
            return;
        }
        series = ITracker(SPUSD).pending_series();
        if (series == address(0)) series = ITracker(SPUSD).active_series();
        require(series != address(0), "no series");
        if (ISeries(series).settled()) {
            vm.skip(true);
            return;
        }
        pToken = ISeries(series).P();
        nToken = ISeries(series).N();
        quoter = vm.addr(quoterPk);
        strikeProximity = ITracker(SPUSD).ROLL_TRIGGER();
        filler = ISignedQuoteFiller(_deployFiller());

        // make the live feed "fresh" relative to block time so the tight desk
        // staleness gate passes deterministically regardless of the fork block
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + 60);

        // skip if the live index is inside the desk's no-trade band (near strike)
        if (IOracleHub(HUB).latest_price(USD) <= ISeries(series).STRIKE() * strikeProximity / UNIT) {
            vm.skip(true);
            return;
        }
        if (block.timestamp + PRE_MATURITY_BUFFER >= ISeries(series).MATURITY()) {
            vm.skip(true);
            return;
        }

        vm.deal(address(this), 10 ether); // operator funds for seeding P
        vm.deal(address(filler), 5 ether); // desk ETH inventory
        vm.deal(taker, 5 ether);
    }

    function _deployFiller() internal returns (address) {
        return deployCode(
            "SignedQuoteFiller",
            abi.encode(
                address(this), // owner (operator)
                SPUSD, // tracker
                HUB, // oracle hub
                USD, // asset (USD-only v1)
                quoter, // approved quoter key
                MIN_EDGE,
                DESK_MAX_STALENESS,
                PRE_MATURITY_BUFFER,
                strikeProximity, // == ROLL_TRIGGER
                OUTFLOW_WINDOW,
                type(uint128).max, // max_fill (unconstrained for these tests)
                type(uint128).max, // max_nav_at_risk
                uint256(0), // min_eth_float
                type(uint128).max // outflow_cap
            )
        );
    }

    // ---- EIP-712: reconstruct the digest independently and confirm parity ----

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gimbal Solo RFQ Desk"),
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
                    "Quote(uint8 side,address taker,address series,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)"
                ),
                q.side,
                q.taker,
                q.series,
                q.amount,
                q.price,
                q.min_edge,
                q.nonce,
                q.deadline
            )
        );
    }

    function _digest(Quote memory q) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _domainSeparator(), _structHash(q)));
    }

    // SIDE_SELL_N = 1 (desk sells N / taker buys N), priced exactly at the sell-dear floor
    function _quoteSellN(uint256 amount, uint256 nonce) internal view returns (Quote memory q) {
        q = Quote({
            side: 1,
            taker: address(0),
            series: series,
            amount: amount,
            price: filler.intrinsic_n(series) * (UNIT + MIN_EDGE) / UNIT,
            min_edge: MIN_EDGE,
            nonce: nonce,
            deadline: block.timestamp + 2 days
        });
    }

    // SIDE_BUY_N = 0 (desk buys N / taker sells N), priced exactly at the buy-cheap floor
    function _quoteBuyN(uint256 amount, uint256 nonce) internal view returns (Quote memory q) {
        q = Quote({
            side: 0,
            taker: address(0),
            series: series,
            amount: amount,
            price: filler.intrinsic_n(series) * (UNIT - MIN_EDGE) / UNIT,
            min_edge: MIN_EDGE,
            nonce: nonce,
            deadline: block.timestamp + 2 days
        });
    }

    // signing + the struct-encoding external call kept in small frames (no via-ir needed)
    function _fillBuy(Quote memory q) internal returns (uint256) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        return filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function _fillSell(Quote memory q) internal returns (uint256) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        return filler.fill_sell_n(q, v, r, s);
    }

    function _seedDeskP(uint256 amount) internal {
        ISeries(series).split{value: amount}();
        IERC20(pToken).approve(address(filler), amount);
        filler.fund_p(series, amount);
    }

    function _takerGetN(uint256 amount) internal {
        vm.prank(taker);
        ISeries(series).split{value: amount}();
        vm.prank(taker);
        IERC20(nToken).approve(address(filler), amount);
    }

    function test_eip712_digestParity() public view {
        Quote memory q = _quoteSellN(0.01 ether, 1);
        assertEq(filler.quote_digest(q), _digest(q), "digest must match independent EIP-712");
    }

    // ---- happy paths ----

    function test_fillBuyN_deskSellsN_jitMintsAndKeepsP() public {
        Quote memory q = _quoteSellN(0.01 ether, 1);
        uint256 takerNBefore = IERC20(nToken).balanceOf(taker);

        vm.prank(taker);
        uint256 outN = _fillBuy(q);

        assertEq(outN, q.amount, "returned N amount");
        assertEq(IERC20(nToken).balanceOf(taker) - takerNBefore, q.amount, "taker received N");
        assertEq(filler.net_n(series), -int256(q.amount), "desk net-short N by amount");
        // desk JIT-split `amount`, sent N out, kept the P
        assertEq(IERC20(pToken).balanceOf(address(filler)), q.amount, "desk kept the P leg");
        assertEq(IERC20(nToken).balanceOf(address(filler)), 0, "desk holds no leftover N");
    }

    function test_fillSellN_deskBuysN_mergesToRecoverEth() public {
        _seedDeskP(0.02 ether);
        _takerGetN(0.01 ether);

        Quote memory q = _quoteBuyN(0.01 ether, 2);
        uint256 proceeds = q.amount * q.price / UNIT;
        uint256 takerEthBefore = taker.balance;
        int256 netBefore = filler.net_n(series);

        vm.prank(taker);
        uint256 outEth = _fillSell(q);

        assertEq(outEth, proceeds, "returned proceeds");
        assertEq(taker.balance - takerEthBefore, proceeds, "taker received ETH");
        // bought 0.01 N then merged 0.01 P+N -> net_n flat, P inventory drawn down
        assertEq(filler.net_n(series), netBefore, "net_n flat after immediate merge");
        assertEq(IERC20(pToken).balanceOf(address(filler)), 0.02 ether - 0.01 ether, "desk P merged down");
        assertEq(IERC20(nToken).balanceOf(address(filler)), 0, "merged N leaves no inventory");
    }

    // ---- guardrails ----

    function test_belowFloorReverts() public {
        Quote memory q = _quoteSellN(0.01 ether, 3);
        q.price = q.price - 1; // one wei under the sell-dear floor
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_nonceReplayReverts() public {
        Quote memory q = _quoteSellN(0.01 ether, 4);
        vm.prank(taker);
        _fillBuy(q);
        vm.prank(taker);
        vm.expectRevert();
        _fillBuy(q);
    }

    function test_pausedReverts() public {
        filler.set_paused(true);
        Quote memory q = _quoteSellN(0.01 ether, 5);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_wrongTakerReverts() public {
        Quote memory q = _quoteSellN(0.01 ether, 6);
        q.taker = address(0xBEEF); // bound to someone else
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_badSignatureReverts() public {
        Quote memory q = _quoteSellN(0.01 ether, 7);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(0xBADBAD), _digest(q)); // not the quoter
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_staleOracleReverts() public {
        Quote memory q = _quoteSellN(0.01 ether, 8); // 2-day deadline, so not "expired" after the warp
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        // push past the tight desk staleness but stay within the hub's 7200s heartbeat
        (, , , uint256 updatedAt, ) = IAggregator(ETH_USD_FEED).latestRoundData();
        vm.warp(updatedAt + DESK_MAX_STALENESS + 1);
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_buy_n{value: q.amount * q.price / UNIT}(q, v, r, s);
    }

    function test_navCapReverts() public {
        // tighten the NAV-at-risk cap so a net-long-N (desk-buys, no mergeable P) fill trips it
        filler.set_caps(type(uint128).max, 1, 0, type(uint128).max);
        _takerGetN(0.01 ether);
        Quote memory q = _quoteBuyN(0.01 ether, 9);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, _digest(q));
        vm.prank(taker);
        vm.expectRevert();
        filler.fill_sell_n(q, v, r, s);
    }
}
