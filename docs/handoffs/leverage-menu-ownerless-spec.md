# Gimbal P2 — Ownerless leverage-tier menu (spec)

> Build spec for the **leverage menu** in the **ownerless** architecture — Split.markets' "pick your
> leverage + tenor" UX, with **no operated desks, no signer, no owner**. Supersedes the venue design in
> [`leverage-menu-spec.md`](leverage-menu-spec.md) (which was built around operated `SeriesQuoteFiller`
> desks — dead since Kyle killed operated desks). Produced via a design→red-team→synthesize pass grounded
> in the **already-shipped** contracts (`GimbalSimpleVault`, `GimbalShortVault`, `PutOptionSeries`,
> `OptionSeries`, `SeriesFactory`, `OracleHub`).
>
> **Sepolia testnet, research code, unaudited.** The honest writable menu on the *current* 7200s ETH/USD
> feed is **≤3×**; 5×/10×/20× are gated on a hardened settlement primitive (§5). Do not advertise 20×.

```
DECISION   HYBRID — curated-C now · param-enforcing factory (B) next · NEVER the multi-series vault (A)
A TIER IS  one immutable single-series vault at a chosen strike. leverage = 1/(1−r), r = STRIKE/spot.
LONG       GimbalSimpleVault (live ~2× rolling) + a NEW reviewed GimbalDatedCallVault for dated tiers
SHORT      GimbalShortVault VERBATIM at new put strikes (already the dated single-series shape)
#1 NEW CODE  an on-chain ctor assert tying BASE_EDGE to leverage (shipped vaults charge a FLAT edge)
CEILINGS   edge-cap refuses 40×; settle-safety (~3× on the 7200s feed) binds FIRST — advertise the MIN
```

---

## 1. The decision: curated-C now, factory-B next, never-A on this feed

There were three ways to write a grid of dated tier-series ownerlessly:

- **(A) one immutable multi-series "menu vault"** that writes the whole grid. **REJECTED — concretely DOA on
  the shipped bytecode**, not merely "more code." `GimbalSimpleVault.open_series` is a `DynArray[..., 8]`
  *settle-drain* buffer (only the tracker's single current vintage is ever appended); a menu vault writing
  many series lets a griefer dust-buy 8 distinct series to fill it and brick every further write + bloat the
  `_nav`/`redeem`/`poke` loops, with no owner to bump the cap (finding **OPTION-A-MAXOPEN-GRIEF**). A also has
  one scalar `MAX_WRITTEN` and marks every series at one oracle `x` — no per-tier params or per-tier NAV. A is
  the entire `autonomous-vault-spec.md` §8 net-new immutable surface, rated NO-GO to freeze. **A is the
  mainnet end-state behind a pausable owner + Halmos + audit — never an immutable testnet freeze.**
- **(B) a permissionless `VaultFactory`** that mints a single-series tier-vault per `(asset, leg, tier, tenor)`.
  **NEXT, not now.** `is_vault` proves bytecode, **not** params — and a tier-vault's entire risk profile is
  deployer-chosen ctor params (`STRIKE`, `BASE_EDGE`, staleness, caps) with no on-chain canonicalization
  (`SeriesFactory` mints *any* strike). A permissionless factory would certify off-grid / mis-edged /
  dead-on-arrival immutable vaults as "real" (finding **FACTORY-TRUST-NOT-PARAM-TRUST**). Safe only once it is
  the **sole minter** of both series + vault in one call, with `tier → params` as **pure functions of a tier
  enum** (no free params), pointing at a hardened blueprint.
- **(C) a small curated set of hand-deployed single-series tier-vaults.** **SHIP THIS NOW.** Each instance is
  the cleared single-series bytecode at a chosen strike; deploys are deliberate (no keeper-race, no MAX_OPEN
  grief, per-vault blast-radius isolation). Discovery is a curated `leverageMenu.json`.

**Why C/B beat A on the merits:** `leverage = 1/(1−r)` is *exactly* our settle math (`payout_n = max(0,
1−STRIKE/x)`), so **a tier is just a strike fed to a single-series vault — there is no new leverage logic
anywhere.** The short side reuses `GimbalShortVault` verbatim; the long side needs one small new reviewed
contract. That is a fraction of A's surface.

## 2. A tier = one single-series vault (the core mechanics)

- **leverage = 1/(1−r)**, `r = STRIKE/spot` at mint. Stored as the ratio `r` so the label is vintage-stable;
  the actual strike is derived at deploy: `strike = round_to_tick(x0·r)`, `x0 = OracleHub.latest_price(USD)`
  read **on-chain at broadcast**, coarse-tick-snapped ($25/$50 bucket) so the trader symbol is clean
  (`N-USD-1900-260710`) and `SeriesFactory`'s `(asset,strike,maturity)` dedupe converges.
- **No in-contract roll.** Each dated tier-vault writes ONE series to maturity, then `poke()` best-effort
  settles + harvests and the vault winds down (LPs redeem oracle-free in-kind). "Mint-fresh-on-expiry" is a
  *deploy* concern (deploy the next cohort), never vault logic — a buyer's N/M is never silently rolled. This
  keeps each instance the cleared single-series bytecode and sidesteps the keeper-race in C entirely.
- **Keeper = the existing `poke()` verbatim** (permissionless, zero privilege). `settle()` is permissionless
  on both primitives, so if no keeper runs, anyone settles and `redeem()` still pays oracle-free in-kind.
- **NAV is partitioned, not aggregated** (the deliberate B/C trade): each vault has its own NAV, soulbound
  share token, buffer, and in-kind redeem. Clean isolation, at the cost of fragmented LP depth (§6).
- **Pricing reuses the shipped formula verbatim**: `price = intrinsic·(1+BASE_EDGE)`; `quote_buy_*` views
  already ship. **No signer, no EIP-712, no quoter service.** The *only* per-tier change is the immutable
  param values — and `BASE_EDGE` **must be leverage-scaled at deploy** (§4, the #1 build requirement).

## 3. The tier grid + the two ceilings

| tier | r = STRIKE/spot | premium/N = max loss | ETH move to worthless | feed-tick amp (per ~0.5% tick) | suggested tenor |
|---|---|---|---|---|---|
| 2× | 0.500 | 0.500 | −50% | 1.0% | ~30d |
| 3× | 0.667 | 0.333 | −33% | 1.5% | ~21d |
| 5× | 0.800 | 0.200 | −20% | 2.5% | ~14d |
| 10× | 0.900 | 0.100 | −10% | 5.0% | ~7d |
| 20× | 0.950 | 0.050 | −5% | 10.0% | ~3d |
| 40× | 0.975 | 0.025 | −2.5% | ~20% | **REFUSED** |

**Two distinct ceilings — state both, advertise their MIN:**
1. **Edge-saturation ceiling** — a leverage-scaled edge at 40× needs ~20%, which collides with the
   hard-asserted `MAX_MIN_EDGE = 20%` in both vault ctors → 40× is structurally undeployable *once edge is
   leverage-scaled* (and honestly ~10–15× is the practical edge ceiling). Owner-independent.
2. **Settle-safety ceiling** — the tier above which `7200s × drift × leverage` mis-pays unacceptably at
   settlement: **~3× on the current USD sentinel.** This **binds first.** The ubiquitous "20×" is the
   *edge-cap* ceiling, **not** launchable on the shipped 7200s feed.

⚠ **40× is NOT refused by the shipped vault as-deployed** — the ctor only checks `base_edge ≤ MAX_MIN_EDGE`,
nothing ties edge to leverage. A deployer can freeze a 40× vault at a flat 2% edge — the money-pump in §4.

## 4. The #1 build requirement: leverage-scale the edge on-chain (FLAT-EDGE)

**The buried lede.** Both shipped vaults price `intrinsic·(1+BASE_EDGE)` with a single **flat** immutable
`BASE_EDGE` and **no `leverage_amp`** (that machinery exists only as net-new Option-A code in the master
spec, not in the deployed bytecode). The live short vault is frozen at `base_edge = 2%` for an algebraic
**~5×** — by the design's own adverse-selection math (`safe edge ≈ leverage × drift-over-staleness`), that is
a **2.5–5%+ free-option edge against a 2% quote on every moving tick.** It is safe *only because it is
unfunded*; the moment an LP funds it, it is the menu's first adverse-selection sink.

**Fix (the single most important new line in P2):** bake an on-chain ctor assert into both the new
`GimbalDatedCallVault` and the (re-cut) short vault:
```
x0 = fresh anchor read once at construction (_assert_fresh-gated)
genesis_lev = x0 // (x0 − STRIKE)
assert base_edge >= BASE + genesis_lev * DRIFT_BUDGET     # e.g. 0.75% + lev·0.5%
DESK_MAX_STALENESS = BASE_STALE * SAFE_LEV // genesis_lev  # 2x→600s, 5x→240s, 10x→120s, 20x→60s
```
This converts the biggest "just config it" foot-gun into a deploy-time revert. `MIN_STALENESS = 30s` permits
a 60s 20× bound, so a correctly-tuned high-tier vault is deployable *params-wise* today — the gap is that
nothing **forces** it. Pin `DRIFT_BUDGET`/`SAFE_LEV` from **one empirical pass** on the live Sepolia
ETH/USD feed (max deviation per update + real cadence vs the 7200s registration) before freezing any edge —
it's immutable.

Also per-tier: the **near-strike band** must be re-tuned. The live `GimbalSimpleVault` froze
`strike_proximity = 1.5e18` (= spUSD `ROLL_TRIGGER`); a dated 5× call is born only +25% above strike — inside
a 1.5 band → it would refuse every fill. The new call vault takes `strike_proximity` as a direct param
`UNIT < prox ≤ ~1.05e18`, tightened `< 1/r` per tier. (The put side is already correctly shaped — sub-UNIT
proximity, no `ROLL_TRIGGER` read.)

## 5. The settlement blocker (gates everything above ~3×)

All three load-bearing risks live in the **frozen primitives**, so reusing them inherits them:

- **SETTLE-STALE-7200 (critical):** `settle()` reads the loose **7200s** hub heartbeat, **not** the vault's
  tight `DESK_MAX_STALENESS` (which only guards `buy_*`). Settle is permissionless + one-shot, so the first
  caller after maturity fixes payout off any print up to 7200s stale, leverage-amplified, no recourse, no
  pause — and a keeper can pick the favorable tick in the window. **Un-patchable in reused bytecode.** ⇒ cap
  writable leverage to **~3×** on the current feed; to unlock high tiers, freeze first a **hardened
  `OptionSeries`/`PutOptionSeries` blueprint**: immutable `max_settle_staleness` asserted *inside* `settle()`,
  `answered_in ≥ round_id`, multi-round median (`getRoundData`), and a `settle_fallback()` after
  `MATURITY + GRACE` for the dead-oracle trap.
- **ORACLEHUB-ROUND-COMPLETE (high, FREE):** `OracleHub._read` omits `assert answered_in ≥ round_id` (the F5
  check the vaults' *write* path carries but `settle()` bypasses). One-line fix; benefits every consumer; the
  hub is Sepolia-redeployable. Necessary-not-sufficient — does **not** replace the staleness fix.
- **DEAD-ORACLE-TRAP (high):** a sunset feed past maturity traps the locked split half (free collateral is
  always oracle-free via `redeem()`). Short tenors shrink the window; the durable fix is `settle_fallback()`.
  Note B's per-vault bounding genuinely helps here (a dead-feed hits only that vault's locked slice).

## 6. Honest economics — fragmentation, cold-start, capped loss

- **FRAG-IS-FROZEN (high):** `MAX_WRITTEN` is immutable per vault and shares are soulbound, so the menu's
  writable risk = the **sum of each vault's frozen cap**, and an LP **cannot** move idle 2×-vault capital to
  the 10× tier. *"P3 aggregates depth across the grid later" is FALSE* unless P3 is a new commingling contract
  (= Option A). Mitigation is **hard curation to ≤4 funded tiers**, not a promised later fix; size each
  `MAX_WRITTEN` to credible single-tier demand and publish it so the UI shows real remaining depth.
- **COLD-START-EMPTY-HOUSES (high):** every new tier-vault needs a first LP to take pure short-vol risk into
  an empty book (junior-only, no senior tranche in v1), and the no-signer formula bleeds from block one.
  Launch the **minimum** tier count, seed the first deposit from a throwaway-key LP (testnet-OK), or show
  "be the first house" instead of a tradeable card; gate rollout on observed deposits.
- **Capped loss is UNAFFECTED by every settle/MEV risk.** `P+N==1` / `M+L==1` by construction: buyer downside
  ≤ premium, LP downside ≤ deposit (pre-funded), never liquidated. The settle/MEV exposure is the settle-time
  *value* of an ITM high-tier leg and the MEV bleed to LPs — **never principal beyond deposit.** Say it loudly.
- **WRITE-ONLY, no pool for dated strikes:** menu N/M is one-way (exit = `merge` if you hold both legs, or
  post-settle `redeem_*`). Keep high-tier tenors short to bound the no-exit window; never show a phantom
  2×-pool route for a dated strike, never cross-route tiers (siblings, not substitutes).

## 7. Long + short, and how the live vaults fit

- **LONG (N, ETH):** the live `GimbalSimpleVault` `0x25cDc8…` is the **perpetual ~2× rung** (rides the spUSD
  tracker; rolling is capped ~2.73× by the genesis-brick guard, so dated is the only way >2.73× long). P2 adds
  dated 3×/5×… long tiers via a **NEW reviewed `GimbalDatedCallVault`** (`SeriesFactory.create_series(USD,
  strike, maturity)` mints the dated call today). **DATED-LONG-CTOR-BLOCKER (high):** it can't reuse
  `GimbalSimpleVault` — that ctor does `ITracker(tracker).ROLL_TRIGGER()` (reverts on a dated series) and
  `buy_n` hard-binds the tracker. The sibling = the short-vault single-series skeleton (immutable `SERIES`,
  cached `STRIKE/P/N`, single `p_held`, `series==SERIES`) wearing the ETH/call pricing + payable split. New
  immutable bytecode → **its own 14-agent review** (does NOT inherit the live vault's clearance).
- **SHORT (M, USDC):** `GimbalShortVault` `0xB835cB…` **is already** the dated single-series tier-vault — add
  put tiers by deploying more instances at other strikes. **PUT-MENU-BLOCKED-NO-FACTORY (high):** there is **no
  `PutSeriesFactory`** and `SeriesFactory` can't be repointed (it passes `asset:bytes32` where
  `PutOptionSeries` wants `stable:address`), so a *permissionless* put menu is hard-blocked — put tiers are
  **hand-deployed (C)** until `PutSeriesFactory` (~70 lines) is built.
- **The two live vaults ARE the first two tiers**, not throwaway demos. The menu grows by adding siblings of
  the same two bytecodes. P3 (writer vaults) is already the shipped vaults' funding model — each tier-instance
  *is* a P1+P3 unit; the remaining P3 work is depth aggregation (= the Option-A mainnet end-state).

## 8. Findings (all confirmed against the code)

| id | sev | one-liner → fix |
|---|---|---|
| **SETTLE-STALE-7200** | critical | `settle()` reads the 7200s heartbeat, not the tight write-staleness → high tiers settle-poisonable, no owner. **Cap ≤3× now; hardened settle blueprint before any 5×+.** |
| **FLAT-EDGE-NO-LEVERAGE-AMP** | critical | shipped vaults charge a flat edge; live ~5× short is a money-pump if funded. **Bake the on-chain `base_edge ≥ f(genesis_lev)` ctor assert (§4) — the #1 new line.** |
| **OPTION-A-MAXOPEN-GRIEF** | critical | the multi-series vault is DOA on `MAX_OPEN=8` dust-grief. **Don't build A on the shipped shape; use B/C.** |
| **DATED-LONG-CTOR-BLOCKER** | high | `GimbalSimpleVault` ctor reverts on a dated series. **Build `GimbalDatedCallVault` (new, reviewed).** |
| **PUT-MENU-BLOCKED-NO-FACTORY** | high | no `PutSeriesFactory`; `SeriesFactory` not repointable. **Hand-deploy put tiers (C) now; build `PutSeriesFactory` for B.** |
| **FACTORY-TRUST-NOT-PARAM-TRUST** | high | `is_vault` ≠ param-trust. **No permissionless factory for v1; when built, bake tier→params as pure functions.** |
| **ORACLEHUB-ROUND-COMPLETE** | high | `_read` omits `answered_in ≥ round_id` (settle accepts carried rounds). **Free one-line hub fix + redeploy.** |
| **DEAD-ORACLE-TRAP** | high | dead feed past maturity traps the locked half. **Short tenors now; `settle_fallback()` for mainnet.** |
| **ORACLE-TICK-AMP-EDGE** | high | per-tier edge has no on-chain tie to strike → MEV bleed forever. **Same fix as FLAT-EDGE (enforce at deploy).** |
| **FRAG-IS-FROZEN** | high | depth can't be pooled across tiers (immutable cap + soulbound shares). **Hard-curate to ≤4 funded tiers.** |
| **COLD-START-EMPTY-HOUSES** | high | empty junior-only books bleed; many tiers = mostly empty. **Launch minimum tiers; seed first deposits.** |
| **KEEPER-RACE-DUP-SERIES** | medium | live-strike snap can mint duplicate cohort series. **Calendar-snap maturity + coarse-snap strike (moot in C).** |
| **EDGE-CEILING-BELOW-20X** | medium | honest edge ceiling ~10–15×, and settle ceiling (~3×) binds first. **Advertise the MIN, not 20×.** |
| **WRITE-ONLY-NO-EXIT** | medium | dated strikes have no buy-back/pool exit. **UX: one-way, hold-to-expiry; short tenors.** |
| **LABEL-DISHONESTY-5X-NOT-4X** | low | live short is ~5× (K=1.25× spot), documented "~4×". **Show genesis badge + live-recomputed leverage; fix the label.** |

## 9. GO / NO-GO

**GO (safe to build + freeze on Sepolia now, testnet funds only):**
- Keep the live `GimbalSimpleVault` (perpetual ~2× long) unchanged.
- Build + adversarially review `GimbalDatedCallVault`; deploy **one dated 3× long** (~21d) — inside the ~3×
  settle-safe bound.
- **Re-deploy the short tier** (`GimbalShortVault` verbatim) at **correct leverage-scaled `base_edge` +
  tier-scaled `desk_max_staleness`** — the live 2%/3600s ~5× instance is mis-edged; do **not** list it as-is.
- Land the free `OracleHub._read` one-liner.
- Ship discovery as a curated `leverageMenu.json` (dapp-builder owns it).

**NO-GO until gated work ships:** any tier **>3×** on the 7200s feed; **Option A**; a **permissionless
factory**; any vault frozen with a **flat edge**.

**GATED on a hardened settle primitive (before any 5×/10×/20×):** hardened `OptionSeries`/`PutOptionSeries`
blueprint (max_settle_staleness inside `settle()` + `answered_in≥round_id` + round-median + `settle_fallback`)
+ leverage-scaled edge enforced at deploy + calendar/anchor-snapped cohorts if a keeper is added.

**MAINNET:** Option-A unified bytecode for depth aggregation, epochs, senior tranche, timelock guardian,
Halmos + audit, named legal entity.

## 10. Build checklist
1. **[CALL]** `GimbalDatedCallVault.vy` — drop `ITracker`/`ROLL_TRIGGER`; immutable `SERIES` + cache
   `STRIKE/P/N`; ctor asserts not-settled / maturity>now / `ASSET==empty`; `strike_proximity` as a direct
   param `UNIT < prox ≤ ~1.05e18` (tightened `< 1/r`); `buy_n` asserts `series==SERIES`; collapse the
   `open_series` DynArray to a single `p_held`.
2. **[EDGE — load-bearing]** the on-chain `base_edge ≥ BASE + genesis_lev·DRIFT_BUDGET` ctor assert +
   `DESK_MAX_STALENESS = BASE·SAFE_LEV//genesis_lev`, in BOTH the call sibling and the re-cut short vault.
3. **[HUB — free]** `assert answered_in ≥ round_id` in `OracleHub._read` + redeploy; re-point new series.
4. **[SETTLE — gated, for >3×]** hardened series blueprint (max_settle_staleness inside `settle()`,
   round-completeness, round-median, `settle_fallback`). Adversarial review before any high-tier freeze.
5. **[PUT FACTORY — for B/permissionless put menu]** `PutSeriesFactory.vy` (~70 lines; pass `stable` as the
   2nd ctor arg; dedupe `keccak(stable,strike,maturity)`; drop the `is_registered` gate). Point at the
   hardened put blueprint if high put tiers are wanted.
6. **[DEPLOY — curated C, v1]** keep 2× live; deploy one dated 3× long; re-deploy the short tier at corrected
   params. Read `x0` on-chain at broadcast, coarse-tick the strike. **≤2 long + ≤2 short.**
7. **[SEED]** fund each vault's first deposit (throwaway-key LP, testnet-OK), or show "be the first house."
8. **[DISCOVERY]** curated `leverageMenu.json` `{leg, tierLabel, kind, vault, series, strike, maturity,
   genesisLeverage, maxWritten}`. Defer an on-chain registry to B.
9. **[EMPIRICAL]** one measurement pass on the live ETH/USD feed to pin `DRIFT_BUDGET`/`SAFE_LEV` before
   freezing any edge/staleness.
10. **[REVIEW]** 14-agent adversarial review + fork suite for `GimbalDatedCallVault` (and, when built, the
    hardened blueprint / `PutSeriesFactory` / any factory).
11. **[UX SPEC]** one-way dated strikes; siblings-not-substitutes (no cross-routing / no phantom pool);
    theta = product, capped loss = premium, no liquidation; genesis badge + live-recomputed leverage ("—"
    in band) + premium-as-max-loss prominent; immutable/ownerless/Sepolia-unaudited disclosure.

## 11. Open decisions for Kyle
1. **High tiers at all on this feed?** Honest writable menu is ≤3× today. (a) ship the ≤3× curated menu now,
   or (b) build the hardened settle blueprint FIRST, then list 5×/10×? *Rec: (a) now, (b) before any high
   tier. 20× is not launchable on the shipped feed regardless.*
2. **Build `GimbalDatedCallVault` now** (a new reviewed bytecode for a dated 3× long), or **ship short-only
   tiers first** (zero new vault code — `GimbalShortVault` verbatim)?
3. **Re-cut the live ~5× short vault** at leverage-scaled params, or **down-tier it to a settle-safe 3×**? It
   must not be the menu's short rung as-is (FLAT-EDGE).
4. **`PutSeriesFactory` now or curated hand-deploy?** *Rec: hand-deploy (C) for testnet; factory only with B.*
5. **Tier-count gate vs fragmentation** — proposed hard ceiling **≤2 long + ≤2 short** for v1. Your number?
6. **Canonical leverage label** — genesis-r badge, live-recomputed, or both? *Rec: both; fix the live short
   to ~5× (or re-deploy at K=1.333× spot for a true 4×).*

*Sepolia testnet, research code, unaudited. Capped loss = premium; no liquidation; fully collateralized by
construction. The honest writable menu on the shipped feed is ≤3× — everything above is post-hardening.*
