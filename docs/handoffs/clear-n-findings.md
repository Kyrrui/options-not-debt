# What actually clears N — research findings

> 7-angle generation × adversarial prove/disprove panel (61 agents), then a
> quantitative burden simulation. Result: **27 candidates, 0 survive, 1
> conditional, 26 broken.** The conclusion is robust and, once quantified,
> actually points at a good solution — just not a clever primitive.

## The verdict: N-clearing is a DEMAND problem, not an engineering one

Every "make N disappear" mechanism broke on one of the same roots, and they all
reduce to a single accounting truth:

- **N is only born via `split()`, 1:1 with deposits, and is only truly cleared by
  a party that *wants* leveraged ETH.** No mechanism creates leverage demand that
  isn't there. The 26 broken candidates each either (a) **presupposed** leverage
  demand ≥ stable inflow (the negation of the stable-skew constraint), or (b)
  **relocated** the orphan to an unwilling holder (an LP, a treasury, a vault) plus
  an **unbounded subsidy** someone pays.
- Recurring kill reasons: stable-skew (C3) — the dominant killer; per-series
  vintage/roll (C4) breaks all merge- and order-based ideas; stale-oracle (C5) +
  the oracle-free merge floor (C2) drain every standing oracle-priced N bid or
  "self-funded from premium" pot (those clear at ≤ intrinsic, so the pot stays
  zero); and "the DAO absorbs N" is disqualified by design (C1).
- **N is not waste.** N + P = 1 ETH and N is *fairly priced* leverage (no funding,
  no liquidation, capped loss, fixed term). The orphan-N "problem" is flow
  imbalance + demand bootstrapping, not value destruction.

The one conditional survivor confirms this: a **JIT mint-on-match router**
(pair a stable depositor with a resting leverage buyer in one tx; the buyer takes
the freshly-minted N of the exact target series) is *provably* clean and
zero-subsidy — but only up to **real resting leverage-order depth.** It's a better
*matching venue*, not a demand source, and it needs a roll-safe target read
(revert if `sync()` flips the vintage mid-match) to survive C4.

## The burden, quantified (and why it's not hopeless)

Per $1 of stable acquired by minting, orphan-N value = **O₁ = (1−r)/r** where r =
strike ratio. Warehouse capital / stable-TVL (worst case) = **O₁ · (1−ρ)**, ρ =
fraction of orphan-N absorbed by real leverage demand.

| strike r | O₁ ($N per $stable) | ETH-drop buffer before roll | warehouse/TVL: ρ=0 / 0.5 / 1.0 |
|---|---|---|---|
| 0.50 | 1.00 | 25% | 1.00 / 0.50 / 0 |
| 0.60 | 0.67 | 10% | 0.67 / 0.33 / 0 |
| 0.63 (cap @ trigger 1.5) | 0.58 | 5% | 0.58 / 0.29 / 0 |
| 0.79 (cap @ trigger 1.2) | 0.27 | 5% | 0.27 / 0.13 / 0 |

(feasibility: genesis-brick guard requires `r · roll_trigger ≤ 0.95`.)

**Readings:**
- **No free lunch:** at r=0.5 with zero leverage demand, someone warehouses **1.0×
  the stable TVL** as N. Confirms every "clear it for free" idea is impossible.
- **Strike ratio** shrinks O₁ up to ~70% (1.00 → ~0.27) but trades away the
  ETH-drawdown buffer (25% → 5%) → hair-trigger rolls. Bounded lever.
- **Matching (ρ)** is the big dial: ρ→1 drives warehouse → 0. ρ *is* realized
  leverage demand.
- **The hopeful structural fact:** only **net-new TVL** mints N — churn (Alice
  sells stable to Bob) trades on the secondary pool with **no split**. So the real
  burden = O₁ · (1−ρ) · *(net TVL growth)*, not *(TVL volume)*. **The warehouse
  burden is growth-linked and self-attenuates as TVL matures.**

## The actual solution (a stack, not a primitive)

Combine the levers; each is proven/bounded above:

1. **Don't over-create N** — tune strike ratio (and roll trigger) to cut O₁ toward
   ~0.3–0.6, within the drawdown-buffer budget. ~40–70% off the burden.
2. **Match it at mint-time** — the JIT mint-on-match router (the survivor):
   creates *zero* orphan for matched flow, zero subsidy, no DAO-held N, roll-safe.
   This realizes ρ up to real demand.
3. **Route churn to secondary** — buy/sell stable on the pool; only net-new TVL
   mints. Burden becomes growth-linked and shrinks vs TVL over time.
4. **Warehouse the small residual with a *willing* holder** sized to the net
   imbalance — in priority: real leverage demand → a treasury making a *deliberate,
   capped* ETH-bull bet → an MM. **Never the DAO** (C1). With levers 1–3 this
   residual is a small, transient, growth-phase number, not 1× TVL.
5. **The durable fix is demand for N itself.** N is a competitive leverage product;
   demand is the *only* true sink **and it's a revenue line, not a cost.** Treat N
   as the product to sell, not a byproduct to dump.

## Bottom line

There is no primitive that clears N — proven 26 ways. The "good solution" the
intuition is reaching for is real, but it's a **system**: shrink N (params) +
match it (mint-on-match) + don't re-mint on churn (secondary-first) → the residual
is small and growth-linked → warehouse it with someone who *wants* the leverage,
and go bootstrap that leverage demand (which is the actual product). The only
genuinely irreducible piece is that **net-new stable growth requires net-new
leverage appetite or a willing warehouser for the gap** — and that gap is bounded
by your growth rate, not your size.
