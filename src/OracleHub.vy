# pragma version ==0.4.3
"""
@title OracleHub — Chainlink RWA feed registry and index pricing
@notice Permissionless registry of Chainlink ASSET/USD aggregators.
        Computes the index x = price of 1 ETH denominated in asset units,
        scaled to 1e18, by combining the canonical ETH/USD feed with the
        asset's USD feed:  x = (ETH/USD) * 1e18 / (ASSET/USD).
@dev    Per ethresear.ch t/25036 the system only needs a *slow*, pull-based
        oracle: prices are read lazily, once, at settlement. This hub never
        pushes prices and never triggers liquidations (there are none).
        The sentinel asset address(0) denotes USD itself (x = ETH/USD).
"""

interface AggregatorV3:
    def decimals() -> uint8: view
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

event AssetRegistered:
    asset: indexed(address)
    heartbeat: uint256
    symbol: String[32]

struct FeedConfig:
    heartbeat: uint256
    symbol: String[32]

UNIT: constant(uint256) = 10**18
MIN_HEARTBEAT: constant(uint256) = 60
MAX_HEARTBEAT: constant(uint256) = 7 * 24 * 3600

ETH_USD_FEED: public(immutable(address))
ETH_USD_HEARTBEAT: public(immutable(uint256))

# asset id == address of its Chainlink ASSET/USD aggregator
feeds: public(HashMap[address, FeedConfig])


@deploy
def __init__(eth_usd_feed: address, eth_usd_heartbeat: uint256):
    assert eth_usd_feed != empty(address), "zero feed"
    assert eth_usd_heartbeat >= MIN_HEARTBEAT and eth_usd_heartbeat <= MAX_HEARTBEAT, "heartbeat"
    ETH_USD_FEED = eth_usd_feed
    ETH_USD_HEARTBEAT = eth_usd_heartbeat


@external
def register(aggregator: address, heartbeat: uint256, symbol: String[32]):
    """
    @notice Permissionlessly register any Chainlink ASSET/USD aggregator as a
            trackable RWA. Registration validates the feed answers sanely.
    """
    assert aggregator != empty(address), "zero feed"
    assert aggregator != ETH_USD_FEED, "is eth feed"
    assert self.feeds[aggregator].heartbeat == 0, "registered"
    assert heartbeat >= MIN_HEARTBEAT and heartbeat <= MAX_HEARTBEAT, "heartbeat"
    # probe the feed: must answer with a positive, fresh, <=18-decimals price
    price: uint256 = self._read(aggregator, heartbeat)
    assert price > 0, "bad feed"
    self.feeds[aggregator] = FeedConfig(heartbeat=heartbeat, symbol=symbol)
    log AssetRegistered(asset=aggregator, heartbeat=heartbeat, symbol=symbol)


@view
@external
def is_registered(asset: address) -> bool:
    if asset == empty(address):
        return True  # USD sentinel
    return self.feeds[asset].heartbeat != 0


@view
@external
def latest_price(asset: address) -> uint256:
    """
    @notice x = ETH price denominated in `asset` units, 1e18-scaled.
            Reverts if either feed is stale or unregistered.
    """
    return self._price(asset)


@view
@internal
def _price(asset: address) -> uint256:
    eth_usd: uint256 = self._read(ETH_USD_FEED, ETH_USD_HEARTBEAT)
    if asset == empty(address):
        return eth_usd
    heartbeat: uint256 = self.feeds[asset].heartbeat
    assert heartbeat != 0, "unregistered"
    asset_usd: uint256 = self._read(asset, heartbeat)
    x: uint256 = eth_usd * UNIT // asset_usd
    assert x > 0, "zero index"
    return x


@view
@internal
def _read(aggregator: address, heartbeat: uint256) -> uint256:
    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in: uint80 = 0
    (round_id, answer, started_at, updated_at, answered_in) = staticcall AggregatorV3(aggregator).latestRoundData()
    assert answer > 0, "bad answer"
    assert updated_at <= block.timestamp, "future update"
    assert block.timestamp - updated_at <= heartbeat, "stale price"
    dec: uint256 = convert(staticcall AggregatorV3(aggregator).decimals(), uint256)
    assert dec <= 18, "decimals"
    return convert(answer, uint256) * 10**(18 - dec)
