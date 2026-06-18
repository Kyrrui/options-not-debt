# Gimbal — Unified Desk (deep shared liquidity + high leverage + guardian) (spec)

> Build spec for **"one big desk"**: a shared pool of LP capital that backs leveraged **longs and shorts
> across high leverage tiers**, instead of today's many small single-purpose vaults. The win Kyle wants is
> **pooled depth** (a big trade draws on all the LP money) **+ high leverage**. Kyle knowingly accepts the
> price: a **narrow emergency-brake guardian** (not a rug key) and an **external audit before real money**.
>
> Produced via design→red-team→synthesize, re-reading all six shipped contracts. **This is "Option A made
> safe + guarded, per collateral"** — the unified vault the master [`autonomous-vault-spec.md`](autonomous-vault-spec.md)
> sketched, with the brittle parts fixed and a mainnet guardian bolted on. It is the eventual end-state of
> [`leverage-menu-ownerless-spec.md`](leverage-menu-ownerless-spec.md) (which ships the safe separate-vault
> menu in the meantime).
>
> **Plain summary:** build the desk's machinery now on testnet **with kill switches on** (not frozen) so we
> can exercise it; high leverage (5×+) waits on a tighter price-feed (the "hardened settle" blueprint); and
> it does **not** touch real money until an outside audit + a legal opinion. On today's feed the honest
> ceiling is **~3×**.

```
ARCHITECTURE   ONE bytecode, TWO instances: CWV (ETH → long N tiers) + PWV (USDC → short M tiers), one UI
WHY NOT 1 POT  the depth win is CROSS-TIER, not cross-collateral; pooling ETH+USDC buys no depth, wrecks NAV
DEPTH          one pool cap on aggregate AT-RISK across all tiers (kills the per-vault MAX_WRITTEN silos)
RISK PRICE     re-commingled: one bad tier hits the whole pool — metered by loss-budget caps, not isolated
GUARDIAN       separate timelock+multisig; 2 flags (pause-writes, force-exit); NO withdraw, NO rewrite; renounceable
HIGH LEVERAGE  needs the hardened settle blueprint (orthogonal to the guardian); ~3× now, 5×/10× post-harden, 40× never
STATUS         mechanics safe to operate PAUSABLE on testnet now; freeze gated on audit + legal + the critical fixes
```

---

## 1. Architecture: one bytecode, two instances (not one pot for both collaterals)

**Decision: `GimbalWriterVault.vy` deployed twice** — `CWV` (WETH collateral → writes the long **N**/call
tiers) and `PWV` (USDC collateral → writes the short **M**/put tiers) — parameterized by `COLLATERAL_KIND`,
presented behind **one product surface, one keeper**. **Not** one contract holding both collaterals.

**Why (confirmed against the bytecode):**
- The `split()` signatures are physically irreconcilable in one instance. `OptionSeries.split()` is
  `@payable` native ETH (`vy:153`); `PutOptionSeries.split(amount)` does a `transferFrom` of `_to_stable`,
  USDC 6-dec, **round down** (`vy:161-173`). One vault would need a two-unit NAV (wei **and** 18-dec-stable),
  a payable callback that must exist on the N path and must **not** exist on the M path (`PutOptionSeries`
  forbids it, `vy:30-32`), and a redeem paying a pro-rata ETH+USDC+P+L mix — re-creating the blast-radius
  problem and making the solvency proof a two-asset solver-intractable mess.
- **The depth win Kyle wants is cross-TIER, not cross-collateral.** It lands fully inside each instance: one
  ETH pot backs all long tiers (2×…N×), one USDC pot backs all short tiers. That defeats the separate-vault
  menu's frozen-per-vault `MAX_WRITTEN` fragmentation **without** paying the commingling tax. Pooling the two
  collaterals buys **zero** extra depth and costs the whole NAV proof — so it's rejected.

"One desk" therefore honestly = **one UI + one keeper + two segregated balance sheets** (the proofs are
*structurally shared*, not identical — the PWV 6-dec round-down marking is a real extra obligation).

## 2. The safe shared pot (fixing what made the naive version DOA)

- **Depth aggregation (the win, located precisely):** replace each vault's scalar `MAX_WRITTEN`
  (`GimbalSimpleVault.vy:114`) with **one pool-level cap on aggregate at-risk across all listed tiers** inside
  the instance. A single 10× buyer draws on the entire ETH pot, not a pre-carved per-tier sleeve.
- **MAX_OPEN dust-grief — fixed, with an honest caveat:** move per-series inventory to mappings
  (`written_units[series]`/`claim_held[series]`), **but** `boundary_nav` and the waterfall must still sum over
  an **enumerable** open-series set, and a Vyper `HashMap` isn't enumerable — so a bounded
  `open_series: DynArray[address, MAX_OPEN]` is still required. **`MAX_OPEN` is a hard gas ceiling (≤6–8), not
  a menu-richness dial.** Plus a `MIN_WRITE_SIZE` dust floor on buy (the shipped `assert cost>0` admits 1-wei
  dust) and gate buys on a **bounded keeper-curated `LeverageMenuRegistry.is_listed`** — never bare
  `SeriesFactory.is_series`.
- **Per-series NAV with a FINITE mark (critical correction — ACC-WORSTCASE):** the master spec said "mark
  every open series at worst case" — but a short-vol house has **no finite worst case** (as `x→∞` the held-P
  mark → 0, writing off the whole book on the first write and bricking share issuance). The shipped vault
  already marks at the **live oracle** (`min(UNIT, STRIKE·UNIT//x)`). Use **live-mark minus a
  leverage×staleness haircut**: `p_mark = max(0, min(UNIT, STRIKE·UNIT//x) · (UNIT − lev·DRIFT_BUDGET)//UNIT)`.
  Reserve the `x→∞` bound **only** for the Halmos `nav()≥0` tail theorem.
  `junior_NAV = free_collateral + Σ collateral_locked(FACE) + premium_collected − Σ mark_haircut_liability −
  senior_escrow` (locked counted once at face).
- **Risk caps denominated in JUNIOR-LOSS, not face (critical — POT-CONCENTRATION):** per-unit max loss is
  `r = STRIKE/x`, which differs per tier, and a stale-tick mis-pay scales as `lev × gap` — a 20× tier inside a
  10%-of-NAV *face* cap can move NAV ~10% on a 5% mistick. Enforce per-write
  `written_face[tier]·lev·MAX_SETTLE_GAP ≤ MAX_TIER_LOSS_BPS·NAV` **and** global
  `Σ written_units·r ≤ MAX_AT_RISK_BPS·NAV`. This is the depth-vs-isolation dial, expressed as a **loss
  budget** — a 10× tier draws proportionally less face from the shared pot.
- **Epoch / boundary-NAV pricing:** the shipped vaults price deposits at live NAV (a JIT-arb that's *sharper*
  in a multi-tier pot). Strike `boundary_nav` once per epoch **after** the senior debit; mark a matured series
  at `min(conservative_pre_settle, fixed_payout_if_settled)` so a keeper settling early can never *raise* the
  mark; `boundary_nav` must be settle-order-independent (Halmos).
- **Incremental cursor settle, atomic NAV:** `poke()` drains the settle backlog over multiple calls
  (`settle_cursor` + `MAX_SETTLE_PER_CALL`, skip-on-failure), but `boundary_nav` is **one atomic snapshot**
  reading one oracle `x` for all open series (incremental marks across blocks make the share price
  inconsistent). Never gate deposit-mint / redeem-clear on a settle succeeding.
- **Premium reserved against open positions (ACC-PREMIUM-COMMINGLE):** redeem queued claims from **equity net
  of open risk** (`free_collateral − Σ mark_haircut_liability`), not gross buffer — else early LPs are paid
  from premium earmarked against still-open positions, leaving the pot equity-insolvent while each series
  stays series-solvent. Halmos: `free_collateral ≥ Σ_open liability` after any op sequence.
- **`force_redeem` = the un-priced exit, bounded + fairness-guarded:** the shipped oracle-free in-kind redeem,
  but cap the `free_collateral` fraction it pays so an informed LP can't loot under-marked tiers / drain the
  buffer ahead of waiters. Halmos: `value(force_redeem(f)) ≤ value(claim_redeemed(f))` for all oracle paths.

## 3. The guardian (the "owner" — narrow, and not a rug key)

**A separate minimal timelock+multisig contract** the vault references as `GUARDIAN: immutable(address)`. The
vault **never delegatecalls it and it never holds vault state** — it is the *inverse* of an upgrade proxy. Its
entire reach is **two booleans the vault reads.** **Mainnet-only** — Sepolia ships the live ownerless vaults
unchanged (adding a privileged surface to testnet funds only adds attack surface).

- **Two flags:** `writes_paused` (checked only at the top of `buy_*`/`request_deposit`; reversible) and
  `force_exit` (a one-way latch flipping the house to redeem-only). **`redeem()`/`force_redeem()` read
  NEITHER** — the oracle-free in-kind path is verbatim. Flags live in a **separate storage word** touched only
  by write-entry asserts (the shipped redeem shares `open_series`/`p_held` with `buy_n`, so this separation is
  load-bearing — GUARD-3).
- **ABI = the prohibition:** `pause_new_writes` / `unpause`; `trigger_migration`; `ratchet_cap(cap_id, new)`
  with `assert MIN_FLOOR ≤ new ≤ current` (monotone-narrowing **and floored** — an unfloored ratchet-to-zero
  is a write-DoS dressed as "narrowing"); `renounce()`. There is **NO** `withdraw`, `set_implementation`,
  `set_oracle`, `set_edge`, `set_strike`, or `loosen_cap`.
- **Timelock split:** `pause` executes immediately (3-of-5; it can only *reduce* risk). Everything
  irreversible/abusable — `trigger_migration`, `ratchet_cap`, `renounce` — sits behind `MIN_DELAY =
  max(EPOCH_LEN, 48h)` + multisig so LPs always out-run a change. `trigger_migration` is gated stricter (4-of-5
  + ≥2 epochs + an **on-chain fresh-feed precondition** so it can't be fired into a stale window that traps the
  in-kind legs).
- **The honest rug distinction, three axes (GUARD-7):** value extraction — guardian **CANNOT** (no withdraw
  exists, code-enforced); logic rewrite — **CANNOT** (immutable address, no proxy); liveness — **CAN** suspend
  (pause) and **CAN** permanently end (migrate). The "narrow brake, not a rug" framing is genuinely true on the
  two axes Kyle cares about (your money can't be taken, the rules can't be rewritten) but **must** carry the
  axis-3 caveat: a captured 3-of-5 can DoS new business or force-exit — **never trap funds** (redeem stays
  open). Mitigate with named accountable signers + a Safe with rotatable signers (the guardian *address* is
  immutable, so signer rotation is the only key-recovery path; hardcode the `(CWV, PWV)` set at guardian
  deploy).
- **Two scoping truths to publish loudly:** (1) only **`force_redeem`** is truly unconditional — the
  NAV-priced `claim_redeemed` is coupled to `boundary_nav`/settle/epoch and can be *delayed/haircut*, so
  `pause` must **not** touch `settle_epoch()`/`poke()` (GUARD-2). (2) **the guardian provably cannot protect
  settle-stale** — `settle()` is permissionless and a griefer calls the raw series directly, bypassing the
  vault entirely (GUARD-4). "We have a guardian" must never imply high tiers are safe.
- **Renounce bound to policy, not theater (GUARD-5):** `renounce()` is sound code, but bind it to a published
  gate (minimum live-and-clean duration **AND** a second audit **AND** hardened-settle live for all listed
  series); forbid renounce while a ratchet is queued; cool-down after the last ratchet.

## 4. High leverage (the other half Kyle wants)

- **Hardened `OptionSeries`/`PutOptionSeries` blueprint — the physical unlock for >3×, a hard pre-freeze
  dependency.** Today `settle()` reads the loose 7200s heartbeat with no in-settle staleness, no
  round-completeness, permissionless one-shot — the first caller after maturity fixes payout off any stale
  tick, leverage-amplified, no owner. The blueprint adds: (a) immutable `max_settle_staleness` asserted
  **inside** `settle()`; (b) `answered_in ≥ round_id`; (c) a **TIME-anchored** multi-round median straddling
  `MATURITY` (a caller-anchored window is still one-shot tick-selectable); (d) `settle_fallback()` after
  `MATURITY+GRACE` pinning the held-leg-favorable bound. **The guardian does not substitute for this** — both
  are mandatory and orthogonal; the registry points only at the hardened blueprint, and a ctor assert binds
  writable leverage to the settle-freshness budget so a 5×+ tier against an unhardened series is structurally
  undeployable.
- **Leverage-scaled edge, on-chain, REVERT-not-clamp (FORTYX):** `ask_hs = BASE_EDGE + lev·DRIFT_BUDGET +
  SKEW_MAX·util`; **`assert required_hs ≤ MAX_EDGE`** (revert, never `min()`-clamp — a clamp silently
  under-edges the riskiest tier). The list path asserts `BASE + genesis_lev·DRIFT_BUDGET ≤ MAX_EDGE`, so an
  over-leveraged tier is **unlistable**. Only then is "40× unquotable" real bytecode (the shipped ctor only
  caps `base_edge ≤ 20%` as a *ceiling*, with no leverage floor — so today a 40× vault at a flat 2% is
  deployable; that's the money-pump).
- **Leverage-scaled freshness:** `allowed_age = DESK_MAX_STALENESS·SAFE_LEV//lev`; a 20× series "goes dark"
  above ~60s. (`MIN_STALENESS=30s` already permits a 60s bound — the gap is nothing forces it.)
- **Two ceilings, advertise the MIN:** edge-saturation (~10–15× practical, 40× refused) and **settle-safety
  (~3× on the current 7200s feed — binds first).** 5×/10× only post-hardened-blueprint; 20× additionally needs
  a **tight-heartbeat OracleHub** redeploy; 40× never.
- **Senior tranche deferred (junior-only first):** spread is ~0 in cold-start, and — importantly — the
  settle-window mis-pay is a **junior-only sink** that materializes *after* senior accrues write-time spread,
  so senior yield would be partly funded by junior's structural MEV cost. Defer on economic grounds; when it
  ships it's one senior claim over the whole pot funded from **spread not premium** (monotonic ERC-4626
  `stspUSD`, so plain spUSD stays $1), with a junior-only MEV reserve carve-out.
- **Empirical feed pass is a freeze blocker:** `DRIFT_BUDGET`/`SAFE_LEV`/`MAX_SETTLE_GAP` are immutable and
  currently *unmeasured*. Run one pass on the live Sepolia ETH/USD aggregator (cadence, max deviation/update,
  worst staleness) before writing the constants — the honest output may be that **no tier above ~2–3× is
  listable even with the blueprint on this feed**, making the tight-heartbeat hub mandatory.

## 5. Depth vs risk isolation — the trade you chose, stated honestly

You cannot have both pooled depth **and** per-tier blast isolation in one pot. In the separate-vault menu a
blown tier hit only its own frozen cap; in the unified pot one mispriced/poisoned/settle-stale tier hits the
**whole junior pool**. The resolution is not to re-fragment but to **meter**: conservative under-marking,
**loss-denominated** caps, leverage-scaled spread, and the per-block/per-window outflow caps (already shipped).
**Honest residual:** this bounds but never eliminates re-commingled risk, and a high-tier settlement remains a
one-shot oracle event whose error is **socialized across the whole pool** even with the hardened blueprint —
strictly worse than the per-vault menu, and the accepted price of the depth you want.

## 6. Findings (load-bearing; full set in the workflow record)

| id | sev | one-liner → fix |
|---|---|---|
| **ARCH-ONE-BYTECODE-TWO-INSTANCES** | resolved | true single-pot is a NAV mess → deploy CWV + PWV, one UI. |
| **ACC-WORSTCASE-MARK** | critical | "mark at worst case" writes off the book → **live-mark minus lev×staleness haircut**; `x→∞` only for the tail theorem. |
| **POT-CONCENTRATION-NONLINEAR** | critical | face sub-caps don't bound pot loss → caps in **junior-loss** (`face·lev·gap ≤ tier budget`). |
| **ACC-MAPPING-GAS-DOS** | critical | mapping doesn't kill the gas-DoS (NAV needs an enumerable set) → keep `MAX_OPEN≤8` as a hard gas ceiling + dust floor + bounded registry. |
| **ACC-WRITTEN-AT-RISK-FACE** | high | global face cap lets one high tier eat the budget → cap `Σ written·r`. |
| **FORTYX-UNQUOTABLE-IS-UNSHIPPED** | high | edge must **revert** above `MAX_EDGE`, not `min()`-clamp; list-path asserts edge fits. |
| **ACC-SETTLE-STALE-SOCIALIZED** | high | hardened settle narrows but doesn't kill one-shot tick selection → **TIME-anchored** median + loss caps + force_redeem values at recoverable. |
| **ACC-DEAD-ORACLE-WHOLE-POT** | high | dead feed traps the whole share class → `settle_fallback()` both legs, short tenors, fallback-value marking. |
| **ACC-PREMIUM-COMMINGLE** | high | redeem from **equity net of open risk**, not gross buffer. |
| **ACC-FORCE-REDEEM-LOOTING** | high | bound the buffer fraction force_redeem pays; size `MARK_HAIRCUT` so claim_redeemed isn't punitive. |
| **GUARD-1-FORCE-EXIT-GRIEF** | high | migrate stricter than pause (4-of-5 + ≥2 epochs + fresh-feed precondition). |
| **GUARD-2-REDEEM-COUPLING** | high | only `force_redeem` is unconditional; pause must not touch `poke()`/`settle_epoch()`. |
| **GUARD-3-FLAG-MISWIRE** | high | flags in a separate storage word; redeem/force_redeem read neither. |
| **GUARD-4-CANNOT-GATE-SETTLE** | high | guardian can't protect permissionless settle → hardened blueprint mandatory + orthogonal. |
| **AUDIT-SCOPE-NOT-COLLAPSIBLE** | high | ~10 net-new immutable components, monolithic Halmos intractable → operate-pausable first, decompose, audit each. |
| **COLD-START-BIG-POT-WORSE** | high | one empty pot concentrates cold-start → ramp the global cap by realized volume; launch 1–2 tiers. |
| **SETTLE-MEV-JUNIOR-ONLY-SINK** | high | residual MEV lands 100% on junior → defer senior; junior-only MEV reserve when it ships. |
| **ORACLEHUB-ROUND-COMPLETE** | high | `_read` omits `answered_in≥round_id` → free one-liner + redeploy (necessary-not-sufficient). |
| **GUARD-5..9, ACC-BOUNDARY-RACE, SHORT-PROOF-NOT-IDENTICAL, EMPIRICAL-FEED-PASS** | med | renounce policy / timelock-gaming / liveness-axis honesty / legal gap / key-loss; settle-order NAV race; PWV 6-dec proof separate; measure the feed before freezing constants. |

## 7. GO / NO-GO

- **SAFE TO BUILD + TESTNET NOW (guardian-less, pausable, NOT frozen):** keep the two live vaults unchanged;
  build the unified-desk machinery as **owner-controlled, pausable, non-frozen** contracts to exercise the
  never-operated parts under kill switches — the `LeverageMenuRegistry`, mapping inventory + bounded
  `open_series` + cursor settle, multi-strike per-series marking, the leverage-scaled **reverting** pricer, the
  epoch/boundary-NAV/queue machine, the keeper. Land the free `OracleHub._read` one-liner. Run the empirical
  feed pass. **~3× ceiling on the current feed; do not list 5×+.**
- **GATED ON THE HARDENED SETTLE BLUEPRINT (before any 5×/10×/20× freeze):** the hardened series + `settle_fallback`
  (the guardian does **not** substitute); 20× additionally needs a tight-heartbeat OracleHub redeploy.
- **GATED ON AUDIT + DECOMPOSED HALMOS + LEGAL BEFORE ANY REAL MONEY (mainnet):** the two **critical** fixes
  (live-mark-minus-haircut; loss-denominated caps) + revert-not-clamp edge + the three conservation lemmas +
  independent audit of each frozen component + a named legal entity & counsel opinion (pool/senior/guardian
  characterization is an architecture *input*, not a downstream checkbox). The guardian is a mainnet-only
  addition bound to its renounce policy.

**Net: the architecture is right and buildable; the mechanics are safe to operate-pausable + testnet now; it
is NOT ready to freeze.** Capped-loss = premium and full collateralization (`P+N==1` / `M+L==1`) hold at the
series level and are unaffected by every settle/MEV finding — never imply principal beyond deposit.

## 8. Build checklist
1. **[MECHANICS — pausable, not frozen]** `GimbalWriterVault.vy`: `LeverageMenuRegistry` (bounded cohort,
   strike-snap, `r<0.96` grid), mapping inventory + `open_series DynArray[≤8]` as the summable set,
   `settle_cursor` + `MAX_SETTLE_PER_CALL`.
2. **[MARKING — critical]** `mark = live-intrinsic · (UNIT − lev·DRIFT_BUDGET)//UNIT`; separate CWV (wei) /
   PWV (6-dec round-down) paths, not one branchless function.
3. **[CAPS — critical]** junior-loss denomination: `face·lev·MAX_SETTLE_GAP ≤ MAX_TIER_LOSS_BPS·NAV` +
   `Σ written·r ≤ MAX_AT_RISK_BPS·NAV`.
4. **[EDGE — critical]** leverage-scaled pricer with `assert required_hs ≤ MAX_EDGE` (revert); list-path
   asserts the tier's edge fits.
5. **[FRESHNESS]** `allowed_age = DESK_MAX_STALENESS·SAFE_LEV//lev` per buy.
6. **[EPOCH]** boundary-NAV pricing after the senior debit; matured-series mark `min(conservative, fixed)`;
   redeem from equity net of open risk.
7. **[HUB — free]** `assert answered_in ≥ round_id` in `OracleHub._read` + redeploy.
8. **[SETTLE BLUEPRINT — gated, >3×]** hardened series: `max_settle_staleness` inside `settle()`,
   round-completeness, TIME-anchored median, `settle_fallback()` both legs.
9. **[PUT FACTORY]** `PutSeriesFactory.vy` (~70 lines; pass `stable:address`, not `asset:bytes32`).
10. **[FORCE_REDEEM]** cap the buffer fraction it pays; fairness guard.
11. **[EMPIRICAL]** measure the live ETH/USD feed; publish the numbers; pin the constants.
12. **[GUARDIAN — mainnet only]** separate timelock+multisig; `writes_paused` (immediate) + `force_exit`
    (4-of-5, ≥2 epochs, fresh-feed precondition) + floored ratchet + policy-bound renounce; flags in a
    separate storage word; Safe with rotatable signers; hardcoded `(CWV, PWV)` set.
13. **[HALMOS — decomposed, hard gate]** mark ≥ true liability; loss-budget bounds pot loss; charged_edge ≥
    leverage floor; truncated-boundary conservation; `free_collateral ≥ Σ_open liability`; boundary_nav
    settle-order-independent; `nav()≥0` + donation-immune; gas-bound poke/redeem; force_redeem totality;
    flag-read touches only writes.
14. **[AUDIT]** independent paid audit of each frozen component (monolith intractable). Hard pre-freeze gate.
15. **[LEGAL]** named entity + counsel opinion (pool/senior/guardian characterization) before freeze.
16. **[UX]** one surface / two pools; one-way dated strikes; capped-loss=premium / no liquidation /
    immutable; explicit "guardian gates the vault, not series settlement; only `force_redeem` is
    unconditional and pays worst-case in-kind; high tiers safe only post-hardening."

## 9. Open decisions for Kyle
1. **Writable leverage at freeze:** ship the settle-safe **~3×** shared pot first and add 5×/10× after the
   hardened blueprint *(spec rec)*, or build the hardened blueprint first and freeze once? (20× needs the
   tight-heartbeat hub regardless.)
2. **The depth-vs-isolation number:** `MAX_TIER_LOSS_BPS` + global `MAX_AT_RISK_BPS` — this dial needs a number,
   not a principle.
3. **`MAX_OPEN` listed-tier count** (proposed ≤6–8): fewer = simpler proof + cheaper NAV snapshot; more = richer
   menu, higher gas ceiling.
4. **Guardian power set:** just pause + migrate, or also the floored cap-ratchet in v1? (more power = more
   brake, more trust surface.)
5. **Migrate gate:** accept the stricter 4-of-5 + ≥2-epoch + fresh-feed precondition on `trigger_migration`?
6. **Senior tranche:** confirm junior-only at launch, senior deferred to the same gate as PWV + measured flow?
7. **`PutSeriesFactory` now, or hand-deploy curated put tiers** until then?
8. **Named legal entity + the 5 signers:** who, same party liable for the pool? (Counsel opinion is a
   pre-freeze architecture input.)

*Sepolia testnet, research code, unaudited. Capped loss = premium; no liquidation; fully collateralized by
construction. The honest writable ceiling on the shipped feed is ~3× — high leverage is post-hardening; real
money is post-audit + legal.*
