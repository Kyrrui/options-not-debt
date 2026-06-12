// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Solidity mirrors of the Vyper contract ABIs, for tests/scripts.

interface IOptionToken {
    function NAME() external view returns (string memory);
    function SYMBOL() external view returns (string memory);
    function DECIMALS() external view returns (uint8);
    function MINTER() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function mint(address, uint256) external;
    function burn(address, uint256) external;
}

interface IOracleHub {
    struct FeedConfig {
        address aggregator;
        uint256 heartbeat;
        string symbol;
    }

    function ETH_USD_FEED() external view returns (address);
    function ETH_USD_HEARTBEAT() external view returns (uint256);
    function feeds(bytes32) external view returns (FeedConfig memory);
    function asset_id(address aggregator, uint256 heartbeat) external pure returns (bytes32);
    function register(address aggregator, uint256 heartbeat, string calldata symbol)
        external
        returns (bytes32);
    function is_registered(bytes32 asset) external view returns (bool);
    function latest_price(bytes32 asset) external view returns (uint256);
}

interface IOptionSeries {
    function HUB() external view returns (address);
    function ASSET() external view returns (bytes32);
    function STRIKE() external view returns (uint256);
    function MATURITY() external view returns (uint256);
    function P() external view returns (address);
    function N() external view returns (address);
    function settled() external view returns (bool);
    function settlement_index() external view returns (uint256);
    function payout_p() external view returns (uint256);
    function split() external payable;
    function merge(uint256 amount) external;
    function settle() external;
    function redeem_p(uint256 amount) external;
    function redeem_n(uint256 amount) external;
}

interface ISeriesFactory {
    function HUB() external view returns (address);
    function SERIES_BLUEPRINT() external view returns (address);
    function TOKEN_BLUEPRINT() external view returns (address);
    function series_by_key(bytes32) external view returns (address);
    function series_count() external view returns (uint256);
    function series_list(uint256) external view returns (address);
    function is_series(address) external view returns (bool);
    function create_series(bytes32 asset, uint256 strike, uint256 maturity) external returns (address);
}

interface ITrackerFactory {
    function HUB() external view returns (address);
    function SERIES_FACTORY() external view returns (address);
    function TRACKER_BLUEPRINT() external view returns (address);
    function tracker_by_key(bytes32) external view returns (address);
    function tracker_count() external view returns (uint256);
    function tracker_list(uint256) external view returns (address);
    function is_tracker(address) external view returns (bool);
    function create_tracker(
        string calldata name,
        string calldata symbol,
        bytes32 asset,
        uint256 term,
        uint256 rollWindow,
        uint256 rollTrigger,
        uint256 strikeRatio,
        uint256 auctionDur,
        uint256 maxEdge
    ) external returns (address);
}

interface ITrackerDAO {
    function NAME() external view returns (string memory);
    function SYMBOL() external view returns (string memory);
    function DECIMALS() external view returns (uint8);
    function HUB() external view returns (address);
    function FACTORY() external view returns (address);
    function ASSET() external view returns (bytes32);
    function TERM() external view returns (uint256);
    function ROLL_WINDOW() external view returns (uint256);
    function ROLL_TRIGGER() external view returns (uint256);
    function STRIKE_RATIO() external view returns (uint256);
    function AUCTION_DUR() external view returns (uint256);
    function MAX_EDGE() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function active_series() external view returns (address);
    function pending_series() external view returns (address);
    function roll_started() external view returns (uint256);
    function eth_buffer() external view returns (uint256);
    function p_bal(address) external view returns (uint256);
    function buy_started() external view returns (uint256);
    function nav() external view returns (uint256);
    function share_price() external view returns (uint256);
    function deposit() external payable returns (uint256);
    function redeem(uint256 shares) external;
    function sync() external;
    function roll_quote(uint256 amountOld) external view returns (uint256);
    function fill_roll(uint256 amountOld) external;
    function p_quote(uint256 amount) external view returns (uint256);
    function sell_p(uint256 amount) external;
}
