# pragma version ==0.4.3
"""
@title TrackerFactory — permissionless creation of soft-peg wrapper DAOs
@notice Lets anyone spin up a TrackerDAO for any registered asset, paying
        their own gas, via an EIP-5202 blueprint of the audited TrackerDAO
        bytecode. The factory is what makes user-created pegs first-class:

        * on-chain registry — every created tracker is enumerable, so any
          frontend can discover all pegs without a config file;
        * known bytecode — factory-created trackers are exactly the
          blueprint, so UIs can trust them without bytecode checks;
        * brick prevention — the cross-contract conditions the TrackerDAO
          constructor cannot validate are enforced here: the asset must be
          registered in the hub, the hub is injected (never caller-chosen),
          and the term fits inside the series factory's maturity bounds;
        * deduplication — one canonical tracker per parameter set
          (name/symbol are cosmetic and excluded from the dedupe key; the
          first creator picks them).

        The factory holds no privileges over created trackers — they are
        as immutable and admin-free as the canonical deployments.
"""

interface IOracleHub:
    def is_registered(asset: bytes32) -> bool: view

interface ISeriesFactory:
    def HUB() -> address: view

event TrackerCreated:
    asset: indexed(bytes32)
    tracker: indexed(address)
    creator: indexed(address)
    name: String[64]
    symbol: String[32]

# must not exceed SeriesFactory.MAX_TERM or the tracker's series
# creation would revert forever
MAX_TERM: constant(uint256) = 5 * 365 * 24 * 3600
MAX_TRACKERS: constant(uint256) = 2**32

HUB: public(immutable(address))
SERIES_FACTORY: public(immutable(address))
TRACKER_BLUEPRINT: public(immutable(address))

# keccak256(abi_encode(asset, term, roll_window, roll_trigger,
#                      strike_ratio, auction_dur, max_edge)) -> tracker
tracker_by_key: public(HashMap[bytes32, address])
tracker_count: public(uint256)
tracker_list: public(HashMap[uint256, address])
is_tracker: public(HashMap[address, bool])


@deploy
def __init__(hub: address, series_factory: address, tracker_blueprint: address):
    assert hub != empty(address), "zero hub"
    assert series_factory != empty(address), "zero factory"
    assert tracker_blueprint != empty(address), "zero blueprint"
    # the series factory must price/register against the SAME hub, or every
    # tracker would pass create_tracker's registration gate yet brick on its
    # first deposit when SeriesFactory re-checks registration against its own
    # hub. This cross-contract condition is cheaply enforceable here.
    assert staticcall ISeriesFactory(series_factory).HUB() == hub, "hub mismatch"
    HUB = hub
    SERIES_FACTORY = series_factory
    TRACKER_BLUEPRINT = tracker_blueprint


@external
def create_tracker(
    name: String[64],
    symbol: String[32],
    asset: bytes32,
    term: uint256,
    roll_window: uint256,
    roll_trigger: uint256,
    strike_ratio: uint256,
    auction_dur: uint256,
    max_edge: uint256,
) -> address:
    """
    @notice Create (or fetch) the soft-peg tracker for this parameter set.
            All economic validation beyond the checks below happens in the
            TrackerDAO constructor itself (term/window ordering, trigger
            and ratio bounds, the genesis-brick invariant, auction bounds).
    @param asset OracleHub asset id (empty(bytes32) = USD).
    @return the tracker address (existing one if the params are already live).
    """
    assert staticcall IOracleHub(HUB).is_registered(asset), "unregistered asset"
    assert term <= MAX_TERM, "term too long"

    key: bytes32 = keccak256(
        abi_encode(asset, term, roll_window, roll_trigger, strike_ratio, auction_dur, max_edge)
    )
    existing: address = self.tracker_by_key[key]
    if existing != empty(address):
        return existing

    tracker: address = create_from_blueprint(
        TRACKER_BLUEPRINT,
        name,
        symbol,
        HUB,
        SERIES_FACTORY,
        asset,
        term,
        roll_window,
        roll_trigger,
        strike_ratio,
        auction_dur,
        max_edge,
        code_offset=3,
    )
    self.tracker_by_key[key] = tracker
    count: uint256 = self.tracker_count
    assert count < MAX_TRACKERS, "too many trackers"
    self.tracker_list[count] = tracker
    self.tracker_count = count + 1
    self.is_tracker[tracker] = True
    log TrackerCreated(asset=asset, tracker=tracker, creator=msg.sender, name=name, symbol=symbol)
    return tracker
