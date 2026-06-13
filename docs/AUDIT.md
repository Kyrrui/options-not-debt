# Internal Security Audit — 2026-06-12

> **Scope honesty:** this is a structured *internal* audit performed by a
> multi-agent adversarial review (independent reviewers, each finding
> verified by a separate skeptic that tries to refute it). It is not a
> substitute for a paid external audit, which remains a prerequisite for
> mainnet / real funds. Its purpose is to find and kill everything findable
> now and arrive at that external audit with a clean, well-understood
> codebase.

## Method

- **11 reviewer lenses** swept all six contracts in parallel: reentrancy &
  call-ordering, arithmetic & precision, access control, oracle integrity,
  economic/MEV/game-theory, Vyper-0.4.3 semantics, ERC-20 conformance &
  interop, DoS/griefing/liveness, lifecycle & state-machine integrity,
  factory & deployment integrity, spec-fidelity & conservation — plus a
  holistic TrackerDAO deep-dive.
- **Every finding was adversarially verified** by an independent agent
  instructed to refute it by tracing the exact call path and arithmetic and
  checking whether existing asserts / the nonreentrant lock / factory
  injection / the test & invariant suites already prevent it. Speculative
  and design-intent-restating findings default to *not real*.
- A **completeness critic** then enumerated all 58 functions and every
  revert string to find what the 11 lenses missed.
- 64 agents, 51 raw findings → **2 confirmed, 49 refuted**; baseline 79/79
  tests passing (81/81 after fixes).

## Confirmed findings & resolutions

| # | Severity | Contract | Issue | Status |
|---|---|---|---|---|
| 1 | LOW (defense-in-depth) | TrackerFactory | `__init__` did not verify the injected `series_factory` shares the factory's `HUB`. A *misconfigured* factory deployment (two different OracleHubs) would mint trackers that pass `create_tracker` but brick on first deposit. Not exploitable against the correctly-wired live deployment. | **Fixed** — added `assert ISeriesFactory(series_factory).HUB() == hub` at construction. |
| 2 | LOW | TrackerDAO | `deposit()` only ran the `_needs_roll` guard when no roll was open; during a *stalled* roll, deposits could split into a pending series that had itself deteriorated past its own roll trigger (sync cannot start a nested roll to fix it). Conservation held throughout (no fund loss), but capital entered a known-bad series. | **Fixed** — the guard is now unconditional; the `strike_ratio·roll_trigger ≤ 0.95` invariant guarantees a freshly created pending series never trips it, so only genuinely deteriorated deposits are blocked. |

Both fixes ship with regression tests (`test_factory_revertsHubMismatch`,
`test_deposit_blockedWhenStalledPendingNeedsRoll`). Neither touches the
Halmos-proven OptionSeries/OptionToken settle-math.

## Notable issues considered and refuted (with reasoning)

The adversarial gate cleared 49 candidates. Representative dismissals:

- **Settlement price sniping** — `settle()` is permissionless and one-shot at
  an attacker-chosen post-maturity moment. Dismissed: the payoff is fully
  collateralized and zero-sum, P's *asset-denominated* value is invariant to
  the index above the strike, and `merge()` is an oracle-free exit available
  any time; a rational holder is not harmed. Intentional slow-oracle design.
- **Donation / first-depositor share inflation** — neutralized by
  tracked-balance NAV accounting (donations aren't counted) plus the
  `DEAD_SHARES` mint on first deposit.
- **Reentrancy** (all paths) — Vyper 0.4.3's contract-global nonreentrant
  lock covers every mutating entrypoint; CEI is honored before every ETH
  send; OptionToken transfers have no hooks. Confirmed by
  `test_reentrancy_redeemToDeposit_blocked`.
- **Oracle price overflow on a hostile feed** — extreme answers revert
  (safe-fail, DoS-only) and a hostile feed registration is content-addressed
  and opt-in, isolating it to its own asset id; blocks nobody.
- **Regressions #1–#3** (genesis self-roll brick, sell_p ramp re-anchor,
  registry squatting) — independently re-verified as still fixed.

## Independent corroboration of the unproven settle-math

The three properties the SMT solver could not close in practical time
(redemption conservation, P-value ≤ strike above strike, payout monotonicity
above strike) were **hand-analyzed by multiple independent reviewers, who
concluded they hold** (conservation with < 2 wei shortfall; no bad debt).
This is corroboration by reasoning, not a machine proof — the README
verification table reflects the distinction.

## Open item (not a code defect)

NAV prices unsettled P at intrinsic value `min(x, S)`, deliberately ignoring
time value (theta). Whether the gap between intrinsic NAV and market P value
creates a deposit/redeem fairness surface is an **economic** question, not a
contract bug — flagged in the design notes as open, and a natural item for
the economic review accompanying the external audit. The ±MAX_EDGE auction
band is where the market prices time value instead.
