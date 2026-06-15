# Surface pool DEPTH / price-impact (not just price) — handoff

> For the dapp builder. Adds the missing signal: a position too large for the
> backing pool's *liquidity*. This is distinct from the existing
> price-vs-NAV (`basisHard`) check — the pool price can be perfectly fine and
> the trade still execute terribly because the pool is thin (today ~0.495
> WETH). Thin-pool price impact is the real reason breakeven sits far out on
> small-looking inputs, and it must be shown.

## The mechanic

`LeverageRouter.open_leverage` (and the cash-out "Sell now") realize value by
selling spUSD into the spUSD/WETH pool. A sale large relative to the pool's
reserve walks down the curve (price impact): you get back less ETH than the
*spot* price implies. Net premium rises, and the payoff chart's breakeven
moves right — not because the option is expensive, but because the pool is
shallow. Large enough inputs are effectively unfillable.

## Compute price impact (separate from basis)

Both quote paths already produce the live quoted ETH out (the value behind
`minOut`) and `sharesOut` (the spUSD being sold); `usePoolMarket(dao)` gives
the pool's marginal **spot** (ETH per share) and the reserves. Then:

- `fairOut = sharesOut × spot`  (zero-impact proceeds at the current price)
- `priceImpact = 1 − quotedOut / fairOut`  (≥ 0; the depth tax)
- `liquidityCostEth = fairOut − quotedOut`  (extra ETH the thinness costs)

`priceImpact` isolates **depth**; the existing `basis` isolates **price**.
Show them as two different things — never fold depth into the basis warning.

Read pool reserves **live** (never hardcode 0.495) — depth changes as the
pool is traded/seeded.

## Surface it (Trade open AND cash-out sell)

Tiered, by `priceImpact`:
- `< 1%` — nothing.
- `1–5%` — quiet note: *"~X% price impact — the pool backing this is small."*
- `≥ 5%` — prominent line: *"This size moves the pool ~X% (only ~Y ETH of
  liquidity). You'd pay ~Z ETH extra and your breakeven is far out because of
  that, not the option price. Try a smaller amount."*
- Above a hard cap (e.g. impact `≥ 10%`, or `quotedOut` near pool-empty) —
  **disable Open Long / Sell now** with: *"Too large for current liquidity
  (~Y ETH in the pool). Max for a fair price: ~M ETH."*

## Two affordances that make it usable

1. **Show pool depth on the card**: one quiet line — *"backed by ~0.5 ETH of
   pool liquidity"* — so the constraint is visible before the user even types.
2. **"Max for a fair price: ~M ETH"** — the largest input keeping impact ≤ a
   target τ (~1%). Closed form for a full-range pool: max spUSD to sell
   `dx ≤ Rx · τ/(1−τ)` (Rx = pool spUSD reserve), then back out the ETH
   deposit that mints ≤ dx shares; or binary-search the quoter. Render it as a
   tappable max, mirroring the existing wallet-balance "max".

## Tie it to the payoff chart (the user-facing "why")

When `priceImpact ≥` the soft threshold, add one line under the breakeven:
*"Breakeven is far from today's price mostly because of pool depth at this
size — a smaller amount breaks even nearer today's price."* This directly
answers the confusion: the chart looked like an expensive option when it's
really a thin-pool tax.

## Honest framing / the real fix

The UI can only *reveal* the constraint and steer size; the cure is **more
liquidity in the pool at NAV** (seed it / keeper MM). Say this plainly in
"Under the hood": the per-market size limit grows as the pool deepens.

## Note for the earlier copy

The existing warning string "pool price is off — quote may be poor" should
stay scoped to the **basis** (mispricing) case only. The new depth warnings
are separate strings; a trade can trigger one, both, or neither.
