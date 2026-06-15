# Launching a peg end-to-end + the UI surfaces — handoff

> For the dapp builder. A peg isn't usable until it has: an oracle, a tracker,
> a genesis series, a spToken/WETH pool, and the two periphery helpers (router
> for **Leverage**, zapper for **Provide**). Everything is permissionless and
> on-chain enumerable — including periphery now, via the **PeripheryFactory**.
> This doc is the create-a-peg checklist + the two UI flows it implies:
> "Create a peg" and "Launch periphery for a peg that has none."

## The lifecycle (each step is one on-chain action)

| # | Step | Call | Who | Notes |
|---|---|---|---|---|
| 0 | Register the feed (non-USD only) | `OracleHub.register(feed, heartbeat, symbol)` | anyone | USD is the built-in sentinel (`asset = 0x0`); skip for spUSD-style pegs. Gives the `asset` id. |
| 1 | Create the tracker | `TrackerFactory.create_tracker(name, symbol, asset, term, roll_window, roll_trigger, strike_ratio, auction_dur, max_edge)` | anyone | Auto-enumerated (`is_tracker`, `tracker_list`). Dedupes on the param set. |
| 2 | Seed + spin up the genesis series | `TrackerDAO.deposit{value: x}()` then `TrackerDAO.sync()` | anyone | First deposit creates the active series; `share_price` starts at `1e18`. Now P/N tokens exist. |
| 3 | Create + initialize the pool | `NPM.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96)` | anyone | **The critical capital-adjacent step.** `sqrtPriceX96` must encode spToken's NAV (~$1 in ETH terms) — see below. Order token0/token1 by address. |
| 4 | Deploy + register the periphery | `PeripheryFactory.deploy_periphery(tracker, fee)` | anyone | Deploys the LeverageRouter + LPZapper, reads tick_spacing from the pool, records them in the registry. Reverts if step 3 wasn't done. |
| 5 | Seed the first liquidity | `LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline)` | anyone with capital | The zapper itself can be the bootstrapper. After this the pool has depth and Hold/Leverage work too. |

After step 4 the peg is fully discoverable; after step 5 it's actually usable
(Hold = pool swaps, Leverage = router, Provide = zapper).

### Addresses (Sepolia)

- PeripheryFactory: `0xDD1310E9ce98a6D34Ee4Db8164B98fEc1AD19bc9`
- TrackerFactory: `0x7C87799cad38576ddB03881570bd62e7ac1daf49`
- OracleHub: `0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62`
- Uniswap v3: factory `0x0227628f3F023bb0B980b67D528571c95c6DaC1c`, NPM
  `0x1238536071E1c677A632429e3655c799b22cDA52`, SwapRouter02
  `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`, WETH
  `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`. Canonical fee tier **3000**.

## Discovery — stop hardcoding periphery addresses

The whole point of the factory: the UI resolves a peg's periphery from chain,
the same way it already lists trackers. For a tracker + canonical fee (3000):

```
PeripheryFactory.is_deployed(tracker, 3000) -> bool
PeripheryFactory.get_router(tracker, 3000)  -> LeverageRouter (Leverage tab)
PeripheryFactory.get_zapper(tracker, 3000)  -> LPZapper       (Provide tab)
PeripheryFactory.get_pool(tracker, 3000)    -> spToken/WETH pool (Hold tab + price)
```

Enumerate everything ever deployed via `entry_count()` +
`entry_tracker(i)` + `entry_fee(i)`. Trust factory-made periphery with
`is_router(addr)` / `is_zapper(addr)` (blueprint bytecode, known-good). Drop the
`@gimbal/protocol` hardcoded router/zapper map — keep only the static infra
addresses (factories, Uniswap, WETH).

> Migration note: spUSD's canonical periphery is already registered — router
> `0xf5DEb5F36Ff8D6ed6657bA159eF7A7dBc46EedB0`, zapper
> `0x8F4C9824Ac836AB636BBA715Bc5dD99C65AA906c`. The earlier **standalone**
> router/zapper (`0xe942…9556`, `0x9657…3897`) are deprecated — read from the
> registry, not those.

## UI flow A — "Launch periphery" for a pre-existing peg

This is the one you asked for. On any peg's page (or a peg list), check
`is_deployed(tracker, 3000)`:

- **Deployed** → show the Leverage and Provide tabs wired to `get_router` /
  `get_zapper`.
- **Not deployed** → the peg has a tracker but no router/zapper yet. Show a
  **"Launch periphery"** panel that walks the missing prerequisites and ends in
  the `deploy_periphery` button:
  1. **Pool check** — `UniV3Factory.getPool(tracker, WETH, 3000)`. If zero,
     show **"Create the pool first"** → step 3 (pool creation UI below). The
     factory call will revert without it, so gate the button on this.
  2. **Deploy button** — `PeripheryFactory.deploy_periphery(tracker, 3000)`.
     One tx, permissionless, no params beyond tracker+fee (tick_spacing is read
     from the pool — the user can't get it wrong). On success, refresh from the
     registry and the Leverage/Provide tabs light up.
  - Copy: *"This peg's stable token is live, but its leverage and liquidity
    tools haven't been deployed yet. Launch them — anyone can, it's a one-time
    permissionless setup."* Show that it deploys two known-bytecode helpers and
    costs only gas.

## UI flow B — "Create a peg" (the full wizard)

A guided flow over steps 0–5, each a tx with clear state:

1. **Pick the asset** — USD (no oracle step) or an asset with a Chainlink feed
   (collect feed + heartbeat → `OracleHub.register`, show the resulting symbol).
2. **Name + params** — name/symbol + the DAO params (offer the canonical preset:
   term 28d, roll window 7d, trigger 1.5×, strike ratio 0.5×, auction 1d, edge
   2%) → `create_tracker`.
3. **Seed** — a small `deposit` + `sync`; confirm `share_price == 1e18`.
4. **Create the pool** — compute `sqrtPriceX96` from NAV and call
   `createAndInitializePoolIfNecessary`. **This is the step that needs care**
   (see pricing note); make it explicit, not hidden.
5. **Launch periphery** — `deploy_periphery(tracker, 3000)` (flow A's button).
6. **Seed liquidity** — first `LPZapper.add_liquidity` to give the pool depth.

Each step should be resumable: a peg half-created (tracker but no pool, or pool
but no periphery) should land the user back at the right next step — which is
exactly what flow A keys off.

## Honest caveats (put in the wizard, don't hide)

- **Pool price is load-bearing.** Step 3 initializes the pool at a price you
  choose; get it wrong and Hold buyers trade off-peg, the router over/under-pays,
  and the zapper LPs lopsidedly (refunding the rest). Initialize at NAV
  (`TrackerDAO.share_price()` → ETH terms via the ETH/USD feed) and seed real
  depth in step 6. Until it's seeded and arb-kept near NAV, surface
  price-impact warnings rather than hiding them.
- **Periphery deploy ≠ liquidity.** `deploy_periphery` makes the tools; it does
  not create or seed the pool. Pool creation + seeding is the capital step and
  is deliberately separate (a stateless factory shouldn't hold/seed funds).
- **One canonical periphery per (tracker, fee).** First successful
  `deploy_periphery` for a (tracker, 3000) wins and is frozen (no admin). It's
  safe because the periphery are deterministic known bytecode and tick_spacing
  is read from the pool — but the UI should call it once and then read the
  registry, not re-call.
- **Testnet · research code, unaudited.** Keep the tag everywhere.

## On-chain reference

| UI action | Call |
|---|---|
| register feed | `OracleHub.register(feed, heartbeat, symbol)` |
| create tracker | `TrackerFactory.create_tracker(name, symbol, asset, term, roll_window, roll_trigger, strike_ratio, auction_dur, max_edge)` |
| seed + series | `TrackerDAO.deposit{value}()` then `TrackerDAO.sync()` |
| create pool | `NPM.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96)` |
| launch periphery | `PeripheryFactory.deploy_periphery(tracker, 3000)` |
| seed liquidity | `LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline)` |
| discover periphery | `PeripheryFactory.get_router/get_zapper/get_pool/is_deployed(tracker, 3000)` |
| enumerate | `entry_count()`, `entry_tracker(i)`, `entry_fee(i)` |
| trust check | `is_router(addr)`, `is_zapper(addr)`, `is_tracker(addr)` |
