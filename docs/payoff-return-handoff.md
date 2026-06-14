# Payoff chart: show return in USD, not ETH (fix the "2× looks <1×" bug)

> For the dapp builder. The payoff tooltip computes the position's **return in
> ETH** while showing ETH's **move in USD** — two numéraires side by side. The
> result: a genuine ~2× long reads as sub-1× (e.g. "ETH +11.3% → return +8%"),
> which makes the flagship product look broken. The position is correct; the
> readout's units are wrong. Make the whole payoff chart USD-native.

## Root cause (in `apps/web/src/components/trade/PayoffDiagram.tsx`)

`onMove` computes:
- `movePct = (index − x)/x` → ETH's **USD price** move. ✓ (USD)
- `returnPct = (payoff − premiumE18)/premiumE18` → return measured **in ETH**
  (`payoff` and `premiumE18` are both ETH-per-unit). ✗ (ETH)

Comparing a USD move to an ETH return hides the leverage: part of a long's
win is "each ETH is now worth more USD," which an ETH-denominated payoff
discards. Worked example (now $1669, strike $836, hover $1858): ETH-return
= +8%, but USD-return = `(1858−836)/(0.510·1669) − 1` ≈ **+20%** on a +11.3%
move ≈ **1.8×** — the leverage was always there.

## The fix — make the chart USD-native (3 coherent changes)

All asset-unit math; for spUSD the asset unit IS USD. `x` = current index
(asset units per ETH, 1e18). Use bigints; floats are fine here (display only,
never a tx value).

**1. Return % → USD.** In `onMove`, replace the ETH return with:
```
// USD cost basis per unit = ETH premium valued at the entry price.
// Use `x` (now) as the entry-price proxy unless you track the true entry
// index from the LeverageOpened log (then use that — more accurate).
const costUsd = (premiumE18 * x) / 10n**18n;          // asset units / unit
const valueUsd = (payoff * index) / 10n**18n;          // asset units / unit
const returnPct =
  premiumE18 !== null && premiumE18 > 0n && x !== null && x > 0n && costUsd > 0n
    ? Number((valueUsd * 10_000n) / costUsd - 10_000n) / 100
    : null;
```
(Preserve the existing `premiumE18 <= 0` guard — when the pool over-pays at
entry the cost basis is ≤0 and a % return is undefined; keep showing the
plain-words case, not a garbage number.)

**2. Breakeven line → USD breakeven**, so "return = 0" lands exactly on the
line. The current `breakevenIndexAtMaturity(strike, premiumE18)` solves the
*ETH* breakeven (`payoffEth = premiumEth`); the USD breakeven is simply:
```
// value_usd(X) = X − S (above strike); set = costUsd:
const breakevenUsd = strike + (premiumE18 * x) / 10n**18n;   // = strike + costUsd
```
Use that for the cyan line (and the faint "before" ghost) instead of the ETH
breakeven. (Cleanest: add a `breakevenIndexUsd(strike, premiumE18, x)` to
@gimbal/protocol so the formula isn't inlined — §5 preamble.)

**3. The breakeven note** ("At today's price, ETH needs to rise ~2% (to
~$1706)…") must read from the **USD** breakeven too (~$1687 / ~+1% in the
example), or it'll disagree with the line and the tooltip.

## While you're in there

- **Tooltip "worth" line:** keep the ETH figure but add USD —
  `worth $1,022 (0.55 ETH)` — so it matches the USD return. (USD = `valueUsd ×
  position size`; the asset unit is ~$1 for spUSD.)
- **Show the multiple** next to the return: `≈1.8× the move` (=
  returnPct/movePct) — it makes the "2×" in the title legible and honest
  (slightly under 2× because of the entry premium/time value + pool-impact
  tax).
- **Sweep for other ETH-denominated framings on the card.** The "YOUR LONG:
  1.53 · ~0.763405 ETH now" line is fine as an ETH worth, but consider adding
  its USD value for consistency. "MAX LOSS: your premium" is fine. The key is
  that nowhere should an ETH-numéraire return sit next to a USD price move.

## Why this matters / priority

High. This is the single most important number on the leverage product, and
right now it tells a trader "I took 2× and underperformed spot" — the exact
opposite of the pitch. It's a display-units bug, not a protocol issue; the
position behaves correctly. (Note the realized multiple is a hair under 2×
because of the entry premium and the thin-pool impact — see
`liquidity-impact-handoff.md`; that part is real and worth surfacing too, but
it's separate from this units fix.)
