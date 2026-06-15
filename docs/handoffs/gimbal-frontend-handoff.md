# Gimbal frontend — full restructure handoff

> For the dapp builder. This is the master handoff: it consolidates **(A) the
> three-role UI restructure** (Hold / Leverage / Provide), **(B) the
> permissionless peg-launch lifecycle** (create a peg, spin up its periphery,
> discover it on-chain), and **(C) the certified-vs-user-created trust layer**
> into one document. It supersedes `three-roles-handoff.md`, `peg-launch-handoff.md`,
> and `certified-pegs-handoff.md`. You may READ the Gimbal repo but this is the
> spec; build from it.
>
> The big idea: the protocol IS a three-sided market, so the app has three
> top-level surfaces — one per role — and the spToken/WETH Uniswap v3 pool is
> the hub all three route through. Pegs (and their periphery) are created
> permissionlessly and discovered on-chain, so the UI stops hardcoding
> addresses.

---

# PART A — The three-role UI restructure

## A0. Why this is cleaner (read first)

The pain in the old saver flow came from one fact: minting spToken via
`TrackerDAO.deposit()` always also mints the leveraged **N** leg, and the N (and
any full-value redeem) only become ETH on a settlement **date** (pull-based —
nothing auto-converts). That machinery is unavoidable for the *manufacturer*,
but a casual stable buyer should never see it.

The fix is to route the two **consumer** roles through the pool and keep the
**producer** role (which touches the options machinery) in its own tab:

- **Hold** = buy/sell spToken on the pool. No N, no claims, no dates. A swap.
- **Leverage** = `LeverageRouter.open_leverage(min_eth_out)`. One tx, ETH → pure N.
- **Provide** = mint spToken (`deposit()`) and LP it via the zapper. The only
  role that holds N / sees the gearbox — correctly, because the N it's handed is
  the inventory the Leverage tab consumes. N stops being an orphan: the producer
  makes it, the leverage buyer buys it.

Three sides feed each other; everything settles onto one pool. That's the
elegance and the single fragility (see A5).

## A1. Information architecture

**Top nav becomes three items: Hold · Leverage · Provide.** A tracker is chosen
inside each (or via the existing tracker list as the landing). Everything else
demotes:

| Today | Goes to |
|---|---|
| Trackers (list/landing) | keep as the picker that feeds all three tabs |
| Trade | becomes **Leverage** |
| Deposit (mint) | moves into **Provide** + an "advanced: mint at exact NAV" option under Hold |
| Cash out (sell on pool) | becomes the **sell** side of **Hold** |
| Collect (claim legs) | becomes **Claims**, under *Advanced / Under the hood* — only producers & redeemers generate legs now |
| Series / Auctions | **Advanced / Under the hood** (unchanged behavior, demoted) — kept reachable: keepers/MMs still need them |
| Create | becomes the **"Create a peg" wizard** (Part B, flow B) under Advanced |

Newcomers don't know which persona they are, so labels must be plain and the
landing should route them: *"Keep it stable → Hold. Bet on ETH → Leverage. Earn
from providing the market → Provide."*

## A2. Tab 1 — Hold (stable buyer)

**Primary action: swap ETH ↔ spToken on the spToken/WETH Uniswap v3 pool.** Not
`deposit()`. A pool swap gives the user *only* spToken — no N leg, no settlement
date, no Collect. Buy and sell are the same surface, flipped.

- **Buy:** `ETH → WETH → spToken` via the v3 pool (SwapRouter02
  `exactInputSingle`, fee tier from the registry). Quote with the Uniswap
  quoter; show spToken out and effective price vs the on-chain peg target
  (`share_price()`, target `1e18`).
- **Sell (replaces "Cash out"):** `spToken → WETH → ETH`, same pool. Honestly
  *instant* now — no date.
- **Depth/price-impact warning:** reuse the liquidity-impact helpers. A thin
  pool means buying/selling *off peg*; show price impact and, above a threshold,
  warn + point to the backstop.
- **Backstop (under "advanced" on the sell side):** `TrackerDAO.redeem(shares)`
  is the guaranteed, oracle-free, pro-rata exit (returns P + buffered ETH that
  become ETH on a date → routes to **Claims**). Frame: *"Sell now at market"*
  (instant, pool price) vs *"Redeem at full value — paid on [date]"* (guaranteed,
  dated). Redeem needs *shares* (a pure pool-buyer holds them) and pays P, not
  cash — which is why it links into Claims.

**Copy:** "stable token," "buy/sell," "≈ \$1." Show the live soft peg
(`share_price`), backed only by ETH. **Do NOT imply yield** — Hold pays nothing;
it just stays level. (Holders don't earn; providers do.)

## A3. Tab 2 — Leverage (leverage buyer)

**Primary action: `LeverageRouter.open_leverage(min_eth_out)`** — one tx, ETH in
→ pure N leg + recovered ETH out, no leftover P. (Re-home the existing
LongEthCard; the router is already built, fork-tested, and deployed — discover it
via Part B.)

- Keep the already-fixed payoff diagram: USD-numéraire return,
  `breakevenIndexUsd`, leverage multiple shown.
- `min_eth_out` is the slippage floor on the P-sink swap — **never 0**. Derive
  from a quote + tolerance; surface price impact (this also routes through the
  pool — A5).
- Honest copy: "no funding, no liquidation, capped downside (you can't lose more
  than the premium)" — all true, all differentiators.

## A4. Tab 3 — Provide (LP / the manufacturer) — the honest, harder one

The producer role; the only one that touches the gearbox. Full flow: **ETH →
`deposit()` mints spToken shares (+ hands you N) → pair shares with WETH → add to
the spToken/WETH v3 pool.** The LP ends up holding: a v3 LP position (≈half ETH
exposure + impermanent loss), **plus the N leg**, and earns swap fees.

### The one-tx path: `LPZapper.add_liquidity()` (deployed)

A periphery **LPZapper** does the whole thing in one tx. **Discover it from the
PeripheryFactory registry — don't hardcode** (Part B):
`PeripheryFactory.get_zapper(tracker, 3000)`.

```
LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline) payable
  -> (token_id, liquidity, sp_used, weth_used)
```

It deposits `eth_to_deposit` into the tracker (mints shares + N), wraps the rest
to WETH, mints a **full-range** spToken/WETH position **straight to the caller's
wallet** (a real Uniswap NFT they manage on Uniswap's own UI), forwards the N
leg, and refunds every leftover. Stateless, no admin, holds nothing after.

**The frontend's job (this is where the work is):**
- **Compute `eth_to_deposit`** from the pool's current price so the two sides
  roughly balance — the contract does NO price math on purpose. A bad split
  isn't lost, just refunded, but a good split = less refund / more LP'd.
- **Set non-zero `amount_sp_min` / `amount_weth_min`** from a quote + tolerance.
  Never 0 in production (0 is for tests only).
- **Show the result honestly:** `sp_used` / `weth_used` vs what was refunded. On
  the current off-NAV pool only ~49% of the WETH side gets used and the rest
  comes back — surface that.

Fallback (still valid): `deposit()` then deep-link to Uniswap's Add Liquidity
UI. But the zapper is the better UX and it's live, so prefer it.

### Honest framing — do NOT sell this as easy yield

Spell out the three exposures: (1) impermanent loss on a *volatile*
spToken/WETH pair, (2) the N leverage leg you're handed, (3) fees as the upside.
"Provide / Earn fees" is fine as a label *because LPs genuinely earn fees* — but
the body copy must name the IL and the N. This is the one place "Earn" is honest.

**Handle the N explicitly.** `deposit()` (and the zapper) hand the provider an N
leg. Make it a first-class choice, not a mystery token: *"keep it (a leverage
position) or sell it to leverage buyers."* It's the supply that feeds the
Leverage tab — say so; selling the N routes through the same pool / Claims
machinery. Show the position + any P/N claims the provider holds (reuse the
Claims/MyLegs enumeration).

## A5. The thread that ties it together (How-it-works / Under the hood)

- **One pool, three roles.** Hold buys/sells spToken on it; Leverage uses it as
  the P-sink; Provide fills it. So *all three* degrade if the pool is thin or
  off-NAV — the elegance and the single fragility. Be honest: buy/sell quality on
  Hold and Leverage depends on Provide-side depth + an arb/keeper holding the
  pool near NAV.
- **Supply before demand.** Consumers (Hold/Leverage) only get good prices once
  producers (Provide) seed the pool. Making Provide a first-class tab recruits
  the supply side. Until depth exists, show price-impact warnings, don't hide.
- **N is not an orphan.** Producer mints it; leverage buyer consumes it. Make
  that loop legible across Provide and Leverage.
- The peg's "≈\$1" on Hold is only as good as the pool holds it; `redeem()` is
  the deep NAV-ish backstop. Normal times: pool. Stress: redeem.

## A6. Copy / honesty rules

- Plain words on the visible path: "stable token," "leverage," "provide
  liquidity," "buy/sell." Never P/N/strike/series/settle on the surface — the
  `?` / How-it-works link carries the mechanism.
- **No implied yield on Hold.** Yield language only on Provide, next to the IL +
  N risk.
- Exact figures on hover; never round a tx amount; keep the *Sepolia testnet ·
  research code, unaudited* tag everywhere.

## A7. What NOT to do

1. **Don't delete `redeem` / Claims.** It's the backstop and the **only
   guaranteed exit** (oracle-free, pays out regardless of pool state) — just
   demote it under Advanced, never remove it.
2. **Don't remove the depth/price-impact warnings to make the demo look clean.**
   The thin/off-NAV pool is the real state; honesty is the brand. Surface
   impact, don't hide it.
3. **Keep Series / Auctions reachable under Advanced** — keepers and
   market-makers need them; just keep them off the newcomer's path.
4. **Don't ship a Provide flow that hides the N or implies yield** (A4), and
   never pass 0 slippage mins on the zapper or router in production.
5. **Provide is a one-tx flow via the zapper** (A4) — prefer it over the
   mint-then-link-to-Uniswap fallback.

---

# PART B — Launching pegs + periphery (lifecycle, factory, discovery)

A peg isn't usable until it has: an oracle, a tracker, a genesis series, a
spToken/WETH pool, and the two periphery helpers (router for Leverage, zapper for
Provide). Everything is permissionless and on-chain enumerable — including
periphery now, via the **PeripheryFactory**.

## B7. The peg lifecycle (each step is one on-chain action)

| # | Step | Call | Who | Notes |
|---|---|---|---|---|
| 0 | Register the feed (non-USD only) | `OracleHub.register(feed, heartbeat, symbol)` | anyone | USD is the built-in sentinel (`asset = 0x0`); skip for spUSD-style pegs. Returns the `asset` id. |
| 1 | Create the tracker | `TrackerFactory.create_tracker(name, symbol, asset, term, roll_window, roll_trigger, strike_ratio, auction_dur, max_edge)` | anyone | Auto-enumerated (`is_tracker`, `tracker_list`). Dedupes on the param set. |
| 2 | Seed + spin up the genesis series | `TrackerDAO.deposit{value: x}()` then `TrackerDAO.sync()` | anyone | First deposit creates the active series; `share_price` starts at `1e18`. P/N tokens now exist. |
| 3 | Create + initialize the pool | `NPM.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96)` | anyone | **Critical capital-adjacent step.** `sqrtPriceX96` must encode spToken's NAV (~$1 in ETH terms). Order token0/token1 by address. |
| 4 | Deploy + register the periphery | `PeripheryFactory.deploy_periphery(tracker, fee)` | anyone | Deploys the LeverageRouter + LPZapper + FlashLeverageRouter, **reads tick_spacing from the pool**, records all three in the registry. Reverts if step 3 wasn't done. |
| 5 | Seed the first liquidity | `LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline)` | anyone with capital | The zapper itself can bootstrap. After this the pool has depth and Hold/Leverage work too. |

After step 4 the peg is fully discoverable; after step 5 it's actually usable
(Hold = pool swaps, Leverage = router, Provide = zapper).

## B8. Addresses (Sepolia)

| | Address |
|---|---|
| **PeripheryFactory** (v2) | `0xdfD387aFFF2aDD0726dDA0fbE6ac7ee77F562D6D` |
| TrackerFactory | `0x7C87799cad38576ddB03881570bd62e7ac1daf49` |
| OracleHub | `0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62` |
| Uniswap v3 factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Uniswap NPM | `0x1238536071E1c677A632429e3655c799b22cDA52` |
| Uniswap SwapRouter02 | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

Canonical fee tier **3000**. Static infra only — periphery + pools are
discovered from the registry, not hardcoded.

## B9. Discovery — stop hardcoding periphery addresses

The UI resolves a peg's periphery from chain, the same way it already lists
trackers. For a tracker + canonical fee (3000):

```
PeripheryFactory.is_deployed(tracker, 3000) -> bool
PeripheryFactory.get_router(tracker, 3000)  -> LeverageRouter (Leverage tab)
PeripheryFactory.get_flash(tracker, 3000)   -> FlashLeverageRouter (Leverage "send exactly your premium" mode)
PeripheryFactory.get_zapper(tracker, 3000)  -> LPZapper       (Provide tab)
PeripheryFactory.get_pool(tracker, 3000)    -> spToken/WETH pool (Hold tab + price)
```

Enumerate all periphery ever deployed via `entry_count()` + `entry_tracker(i)` +
`entry_fee(i)`. Trust factory-made periphery with `is_router(addr)` /
`is_zapper(addr)` (blueprint bytecode, known-good). Drop the `@gimbal/protocol`
hardcoded router/zapper map — keep only the static infra addresses (B8).

> Migration note: use **PeripheryFactory v2** (`0xdfD3…2D6D`). spUSD's v2
> periphery is registered — router `0xdA387BdE50b4943162947ccDF4E9eca3dA70940E`,
> zapper `0x8828AF8682dC8B95DCC08a52F79E5d6Cb9c80aF1`, flash
> `0xF8a2DF8E9288a9b9dd56a0F6F749773dBb8A2957`. Deprecated (don't use): v1 factory
> `0xDD13…9bc9` + its periphery (`0xf5DE…edB0`/`0x8F4C…906c`), the standalone flash
> (`0x0a48…e0df`), and the pre-factory standalones (`0xe942…9556`/`0x9657…3897`).
> Always read from the v2 registry, never hardcoded addresses.

## B10. UI flow A — "Launch periphery" for a pre-existing peg

On any peg's page (or the peg list), check `is_deployed(tracker, 3000)`:

- **Deployed** → show the Leverage and Provide tabs wired to `get_router` /
  `get_zapper`.
- **Not deployed** → the peg has a tracker but no router/zapper yet. Show a
  **"Launch periphery"** panel:
  1. **Pool check** — `UniV3Factory.getPool(tracker, WETH, 3000)`. If zero, show
     **"Create the pool first"** → lifecycle step 3. The factory call reverts
     without it, so gate the button on this.
  2. **Deploy button** — `PeripheryFactory.deploy_periphery(tracker, 3000)`. One
     tx, permissionless, no params beyond tracker+fee (tick_spacing is read from
     the pool — the user can't get it wrong). On success, refresh from the
     registry and the Leverage/Provide tabs light up.
  - Copy: *"This peg's stable token is live, but its leverage and liquidity tools
    haven't been deployed yet. Launch them — anyone can, it's a one-time
    permissionless setup."* Show it deploys three known-bytecode helpers
    (router + zapper + flash), costs only gas.

## B11. UI flow B — "Create a peg" wizard (the Advanced "Create" surface)

A guided flow over lifecycle steps 0–5, each a tx with clear state:

1. **Pick the asset** — USD (no oracle step) or an asset with a Chainlink feed
   (collect feed + heartbeat → `OracleHub.register`, show the resulting symbol).
2. **Name + params** — name/symbol + DAO params (offer the canonical preset:
   term 28d, roll window 7d, trigger 1.5×, strike ratio 0.5×, auction 1d, edge
   2%) → `create_tracker`.
3. **Seed** — a small `deposit` + `sync`; confirm `share_price == 1e18`.
4. **Create the pool** — compute `sqrtPriceX96` from NAV; call
   `createAndInitializePoolIfNecessary`. **Make this explicit, not hidden**
   (see B12 — pool price is load-bearing).
5. **Launch periphery** — `deploy_periphery(tracker, 3000)` (flow A's button).
6. **Seed liquidity** — first `LPZapper.add_liquidity` to give the pool depth.

Each step must be resumable: a half-created peg (tracker but no pool, or pool but
no periphery) should land the user back at the right next step — which is exactly
what flow A keys off.

## B12. Honest caveats (put in the wizard, don't hide)

- **Pool price is load-bearing.** Step 3 initializes the pool at a price you
  choose; get it wrong and Hold buyers trade off-peg, the router over/under-pays,
  the zapper LPs lopsidedly (refunding the rest). Initialize at NAV
  (`TrackerDAO.share_price()` → ETH terms via the ETH/USD feed) and seed real
  depth in step 6. Until seeded + arb-kept near NAV, surface price-impact
  warnings.
- **Periphery deploy ≠ liquidity.** `deploy_periphery` makes the tools; it does
  not create or seed the pool. Pool creation + seeding is the capital step,
  deliberately separate (a stateless factory shouldn't hold/seed funds).
- **One canonical periphery per (tracker, fee).** First successful
  `deploy_periphery` wins and is frozen (no admin). Safe because periphery are
  deterministic known bytecode and tick_spacing is read from the pool — but call
  it once, then read the registry.
- **Testnet · research code, unaudited.** Keep the tag everywhere.

---

# PART C — Certified vs user-created pegs (trust layer)

Pegs are created permissionlessly (anyone can run the Create-a-peg wizard), but
the app curates trust: **certified** pegs (operator-blessed + keeper-maintained)
show by default; **user-created** pegs are permissionless, unmaintained, and live
behind an optional "show more" with clear warnings. This is the token-list /
verified-vs-unverified pattern, layered on the Part B discovery model.

## C1. Data model

There is **no on-chain "certified" bit** (the protocol is admin-free). Certified
= membership in an **operator-curated list**, off-chain — a versioned
`certifiedPegs.json` in `@gimbal/protocol` (token-list style). Key point: **the
keeper reads the same list**, so "shown as certified" ⇔ "maintained by our
keeper." One source of truth. Each entry carries curated display metadata (so
names never come from untrusted on-chain strings):

```
{ tracker, assetId, feed, heartbeat, assetSymbol, trackerName, fee, certifiedSince }
```

Three lists the UI builds:
- **Certified** = the config (validate each still exists on-chain:
  `TrackerFactory.is_tracker(tracker)`, `PeripheryFactory.is_deployed(tracker, fee)`).
- **All pegs** = `TrackerFactory.tracker_count()` + `tracker_list(i)`.
- **User-created** = All − Certified.

Per-peg truth (for badges + the unverified panel), all on-chain:
- What it actually tracks: `tracker.ASSET()` → `assetId`, then
  `OracleHub.feeds(assetId)` → `(aggregator, heartbeat, symbol)`. This is the
  truth regardless of the tracker's display name.
- Periphery/pool: `PeripheryFactory.get_router/get_zapper/get_pool/is_deployed(tracker, fee)`.
- Health: `tracker.share_price()` / `nav()`; active series `MATURITY`/`settled`
  (past maturity + unsettled ⇒ nobody's maintaining it).
- Creator: the `TrackerCreated` event's indexed `creator`.

## C2. What the two tiers mean (state it in the UI)

- **Certified** = operator vouches and runs it: curated name + symbol, a sane
  (weekend-safe) heartbeat, **keeper-maintained** (rolls/settles on time),
  periphery deployed, pool seeded. Safe default.
- **User-created** = permissionless, **not maintained by our keeper**, with risks
  the UI must spell out: no keeper → may never settle/roll → **can stall/break**;
  custom heartbeat → may accept stale prices; **untrusted name** (first-writer-
  wins on-chain) → could impersonate a certified peg; possibly thin liquidity.

## C3. UI behavior — one rule everywhere

**Certified by default; user-created behind "show more"; visually distinct; never
intermixed.**
- **Home dashboard:** certified grid up top; a collapsed **"Show N user-created
  pegs"** expander renders the rest in a muted, separated section, each with an
  `Unverified` badge.
- **Hold tab (asset picker):** certified first; "show more" reveals user-created;
  selecting one triggers the warning gate (C4) before the buy/sell UI.
- **Provide tab:** same split, with *stronger* emphasis — providing into an
  unmaintained, possibly-stale peg is riskier than trading it (your capital sits
  in it). Require the warning ack here too.
- **Leverage tab:** apply the same rule for consistency.

## C4. Badges & non-certified safeguards (required)

Badges: `Certified ✓`; `Unverified ⚠` plus on-chain sub-flags — `No keeper`,
`Overdue` (active series past `MATURITY`, `settled==false`), `Custom staleness:
<heartbeat>`, `Thin liquidity`, `⚠ Mimics a certified name`.

Safeguards:
1. **Collapsed by default**, muted styling, never ranked/styled like certified.
2. **Warning gate on first interaction** (modal): *"This peg was created by
   `0x…`, is not maintained by Gimbal, uses a custom oracle staleness of `<X>`,
   and may not settle or hold its peg. Verify the underlying feed and proceed at
   your own risk."* + a proceed checkbox.
3. **Show the raw truth**, not the self-reported name: the underlying Chainlink
   feed (link out), heartbeat, creator address, last settle/roll time. Display
   name shown as *"(unverified name)"*.
4. **Anti-impersonation:** if a user-created peg's name/symbol matches a certified
   one, suppress the user-supplied name and render it as *"Unverified peg tracking
   `<feed>` — created by `0x…`"* with a prominent warning. Certified pegs must be
   unspoofable.

## C5. Adding / certifying

- **Anyone can create** (keep the wizard). Its output is **user-created** — it
  lands in show-more, not the certified grid. Optionally show a "Request
  certification" link.
- **Certifying** is an operator action, off-chain: add the entry to
  `certifiedPegs.json` (which also enrolls it in the keeper) after confirming
  periphery is deployed and the pool is seeded. No on-chain role needed —
  certification is curation, not a permission.

---

# PART D — Consolidated on-chain reference

| UI action | Call |
|---|---|
| Hold · buy | SwapRouter02 `exactInputSingle` ETH→spToken (pool from `get_pool`) |
| Hold · sell (instant) | SwapRouter02 `exactInputSingle` spToken→ETH |
| Hold · redeem (backstop) | `TrackerDAO.redeem(shares)` → pays P + ETH → Claims (dated) |
| Leverage · open | `LeverageRouter.open_leverage(min_eth_out)` (router from `get_router`; min ≠ 0) |
| Leverage · open (send exactly premium) | `FlashLeverageRouter.open_leverage(flash_amount, min_eth_out)` payable, msg.value = premium (from `get_flash`; min ≥ flash_amount) |
| Provide · LP (one tx) | `LPZapper.add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline)` (zapper from `get_zapper`; mins ≠ 0; split off-chain) |
| Provide · LP (fallback) | `TrackerDAO.deposit{value}()` then link to Uniswap Add Liquidity |
| Claims · collect | settle-if-needed → `redeem_p`/`redeem_n` (one `useTxFlow`) |
| Peg / NAV reads | `share_price()`, `nav()` (target `1e18`) |
| Create: register feed | `OracleHub.register(feed, heartbeat, symbol)` |
| Create: tracker | `TrackerFactory.create_tracker(name, symbol, asset, term, roll_window, roll_trigger, strike_ratio, auction_dur, max_edge)` |
| Create: seed + series | `TrackerDAO.deposit{value}()` then `TrackerDAO.sync()` |
| Create: pool | `NPM.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96)` |
| Launch periphery | `PeripheryFactory.deploy_periphery(tracker, 3000)` |
| Create: seed liquidity | `LPZapper.add_liquidity(...)` — lifecycle step 5; first LP bootstraps pool depth |
| Discover periphery | `PeripheryFactory.get_router / get_zapper / get_flash / get_pool / is_deployed(tracker, 3000)` |
| Enumerate pegs w/ periphery | `entry_count()`, `entry_tracker(i)`, `entry_fee(i)` |
| Trust checks | `is_router(addr)`, `is_zapper(addr)` (PeripheryFactory); `is_tracker(addr)` (TrackerFactory) |
| Enumerate ALL pegs | `TrackerFactory.tracker_count()`, `tracker_list(i)` |
| What a peg really tracks | `tracker.ASSET()` → `OracleHub.feeds(assetId)` → `(aggregator, heartbeat, symbol)` |
| Peg creator (unverified panel) | `TrackerCreated` event, indexed `creator` |
| Certified set | `@gimbal/protocol` `certifiedPegs.json` (same list the keeper consumes) |

Reuse existing helpers: `breakevenIndexUsd`, the liquidity-impact price-impact
helpers, the MyLegs/Claims enumeration. Keep only static infra addresses
hardcoded; everything peg-specific comes from the registries.
