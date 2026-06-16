# Features to pull from Split — prioritized build roadmap

> Derived from the deep-research pass on **split.markets** (Base/Arbitrum, live). This is
> the **roadmap** — the build order and the rationale — not the specs. Each feature gets
> its own design → red-team → build → fork-test → deploy pass (like the N and stable desks)
> when you call it. The two you flagged as most interesting — **spUSD-collateralized shorts**
> and the **crowdsourced market maker** — are P1 and P3; the ordering is dependency-driven,
> and P1/P2 are independent so the order between them is a value-vs-effort choice (noted below).

> **Provenance / honesty caveat.** Split's mechanism was reverse-engineered from their **live
> frontend JS bundle** (which hard-codes the ABIs, addresses, RFQ API, and copy), *not* from
> Basescan-verified bytecode — and Split self-labels **"Beta — unaudited"** with no third-party
> coverage. So we are pulling the **ideas**, each validated against *our own* primitive and put
> through our own review pipeline — we are **not** copying their unaudited contracts.

## What Split has that we don't (one-paragraph recap)

- **Multi-leverage = a MENU of strike series.** Leverage is set by the **premium**, not margin:
  their UI computes `leverage = spot / premiumPerN`, tiers hard-coded `[2,5,10,20]`. Cheaper
  premium-per-N (further-OTM strike) = higher leverage. Every N fully collateral-backed, max
  loss = premium, no liquidation.
- **Shorts = a PUT series collateralized in a STABLE (USDC), not ETH** — because a short pays
  out *as ETH falls*, so ETH collateral (which also falls) can't back it. Stable collateral is
  the unlock.
- **"Earn" = an option-WRITING vault.** LPs fund the desk, it writes the N that leverage-buyers
  purchase, LPs collect premium up front; short-vol, can lose principal, never liquidated.
  = a **crowdsourced market maker.**
- Same **RFQ + signed-quote + expiry-settlement** skeleton we already built (`SignedQuoteFiller`).

We independently built the same core (P/N split + signed-quote RFQ desks). The gap is these
three product moves, all of which are reachable *within* our "options not debt" frame.

---

## P1 — Stable-collateralized SHORT series (debt-free leveraged shorts) ⭐ *your top interest*

- **What:** a new put/short `OptionSeries` variant whose collateral leg is a **stable** (spUSD
  or USDC). Its leveraged leg pays out as ETH **falls**; max loss = premium; no liquidation. Plus
  a short RFQ desk (a third sibling to `SignedQuoteFiller` / `StableQuoteFiller`).
- **Why the insight matters:** a leveraged short **cannot** be ETH-collateralized — the collateral
  falls with the thing you're short. **Stable collateral is the structural unlock.** And our native
  **spUSD is a natural collateral** — using it makes shorts *compose our own product* (spUSD becomes
  the thing that backs shorts) instead of importing external USDC. That's the elegant, in-house path
  you flagged; the trade-off (spUSD vs USDC) is the first design decision to settle.
- **Have vs need:** HAVE — the split/merge/redeem machinery, the desk pattern (built twice), the
  signed-quote skeleton. NEED — the mirror settle/payoff math, the stable-collateral accounting,
  the spUSD-vs-USDC decision, and a short desk.
- **Depends on:** nothing (standalone). It's the cleanest big win.
- **Effort & risk:** new core contract ⇒ full pipeline. Medium-high. The careful part is the mirror
  settle math + collateral model — we'd **re-prove the conservation invariant** (the Halmos `P+N`
  property) for the mirror before shipping.
- **Why P1:** biggest capability gap (we're long-only beyond a 1× stable hold), highest interest,
  self-contained, and it *doubles* the product (long **and** short).

## P2 — Leverage tiers via a strike menu (3×/5×/10×/20×)

- **What:** a "leverage market" layer that mints **CALL** series (and, once P1 lands, **PUT** series)
  at **multiple strikes** per asset, exposing the `[2,5,10,20]`-style menu — leverage = `spot/premium`
  per strike. Plus desks per series (or one multi-series desk) and a registry to list them.
- **Why:** matches Split's headline UX ("pick your leverage"). Higher strike = higher-leverage long.
- **Have vs need:** HAVE — `OptionSeries`/`SeriesFactory` already mint **any** strike; we only ever
  wired the single 0.5-strike (2×) series because that's what the soft-peg DAO needs. NEED — a
  strike-menu factory/registry, desks per strike, discovery + UI.
- **Depends on:** reuses the existing call primitive; the same mechanism extends to P1's put series
  for short tiers. So it's lower **new-contract** risk than P1, but more **wiring** (many series +
  desks + discovery).
- **Effort & risk:** moderate — mostly orchestration + a registry, not new core math.
- **P1-vs-P2 ordering note:** these two are **independent**. P1 (shorts) is the bigger differentiator
  and your stated priority; P2 (strike-menu longs) is the **lower-effort, lower-risk quick win** that
  reuses what we have. Lead with whichever you value more — but **both must precede P3**.

## P3 — Crowdsourced market maker (option-writing "Earn" vault) ⭐ *your other interest*

- **What:** an LP vault where depositors **fund the desk's writing** — the vault holds collateral
  (ETH for calls, stable for puts), the desk writes the N that buyers purchase, LPs collect the
  premium up front. Epoch'd (Split uses 7-day deposit→trade→settle), NAV/share accounting, a fee
  (~0.5%), and withdrawal locks while trades are open.
- **Why it's the big strategic unlock:** it **solves the MM-capital bootstrap** we've circled the
  whole project — the "where does the 5 ETH come from / how do you recruit an MM" problem. **LPs fund
  depth instead of the operator.** And it pools the **writer (premium-collecting) side** — which our
  *own* MM-vault red-team identified as the **sound** side to pool (we killed pooling the *buyer /
  long-N* side; this is the opposite, correct side).
- **Have vs need:** HAVE — the writer-side reframe already worked out (`mm-vault-spec.md`), and the
  desks as writing venues. NEED — the vault contract (epochs, shares/NAV, withdrawal locks, and the
  **depositor-protection guardrails** the red-team flagged: deposit/withdraw NAV arb, JIT, mark
  fairness), plus instruments to write against.
- **Depends on:** P1 + P2 (it writes the call/put series across the menu) **and** on phase 1 being
  **live with real demand** — you don't crowdsource depth for a market with no flow.
- **Effort & risk:** HIGHEST. It **re-opens the crowd-vault risk surface** our red-team studied —
  now on the correct (writer) side, but still short-vol (LPs bear the tail: "you can lose if traders
  win big"), still a public pooled product (optics/disclosure), and it needs a fresh red-team of the
  epoch/NAV/withdrawal mechanics. Split ships it explicitly as "Beta — unaudited, you can lose
  principal"; we'd want the guardrails + honest framing before retail touches it.
- **Why P3:** depends on everything else, carries the most risk, and should follow **proven demand**.
  It's the scale-up that funds depth, not the bootstrap.

---

## Explicitly NOT pulling (and why)

- **Physical/expiry settlement** (Split's model): we use **oracle** (slow, one-shot) settlement —
  core to the t/25036 thesis and already **Halmos-proven**. Not worth a settlement-model rewrite.
- **Margin / partial collateralization:** the thing the whole "options not debt" design *avoids*;
  it's why we have no liquidation. Keep avoiding it.
- **Multi-chain (Base/Arbitrum):** a go-to-market/deployment choice, not a protocol feature.

## Sequencing context (the prerequisites that gate the above)

- **Phase 1 first.** The existing spUSD **N desk** + **stable desk** are built & deployed but
  unfunded/not-live. Get them live (builder's app + quoter, your funding) and look for any flow
  **before P3** — crowdsourcing MM capital into a market with no demand is backwards.
- **RWA pegs (gold/BTC)** still need the **F6 two-feed oracle fix** before *any* series or desk —
  orthogonal to this roadmap (everything here is spUSD/USD-collateralized).
- Each feature is a separate **design → red-team → build → fork-test → deploy** pass when you call
  it. This doc is the **order**, not the spec. Source research: the deep-research pass on
  split.markets (see provenance caveat above).
