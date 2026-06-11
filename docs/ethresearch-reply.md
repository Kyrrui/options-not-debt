# Draft reply for ethresear.ch t/25036 — review before posting

> Status: DRAFT. Sepolia addresses are placeholders until the deployment
> lands. Post under Kyrrui's account after review. Tone: research
> contribution, not launch announcement.

---

I implemented the full design end-to-end as a public repo —
[options-not-debt](https://github.com/Kyrrui/options-not-debt) — Vyper 0.4.3
contracts, Foundry fuzz/invariant suites, and Halmos symbolic proofs over the
compiled bytecode. It covers the P/N primitive, a permissionless Chainlink
RWA registry (any asset with a USD feed; ETH is the only collateral), and the
"fully-automated onchain DAO — all rules, no voting, no AI" wrapper as a
soft-peg ERC-20. A few implementation notes and pitfalls that may be useful
to others building on this design.

**Implementation choices**

1. *Exact conservation.* Settlement computes `payout_p = min(1e18, S·1e18/x)`
   once, and N's payout is defined as the exact integer remainder — so
   P + N = 1 holds in integer arithmetic, not just in the limit. Machine-checked
   with symbolic execution (plus 128k-call stateful invariant fuzzing); the
   per-redemption rounding shortfall is provably < 2 wei.

2. *`merge` works after settlement.* Since P + N = 1 always, recombining legs
   into ETH never needs the oracle — an exit that survives total oracle
   failure, echoing @mmchougule's "settlement is an asset transfer" point.

3. *The wrapper never holds N.* `deposit()` splits the ETH, keeps P, and hands
   N straight back to the depositor — "rely on speculators and market makers
   to hold N" taken literally. Wrapper NAV prices P at intrinsic `min(x, S)`
   only: no volatility oracle, no Black–Scholes (per the OP's warning). Time
   value is priced instead by the market through the auction edges.

4. *Rolling per @Czar102's "predictable rolling."* Roll triggers at
   `x < 1.5·S` or 7 days before maturity; rotation is a one-sided gradual
   auction (deliver new-strike P, take old-strike P) whose rate improves
   linearly to a 2% cap over a day. If nobody fills, the old series settles
   via the slow oracle and the wrapper harvests to ETH — a stalled roll
   degrades to tracking drift, never to bad debt or a frozen system.

5. *Slow oracle, content-addressed.* Registry entries are keyed by
   `(feed, heartbeat)` pairs, so integrators opt into the exact staleness
   tolerance they trust. Settlement is one lazy pull at/after maturity; a
   quorum/dispute gate like @CertifiedCryp suggests would slot in at the
   registry boundary without touching the series.

**Pitfalls found by adversarial review** (worth checking in any implementation)

- *Genesis self-roll brick.* If `strike_ratio × roll_trigger ≥ 1`, a freshly
  created series already satisfies the roll rule, and the wrapper tries to
  roll it into an identical series in the same block (factory dedupe returns
  the same address) — permanently bricking a no-admin contract. Needs a
  constructor cross-parameter invariant.
- *Auction-anchor stickiness.* Anchoring the re-entry auction's price ramp at
  "buffer became nonzero" lets a 1-wei residue pin the ramp at max premium
  forever, leaking the full edge to searchers on every subsequent harvest.
  The anchor must reset per harvest.
- *Registry squatting.* Keying oracle configs by feed address alone lets the
  first registrant lock a bad heartbeat permanently; content-addressing
  removes the entire class.

**Verification status** (kept current in the repo README): five theorems
proven on the published bytecode — payout bounded, split/merge value-exact,
full collateralization at entry, ERC-20 conservation, mint authority. The
remaining three (redemption conservation, P-value ≤ S, payout monotonicity)
compose symbolic 256-bit division chains — the hardest SMT query class — and
are still grinding with no counterexample found; they're covered meanwhile by
the invariant suites.

**Sepolia deployment** (real Chainlink feeds, ETH/USD + XAU/USD):

- OracleHub: `<HUB>`
- SeriesFactory: `<FACTORY>`
- spUSD wrapper: `<SPUSD>`
- spXAU wrapper: `<SPXAU>`

**Open questions for the thread**

1. Wrapper share pricing at intrinsic value ignores theta entirely
   (@equivrel's point); the auction edge (±2%) is where time value gets
   priced. Is there a manipulation surface in the gap between intrinsic NAV
   and market P value large enough to matter for deposit/redeem fairness, or
   does pro-rata redemption neutralize it?
2. Is a linear ramp to a capped edge the right shape for the rotation
   auction, or is @Czar102's bp-per-minute premium-yield decay strictly
   better for minimizing the rolling cost the OP flags as the main
   competitiveness risk?
3. The N leg is the structural bottleneck (@JSeam2's liquidity concern): is
   there a standing-buyer design for N — perhaps @Xatarrer's saturation-zone
   LP construction — that doesn't reintroduce a real-time oracle dependency?

Research code, ten days from post to implementation, unaudited — treat
accordingly. Issues and PRs welcome.
