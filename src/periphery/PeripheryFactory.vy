# pragma version ==0.4.3
"""
@title PeripheryFactory — permissionless, enumerable deployment of a tracker's
       LeverageRouter + LPZapper + FlashLeverageRouter
@notice Completes the permissionless peg lifecycle. TrackerFactory makes the
        soft-peg DAO; THIS makes (and registers) the three periphery helpers that
        give a peg its "Leverage" (standard + flash) and "Provide" surfaces,
        deployed from EIP-5202 blueprints of the audited periphery bytecode.
        Mirrors TrackerFactory/SeriesFactory:

        * on-chain registry — every periphery set is enumerable and reverse-
          lookupable (get_router/get_zapper/get_flash/get_pool, is_router/
          is_zapper/is_flash), so a frontend discovers a peg's helpers without a
          config file, the same way it already discovers trackers;
        * known bytecode — blueprint-deployed, so UIs can trust them without a
          bytecode check;
        * real-tracker gate — periphery may only be deployed for a tracker that
          the TrackerFactory itself created (is_tracker), and only once the
          spToken/WETH Uniswap v3 pool already exists (created + initialized);
        * no privileges — the factory holds no funds and controls nothing it
          deploys. The periphery it makes are as stateless/admin-free as the
          hand-deployed ones.

        Registry is keyed by (tracker, fee), NOT tracker alone: Uniswap's
        getPool is deterministic per fee tier, so every (tracker, fee) entry is
        canonical-by-construction. This denies a griefer the ability to lock a
        peg's registry to an off-tier junk pool by front-running the canonical
        deployment.

        Pool creation + initial liquidity are deliberately NOT here: a pool is
        initialized at a NAV-derived price and seeded with capital — a liquidity
        operation, not a stateless deploy. Create + initialize the pool first
        (e.g. NPM.createAndInitializePoolIfNecessary), then call this, then seed
        the first liquidity through the LPZapper.
"""

interface ITrackerFactory:
    def is_tracker(addr: address) -> bool: view

interface IUniV3Factory:
    def getPool(token_a: address, token_b: address, fee: uint24) -> address: view

interface IUniV3Pool:
    def tickSpacing() -> int24: view

event PeripheryDeployed:
    tracker: indexed(address)
    router: indexed(address)
    zapper: indexed(address)
    flash: address
    pool: address
    fee: uint24
    tick_spacing: int24
    creator: address

MAX_ENTRIES: constant(uint256) = 2**32

TRACKER_FACTORY: public(immutable(address))     # the permissionless TrackerFactory
LEVERAGE_BLUEPRINT: public(immutable(address))  # EIP-5202 blueprint of LeverageRouter
ZAPPER_BLUEPRINT: public(immutable(address))    # EIP-5202 blueprint of LPZapper
UNIV3_FACTORY: public(immutable(address))       # Uniswap v3 factory (pool resolution)
NPM: public(immutable(address))                 # Uniswap v3 NonfungiblePositionManager
SWAP_ROUTER: public(immutable(address))         # Uniswap v3 SwapRouter02
WETH: public(immutable(address))                # WETH9 every pool is paired against
FLASH_BLUEPRINT: public(immutable(address))     # EIP-5202 blueprint of FlashLeverageRouter
VAULT: public(immutable(address))               # Balancer v2 vault (flash source)

# key = keccak256(abi_encode(tracker, fee))
router_by_key: public(HashMap[bytes32, address])
zapper_by_key: public(HashMap[bytes32, address])
flash_by_key: public(HashMap[bytes32, address]) # tracker,fee -> FlashLeverageRouter
pool_by_key: public(HashMap[bytes32, address])
exists_by_key: public(HashMap[bytes32, bool])
is_router: public(HashMap[address, bool])       # trust check
is_zapper: public(HashMap[address, bool])       # trust check
is_flash: public(HashMap[address, bool])        # trust check
entry_count: public(uint256)
entry_tracker: public(HashMap[uint256, address])  # index -> tracker (enumeration)
entry_fee: public(HashMap[uint256, uint24])       # index -> fee


@deploy
def __init__(
    tracker_factory: address,
    leverage_blueprint: address,
    zapper_blueprint: address,
    flash_blueprint: address,
    univ3_factory: address,
    npm: address,
    swap_router: address,
    weth: address,
    vault: address,
):
    assert tracker_factory != empty(address), "zero tracker factory"
    assert leverage_blueprint != empty(address), "zero leverage bp"
    assert zapper_blueprint != empty(address), "zero zapper bp"
    assert flash_blueprint != empty(address), "zero flash bp"
    assert univ3_factory != empty(address), "zero univ3 factory"
    assert npm != empty(address), "zero npm"
    assert swap_router != empty(address), "zero swap router"
    assert weth != empty(address), "zero weth"
    assert vault != empty(address), "zero vault"
    TRACKER_FACTORY = tracker_factory
    LEVERAGE_BLUEPRINT = leverage_blueprint
    ZAPPER_BLUEPRINT = zapper_blueprint
    FLASH_BLUEPRINT = flash_blueprint
    UNIV3_FACTORY = univ3_factory
    NPM = npm
    SWAP_ROUTER = swap_router
    WETH = weth
    VAULT = vault


@view
@internal
def _key(tracker: address, fee: uint24) -> bytes32:
    return keccak256(abi_encode(tracker, fee))


@view
@external
def key(tracker: address, fee: uint24) -> bytes32:
    return self._key(tracker, fee)


@view
@external
def get_router(tracker: address, fee: uint24) -> address:
    return self.router_by_key[self._key(tracker, fee)]


@view
@external
def get_zapper(tracker: address, fee: uint24) -> address:
    return self.zapper_by_key[self._key(tracker, fee)]


@view
@external
def get_flash(tracker: address, fee: uint24) -> address:
    return self.flash_by_key[self._key(tracker, fee)]


@view
@external
def get_pool(tracker: address, fee: uint24) -> address:
    return self.pool_by_key[self._key(tracker, fee)]


@view
@external
def is_deployed(tracker: address, fee: uint24) -> bool:
    return self.exists_by_key[self._key(tracker, fee)]


@external
def deploy_periphery(tracker: address, fee: uint24) -> (address, address, address):
    """
    @notice Deploy + register the LeverageRouter, LPZapper, and
            FlashLeverageRouter for `tracker` against its spToken/WETH Uniswap v3
            pool at `fee` (one canonical periphery set per (tracker, fee)).
    @param tracker a TrackerFactory-created soft-peg DAO (also the sp ERC20).
    @param fee     the pool fee tier (e.g. 3000). The tick spacing is read from
            the pool itself, never trusted from the caller.
    @return (router, zapper, flash)
    @dev Reverts if the tracker is unknown to the TrackerFactory, periphery
         already exists for (tracker, fee), or the pool is not created yet.
    """
    assert staticcall ITrackerFactory(TRACKER_FACTORY).is_tracker(tracker), "unknown tracker"

    k: bytes32 = self._key(tracker, fee)
    assert not self.exists_by_key[k], "already deployed"

    pool: address = staticcall IUniV3Factory(UNIV3_FACTORY).getPool(tracker, WETH, fee)
    assert pool != empty(address), "pool not created"

    # tick spacing is read from the resolved pool, never from the caller, so the
    # LPZapper's full-range ticks are canonical-by-construction — a caller cannot
    # mis-wire (and thereby permanently brick, since the (tracker,fee) slot is
    # frozen with no admin) the zapper for a peg's canonical tier.
    tick_spacing: int24 = staticcall IUniV3Pool(pool).tickSpacing()
    assert tick_spacing > 0, "bad pool spacing"

    router: address = create_from_blueprint(
        LEVERAGE_BLUEPRINT, tracker, SWAP_ROUTER, WETH, fee, code_offset=3
    )
    zapper: address = create_from_blueprint(
        ZAPPER_BLUEPRINT, tracker, NPM, WETH, fee, tick_spacing, code_offset=3
    )
    flash: address = create_from_blueprint(
        FLASH_BLUEPRINT, tracker, SWAP_ROUTER, WETH, fee, VAULT, code_offset=3
    )

    self.router_by_key[k] = router
    self.zapper_by_key[k] = zapper
    self.flash_by_key[k] = flash
    self.pool_by_key[k] = pool
    self.exists_by_key[k] = True
    self.is_router[router] = True
    self.is_zapper[zapper] = True
    self.is_flash[flash] = True
    count: uint256 = self.entry_count
    assert count < MAX_ENTRIES, "too many"
    self.entry_tracker[count] = tracker
    self.entry_fee[count] = fee
    self.entry_count = count + 1

    log PeripheryDeployed(
        tracker=tracker,
        router=router,
        zapper=zapper,
        flash=flash,
        pool=pool,
        fee=fee,
        tick_spacing=tick_spacing,
        creator=msg.sender,
    )
    return (router, zapper, flash)
