# Formal Verification — Halmos symbolic proofs

> Machine-checked proofs of the core P/N settlement math, run by
> [Halmos](https://github.com/a16z/halmos) symbolic execution against the **actual
> compiled Vyper bytecode** (`out/*.json` via `vm.getCode`/`deployCode`), for **all**
> inputs within the stated bounds — not sampled inputs like fuzzing. Source:
> [`test/Halmos.t.sol`](../test/Halmos.t.sol). This doc is a snapshot; the README table
> and this file are updated as the remaining solver runs close.

> **Scope honesty.** "Formally verified" here means the ✅ theorems below are proven
> over the deployed bytecode within the stated input bounds — nothing more. It does
> **not** mean every behavior is proven. The proofs cover `OptionSeries`'
> split/merge/settle/redeem payout math and `OptionToken` conservation + access
> control. The `TrackerDAO` economic layer (deposit/redeem/roll/auction/harvest), the
> multi-feed `OracleHub` paths, and the periphery (routers, zapper, factory,
> `SignedQuoteFiller`) are **not** symbolically proven — they are covered by the
> stateful invariant suites (128k calls each), unit/fuzz + fork tests, and the
> internal audit ([`AUDIT.md`](AUDIT.md)). A paid external audit remains a prerequisite
> for mainnet / real funds.

## What is proven (✅)

Each is `∀ inputs in range` over the compiled bytecode.

| Theorem | Statement | Range |
|---|---|---|
| `check_payoutBounded` | after `settle()`, `payout_p ≤ 1e18` (P never owed > 1 ETH/unit) | price ∈ [1, 1e40] |
| `check_splitFullyCollateralized` | `split` mints equal P and N supplies, backed 1:1 by locked ETH | amount ∈ [1, 2⁹⁶) |
| `check_splitMergeExact` | `split` then `merge` is value-exact (returns exactly the ETH in; supplies → 0) | amount ∈ [1, 2⁹⁶) |
| `check_pValueAtOrBelowStrike` | for x ≤ strike: P pays in full (`payout_p == 1e18`) and `payout_p·x ≤ S·1e18` | price ∈ [1, 1e40] |
| `check_payoutMonotone_belowStrike` | x1 ≤ x2 ≤ strike ⟹ payout pinned at 1e18 | price ∈ [1, 1e40] |
| `check_payoutMonotone_acrossStrike` | x1 ≤ strike < x2 ⟹ `payout_p(x1) = 1e18 ≥ payout_p(x2)` | price ∈ [1, 1e40] |
| `check_erc20TransferPreservesSupply` | transfers conserve balances and total supply (no inflation, no burn-on-transfer) | mints ≤ 2¹²⁸ |
| `check_onlyMinterMints` | any caller ≠ the series cannot mint a leg (reverts) | ∀ caller, amount |

## What is still open (⏳ solver running, no counterexample found)

These are the remaining **256-bit symbolic division** facts. The solver has not closed
them in practice (the monolithic form ran >13h with yices and bitwuzla and returned no
result), so they were isolated into single-division lemmas that are still running. None
has produced a counterexample. Until they close, these claims rest on the proven lemmas
plus the invariant suites (128k randomized calls each, zero violations).

| Theorem | Statement | Range |
|---|---|---|
| `check_pValueAboveStrike` | for x > strike: `payout_p·x ≤ S·1e18` — the soft peg's hard upper bound (P never worth more than S asset units) | price ∈ [1, 1e40] |
| `check_payoutMonotone_aboveStrike` | x1 ≤ x2, both > strike ⟹ `payout_p` non-increasing in x (`floor(S·1e18/x)` anti-monotonicity) | price ∈ [1, 1e40] |
| `check_redeemConservation` | ∀ `payout_p ≤ 1e18`, ∀ amount: redeeming P then N returns ≤ the locked ETH, shortfall < 2 wei (**no bad debt**) | amount ∈ [1, 2⁹⁶) |

## The no-bad-debt theorem, as a lemma chain

The headline safety property — *redeeming both legs can never return more ETH than was
locked* (full collateralization survives settlement) — is proven as a chain rather than
one query, because the monolithic form composes a symbolic 256-bit division with two
further mul-divs, which SMT solvers don't close:

1. **`check_payoutBounded` (✅):** `settle()` can only ever write `payout_p ≤ 1e18`, for
   every oracle price.
2. **`check_redeemConservation` (⏳):** for *every* settled state with `payout_p ≤ 1e18`
   — i.e. exactly the states step 1 proves are reachable — redeeming P + N returns at
   most the locked ETH (shortfall < 2 wei, integer-division rounding).

Step 2 installs the settled state directly with `vm.store` (`settled = true`,
`payout_p = pp` for symbolic `pp ≤ 1e18`; storage slots from `vyper -f layout`). This is
sound precisely because step 1 proves those are the only states `settle()` can produce —
the decomposition proves the identical end-to-end property over the same bytecode. The
single-query equivalent, `check_conservation_deep`, is kept in the test file for reference
and is **not run in CI** (solver-intractable).

## Assumptions / trust base

- **Input bounds are explicit, not all of uint256.** Prices are bounded to [1, 1e40]
  (covers any realistic 1e18-scaled feed value with margin) and amounts to [1, 2⁹⁶) /
  mints to 2¹²⁸ — chosen to cover realistic ranges while keeping the division queries
  tractable. The proofs are universal *within* these bounds.
- **The oracle is modeled** by `MockV3Aggregator` (the real Chainlink `latestRoundData`
  interface). The proofs are over the contract's arithmetic *given* an oracle answer; they
  do not prove anything about Chainlink's own behavior or liveness.
- **Strike-parametric.** Proven against a single series at `STRIKE = 1250e18`, USD asset.
  The settlement arithmetic does not depend on the specific strike beyond the stated
  bounds; the bytecode under test is the shipped artifact.
- **Real bytecode.** Halmos executes the compiled Vyper (`out/OptionSeries.vy/...`,
  `out/OptionToken.vy/...`), so the proofs bind the deployed artifact, not a Solidity
  re-model.

## Reproduce

```bash
# halmos needs AST-bearing artifacts; run from a clean state. pip install halmos
forge clean && halmos --contract HalmosVerification --solver bitwuzla --solver-timeout-assertion 0

# a single theorem:
forge clean && halmos --contract HalmosVerification --function check_payoutBounded \
  --solver bitwuzla --solver-timeout-assertion 0
```

## Pointers
- Proofs: [`test/Halmos.t.sol`](../test/Halmos.t.sol)
- Internal multi-agent security audit: [`AUDIT.md`](AUDIT.md)
- Test strategy overview + the live status table: repo `README.md`
- Economic-layer coverage (not symbolic): the invariant suites in `test/Invariants.t.sol`
