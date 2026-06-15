# Solo RFQ — best-execution routing spec (for the dapp builder)

> How to make the RFQ desk a first-class liquidity source **across the site** rather
> than a single card, and route between it and the Uniswap path by price + capacity.
> Builds on `docs/handoffs/solo-rfq-frontend-handoff.md` (the desk integration) and
> `docs/handoffs/solo-rfq-quoter-spec.md` (the quoter API). Frontend logic — implement in the app.

## The rule, stated precisely

RFQ-first, fall back to / prefer Uniswap **only** when (a) Uniswap gives the user a better
effective price, or (b) the order exceeds what the desk will take. This is best-execution
with a capacity constraint. **It applies to BUY N only.** Sell-N is RFQ-exclusive.

## Venue map (what each leg/side can route to)

| Trade | RFQ desk | Uniswap path | Router behavior |
|---|---|---|---|
| **Buy N** (open leverage) | desk SELLS N (signed quote → `fill_buy_n`) | `LeverageRouter.open_leverage` (mints, sells the P into the spUSD/WETH 0.3% pool, returns N) | quote BOTH, execute the better effective price; if the desk can't take the size or is down → Uniswap |
| **Sell N** (close leverage) | desk BUYS N (signed quote → `fill_sell_n`) | **none — N is in no pool** | RFQ only. If the desk can't take the size or is down → show "unavailable / try smaller / wait"; **never imply a pool route** |
| **Buy spUSD** (Hold) | — (desk is N-only in v1) | spUSD/WETH pool, or `deposit()` mint | pool/mint only until phase-2 spUSD quoting |
| **Sell spUSD** (Hold) | — (v1) | pool, or `redeem()` (oracle-free, pro-rata) | pool/redeem only in v1 |

So "across the site" in v1 = **everywhere N is acquired or disposed** route through this logic:
the Leverage tab (buy + the new sell), the Earn/Provide flow (which hands users N they'll
want to sell), and any portfolio/positions view showing an N balance. spUSD/Hold stays
pool-based until the desk quotes spUSD.

## The routing algorithm (per N trade)

Inputs: `side` (buy/sell N), `size` (N units), `slippageTolerance`, user address.

1. **Request an RFQ quote** (`POST /quote`). Outcomes:
   - valid → `{ price, amount=size, deadline, v,r,s }`.
   - `over-max-fill` (400) / `inventory-full` (409) → desk can't take the full size.
   - `desk-paused` / `near-strike` / `no-series` / `series-settled` / `near-maturity` (503) → desk unavailable.
2. **Price the Uniswap path for the same size** — *buy-N only* (sell-N skips this):
   - effective cost via `LeverageRouter`: use the Uniswap **Quoter** to price the P→WETH sale at `size`, including the 0.3% fee and depth-driven slippage; derive ETH-in per N-out.
3. **Normalize to one comparable metric** per venue: **N received per ETH** (buy) at the
   requested size, net of pool fee + expected slippage (+ optionally gas). Compare *these*,
   never the RFQ price vs the raw pool mid.
4. **Choose:**
   - both available, full size → route to the **better effective price**.
   - desk can't take full size (`over-max-fill`/`inventory-full`):
     - buy-N → route to Uniswap (v1: whole order; phase-2: fill desk to cap + remainder to pool — "split").
     - sell-N → offer to fill **only what the desk will take now** (read `max_fill`/inventory), tell the user the rest must wait or be split over time. No pool fallback.
   - desk unavailable (paused/down):
     - buy-N → Uniswap.
     - sell-N → "sell-N temporarily unavailable (no desk quoting this leg)".
5. **Execute** on the chosen venue with the user's `minOut`/`maxIn` from `slippageTolerance`
   (RFQ: submit `fill_*`; Uniswap: `LeverageRouter` with `min_eth_out`).

## Subtleties that must be handled

- **Apples-to-apples comparison.** Build one canonical `quote(side,size) → {effectiveOut, venue}`
  per venue and compare the outputs. The RFQ leg is a direct N price; the Uniswap leg's cost is
  size-dependent (fee + slippage). Comparing RFQ price to the pool mid will mis-route.
- **The pool is thin and often off-NAV** (`0x8362…`, see deployments.md). When it's mispriced,
  the `LeverageRouter` route over/under-pays and the comparison will (correctly) favor RFQ —
  which is the whole point. Don't special-case it; the effective-price math handles it.
- **Sell-N has no fallback.** Reinforced because it's the easy mistake: if the desk is capped or
  down, sell-N is unavailable. The UI must not show a Uniswap option for it.
- **Quote staleness / race.** The RFQ quote has a short TTL; the pool moves. Fetch both within a
  tight window, show the user a countdown, re-quote on expiry, and always submit with `minOut` so
  a moved pool/quote can't sandwich. A fill can still revert ("get a fresh quote", per the handoff).
- **Capacity hinting.** Read `max_fill` / `net_n` / `max_nav_at_risk` off the desk to pre-show
  "desk handles up to X; larger routes to the pool", but treat the quoter's `over-max-fill` /
  `inventory-full` responses as the source of truth.
- **Gas.** RFQ ≈ 1 tx; `LeverageRouter` ≈ 1 tx (more pool interaction). Either fold a gas estimate
  into the comparison or ignore it in v1 (both ~1 tx) — just be consistent.

## v1 vs phase 2

- **v1 (frontend SOR):** whole-order routing (no splitting), N-leg only, buy-N has the pool
  fallback, sell-N is RFQ-only. This satisfies "across the site + fall back to Uniswap on
  size/price."
- **Phase 2:** order **splitting** (fill the desk to its cap, route the remainder to the pool);
  **spUSD-side RFQ** once the desk quotes spUSD; and an optional **on-chain best-execution router**
  (a periphery contract — contract-side, not the builder's) that takes a signed RFQ quote + a pool
  route and executes the better/split atomically with one `minOut`, removing the frontend race and
  giving true atomic best-ex. Flag if you want this; it's a contract deliverable.

## Pointers
- Desk integration + ABI + trust labeling: `docs/handoffs/solo-rfq-frontend-handoff.md`
- Quoter API + error codes: `docs/handoffs/solo-rfq-quoter-spec.md`
- Deployed desk + the spUSD/WETH pool + `LeverageRouter` addresses: `docs/deployments.md`
