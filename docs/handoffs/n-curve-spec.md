# Bonding-curve / primary-market for N — spec + honest appraisal

> Exploration doc, not a build order. Question: can we solve the "needs seeded
> liquidity" problem with a bonding curve that mints locked P/N and releases
> them through a curve, instead of a pre-seeded Uniswap pool?
>
> Short answer: the *classic* bonding curve doesn't work here — the split/merge
> invariant pins N's price, so it can't free-float. The instinct points at two
> real ideas — **demand-matching** (let stable buyers and leverage buyers be
> each other's counterparty) and **graduate-to-pool** (let demand bootstrap the
> pool from zero) — and a clean realization (**batch clearing + route the P leg
> into the DAO's existing `sell_p`**). This doc specs that and is blunt about
> where it beats today's design and where it's worse. Verdict up front: **only
> worth it if cold-start-from-literally-zero is a hard requirement** — otherwise
> seeding the existing pool with the same capital strictly dominates.

## 0. The constraint that kills the naive version

From the primitive (`OptionSeries`):
- `split`: 1 ETH → 1 P + 1 N (1:1 per wei), anytime before maturity.
- `merge`: 1 P + 1 N → 1 ETH, **anytime, oracle-free**, even post-settlement (`OptionSeries.vy:167`, no maturity/oracle guard).
- intrinsic, ETH per unit: `P = min(1, STRIKE/x)`, `N = max(0, 1 − STRIKE/x)`, `P + N = 1` exactly (settle fixes `payout_p + payout_n == 1e18`).

Because anyone can split *or* merge at will, **`price(P) + price(N)` is arbitraged to ≈ 1 ETH at all times**. This is the load-bearing fact:
- N **cannot** be priced on a free supply-based curve (no pump.fun "price rises with hype"); it's pinned to `≈ N_intrinsic`.
- **Merge-arb floor invariant (must be enforced on-chain):** any venue quoting *both* legs must charge `price(stable's P) + price(leverage's N) ≥ 1 ETH` per matched unit *at all times*. If the two quotes ever sum to < 1 ETH (a discount ramp on one side, or oracle drift moving `N_intrinsic` between the two quotes), an arber buys both legs and `merge()`s for a risk-free 1 ETH, draining the reserve. The spread floor must be tied to *this*, not to an abstract `MAX_EDGE`.

So a "bonding curve" for N is really an **oracle-referenced reserve market** — a sibling of the DAO's `sell_p` (ETH/`eth_buffer`-backed oracle auction). Note `fill_roll` is *not* the precedent: it's a P-for-P inventory swap, no ETH. Only `sell_p` fronts ETH.

## 1. What's actually worth building

The DAO already mints/redeems the stable leg at **NAV (NAV-proportional; the peg is *soft*, target `1e18`, not a fixed 1:1)**, and `redeem` is already **instant + oracle-free** (`TrackerDAO.redeem`, pro-rata `p_bal` + `eth_buffer`, no oracle call). So the pool was never needed for stable-side *safety* — only for *clean-ETH-out convenience* (avoid receiving the pro-rata P slice). The real gaps are: (a) a stable buyer's `deposit` hands them an unwanted **N**; (b) a leverage buyer is stuck with an unwanted **P**. These are **mirror images** — pair them instead of pooling them.

### Mechanism: `PrimaryMarket` — batch-clearing demand-matching, DAO as P-sink, imbalance reserve, graduate

Per (tracker). Two user entrypoints that **escrow ETH** into a recurring batch:

```
buy_stable(min_shares) payable        # ETH -> pure spUSD shares, no N
buy_leverage(min_n) payable           # ETH -> pure N, no P
clear()                               # permissionless; one oracle read; clears the batch
graduate()                            # permissionless (guarded); seeds the pool past threshold
```

1. **Batch, don't per-trade.** Orders accumulate; a permissionless `clear()` reads
   the oracle **once** and clears the whole batch at one price. This collapses the
   per-trade oracle/MEV surface (the spec's own biggest objection, §3) into
   per-batch — same shape as the DAO's once-per-call auctions.
2. **Match by novation — matched flow is self-funding.** Each `buy_stable` ETH
   `split`s into 1 P + 1 N; each `buy_leverage` ETH does too. The stable buyer
   keeps shares (P-backed) and sheds N; the leverage buyer keeps N and sheds P.
   They hand each other their orphan leg. Because `P_intrinsic + N_intrinsic = 1`,
   **the two buyers' own payments fund the entire matched notional — the reserve
   fronts ZERO principal for matched volume** (pure novation, no inventory, no IL).
3. **Route the residual P into the DAO's `sell_p`, not a pool.** The unmatched
   leverage side has leftover P. The DAO *already* has an oracle-priced,
   `eth_buffer`-backed P-buyer (`sell_p`) whose entire purpose is to attract P
   sellers — the leverage buyer is exactly that counterparty. So when the buffer
   can absorb it, leverage needs **no pool and no new reserve**. The reserve is
   *overflow only* (buffer dry).
4. **Reserve absorbs the rest, oracle-free-drainable.** Leftover N the reserve
   holds is **extinguishable any time via `merge`** the instant any P arrives
   (later flow or `sell_p` inventory) — so directional inventory mean-reverts with
   two-sided flow; the hard cap (§4) is a tail backstop, not the main control.
5. **Graduate to pool from protocol-owned liquidity.** Once accumulated, `graduate()`
   seeds the spToken/WETH Uniswap pool at a **demand-discovered** price and hands
   off — turning the cold-start "operator fronts IL-bearing capital at a guessed
   price" into "pool seeded later, at a known price, from protocol-owned funds."

This subsumes the LeverageRouter (it's `buy_leverage` with `sell_p`/reserve as the
P-sink) and supplies the clean pure-`buy_stable` exit, with `redeem` as the floor.

## 2. Why it's a GOOD idea (vs today: DAO + eventually-seeded pool)

- **Cold-start from literally zero — the one real edge.** `PeripheryFactory.deploy_periphery`
  *requires the pool to already exist* (`PeripheryFactory.vy:157`), and seeding it
  today means an operator fronting paired WETH at a *guessed* NAV price, eating IL
  + a forced long-N position (`LPZapper.vy:23-28`). That under-compensated LP role
  is the root of the seeding problem. Matching needs **no pool at all** to start,
  and `graduate()` seeds it later at a discovered price from protocol-owned
  liquidity. The operator's job shrinks from "front IL-bearing capital before any
  users exist" to "nothing."
- **Matched flow consumes no reserve principal.** Pure novation: each side funds
  its own `split`, they swap orphan legs. A Uniswap LP must pre-commit WETH for the
  *entire* depth whether or not an offsetting trade ever arrives.
- **Eliminates a money-losing role, not just its fee.** The spread that would
  underpay external LPs (who eat IL + forced long-N) instead accrues to the DAO,
  with **zero IL** on matched novation. It removes the recruitment problem and
  feeds backing in one move.
- **Leverage becomes poolless via `sell_p`.** Leverage demand is the exact
  counterparty the DAO's re-entry auction was built for; the harvest cycle that
  fills `eth_buffer` already supplies the ETH leverage buyers pull.
- **Stable round-trip already poolless:** `deposit`/`buy_stable` in, `redeem`
  (instant, oracle-free) or matched-sell out.

## 3. Why it's a BAD idea (vs today)

- **"Capital scales with imbalance" is mostly false for THIS product.** On-chain,
  a same-block coincidence of opposite buyers is rare, so ~all fills hit the
  reserve, not a counterparty; required capital is the **time-integral of one-sided
  flow between clears**. And peg demand is structurally **stable-skewed** (the
  product *is* a soft peg; the DAO hands N *away* as a deposit byproduct — leverage
  is the niche side). So the imbalance ≈ the volume. "Nearly free under balanced
  flow" describes a regime this product is designed never to be in.
- **The lopsided-demand trap (the big one), worse than it sounds.** The reserve
  doesn't hold neutral inventory — it accumulates the protocol's *deliberately
  leveraged* leg (fresh strike set at `x·STRIKE_RATIO`, `STRIKE_RATIO < 1` e.g.
  0.5, so N has beta ≫ 1 on ETH). Worse, the loss is **pro-cyclical into the DAO's
  own roll**: when ETH falls toward STRIKE, `sync()` forces a roll (`_needs_roll`),
  and the reserve is holding the *old* series' N as it decays to floor — short
  gamma into the precise event the protocol is engineered around. A balanced
  Uniswap LP has no such forced-rotation interaction. Any cap must be denominated
  in **NAV-at-risk under an adverse move to STRIKE**, not raw N units.
- **Breaks the periphery's core invariant.** Every periphery contract today is
  *stateless, holds no funds, no admin* — that's what makes them trustless. The
  reserve is **stateful and custodial** — a directional honeypot. New high-severity
  surface (we just caught a HIGH in the much simpler PeripheryFactory).
- **Stale-oracle extraction on the hot path.** OracleHub accepts answers up to a
  `heartbeat` of **7 days** (`MAX_HEARTBEAT`). Today only `settle`/auctions touch
  the oracle; the pool trades oracle-free. Pricing buys off a possibly-days-stale x
  **while `merge` settles oracle-free** is the textbook stale-oracle arb: buy the
  cheap leg at stale x, `merge`/redeem at true value, drain the reserve. Batch
  clearing + a tight freshness/deviation guard + per-batch outflow bound are
  *mandatory*, not optional.
- **`graduate()` is a one-shot, manipulable, hard-to-reverse event.** Its seed
  price is NAV-derived (oracle-dependent) at pool birth — the worst moment; a
  manipulated x hands the first swapper free arb against pooled backing.
  Threshold-gaming can force premature graduation into a thin pool; and it must
  reproduce *all* of PeripheryFactory/LPZapper's fee/tick hardening or reintroduce
  the brick bug. Needs TWAP/freshness guard, anti-front-run on the threshold, and
  the pool-read tick pattern.
- **The decisive comparison: same capital into the pool strictly dominates** on
  every axis but cold-start. Pure-stable already = `deposit()`; pure-leverage
  already = `open_leverage()` — both audited and stateless. Seeding the pool buys
  **neutral, two-sided, oracle-free** depth with **zero new contracts**; the
  proposal buys **directional, oracle-priced, custodial** depth with ~3 new
  high-severity surfaces (reserve, hot-path oracle, graduation).

## 4. Recommendation

1. **Drop the literal bonding curve.** split/merge pins N to intrinsic — it's an
   oracle-priced reserve market, not price discovery. Don't sell it as the latter.
2. **Gate the whole idea on one question:** is cold-start-*from-zero* a hard
   requirement that a small operator/LP seed (or just letting `add_liquidity`
   bootstrap) genuinely can't meet? If **no** → seed the existing pool; you already
   have the audited, stateless path end-to-end. If **yes** → build only the minimal
   matching layer, in this order of safety:
   - **Batch-clearing matcher** (escrow orders, one oracle read per `clear()`, net
     the two queues) — removes hot-path oracle/MEV.
   - **`sell_p` as the primary P-sink** — leverage poolless, reserve only on
     overflow; reuses reviewed core machinery.
   - **Reserve as overflow only**, with the merge-arb floor invariant enforced
     on-chain, a NAV-at-risk cap on directional N, oracle freshness + per-batch
     outflow bounds, and `merge` as the oracle-free drain.
   - **`graduate()`** with TWAP/freshness seed-price guard, anti-front-run
     threshold, and the PeripheryFactory tick/fee pattern.
3. **Keep the DAO as the NAV anchor + `redeem` backstop unchanged** — the matcher
   sits *in front* for clean instant fills; the DAO stays the guaranteed exit.

Net: the bonding-curve framing is wrong (the invariant pins it), and for a
stable-skewed peg the reserve is a directional, pro-cyclical liability that a
balanced pool isn't. The instinct's genuine prize is **cold-start**: matching +
`graduate()` removes the operator-fronted, IL-bearing, guess-the-price pool seed.
If that cold-start pain is real, build the batch matcher + `sell_p` sink. If you
can find even a modest seeder, the existing pool wins on simplicity and safety.
