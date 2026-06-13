# Draft reply for ethresear.ch t/25036 — review before posting

> Status: READY FOR REVIEW (refreshed 2026-06-13, first person). A research
> contribution + a direct answer to @KG's oracle-spectrum question in #17.
> Post under Kyrrui's account. Tone: contribution, not promotion. Repo +
> contracts are the artifacts; the frontend is secondary.

---

I took the maturity-only construction in the OP and built it end-to-end as an
open-source, formally-verified, deployed system —
[options-not-debt](https://github.com/Kyrrui/options-not-debt) — to see what
the design teaches you once it has to run against real oracles and real
users. In the interest of full transparency: I built the entire thing — the
Vyper contracts, the test and formal-verification harness, and the frontend —
with Claude Fable (Anthropic's model) doing the implementation under my
direction. A few things from the process that may be useful to the thread,
plus a direct response to @KG's oracle question.

**What it is.** The P/N primitive exactly as described (split 1 ETH → P + N,
recombine any time, one lazy oracle read at maturity, `P + N = 1 ETH`
always). On top of it: a permissionless Chainlink registry so any asset with
a USD feed is trackable; a permissionless factory so anyone mints a soft-peg
wrapper in one transaction; and the "fully-automated, all-rules-no-voting"
wrapper DAO that holds only the P (tracking) leg and rolls it down-strike via
gradual auctions. Three pegs are live on Sepolia against real Chainlink feeds
(USD, gold, BTC); contracts are source-verified, addresses in the repo's
`docs/deployments.md`, and there's an interactive reference frontend if you
want to poke it.

**On the options-liquidity concern (@JSeam2 #14, @Xatarrer #15).** I think
this is real but aimed at the wrong layer. I do *not* try to run an options
order book. Following the OP's "rebalancing should be one-sided market
making, not an instant sell," rolling is a gradual auction: the wrapper posts
a standing offer to swap old-strike P for new-strike P at a rate that starts
oracle-fair and improves linearly to a bounded edge (2% over a day). The
crucial part is the fallback — if nobody fills, the old series simply settles
via the slow oracle and the wrapper harvests it to ETH. So a roll that finds
no liquidity degrades to *tracking drift*, never to a failed or liquidated
trade. Honest tradeoff, not hidden: the tracking is genuinely "soft" — exact
above the strike, drifting below it — which is the quadratic drift the OP
already accepts, restated as a concrete mechanism rather than a promise.

Relatedly, I think the liquidity bottleneck is better attacked as a *demand*
problem on the N leg than as an order-book problem. The N leg — the side the
OP assigns to "speculators and market makers" — is, concretely, **leverage on
ETH (or any tracked asset) with no liquidation and no funding rate**, capped-
loss by construction. Framed and surfaced as a product in its own right, that
is the natural counterparty the P side needs, and a sharper pitch than
"on-chain options," which (as @JSeam2 notes) has not historically pulled
liquidity.

**Implementation pitfalls anyone rebuilding this will hit.** Three that an
adversarial review caught and that are inherent to the design, not a coding
style:
1. *Genesis self-roll.* If the wrapper's roll trigger and its initial-strike
   ratio overlap, a freshly created series immediately qualifies for a roll
   and the wrapper tries to roll it into an identical series — bricking a
   no-admin contract at birth. Needs a constructor cross-parameter invariant.
2. *Re-entry-auction anchor.* Anchoring the buy-back auction's price ramp on
   "buffer became non-empty" lets a 1-wei residue pin the ramp at maximum
   premium forever, leaking the edge to searchers on every later harvest. The
   anchor must reset per harvest.
3. *Oracle-registry squatting.* Keying oracle configs by feed address alone
   lets a first registrant lock a bad staleness setting permanently;
   content-addressing by `(feed, heartbeat)` removes the whole class and
   makes registration idempotent.

**Formal verification (which invariants actually hold).** Eight properties
are machine-proven on the compiled bytecode with Halmos: full
collateralization at split, split→merge value-exactness, payout bounded by 1
ETH/unit, ERC-20 supply conservation, mint authority, and the peg-cap and
monotonicity properties below the strike. The three properties that compose
symbolic 256-bit floor-division (redemption conservation to <2 wei, the
peg-cap and monotonicity *above* the strike) are not closed by the SMT
solver in practical time; they're corroborated by independent reasoning and
by 128k-call stateful invariant suites, and flagged as such rather than
claimed. The takeaway for implementers: the no-bad-debt / conservation
direction is the part worth proving, and it largely is.

**@KG (#17) — your oracle-spectrum question.** This is the most interesting
open question in the thread, and being the maturity-only end of it, here's my
concrete datapoint. In this construction the oracle is consulted exactly
once, at/after maturity, to set a single scalar — and, critically, the
**redeem and merge paths are entirely oracle-free** (a holder can always
recombine P + N back to ETH, or redeem a settled leg, with zero oracle
involvement). So the most a wrong, stale, or manipulated oracle can do is
delay one settlement or mis-set one settlement value; it can never force-
close a position, strand collateral, or create bad debt.

I'd argue the axis that actually matters isn't "oracle or no oracle" — it's
**whether the oracle ever makes an irreversible, time-pressured decision.**
That gives a clean ordering of the same design family:
- *Maturity-only (this):* oracle makes one reversible-by-exit, non-time-
  critical scalar call. Smallest trust surface; tolerates slow/disputable
  oracles.
- *Path-dependent barrier (TRP):* oracle drives mid-life state transitions on
  a fully-collateralized pair. Larger surface — it reintroduces real-time
  response and adversarial-timing sensitivity — but, because the pair stays
  fully collateralized, it still never produces bad debt the way liquidation
  does.
- *Debt + liquidation:* oracle makes a real-time, adversarially-timed,
  *irreversible* solvency decision. Largest surface.

So my answer to your question: yes, your barrier is meaningfully different
from liquidation oracle-dependence (no bad debt, no undercollateralized
rescue), but it is also meaningfully *larger* than the maturity-only
surface — and the difference is precisely the path-dependence you flagged.
The richer payoff you get for it (perpetual experience, explicit protected
collar) is a real user-facing gain; the question is whether a given use case
needs the oracle to ever act under time pressure at all. For pure price-
stability I found it doesn't, which is why I kept it maturity-only and pushed
all timing decisions to users/wrappers. I'd be very interested in where TRP
draws that line and how the costless-collar reset stays non-extractive — the
"keep the primitive non-extractive" point in #18 is the right constraint.

Research code, ten-ish days old, built with Claude Fable, **unaudited** (one
structured multi-agent internal review; an external audit is the gate before
mainnet) and testnet-only. Issues, counterexamples, and PRs welcome —
especially anyone who can close the three remaining division proofs or break
the conservation invariant.
