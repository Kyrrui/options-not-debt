# Gimbal P1 — Debt-free leveraged SHORT (stable-collateralized put series) (spec)

> **⤳ Unified into [`autonomous-vault-spec.md`](autonomous-vault-spec.md)** — the crowd-owned immutable end-state folds this in. This doc stays the detail for its piece; the master holds the architecture + the **GO/NO-GO** (prove demand on the *pausable* operated desks first, then freeze immutable — immutability is a one-way door).

> **✅ SHIPPED (Sepolia), built the OWNERLESS way.** The put primitive + an ownerless venue are live:
> [`PutOptionSeries`](../../src/PutOptionSeries.vy) `0xa9Eac5413C3058224DCbCa676FEB0C7b47a31FcC` +
> [`GimbalShortVault`](../../src/periphery/GimbalShortVault.vy) `0xf9b268eB464178349Bd81BbCAcc3EC771d0C6254`
> (USDC `0x31B7d96A5C8ab4d91077873e61aFaBCFE11E5002`). **NOTE: §3.3's operated `ShortQuoteFiller` was NOT
> built** — it predates Kyle's "no operated desks" decision. The trading venue is instead the immutable,
> ownerless `GimbalShortVault` (USDC/put mirror of `GimbalSimpleVault`): on-chain formulaic price (no signer/
> owner), Earn-funded, in-kind oracle-free redeem, permissionless `poke()`. Frontend handoff:
> [`short-vault-frontend-handoff.md`](short-vault-frontend-handoff.md). 14-agent pre-deploy review =
> DEPLOY-AS-IS (4 low/info; VYP-01/VYP-02 dust guards applied pre-freeze); 13/13 fork tests. F-DEC (6-dec
> round-down), F-BAND (flipped band), F-DEFAULT (no payable default) all implemented + verified. The §3.3
> operated-desk design and the spUSD soft-short remain as written for reference / mainnet phases only.

> Build spec, not a sketch. A **new core primitive** — `PutOptionSeries.vy` — that is the algebraic **mirror** of the deployed call primitive (`OptionSeries.vy`), plus a `PutSeriesFactory.vy` and a **third RFQ desk sibling**, `ShortQuoteFiller.vy`, alongside the live `SignedQuoteFiller` (N leg, Sepolia `0x48c93eD52507DEe37d79eA37Df9ed7fAF739C8F1`) and `StableQuoteFiller` (spUSD leg). It gives Gimbal a **debt-free leveraged SHORT on ETH**: lock **1 stable unit** → mint **M + L**, get the **M** leg that **gains as ETH falls**, with **max loss = the premium paid, NO liquidation, NO margin, fully collateralized by construction.** It is the mirror of the leveraged LONG (the N leg) and *doubles* the product. P1 in `docs/handoffs/split-derived-roadmap.md`.
>
> It reuses everything: `OptionSeries`'s split/merge/lazy-one-shot-settle/redeem machinery (mirrored), the `SeriesFactory` blueprint/dedupe pattern, the `OracleHub` ETH/USD read, and the N/stable desks' EIP-712 + G1–G6 guardrail skeleton — generalized by the same *subtraction* the dated `SeriesQuoteFiller` uses (`leverage-menu-spec.md §3.3`), not copied verbatim.
>
> **Sepolia testnet, research code, unaudited. The mirror conservation invariant (the Halmos-proven `P+N==1`) must be re-proved for `M+L==1` before shipping. The desk is the operator's own capped capital, not a yield product, not a pooled fund.**

---

## ⚠ COLLATERAL DECISION — ship v1 on USDC, not spUSD

**The verdict: lock USDC for v1. spUSD-collateral is *structurally sound* but *economically unfaithful* to the short's purpose, so it is deferred to an explicitly-labeled, lower-leverage phase-2 "spUSD soft short" — and v1 enforces USDC-only by a hard on-chain assert, not just a UI gate.**

This is **not** a solvency question. The conservation proof (§2) holds for **any** non-rebasing stable: `M + L == 1 locked stable unit` for every ETH price, so the protocol carries **zero bad debt under USDC or spUSD alike** — no insolvency, no liquidation, no shortfall to the L writer. The question is narrower and sharper: **is the stable the short pays out in still worth $1 in the exact scenario the short pays out?** (a deep ETH crash). USDC and spUSD diverge violently here.

**The tail-correlation hole.** spUSD is an ETH-derived soft peg. From the real `TrackerDAO._val_p` (`= min(x, S_spusd)`, `TrackerDAO.vy:266`) and `_nav` (`= [eth_buffer·x + Σ p_bal·min(x, S_spusd)] / supply`, `:271-278`), one spUSD share is worth, in USD, **≈ `min(1, x/S_spusd)`** where `x = ETH/USD` and `S_spusd` is the live spUSD series strike. It holds ~$1 **only while ETH ≥ `S_spusd`** and **de-pegs linearly downward below it**. The short's payout `M = max(0, 1 − p/K)` is **largest exactly as ETH → 0** — which is **exactly the deepest de-peg zone.** Collateralizing an ETH short with an ETH-derived stable means *the collateral loses USD value precisely when the short must pay the most.* That is the tail a short buyer is buying protection for.

**Scenario math (fast crash before `sync()` rolls).** ATM short `K = 2000`. "Delivered %" = USD the spUSD short actually pays ÷ USD a USDC short pays.

*Fresh-roll state, `S_spusd = 1000` (50% buffer — `STRIKE_RATIO = 0.5`):*

| ETH `p` | M (units) | spUSD $ = min(1, p/S) | M$ via spUSD | M$ via USDC | delivered |
|---|---|---|---|---|---|
| 1500 | 0.250 | 1.00 | 0.250 | 0.250 | **100%** |
| 1000 | 0.500 | 1.00 | 0.500 | 0.500 | **100%** (buffer edge) |
| 800 | 0.600 | 0.80 | 0.480 | 0.600 | **80%** |
| 500 | 0.750 | 0.50 | 0.375 | 0.750 | **50%** |
| 200 | 0.900 | 0.20 | 0.180 | 0.900 | **20%** |

*Near-roll-trigger state, `S_spusd = 1333` (33% buffer — `ROLL_TRIGGER = 1.5`):*

| ETH `p` | M (units) | spUSD $ | M$ via spUSD | M$ via USDC | delivered |
|---|---|---|---|---|---|
| 1000 | 0.500 | 0.75 | 0.375 | 0.500 | **75%** |
| 500 | 0.750 | 0.375 | 0.281 | 0.750 | **37.5%** |
| 200 | 0.900 | 0.15 | 0.135 | 0.900 | **15%** |

**Reading.** spUSD pays the short out **100% faithfully while ETH stays above `S_spusd`** — and the soft peg keeps `S_spusd` 33–50% below spot, rolling it down in *slow* declines, so a gradual bear market is largely covered. The damage is confined to a **fast crash that punches through the buffer faster than `sync()` rolls**, and there the under-delivery is monotone in crash depth, → 0 in a true collapse. *That tail is the product.* (And the table above is **optimistic**: see finding F-BUFFER — the `eth_buffer` slice of NAV de-pegs even *above* `S_spusd`.)

**Both rescues fail.** (1) **Capping `K` to the spUSD safe band is backwards** — setting `K ≤ S_spusd` forces *100% of the payoff* into the de-peg zone (per-price fidelity is `min(1, p/S_spusd)` for *any* K; a higher K at least collects the `[S_spusd, K)` slice at full fidelity, which a capped K forfeits). (2) **Over-collateralization needs an unbounded haircut** — full USD-faithfulness at floor `p_floor` requires `OC = S_spusd / p_floor` spUSD per M-unit (haircut `= 1 − p_floor/S_spusd`): a crash to 50% of `S` needs 2×, to 10% needs **10×**, to 1% needs **100×**, → ∞ as `p_floor → 0`. No finite OC makes the deep tail faithful, and any finite OC breaks `M+L==1` / max-loss-=-premium (it is margin by another name — the thesis forbids it).

**USDC** is hard external ~$1, **zero correlation to the ETH bet**: it delivers the short's USD payoff faithfully on *every* path, including the fast-crash tail (100% in every row). Its costs are real but ordinary — external issuer/chain dependency (uncorrelated to the bet, unlike spUSD's correlated one), the operator must hold a USDC float (a new inventory class), and it does not grow spUSD demand. Those are a *growth* want, not a *soundness* property, and must not override payoff fidelity at launch.

**Recommendation, in one line:** **USDC v1 (hard-asserted on-chain); spUSD ships in phase 2 as a separately-audited, conservatively-struck, clearly-labeled "spUSD soft short" only after the live peg has survived a real drawdown; a USDC-default / spUSD-opt-in hybrid is the phase-2 end state** that gives the operator their in-house composition without putting the de-peg tail on an unwitting buyer at launch.

---

## 1. What it is

`PutOptionSeries.vy` — `# pragma version ==0.4.3`, same conventions as `src/` — is the **stable-collateralized mirror** of `OptionSeries.vy`. It is a **separate contract**, not a `kind`-flagged fork of the audited call core: the ETH-payable-vs-ERC20-pull collateral path, the 6↔18-decimal scaling, and the flipped payout direction all branch on the variant, which would double the state machine and review surface of an audited-shape contract for no shared-code win (the leg token `OptionToken` and the `OracleHub` read are already shared). Same call the leverage-menu spec made building `SeriesQuoteFiller` vs the rolling N desk: **generalize by subtraction, ship a sibling.**

| | Call (`OptionSeries`, deployed) | Short (`PutOptionSeries`, this spec) |
|---|---|---|
| Locked asset | native ETH (`@payable split`) | ERC20 stable (`split(amount)`, `transferFrom`) — **USDC v1** |
| Legs | `P` (tracking/capped) + `N` (leveraged LONG) | `L` (covered/capped) + `M` (leveraged SHORT) |
| Settle reads | `x = ETH in asset units` | `p = ETH/USD` (`OracleHub.latest_price(empty(bytes32))`) |
| Compare | strike `S` vs index `x` | spot `p` vs strike `K` |
| Capped leg | `P = min(1, S/x)` | `L = min(1, p/K)` (worth 1 stable when ETH ≥ K) |
| Leveraged leg | `N = max(0, 1 − S/x)` (gains ETH up) | `M = max(0, 1 − p/K)` (gains ETH down) |
| Conservation | `P + N = 1 ETH` always | `M + L = 1 stable` always |
| Merge | burn 1P+1N → 1 ETH, oracle-free, any time | burn 1M+1L → 1 stable, oracle-free, any time |
| Liquidation | none | none |
| Desk-traded leg | N (`SignedQuoteFiller`) | **M** (`ShortQuoteFiller`) |

`STRIKE` in the call is "asset units per ETH"; here `K` is **ETH/USD** (USD per 1 ETH, 1e18-scaled) — the same unit `OracleHub.latest_price(empty(bytes32))` returns. **v1 is USD-only** (`ASSET == empty(bytes32)`), so `p` is a single ETH/USD feed read — the same single-feed-freshness posture the existing desks require (F6).

**Why a leveraged short cannot be ETH-collateralized.** A short pays out *as ETH falls*; ETH collateral falls with the thing you're short, so backing shrinks exactly as the obligation grows — the debt/liquidation death-spiral the whole "options not debt" frame avoids. **Stable collateral is the structural unlock**: the locked value does not move with the ETH bet, so the leg stays fully collateralized to the wei on every path, no margin, no liquidation. The chosen stable is **USDC** (the COLLATERAL DECISION banner).

## 2. The primitive + conservation proof

### 2.1 Settle (mirror of `OptionSeries.settle`, comparison flipped)

The call pins `payout_p` and gives `N` the exact remainder. The short pins the **capped leg `L`** and gives **`M`** the exact remainder — flipping the comparison so the capped leg is worth 1 when ETH is **above** the strike (the covered-long side) and decays below it:

```vyper
# OptionSeries.settle()  (deployed, for reference — OptionSeries.vy:194-198)
pp: uint256 = UNIT
if x > STRIKE:
    pp = STRIKE * UNIT // x            # payout_p = min(1e18, S*1e18//x)
# payout_n = UNIT - pp   (exact remainder)

# PutOptionSeries.settle()  (this spec)
pl: uint256 = UNIT                     # L pinned at 1 stable when ETH at/above K (covered long worth 1)
if p < STRIKE:                         # STRIKE here is K (ETH/USD), 1e18-scaled
    pl = p * UNIT // STRIKE            # payout_l = min(1e18, p*1e18//K)
self.settlement_price = p
self.payout_l = pl                     # wei-stable owed per 1e18 L
# payout_m = UNIT - payout_l  is the EXACT remainder  ->  redeem_m reads (UNIT - payout_l)
```

This is a **dedicated mirror `settle()`**, *not* `OptionSeries.settle()` reused verbatim: that formula is `min(1, S/x)`, denominated in ETH and monotonic the wrong way for a short. Everything else — `split`/`merge`/`redeem_*`, lazy one-shot settlement (`settled` flag, callable by anyone at/after `MATURITY` while the feed is fresh), leg symbology — is the same skeleton denominated in the stable.

### 2.2 PROOF: `M + L = 1 stable` for all `p ≥ 0` (the conservation / no-bad-debt theorem)

**Algebraic (continuous).** With `M = max(0, 1 − p/K)`, `L = min(1, p/K)`:
- **`p ≥ K`:** `p/K ≥ 1` ⇒ `M = 0`, `L = 1` ⇒ `M + L = 1`.
- **`0 ≤ p < K`:** `0 ≤ p/K < 1` ⇒ `M = 1 − p/K`, `L = p/K` ⇒ `M + L = (1 − p/K) + (p/K) = 1`.

Holds for every `p ≥ 0`. At `p = 0`: `M = 1`, `L = 0` — the deepest short payoff is exactly 1 locked stable.

**On-chain (exact — the no-bad-debt form).** The contract never computes `M` directly; it pins `payout_l = min(1e18, p·1e18//K) ∈ [0, 1e18]` and defines `payout_m ≡ 1e18 − payout_l` as the **exact integer remainder**. So `payout_m + payout_l == 1e18` **identically, with zero drift**, for any `p` — there is no second division on the M side to disagree, exactly as the deployed call gives `N` the remainder of `payout_p` (`OptionSeries.vy:223`).

**No bad debt.** `payout_l ≤ 1e18` ⇒ `payout_m = 1e18 − payout_l ∈ [0, 1e18]`. Redeeming both legs of `amount` units pays `amount·payout_l//1e18 + amount·payout_m//1e18 ≤ amount` stable, floor-rounding shortfall `< 2 wei` (dust retained by the contract, identical to the call). **One locked stable unit always covers both legs, every ETH price, under USDC or spUSD alike.** (The spUSD question in the banner is a separate, *economic* one about what that stable is *worth in USD*.)

### 2.3 What must be Halmos-proven (ship gate — mirror `test/Halmos.t.sol`)

Port the existing lemma chain with `x→p, S→K, P→L, N→M`. The monolithic conservation query is solver-intractable (the call's `check_conservation_deep` runs >13h, kept for reference only); the **decomposition** is what closes in the SMT solver and gates CI:

- **`check_payoutBounded_short`** — ∀ `p`, `settle()` writes `payout_l ≤ 1e18` (mirror of `check_payoutBounded`).
- **`check_redeemConservation_short`** — ∀ `payout_l ≤ 1e18`, ∀ `amount`: redeem L then M returns ≤ `amount`, shortfall `< 2`. Install settled state via `vm.store` (slots from `vyper -f layout`), exactly as the call's `check_redeemConservation` does (mirror of `Halmos.t.sol:87-105`).
- **`check_splitMergeExact_short`** / **`check_splitFullyCollateralized_short`** — split→merge is value-exact; split mints equal M and L backed 1:1 by the locked stable (mirrors `:154-175`).
- **Payout monotonicity** split by strike region (`p ≤ K`, crossing, `p > K`) — mirror of `check_payoutMonotone_*`.
- **USDC decimal boundary** (NEW vs the 18-dec call, per F-DEC): a property that the 6↔18 scaling on `split`/`merge`/`redeem` **never lets the redeem pair return more stable than was locked** — the rounding must always favor the contract (round payouts **down**). This is a *second* division the wei-exact ETH call never had and is **not** covered by the 18-dec Halmos chain; it needs its own pass.

## 3. The contracts (real signatures)

### 3.1 `PutOptionSeries.vy` — the short primitive

`# pragma version ==0.4.3`. Deployed via EIP-5202 blueprint by `PutSeriesFactory`; mints two `OptionToken` legs (reused verbatim — it is asset-agnostic), symbology `M-USD-2000-260710` / `L-USD-2000-260710`.

**Immutables:** `HUB`, `ASSET` (= `empty(bytes32)`, USD-only v1), `STABLE` (locked collateral ERC20 — USDC v1), `STABLE_DECIMALS` (cached, `assert <= 18`), `STRIKE` (= K, ETH/USD 1e18), `MATURITY`, `L`, `M`. **State:** `settled`, `settlement_price`, `payout_l`.

**Structural deltas from `OptionSeries` (ETH → ERC20 stable) — all flagged:**
- **No `@payable`.** `split` takes `uint256 amount` (in **leg units, 1e18**) and **pulls** the scaled stable via `transferFrom` (caller `approve`s first), replacing `msg.value`.
- **All ETH `raw_call(value=…)` outs become ERC20 `transfer`**, with a return-value check (`assert extcall IERC20(STABLE).transfer(...)`), since the token may not revert on failure.
- **No `__default__` payable** (F-DEFAULT): the series never receives ETH; there is no ETH callback to accept. (This corrects the "reuse the call's payable default verbatim" instinct — that is an ETH-desk artifact.)
- **Reentrancy posture.** Keep every entrypoint `@nonreentrant` AND strict **CEI** (burn/effects before the stable `transfer`): an ERC20 with transfer hooks could otherwise re-enter. `split` pulls first, then mints — no intermediate corruptible state.
- **Fee-on-transfer / rebasing collateral is UNSUPPORTED** (would silently break `M+L == amount`) — pinned out at the factory (§3.2).
- **Decimals.** USDC is 6-dec; legs are 18-dec. Store/mint legs in 1e18; scale the stable on the boundary: `split(legs18)` pulls `legs18 · 10**STABLE_DECIMALS // 1e18`; `merge`/`redeem` push back the same scaling, **rounding down** so the contract never overpays (F-DEC). spUSD (phase 2) is 18-dec ⇒ scale factor 1.

```vyper
@deploy
def __init__(hub: address, stable: address, strike_k: uint256, maturity: uint256, token_blueprint: address)
    # ASSET fixed to empty(bytes32) (USD) in v1; assert strike_k>0, maturity>now, stable!=0,
    # decimals = IERC20Detailed(stable).decimals(); assert decimals <= 18

@external @nonreentrant
def split(amount: uint256)
    # before maturity; pull _to_stable(amount) STABLE via transferFrom; mint amount L + amount M to caller

@external @nonreentrant
def merge(amount: uint256)
    # burn amount L + amount M -> transfer _to_stable(amount) STABLE; ANY time, oracle-free

@external @nonreentrant
def settle()
    # block.timestamp >= MATURITY, not settled; p = OracleHub.latest_price(ASSET); assert p > 0
    # payout_l = min(UNIT, p*UNIT//STRIKE); settlement_price = p; settled = True

@external @nonreentrant
def redeem_l(amount: uint256)   # settled; burn L; transfer _to_stable(amount * payout_l // UNIT)

@external @nonreentrant
def redeem_m(amount: uint256)   # settled; burn M; transfer _to_stable(amount * (UNIT - payout_l) // UNIT)
```
Getters: `L()`, `M()`, `STRIKE()` (=K), `MATURITY()`, `STABLE()`, `STABLE_DECIMALS()`, `ASSET()`, `settled()`, `settlement_price()`, `payout_l()`. `_to_stable(legs)` applies the 6↔18 scaling (round down).

### 3.2 `PutSeriesFactory.vy` — mirror of `SeriesFactory`

Line-for-line mirror of `SeriesFactory.vy`, keyed on **`(stable, K, maturity)`** (ASSET implicitly USD), with **one** new guard vs the call factory's open permissionlessness, and **the v1 collateral hard-gate**:

```vyper
@external
def create_series(stable: address, strike_k: uint256, maturity: uint256) -> address:
    assert stable == USDC, "v1 USDC-only"        # F-SPUSD-GATE: a single-address immutable, NOT a {USDC,spUSD}
                                                  #   allowlist. The spUSD variant is UNREACHABLE without a
                                                  #   different (separately-audited) factory — mirrors the
                                                  #   desks' `assert asset == empty(bytes32)` precedent.
    assert strike_k > 0, "zero strike"
    assert MIN_TERM <= maturity - block.timestamp <= MAX_TERM, "term"
    key: bytes32 = keccak256(abi_encode(stable, strike_k, maturity))
    # dedupe -> existing; else create_from_blueprint(PUT_SERIES_BLUEPRINT, HUB, stable, strike_k, maturity,
    #   TOKEN_BLUEPRINT, code_offset=3); record (is_put_series registry); log; return
```
`SeriesFactory`'s "any registered asset" model is unsafe here because the collateral is an arbitrary ERC20, not an oracle id — an arbitrary-token collateral (fee-on-transfer / malicious) breaks `M+L==amount`. `MIN_TERM`/`MAX_TERM` (1h / 5y) carry over from `SeriesFactory.vy:20-21`. **New contract, not an extended `SeriesFactory`** — keeps the proven call factory untouched and the dedupe-key change isolated.

### 3.3 `ShortQuoteFiller.vy` — the short RFQ desk (third sibling, generalized by subtraction)

Built as the **put twin of the dated `SeriesQuoteFiller`** (`leverage-menu-spec.md §3.3`), trading **M** instead of N. **Not** a verbatim copy of the rolling N desk: a standalone put series **never rolls**, so the rolling-tracker coupling that bricks a verbatim copy at deploy is *subtracted*, not kept (F-NOROLL). Deltas from `SignedQuoteFiller`:

| `SignedQuoteFiller` (rolling N desk) | `ShortQuoteFiller` (this spec) |
|---|---|
| `TRACKER` immutable + `ITracker` interface | **deleted** — `SERIES` (or `COLLATERAL` + per-series) immutable instead |
| `__init__` reads `ROLL_TRIGGER`, asserts `strike_proximity >= roll_trigger` (`:190-191`) | **delete both lines** (no tracker, no roll); `strike_proximity` a direct ctor param, asserted `>= SP_FLOOR and < UNIT` — a **sub-UNIT ceiling** because the band flips direction (M is worthless *at/above* K) |
| G3: `target = pending/active_series(); assert q.series == target` (`:292-295`) | G3 collapses to `assert q.series == SERIES` (one constant compare; vintage-safe — a dated short never rolls) |
| inventory primitive: ETH + N; `raw_call` ETH-out; payable `__default__` | inventory: **stable + M**; `IERC20(STABLE).transfer` out; **no payable `__default__`** (F-DEFAULT); `fund()`→`fund_stable()` |
| near-strike band refuses `x <= STRIKE*proximity` (M-of-N region) | band **flips**: refuses `p >= STRIKE*proximity` (M worthless at/above K; the active short region is `p < K`) |
| `NAME_HASH = keccak256("Gimbal Solo RFQ Desk")` | distinct `NAME_HASH = keccak256("Gimbal Solo RFQ Short Desk")` (F-DOMAIN) |
| `PRE_MATURITY_BUFFER` + permissionless settle is an edge case (series rolls away first) | **the NORMAL end-of-life** — a dated short *reaches* maturity; `operator_redeem_m` after `settled()` is the only wind-down (no merge-to-ETH or DAO redeem floor for a lone M holder) |

**Kept verbatim** (load-bearing): EIP-712 domain (recomputed, includes `self`, fork-safe `_digest`, cached + `CACHED_CHAIN_ID`), G1 (sig is the only fill authority), G2 (replay/deadline/taker, CEI nonce consume), G4 (tight `DESK_MAX_STALENESS` + `_assert_fresh`, including the F5 `answered_in >= round_id` completeness check, `SignedQuoteFiller.vy:265`), the directional floor + truncation-corner guard structure (G5), the size/inventory/outflow/float caps (G6), `@nonreentrant`. `Quote` **keeps `series`** (the short *is* per-vintage, unlike the single-token stable desk) so the digest/ABI stay shape-compatible.

```vyper
struct Quote:
    side: uint8        # SIDE_BUY_M (desk buys M, taker sells) | SIDE_SELL_M (desk sells M, taker buys)
    taker: address
    series: address    # exact PutOptionSeries vintage (bound into the sig); == SERIES
    amount: uint256    # M units (1e18)
    price: uint256     # STABLE wei per 1e18 M  (NOT ETH wei)
    min_edge: uint256
    nonce: uint256
    deadline: uint256
# NAME_HASH = keccak256("Gimbal Solo RFQ Short Desk")

@external @nonreentrant
def fill_buy_m(q, v, r, s) -> uint256:    # TAKER buys M == DESK SELLS M ; q.side == SIDE_SELL_M
    # NOT payable. Taker pays STABLE = floor(amount*price/UNIT) via transferFrom (approve first).
    # Source M from inventory or JIT split(need) funding the full 1 stable, keeping L; MIN_STABLE_FLOAT guard;
    # transfer M out; net_m[series] -= amount

@external @nonreentrant
def fill_sell_m(q, v, r, s) -> uint256:   # TAKER sells M == DESK BUYS M ; q.side == SIDE_BUY_M
    # Proceeds = floor(amount*price/UNIT) STABLE; pull taker's M (CEI: before paying); net_m[series] += amount
    # RECYCLE: mergeable = min(l_held, amount); if>0 merge(mergeable) -> STABLE oracle-free; net_m -= mergeable;
    # pay proceeds STABLE last
```
Views: `intrinsic_m(series) -> uint256` (STABLE wei per 1e18 M, 0 at/above K), `net_m(series) -> int256`, `quoter()`, `paused()`, `quote_digest(q)`. Owner-only (2-step ownership): `fund_stable(amount)`, `fund_l(series, amount)`, `withdraw_token(token, amount)` (collateral **or** M/L legs — **no `withdraw_eth`**, F-DEFAULT), `set_paused`, `set_quoter`, `set_caps`, `operator_merge(series, amount)`, `operator_redeem_m(series, amount)` (`assert ISeries(series).settled()`). `__init__(owner, series_or_collateral, hub, asset, stable, quoter, min_edge, desk_max_staleness, pre_maturity_buffer, strike_proximity, outflow_window, max_fill, max_net_at_risk, min_stable_float, outflow_cap)` — `assert asset == empty(bytes32)` (USD-only v1); `assert SP_FLOOR <= strike_proximity < UNIT`; distinct `NAME_HASH`. Deploy/test harness asserts `DOMAIN_SEPARATOR ≠` the N desk's and `≠` the stable desk's, and that an N/stable quote+sig reverts `"bad sig"` here.

## 4. Pricing + on-chain guardrails

Two layers, mirror of `solo-rfq-quoter-spec.md §4` and `SignedQuoteFiller._verify_and_guard`; only the priced object and the band direction change.

**Fair value — the short intrinsic, denominated in the collateral stable**, read **fresh** per fill (matches `PutOptionSeries.settle()` exactly):
```
p = OracleHub.latest_price(ASSET)            # ETH/USD, 1e18, single feed (USD-only v1)
intrinsic_m(p) = (p >= K) ? 0 : UNIT - p*UNIT//K     # == max(0, 1 - p/K), STABLE wei per 1e18 M
```
Mirror of `intrinsic_n(x) = max(0, UNIT - STRIKE*UNIT//x)` (`SignedQuoteFiller.vy:223`) — same formula with `p` and `K` swapping the roles of `x` and `STRIKE`.

**On-chain directional floor (G5), the only thing the chain trusts** — the filler independently recomputes `intrinsic_m` from its own fresh oracle read and rejects any quote more favorable to the taker than the floor:
- **Desk SELLS M** (`fill_buy_m`): `q.price >= intrinsic_m·(UNIT + q.min_edge)//UNIT` — sell dear.
- **Desk BUYS M** (`fill_sell_m`): `q.price <= intrinsic_m·(UNIT − q.min_edge)//UNIT` — buy cheap.

**Near-strike band, flipped (F-BAND).** The N desk refuses *at/below* strike (`x <= STRIKE·proximity`, where N intrinsic → 0). The M short is worthless *at/above* K, so the band refuses the **other** end: `assert p < STRIKE · STRIKE_PROXIMITY // UNIT` with `STRIKE_PROXIMITY < UNIT` (a sub-UNIT ceiling, e.g. `0.95e18`). Then `intrinsic_m > 0` by the band, and the **truncation-corner guard is kept verbatim**: `assert intrinsic_m · q.min_edge // UNIT > 0, "edge degenerate"`. Bind `STRIKE_PROXIMITY` so high-leverage tiers (K near spot from below) still have genesis headroom; pair with **leverage-scaled `MIN_EDGE`** on the higher tiers (F-EDGE from the menu spec — a flat 2× edge is free money at 10×).

**Tight staleness + the within-window-drift floor (F-DRIFT, ported).** The oracle is on the floor path ⇒ the same tight `DESK_MAX_STALENESS` gate the N desk runs (`_assert_fresh` off `ETH_USD_FEED.latestRoundData()`, independent of the hub's up-to-7-day heartbeat), copied **verbatim** including `answered_in >= round_id`. Because the M payout is leveraged ~`1/(1 − p/K)`, within-window ETH drift is amplified on the short just as on N — so launch `MIN_EDGE >= drift_budget × leverage` (launch ≥ 1% for the workhorse tier, larger for higher tiers), not a flat 0.5%. A stolen quoter key's worst case is bounded to `min_edge × MAX_FILL` per nonce, the per-window outflow budget, and `MAX_NET_AT_RISK` on inventory — with `set_paused`/`set_quoter` as instant kill switches.

## 5. Economics + leverage tiers

### 5.1 Leverage = f(K) (mirror of the call's `leverage = 1/(1−r)`)

For a live short the strike sits **above spot**: `k = K/p₀ > 1`. Genesis M-value (= premium paid) per unit `= 1 − p₀/K = (k−1)/k` stable. M's delta is `−1/K`, so **M's return per 1% ETH-down = `1/(k−1)` = the short leverage** — the exact mirror of the long's `spot/premiumPerN`. Cheaper premium ⇒ higher leverage, set entirely by `K`.

| k = K/p₀ | short leverage `1/(k−1)` | premium `(k−1)/k` (stable/unit) | M return per 1% ETH-down | tier role |
|---|---|---|---|---|
| 1.50 | **2.0×** | 0.3333 | 2.0% | conservative |
| 1.25 | **4.0×** | 0.2000 | 4.0% | **recommended launch workhorse** |
| 1.10 | **10.0×** | 0.0909 | 10.0% | gate behind tight caps |
| 1.05 | **20.0×** | 0.0476 | 20.0% | thin premium; smallest `MAX_FILL` |

Max loss = premium (M → 0 if ETH is flat/up at maturity), no liquidation, fully collateralized. Recommend launching **k = 1.25 (4×)** workhorse + **k = 1.5 (2×)** conservative; gate >10× behind tight caps (thin premium amplifies adverse selection and the truncation corner near the floor, exactly the F-EDGE/F-CEILING ceiling from the menu spec — the desk's 20% `MAX_MIN_EDGE` is the contract-level ceiling).

### 5.2 Carry — the M desk is the N desk's mirror, NOT the stable desk's

M is **long-put-like and decays**: the buyer pays theta (M's intrinsic bleeds to 0 as time passes with ETH flat/up). A desk that **warehouses M** sits on the **same negative-carry seat as the N desk** — it collects the spread but is net-long a decaying leg.

| | N desk | **M short desk** | spUSD stable desk |
|---|---|---|---|
| Warehoused leg | N (decaying) | **M (decaying)** | spUSD/P (premium-collecting) |
| Carry sign | **≤ 0** (theta) | **≤ 0 (theta)** | **≥ 0** (NAV accretes) |
| Bleeds when | ETH **falls** | ETH **rises** | (mild 1× short-ETH) |

The M desk does **not** offset the N desk's *carry* (both pay theta) — it offsets the N desk's *direction* (N loses ETH-down, M loses ETH-up): a **partial delta offset, not a carry offset, and NOT a hedge** (F-SHARED). Critically the two are **additive** in a crash if both are loaded the wrong way (see §9).

### 5.3 Sizing (~5 ETH-equivalent of USDC) and the honest verdict

Split a ~5-ETH-equivalent USDC book as **3 ETH-eq M-directional/inventory budget** (`MAX_NET_AT_RISK` = stable lost if ETH **rises** and M → 0) + **2 ETH-eq USDC float** (buy-M payouts, gas). Per-unit max desk loss on warehoused M = the genesis premium `(k−1)/k`, lost as ETH rises to strike:

| tier | premium/unit | warehouse cap before SELLS-ONLY (3 ETH-eq face) | per-fill cap |
|---|---|---|---|
| 2× | 0.3333 | 9.0 M-units | 0.30–0.75 ETH-eq risk |
| 4× | 0.2000 | 15.0 M-units | 0.30–0.75 |
| 10× | 0.0909 | 33.0 M-units | 0.30 (tight) |
| 20× | 0.0476 | 63.0 M-units | 0.30 (tightest) |

At the cap the on-chain guard flips to inventory-reducing (sell-M) only, mirroring the N desk. **Spread tables are identical to the N/stable desks** (`s = 2·min_edge` round-trip): launch `s = 2%` (min_edge 1%); `$30k/mo RT @2% → +$300`; tighten toward 1% with flow. With **USDC** the only risk axes are M-direction (ETH up) + theta; the stable face is hard, so the cap denominated in stable fully captures the risk (with spUSD there is an extra de-peg axis the cap would *not* capture — another reason for USDC v1).

**Honest verdict.** **Not a money-maker at bootstrap** — same economic shape as the N desk: a near-zero-cost capability/peg desk (off-chain signed quotes ⇒ ~$0 idle) that turns a **small bleed when ETH rises while M inventory is loaded** (short theta + adverse direction, capped at the 3-ETH-eq budget, a knowing bet on expendable capital). Milder than the N desk only in flow (crash-hedgers/bears may give more two-sided flow than pure leverage-longs). Money-maker only at sustained two-sided round-trip flow >~$30k/mo at 1–2% spread. Its real value is being the **first debt-free leveraged ETH short and the only venue to sell M** — a capability, not a yield product.

## 6. Confirmed findings + fixes

Every confirmed finding, folded into the design above:

| # | Title | Sev | Fix (folded in) |
|---|---|---|---|
| **F-SPUSD** | spUSD-collateral is **structurally sound** (`M+L==1` always; zero bad debt) but **economically unfaithful**: USD value `min(1, x/S_spusd)` under-delivers in the deep crash that is the short's whole purpose (100% above `S_spusd`; 80%/50%/20% at −20%/−50%/−80% once a fast crash punches the buffer). | med | **Ship USDC v1.** No code fix — the finding *validates* the decision. spUSD only as a phase-2, labeled, near-money, lower-leverage "soft short" after the live peg survives a real drawdown; the eventual spUSD quoter must price M against the live `share_price()`, not a static $1. Re-run the mirrored Halmos chain (§2.3) regardless of collateral. |
| **F-BUFFER** | The `min(1, x/S)` de-peg table is **optimistic** — the `eth_buffer` NAV slice has no floor, so spUSD de-pegs even **above** `S_spusd` (e.g. with 20% buffer: $0.90 at ETH=S, vs the table's $1.00). | low | Doc/model fix only (moot under USDC). Replace the static `min(1, x/S)` with the true `share_price(x) = [eth_buffer·x + Σ p_bal·min(x,S)]/supply` (`TrackerDAO.vy:271-278`); state the buffer drag `= f·(1 − S/x_ref)`; narrow the "100% faithful above `S_spusd`" claim. The phase-2 spUSD desk reads the **live** `share_price()` (as `StableQuoteFiller` already does), never a static table, and adds buffer drag to the amber warning. |
| **F-REALIZE** | Circularity is also a **payout-realizability** loop: in a crash, mass M settlement → wave of spUSD redeem/dump → `eth_buffer ≈ 0` so redeemers get illiquid P + pool slippage < already-de-pegged NAV. | low | No protocol insolvency (redeem is pro-rata, doesn't move `share_price`; base `P+N=1` ETH layer holds) — so no v1 code change. Document in the phase-2 spUSD disclosure that the M buyer eats de-peg **plus** exit slippage/illiquidity. Reinforces USDC v1. |
| **F-RESCUE** | Both proposed spUSD rescues fail: K-cap is **backwards**; over-collateralization haircut is **unbounded** (`OC = S_spusd/p_floor` → ∞). | med | Keep the conclusion; two precision tweaks to the write-up (done in the banner): correct OC to `S/p_floor` (10× at a crash to 10% of S, 100× at 1% — not 5×/50×); state K-cap mechanism = forfeiting the `[S_spusd, K)` 100%-faithful slice. No code change — validates USDC v1. |
| **F-DEC** | USDC's 6-dec `//1e12` adds a **second division** the wei-exact ETH call never had; naive/ceil rounding can redeem **more than was locked**, breaking no-bad-debt at the token boundary; not covered by the 18-dec Halmos. | med | Scale legs in 1e18, convert stable on the boundary **rounding down** (`out6 = out18 // 1e12`); retain sub-unit dust. Add a dedicated Halmos pass that the redeem pair never returns more stable than locked (§2.3). |
| **F-FREEZE** | USDC freeze/blocklist can brick `redeem`/`merge`; there is **no oracle-free ETH exit** to fall back to (unlike the spUSD leg's `redeem()`). | low | Accept + disclose as the external-dependency cost of a faithful short (the banner names it). Uncorrelated to the ETH bet. Document the mainnet issuer/freeze-risk disclosure for the Short tab; use a canonical Sepolia test-USDC. No mitigation pretends this away. |
| **F-BAND** | The near-strike band must **flip** (M intrinsic lives **below** K, not above); a verbatim copy of the N desk's band would let the desk sell M near-free at/above strike. | med | `__init__`: drop the `ROLL_TRIGGER` read / `>= roll_trigger` assert; `assert SP_FLOOR <= strike_proximity < UNIT` (default ~0.95e18). G5: `assert p < STRIKE * STRIKE_PROXIMITY // UNIT, "near strike"`; compute `intrinsic_m = UNIT - p*UNIT//K` (>0 by the band); **keep** the truncation-corner guard. Halmos: ∀ p passing the band, `intrinsic_m > 0 and intrinsic_m*min_edge//UNIT > 0`. |
| **F-SPUSD-GATE** | No on-chain guard forbids spUSD collateral in v1 — one config entry could ship the unsound variant behind only the UI gate. | med | `PutSeriesFactory.create_series` asserts `stable == USDC` (a single immutable address, **not** a `{USDC,spUSD}` allowlist), mirroring the desks' `assert asset == empty(bytes32)` precedent (`SignedQuoteFiller.vy:181`). The spUSD variant is unreachable without a different, separately-audited factory. Keep the frontend amber gate as defense-in-depth, never the only barrier. |
| **F-NOROLL** | A standalone short never rolls; `settle()` fixes `payout_m` forever (holders self-roll), and the N desk's G3 binds to a `TrackerDAO` that does not exist — a verbatim copy **bricks the desk at deploy**. | med | Build `ShortQuoteFiller` as the put twin of `SeriesQuoteFiller` (§3.3): `SERIES` immutable replaces `TRACKER`; delete the `ROLL_TRIGGER` staticcall + `strike_proximity >= roll_trigger` assert; G3 → `assert q.series == SERIES`; keep `PRE_MATURITY_BUFFER` + permissionless `settle()` + `operator_redeem_m(... assert settled())` as the **normal** expire-and-redeem end-of-life. Strike the "G3 KEPT / reused verbatim" wording. Deploy/test assertion: the short desk needs no `TrackerDAO`. |
| **F-DEFAULT** | ERC20 collateral has no ETH callback, so the payable `__default__` + `withdraw_eth` the call/N-desk carry are wrong here; a transfer hook / fee-on-transfer token can re-enter and break equal-mint conservation. | low | **No payable `__default__`, no `withdraw_eth`** on `PutOptionSeries` or `ShortQuoteFiller` (resolve the Pass-1 vs later contradiction in favor of removing them). Keep `withdraw_token` for collateral + M/L legs; rename funding `fund_stable`; keep `@nonreentrant` + strict CEI. The factory's non-rebasing/non-fee pin (F-SPUSD-GATE allowlist logic) — not the fallback — is what protects `M+L==amount`. Deploy/test assertion: no payable receive path. |

## 7. How it plugs in

### 7.1 Routing — the short leg is RFQ-ONLY with NO fallback (strictest leg)

Extend `solo-rfq-routing-spec.md` with two short rows. The short is **more constrained than sell-N**, which is already the most constrained leg — state this bluntly in the UI:

| Trade | RFQ desk | Pool | Mint / fallback | Router behavior |
|---|---|---|---|---|
| **Buy M** (open short) | desk SELLS M (`fill_buy_m`) | **none — no M pool** | short-`split` (operator/advanced only) | **RFQ only.** Capped/down → "no desk quoting this short / smaller / wait." Never imply a pool. |
| **Sell M** (close short) | desk BUYS M (`fill_sell_m`) | **none** | **none usable by the taker** | **RFQ only, NO fallback whatsoever** — strictly the sell-N situation, and *worse*. |

Why short is the strictest leg: (1) no M pool (we must not build one — it would re-create the pooled-buyer surface we killed and M decays like N); (2) the mirror `merge` does **not** give a lone M holder an exit — it needs a *matched* M+L holder and returns the **stable, not ETH**, and there is **no short-side DAO** issuing a redeemable share, so unlike spUSD-sell there is **no `redeem()` floor**; (3) no JIT mint-to-buy for the taker until an **L-sink** exists (the L the desk would dispose of has no pool — the short-side analog of the stable desk's "never mint-to-sell"). There is only one venue, so the cross-venue best-ex normalize step is a no-op for M — render the RFQ quote + its edge vs `intrinsic_m(series)`. Capacity hints from `max_fill`/`net_m`/`max_net_at_risk`; treat the quoter's `over-max-fill`/`inventory-full`/`near-strike`/`near-maturity`/`series-settled` as truth.

### 7.2 Frontend — a Long↔Short toggle on the Leverage tab (not a new tab)

Keep the three-role nav (`Hold · Leverage · Provide`); **Leverage** becomes bidirectional. **Long** (default) = `leg:"N"` + `LeverageRouter`, unchanged. **Short** (new) = `leg:"short"` desks grouped by strike (already the P2 strike-menu shape — building it here pre-populates P2). Mirror the payoff diagram (USD return that rises as ETH falls; an **upper** breakeven; leverage `= spot/premiumPerM` and `K`). Reuse the **max-loss = premium** framing verbatim (literally true for M). Reuse the **operator-quoted trust label verbatim**: *"Operator-quoted desk. Your counterparty is 0x… (the operator), not the Gimbal protocol. Quotes are signed off-chain and filled at a price floored on-chain."* Cross-check on-chain `quoter()` vs `operatorDesks.json`; unlisted series → the unverified-peg gate; disable the Short toggle with honest copy when no desk is listed. New EIP-712 domain `"Gimbal Solo RFQ Short Desk"`; the frontend submits `v,r,s` from `/short`, never signs. **Collateral honesty badge** (NEW, required): `collateral:"USDC"` → neutral "USDC hard short"; the phase-2 `collateral:"spUSD"` → a **non-suppressible amber gate** before the first fill ("pays in spUSD, which can be < $1 in a fast crash — NOT hard USD protection").

Funding direction (frontend branches on `collateral`): **Buy M** → `approve(desk, cost)` on the stable, then `fill_buy_m` (NOT payable in v1). **Sell M** → `approve(desk, amount)` on the M token (`ISeries(series).M()`), then `fill_sell_m`; desk pays the stable.

### 7.3 `operatorDesks.json` — a third `leg`, keyed per series

`leg` gains a third value `"short"` (`"put"` accepted as a loader synonym; canonical string `"short"`). Unlike N/spUSD (per-tracker), the short leg is **per-series** — the entry carries `series`, `collateral`, `strike`, `maturity`:

```json
{ "tracker":"0x80A2…4FAE", "leg":"short", "series":"0x<PutSeries-K>", "desk":"0x<ShortQuoteFiller>",
  "operator":"0x…", "quoterPubkey":"0x…", "quoterUrl":"https://…/short", "assetSymbol":"spUSD",
  "collateral":"USDC", "strike":"<K,1e18>", "maturity":<unix>, "label":"ETH short desk (K=…)", "sinceBlock":9012 }
```
Frontend keys short desks by `(tracker, series)`, groups by strike. **Separate quoter keys per leg/series** (blast-radius isolation — a leaked `/short` key cannot touch N or spUSD inventory).

### 7.4 Coexistence + compose with P2/P3

A **fourth independent desk** (separate funds/caps/pause/quoter, no on-chain coupling — a drain/pause of one touches none). But **F-SHARED applies with full force**: the short desk's risk is on the **same ETH axis** as N/spUSD (net-long-L ≈ capped-long-ETH; net-long-M ≈ leveraged-short-ETH + theta), so it is **additive, not hedging**. Allocate the shared reserve across N + spUSD + short (don't apply the full per-desk "3+2 ETH" table to each); set short caps **smallest** until two-sided short flow appears.

- **P2 (strike menu):** the short series is born per-strike with a `series`/`strike` entry and a group-by-strike Short view — that *is* the P2 strike-menu shape pre-populated. v1 ships **one** short strike; P2 lights up the rest with no new Short-UI work, and the menu's `Tier.is_put` discriminator (`leverage-menu-spec.md §3.1`) already routes put series through the same registry/keeper.
- **P3 (writer vault):** the short desk is the **M-writing venue** the crowdsourced writer vault funds — the vault holds **stable** collateral (mirror of holding ETH for calls), short-`split`s to mint M + L, sells M here, warehouses/disposes L. Built funder-agnostic so P3 drops in as an ownership/config change, not a rewrite. P3 stays gated on P1+P2 live with real flow.
- **No `TrackerDAO` change.** The short is a standalone primitive — not wrapped by a soft-peg DAO (no tracking leg to warehouse, no roll), which *simplifies* the desk's vintage handling vs the N desk. (If/when the spUSD soft short ships, the put series simply locks the spUSD ERC20 — which *is* the TrackerDAO address — via `transferFrom`, identical plumbing to USDC with scale factor 1.)

## 8. Components to build — v1 checklist vs phase 2

**v1 (minimal launchable short, USDC-only, one strike, single quoter, tiny caps):**
1. `PutOptionSeries.vy` + `OptionToken` legs (M/L) — ERC20-pull `split`, `transfer`-out merge/redeem with return checks, the mirror `settle` (pin `payout_l`, M = exact remainder), USDC 6-dec normalization rounding **down** (F-DEC), **no payable `__default__`** (F-DEFAULT), `@nonreentrant` + strict CEI.
2. **Halmos lemma chain** mirroring `test/Halmos.t.sol` (`x→p, S→K, P→L, N→M`) + the new 6-dec boundary pass (§2.3) — a **ship gate**.
3. `PutSeriesFactory.vy` — blueprint, dedupe on `(stable, K, maturity)`, `is_put_series` registry, **`assert stable == USDC`** (F-SPUSD-GATE).
4. `ShortQuoteFiller.vy` — `fill_buy_m` + `fill_sell_m`; G1/G2 (CEI nonce) + tight `DESK_MAX_STALENESS`/`_assert_fresh` verbatim (G4) + **flipped** near-strike band + directional floor + truncation corner (G5, F-BAND) + `MAX_FILL`/`MAX_NET_AT_RISK`/`MIN_STABLE_FLOAT`/outflow (G6); `SERIES` immutable (no tracker, F-NOROLL); distinct `NAME_HASH`; stable inventory/floats; **no payable `__default__` / no `withdraw_eth`** (F-DEFAULT); 2-step ownership; `operator_merge`/`operator_redeem_m`.
5. Deploy/test EIP-712 separation harness: short `DOMAIN_SEPARATOR ≠` N's and `≠` stable's; an N/stable quote+sig reverts `"bad sig"`; off-chain digest reproduces `quote_digest(q)` byte-for-byte; assert the desk needs no `TrackerDAO`.
6. Fork tests vs canonical Sepolia USDC + the live `OracleHub`/`ETH_USD_FEED` (the ERC20-transfer-out path is a real delta vs the call's `raw_call`).
7. Short **quoter service** (`/short`) — `fair = intrinsic_m(series)` in USDC units (v1 may assume hard $1), depletion/inventory skew, leverage-scaled `min_edge` (F-EDGE), `over-max-fill`/`inventory-full`/`desk-paused`/`near-strike`/`series-settled`/`near-maturity` errors; startup self-check vs on-chain `quoter()`; short TTL.
8. `operatorDesks.json` `leg:"short"` + `collateral`/`series`/`strike`/`maturity`; Short toggle + mirrored payoff + collateral badge + trust label + unlisted-series gate; RFQ-only routing (no pool/merge/redeem fallback for M).
9. "Sepolia testnet, research code, unaudited; operator-quoted; max loss = premium, no liquidation" on every short surface.

**Phase 2:**
- **spUSD-collateral soft short** behind its **own separately-audited factory** (the `assert stable == USDC` gate is immutable): a de-peg-aware quoter pricing M against the live `share_price()` not $1 (F-BUFFER), conservative near-money K + lower leverage inside the peg's safe band, the non-suppressible amber gate, gated on the live peg surviving a real drawdown. Optionally a **bounded-haircut** rung (honestly disclosed as still failing the deep tail). A **USDC-default / spUSD-opt-in hybrid** is the end state — one blueprint, two collateral variants per asset, `collateral` discriminator in the JSON.
- **P2** multiple short strikes per peg (the group-by-strike Short view already renders them); **multi-series `ShortQuoteFiller`** with global caps if flow justifies.
- **L-sink / `ShortLeverageRouter`** (a mint-to-buy route that atomically disposes L) — until then mint-to-buy stays operator-only and buy-M is RFQ-only.
- Shared F-DRIFT hardening (quoter signs `x_sign`, assert `|p_fill − p_sign| ≤ max_dev`; per-fill mark-to-true-`p` PnL); rotatable multi-key quoter; on-chain `OperatorDeskRegistry` enumerating all four legs; on-chain best-ex router.
- **P3** writer-vault as the M-writing funder.

## 9. Honest risks + bottom line

- **The short bleeds when ETH rises** while M inventory is loaded (short theta + adverse direction), capped at the ~3-ETH-eq budget — a knowing bet on the operator's expendable capital, the N desk's economic mirror. **Not a yield product.**
- **The short leg has no fallback exit** (§7.1): a lone M holder cannot `merge` (needs matched L) and there is no DAO `redeem()` floor — sell-M is RFQ-only, and if the desk is capped/down it is *unavailable*. The UI must say so and never imply a pool/merge/redeem exit.
- **spUSD-collateral, if ever shipped carelessly, sells protection that evaporates in the tail** (F-SPUSD/F-BUFFER/F-REALIZE). v1's on-chain `assert stable == USDC` (F-SPUSD-GATE) plus the separately-audited phase-2 factory make the unsound variant unreachable by config; do not weaken either.
- **USDC is an external dependency** (issuer freeze/blocklist can brick redeem/merge with no oracle-free fallback, F-FREEZE) — uncorrelated to the ETH bet, the right price for a faithful short, but real and disclosed.
- **USDC 6-dec rounding** must always favor the contract (F-DEC) — the second division is the one place no-bad-debt can leak; it gets its own Halmos pass.
- **Stolen quoter key** is bounded by the directional floor + `MAX_FILL` + per-window outflow + `MIN_STABLE_FLOAT`, with `set_paused`/`set_quoter` as instant kill switches — bounded griefing of liquidity on expendable capital, never theft of retail funds.
- **Shared-capital correlation** (F-SHARED): the short desk's risk is additive with the N/spUSD desks on the ETH axis, not a hedge — allocate the reserve, size short caps smallest until flow.
- **The conservation guarantee is unconditional and the only thing the chain enforces**: `M + L == 1 stable` for every ETH price, no liquidation, max loss = premium — re-proved in Halmos before ship.

**Bottom line.** The debt-free leveraged short is the **exact algebraic mirror** of the deployed call: lock 1 stable → mint M + L, settle reading `p = ETH/USD` vs strike `K`, with `M = max(0, 1 − p/K)` (the leveraged short, gains as ETH falls, max loss = premium, no liquidation) and `L = min(1, p/K)` (the capped-long complement). Conservation `M + L = 1 stable` re-proves identically to the Halmos `P+N` chain — `payout_m = 1e18 − payout_l`, zero drift, no bad debt — under **any** collateral. The whole design is `OptionSeries` with two substitutions (ERC20 stable in place of native ETH; the settle comparison flipped) plus a fourth RFQ desk that generalizes the N/stable skeleton by subtraction. The **central decision is resolved: ship v1 on USDC**, hard-asserted on-chain — spUSD is structurally sound but under-delivers USD in the exact crash tail the short exists to cover, a tail-correlation hole that K-capping and bounded over-collateralization cannot close; it returns in phase 2 as a labeled, conservatively-struck "soft short" once the peg is battle-tested, with a USDC/spUSD hybrid as the end state. **Sepolia testnet, research code, unaudited; options not debt — no liquidation, no margin, fully collateralized by construction.**