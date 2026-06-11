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

        Assets are keyed by id = keccak256(aggregator, heartbeat), NOT by
        the aggregator address alone. This makes registration squat-proof:
        any (feed, staleness-tolerance) combination can be registered by
        anyone, registrations are immutable and content-addressed, and
        integrators (series creators, wrapper DAOs) opt into exactly the
        configuration they trust. A maliciously loose or tight heartbeat
        registration occupies only its own id and blocks nobody.

        The sentinel id empty(bytes32) denotes USD itself (x = ETH/USD).
"""

interface AggregatorV3:
    def decimals() -> uint8: view
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view

event AssetRegistered:
    asset: indexed(bytes32)
    aggregator: indexed(address)
    heartbeat: uint256
    symbol: String[32]

struct FeedConfig:
    aggregator: address
    heartbeat: uint256
    symbol: String[32]

UNIT: constant(uint256) = 10**18
MIN_HEARTBEAT: constant(uint256) = 60
MAX_HEARTBEAT: constant(uint256) = 7 * 24 * 3600

ETH_USD_FEED: public(immutable(address))
ETH_USD_HEARTBEAT: public(immutable(uint256))

# asset id == keccak256(abi_encode(aggregator, heartbeat))
feeds: public(HashMap[bytes32, FeedConfig])


@deploy
def __init__(eth_usd_feed: address, eth_usd_heartbeat: uint256):
    assert eth_usd_feed != empty(address), "zero feed"
    assert eth_usd_heartbeat >= MIN_HEARTBEAT and eth_usd_heartbeat <= MAX_HEARTBEAT, "heartbeat"
    ETH_USD_FEED = eth_usd_feed
    ETH_USD_HEARTBEAT = eth_usd_heartbeat


@pure
@external
def asset_id(aggregator: address, heartbeat: uint256) -> bytes32:
    return self._asset_id(aggregator, heartbeat)


@pure
@internal
def _asset_id(aggregator: address, heartbeat: uint256) -> bytes32:
    return keccak256(abi_encode(aggregator, heartbeat))


@external
def register(aggregator: address, heartbeat: uint256, symbol: String[32]) -> bytes32:
    """
    @notice Permissionlessly register a (Chainlink ASSET/USD aggregator,
            heartbeat) pair as a trackable RWA. Content-addressed and
            idempotent: the same pair always maps to the same asset id and
            an existing registration is simply returned. Registration
            probes the feed for a positive, fresh, <=18-decimals answer.
    @return the asset id to use in SeriesFactory / TrackerDAO.
    """
    assert aggregator != empty(address), "zero feed"
    assert heartbeat >= MIN_HEARTBEAT and heartbeat <= MAX_HEARTBEAT, "heartbeat"
    asset: bytes32 = self._asset_id(aggregator, heartbeat)
    assert asset != empty(bytes32), "sentinel collision"
    if self.feeds[asset].aggregator != empty(address):
        return asset  # idempotent
    price: uint256 = self._read(aggregator, heartbeat)
    assert price > 0, "bad feed"
    self.feeds[asset] = FeedConfig(aggregator=aggregator, heartbeat=heartbeat, symbol=symbol)
    log AssetRegistered(asset=asset, aggregator=aggregator, heartbeat=heartbeat, symbol=symbol)
    return asset


@view
@external
def is_registered(asset: bytes32) -> bool:
    if asset == empty(bytes32):
        return True  # USD sentinel
    return self.feeds[asset].aggregator != empty(address)


@view
@external
def latest_price(asset: bytes32) -> uint256:
    """
    @notice x = ETH price denominated in `asset` units, 1e18-scaled.
            Reverts if either feed is stale or unregistered.
    """
    return self._price(asset)


@view
@internal
def _price(asset: bytes32) -> uint256:
    eth_usd: uint256 = self._read(ETH_USD_FEED, ETH_USD_HEARTBEAT)
    if asset == empty(bytes32):
        return eth_usd
    cfg: FeedConfig = self.feeds[asset]
    assert cfg.aggregator != empty(address), "unregistered"
    asset_usd: uint256 = self._read(cfg.aggregator, cfg.heartbeat)
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
