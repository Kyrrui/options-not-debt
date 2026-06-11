# pragma version ==0.4.3
"""
@title SeriesFactory — permissionless creation of P/N option series
@notice Anyone can create an OptionSeries for ANY asset registered in the
        OracleHub (any RWA with a Chainlink ASSET/USD feed, plus the USD
        sentinel), at any strike and maturity within sane bounds. Series
        are deduplicated on (asset, strike, maturity): creating an
        existing series returns the existing address.
"""

interface IOracleHub:
    def is_registered(asset: address) -> bool: view

event SeriesCreated:
    asset: indexed(address)
    series: indexed(address)
    strike: uint256
    maturity: uint256

MIN_TERM: constant(uint256) = 3600              # 1 hour
MAX_TERM: constant(uint256) = 5 * 365 * 24 * 3600  # 5 years
MAX_SERIES: constant(uint256) = 2**32

HUB: public(immutable(address))
SERIES_BLUEPRINT: public(immutable(address))
TOKEN_BLUEPRINT: public(immutable(address))

# keccak256(abi_encode(asset, strike, maturity)) -> series
series_by_key: public(HashMap[bytes32, address])
series_count: public(uint256)
series_list: public(HashMap[uint256, address])
is_series: public(HashMap[address, bool])


@deploy
def __init__(hub: address, series_blueprint: address, token_blueprint: address):
    assert hub != empty(address), "zero hub"
    assert series_blueprint != empty(address), "zero series bp"
    assert token_blueprint != empty(address), "zero token bp"
    HUB = hub
    SERIES_BLUEPRINT = series_blueprint
    TOKEN_BLUEPRINT = token_blueprint


@external
def create_series(asset: address, strike: uint256, maturity: uint256) -> address:
    """
    @notice Create (or fetch) the P/N series for (asset, strike, maturity).
    @param asset    Chainlink ASSET/USD aggregator address, or address(0) for USD.
    @param strike   asset units per ETH, 1e18-scaled.
    @param maturity unix timestamp of option maturity.
    """
    assert staticcall IOracleHub(HUB).is_registered(asset), "unregistered asset"
    assert strike > 0, "zero strike"
    assert maturity >= block.timestamp + MIN_TERM, "term too short"
    assert maturity <= block.timestamp + MAX_TERM, "term too long"

    key: bytes32 = keccak256(abi_encode(asset, strike, maturity))
    existing: address = self.series_by_key[key]
    if existing != empty(address):
        return existing

    series: address = create_from_blueprint(
        SERIES_BLUEPRINT, HUB, asset, strike, maturity, TOKEN_BLUEPRINT, code_offset=3
    )
    self.series_by_key[key] = series
    count: uint256 = self.series_count
    assert count < MAX_SERIES, "too many series"
    self.series_list[count] = series
    self.series_count = count + 1
    self.is_series[series] = True
    log SeriesCreated(asset=asset, series=series, strike=strike, maturity=maturity)
    return series
