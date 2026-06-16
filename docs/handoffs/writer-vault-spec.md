# Gimbal P3 — Crowdsourced market maker (option-writing Earn vault) (spec)

> **⤳ Unified into [`autonomous-vault-spec.md`](autonomous-vault-spec.md)** — the crowd-owned immutable end-state folds this in. This doc stays the detail for its piece; the master holds the architecture + the **GO/NO-GO** (prove demand on the *pausable* operated desks first, then freeze immutable — immutability is a one-way door).

> Build spec, not a sketch. An **epoch-locked, ERC-4626-ish pooled "Earn" vault** that is the
> **backing capital** for Gimbal's already-built signed-quote desks. LPs deposit collateral; the
> desks **WRITE** the N (leverage-long / call) and — once P1 lands — M (leverage-short / put) legs
> that buyers purchase. LPs collect the **premium up front** and are the **short-vol counterparty**:
> they are paid only when a trader's bet wins, are **never liquidated**, and **can never lose more
> than they deposited**. NAV/share accounting, a 7-day deposit→trade→settle epoch, withdrawal locks
> while collateral backs open writes, conservative marks, and a ~0.5% fee.
>
> This is **P3** of `split-derived-roadmap.md`. It **depends on P1 (the stable-collateralized
> PUT/short series + short desk) and P2 (the strike menu) being LIVE WITH REAL TWO-SIDED FLOW** —
> neither exists in `src/` today, so most of this spec is gated, and §8 ends with an explicit
> GO/NO-GO that is currently **NO-GO**.
>
> **Sepolia testnet, research code, unaudited. BETA — a public POOLED TRADING FUND. LPs are short
> volatility: you CAN lose principal ("winners are paid from the pool"). Capped at your deposit;
> never liquidated; can never go negative. Not a deposit, not a stablecoin yield, not a guaranteed
> rate. Securities/fund optics — honest framing is load-bearing, not a footnote.**

## ⚠ Why this is SOUND where the crowd-vault was KILLED — the carry sign is FLIPPED (and where it still isn't)

`mm-vault-spec.md` died on **29 findings, 3 clusters**, with an explicit verdict: *do not build a
retail "Earn" product that pools the **long-N (decaying)** side.* This vault is the **reframe that
same red-team pointed at** (`mm-vault-spec.md:39-44`): **pool the premium-COLLECTING (writer) side,
not the decaying side.** Mapped cluster by cluster, and grounded in the real contract:

1. **Cluster 3 — THE KILLER, flipped to the good side (confirmed in code).** The killed vault was
   *net-long the decaying N leg → short theta → it PAID carry*: it warehoused the losing side and
   foisted it on retail (the disproven *"relocate the orphan into an unwilling warehouse"*). This
   vault **WRITES** the option the buyer buys. Confirmed against `SignedQuoteFiller.fill_buy_n`
   (lines 369-381): to sell a buyer N the desk calls `OptionSeries.split(value=need)` — which locks
   `need` ETH and mints `need` **P AND** `need` N to the desk — then **transfers the N to the buyer**
   (line 381) and **keeps the P** (`net_n[series] -= amount`, line 380, so the desk goes
   net-**SHORT** N). The pool ends up **long P + the buyer's premium, short N** = the **writer /
   short-vol** position. P is exactly the index-tracking, premium-collecting leg the DAO itself holds
   (`TrackerDAO` holds only P, never N) and that `stable-rfq-spec.md` proved is positive-carry. **The
   decaying N goes to the buyer.** The carry sign is reversed from `≤ 0` to `≥ 0`. This is structural,
   not cosmetic.

2. **Cluster 1 — symmetric price BAND wrong → DIRECTIONAL vault-favorable edge FLOOR (the PRICE is
   inherited; the LOSS-SIZE cap is NOT — see F-WRITER-CAP).** The killed vault's ±X% band "licensed a
   continuous within-band drain." This vault does **not** quote; it lends inventory to the existing
   desks, and every write/buyback crosses the desk's on-chain `intrinsic·(1±min_edge)` floor
   (`SignedQuoteFiller` G5, lines 312-324), re-derived from a fresh oracle read per fill, surviving a
   stolen quoter key. **But the directional risk *cap* is not inherited:** the desk's only size cap,
   `max_nav_at_risk`, fires only on the `proj_net > 0` (net-LONG-N) branch (lines 365-367, 411-414).
   When the desk is net-SHORT N — the writer position the vault deliberately runs — that cap is
   **skipped entirely.** So the floor (price) is reused for free; the writer loss-size cap must be
   **built new** (F-WRITER-CAP). Do not market this as "cluster 1 inherited for free."

3. **Cluster 2 — deposit/withdraw oracle + JIT NAV/share arb → epochs + conservative marks +
   withdrawal locks (mitigated, NOT deleted — see F-MARK-DRIFT, F-CARRY-MARK).** The killed vault
   read the live oracle on the deposit/withdraw NAV path and could be JIT-sandwiched. This vault:
   (a) **epochs** the lifecycle so deposits/redemptions are *requested* in a window and priced at an
   epoch-boundary NAV, never at a hot pokeable instant; (b) **marks open written exposure
   conservatively** (the pool under-marks itself while writes are open); (c) **locks redemptions**
   while collateral backs open writes. The honest residual: because the series mature on the DAO's
   roll cadence (~28-day rolling / dated tiers), **not** the 7-day epoch, an epoch routinely closes
   with *open* positions that must be **oracle-marked** at the boundary — so the live oracle is on the
   withdraw price path through the back door. This is mitigated by conservative two-sided marking +
   haircut + paying redemptions oracle-free from `free_collateral`; it is **not "deleted."**

### The categorical improvement claim — and exactly where it does NOT hold (v1)

The intended improvement over the killed *one-sided* version: write **BOTH** the N/call leg
(against ETH) **and** the M/put leg (against spUSD, from P1). Writing calls is short-upside; writing
puts is short-downside. **Under two-sided buyer flow the pool is short-vol on both sides but roughly
DELTA-BALANCED** — earning spread + premium with bounded directional risk. **This is a v2 property,
gated on P1.** P1 (the put/M series + short desk) **does not exist in `src/` today** — there is no
`MShort`/put `OptionSeries`/`payout_m` contract. So **v1 is CWV-only (calls only) = a one-sided
short-call book**, which is the **mirror of the killed vault's directional bet** — same risk shape,
betting the other direction, differing only in carry sign and per-epoch capping. The
**StableQuoteFiller is the spUSD-token (positive-carry dollar) desk, NOT the put writer** — funding
it does not make the book two-sided. Until P1 is live with flow, the **honest v1 framing is
"one-sided directional short-vol bet, bounded by the new writer cap, capped at deposit, never
liquidated"** — and the correct interim venue remains the **operator-funded solo desks** (their own
capital, their own bag).

### The residual, disclosed loudly (not hidden)

It is **still short-vol.** When buyers win big (a sharp ETH move through written strikes), the pool
**pays the winners out of LP collateral** — LPs **can lose principal.** What is structurally true and
load-bearing: every written leg is **fully collateralized at write time** (`P + N == 1 ETH` by
construction, Halmos-proven; the M/put leg stable-collateralized to its max payout), so LPs are
**never liquidated** and an LP **can never lose more than their deposited share.** This is the honest
Split "Beta — you can lose principal" posture, made precise.

---

## 1. What it is

The architecture question — **one vault holding two collateral kinds, vs two segregated vaults, vs a
manager that owns the desks** — is settled here (the embedded facet designs disagreed; F-ARCH):

- **Topology: TWO segregated vaults, one per collateral family** (mirroring Split's "Deposit WETH" /
  "Deposit USDC"), NOT one contract commingling ETH and spUSD. A written **call/N** owes ETH as ETH
  *rises* → back it with **ETH/WETH**. A written **put/M** owes ETH-value as ETH *falls* → back it
  with **spUSD** (the P1 unlock). Collateral asset, NAV unit, withdrawal asset, and risk axis all
  differ, and segregation isolates blast radius (the `stable-rfq-spec.md` F-SHARED lesson). Cross-leg
  delta-balance is achieved at the **portfolio** level (an LP holds both; or a phase-2 paired-deposit
  helper) — not by mixing collateral in one contract.
  - **CWV — Call Writer Vault:** deposits/NAV in **WETH (ETH)**, writes **N** via `SignedQuoteFiller`.
  - **PWV — Put Writer Vault:** deposits/NAV in **spUSD**, writes **M** via P1's short desk. **STUB
    until P1 ships and is Halmos-proven.**

- **Coupling: the vault is the desks' BALANCE SHEET, not a new trading venue and not a custodian of
  user trades.** Buyers keep trading the unchanged, already-built desks (same EIP-712 quotes, same
  `fill_*`, same G1-G6 floor, same `_assert_fresh` gate, same stolen-key bound). The **only** new
  hot-path coupling is a minimal `IVaultBacked` extension: when a desk's `funding_source` is a vault,
  it draws its split collateral from the vault and routes the buyer's premium + the kept P back to the
  vault, atomically, inside the desk's existing CEI fill (§2). The vault adds **no pricing**; it
  enforces caps + epoch-window + a conservation check. (The alternative — VaultManager *owns* the
  desks and funds them via `fund()`/`withdraw_eth()` — is **rejected** because the desks' owner has an
  uncapped `withdraw_eth` (line 480) with no timelock; making a contract that holds pooled LP ETH the
  owner re-creates a single-key rug surface the solo desks never had. See F-OWNER-RUG.)

- **Epoch-locked** (Split pattern): a 7-day **DEPOSIT → TRADE/WRITE → SETTLE** cycle. Deposits and
  redemption *requests* are queued in the deposit window and priced at the next epoch boundary;
  collateral is locked as writing inventory through the trade window; redemptions clear at settle once
  the backing is freed.

- **Fee ~0.5%, performance-only** — charged at `harvest()` on positive harvested premium, so it never
  skims principal in a down epoch.

- **Never liquidated, capped at deposit** — inherited from the P/N primitive: `split()` locks 1 ETH
  and mints 1 P + 1 N (`OptionSeries.split`, lines 153-162), `P + N == 1 ETH` always (Halmos
  `check_splitFullyCollateralized`/`check_splitMergeExact`). The vault's worst case is "all written
  options finish max-ITM for buyers" = it pays the buyers and LPs eat the loss down to (never below)
  zero.

## 2. Vault mechanics — epochs, NAV, locks, fee, and how the writing works

### 2.1 The writing mechanics (the heart)

To *write* one N unit, the vault-backed `SignedQuoteFiller.fill_buy_n` does what it already does for
the operator today, but sourced from the vault:

```
pool locks 1 ETH (split)  →  desk mints 1 P + 1 N  →  desk sends N to the buyer, keeps P
buyer pays premium ≈ intrinsic·(1+min_edge)  →  pool now holds P + premium, is short N
at settle:  P pays the pool payout_p ETH ;  buyer's N pays (1 − payout_p)
pool economics per unit  =  premium + payout_p − 1  =  premium − (1 − payout_p)
                         =  (what the buyer paid) − (what the buyer's leg was worth)
                         =  the floor edge + the time-value the buyer overpaid − losses if N finishes deeper ITM than the premium
```

Positive expected value precisely because every write crosses the desk's vault-favorable floor. The
vault **never** calls `TrackerDAO.deposit()` (which hands back the N leg at `TrackerDAO.vy:343` — the
F-ORPHAN trap); it writes via `split()` and routes the N out, keeping P. Buybacks recycle oracle-free
via `merge()` (`OptionSeries.vy:167`); settlement harvests via `settle()` + `redeem_p` (lines 182-213),
oracle-free after settle.

### 2.2 `IVaultBacked` — the only new coupling

A vault exposes exactly two desk-facing functions, callable **only** by a registered desk, and the
write is made **atomic and conservation-checked** so the kept-P is provably vault-owned (F-CONSV):

```
draw_collateral(amount, kind)                       # desk pulls ETH(kind=N)/spUSD(kind=M) to split; books collateral_locked += amount, written_{kind} += amount (effects before transfer, CEI)
route_premium(premium, claim_token, claim_amount, series)   # desk pushes premium + the kept P INTO the vault; vault verifies claim_token is the genuine P of `series` AND claim_amount == amount drawn, then books premium_collected, claim_held[series]
```

- `draw_collateral` asserts: `msg.sender` is a `registered_desk`; epoch is in **TRADE**; the
  per-kind **directional write cap** is not exceeded (`written_N + amount ≤ epoch_write_cap_N`);
  `free_collateral − amount ≥ MIN_RESERVE` and `≥ redemption_reserve` (the never-lent slice, §2.4).
- `route_premium` is the **conservation gate**: it `transferFrom`s the kept P and asserts it is the
  genuine P of `series` and `claim_amount == amount drawn`, verified against the **received delta**
  (not `balanceOf`, so operator-donated P can't spoof it). A premium cannot be routed without
  depositing the fully-collateralized claim that backs the payout. The whole draw+split+route is
  one atomic, revert-all-or-nothing sequence (single vault orchestration entrypoint), so the vault is
  never left with `collateral_locked` incremented but `route_premium` unexecuted.
- The desk's own G1-G6 floor still runs on every fill. A compromised desk *quoter* can't make the
  vault write below the floor (the desk reverts first); a compromised desk *contract* is bounded by
  `epoch_write_cap_*`, `MIN_RESERVE`, the per-epoch outflow, and the conservation check, and is
  removable via `set_desk(desk, False)`.
- **Vault desks are WRITE-ONLY (F-SELLN):** `fill_sell_n` (the desk *buying* N from a seller, which
  *retains net-long N* beyond available P — the killed warehouse pattern) is **disabled** when
  `funding_source` is a vault. The vault is a writing venue, never the buy-N-of-last-resort. Holders
  who want to sell N use the operator's own solo desk.

### 2.3 NAV / share — conservative, epoch-anchored (resolves cluster 2)

NAV (collateral units) is marked so the vault always slightly **under-values itself while writes are
open**. The identity (corrected per F-NAV-IDENTITY — the embedded facet double-counted the locked
ETH against the kept-P claim):

```
NAV = free_collateral
    + collateral_locked                          # FACE VALUE; recovery guaranteed by P+N==1 (locked ETH = kept-P + buyer's-N at settle)
    + premium_collected_this_epoch               # cash the pool already holds (face)
    − Σ_series  open_written_liability(series)    # = Σ payout_n, marked at conservative WORST CASE for the pool
```

Crucially, `collateral_locked` is counted **once** (as face value) and the open written short is
marked at its **liability** `−payout_n` (haircut up toward worst case), **not** as a second
full-notional subtraction. The kept-P is the *other half* of `collateral_locked`; counting both the
locked ETH and a separate `claim_held·mark` term double-counts. Net effect per open written unit: NAV
drops by **at most `(1 − premium)`** (≈ 0.6 ETH at the 2.5× tier), never the full 1.0, and `nav()`
can never underflow. **Invariant to test/prove:** opening a fully-collateralized write changes NAV by
at most `−(1 − premium)` per unit — the pool always retains the premium.

- **Conservative bias.** Before settle, mark the short at worst-case `payout_n` (assume the buyer's
  leg finishes maximally ITM) with a small `MARK_HAIRCUT` (1-2%), and on the deposit side mark the
  asset conservatively too (F-MARK-DRIFT), so a keeper-chosen fresh print can only move boundary NAV
  *against* the transactor, never in their favor. After `settle()`, mark at the exact oracle-free
  `payout_p` — no oracle, no arb.
- **Epoch anchoring.** Deposits/redemptions are priced at the **boundary NAV**, computed once per
  epoch in `settle_epoch()`. Intra-epoch `nav()` is **display-only** and never the transaction price.
- **Freshness.** Every oracle read on the mark path runs the desks' tight `DESK_MAX_STALENESS` gate
  (`_assert_fresh`, identical to `SignedQuoteFiller.vy:253-267`), independent of the hub's 7-day
  heartbeat. v1 is **USD-only** (`assert asset == empty(bytes32)`) and asserts the tracker's oracle
  wiring matches (the `stable-rfq-spec.md` F6 fix).
- **First-depositor bootstrap.** Same `DEAD_SHARES` pattern as `TrackerDAO.deposit` (lines 347-350):
  mint `DEAD_SHARES` to a dead address on the first deposit; `assert value_in > DEAD_SHARES`.

### 2.4 Epoch lifecycle + withdrawal locks

| Phase | Window | Allowed | Locked |
|---|---|---|---|
| **DEPOSIT** | first `DEPOSIT_WIN` (~24h) | `request_deposit`/`request_redeem` queue | desks **cannot** `draw_collateral` |
| **TRADE / WRITE** | until `EPOCH_LEN − SETTLE_WIN` | desks `draw_collateral` + `route_premium`; buybacks; **no deposits/redemptions priced** | queued requests wait; lent collateral locked |
| **SETTLE** | last `SETTLE_WIN` (~24h) | `settle_epoch()` settles/marks, fixes boundary NAV, mints queued shares, pays cleared redemptions, accrues fee | new writes blocked |

- **`request_redeem(shares)`** escrows shares to the vault. At the boundary, redemptions pay **only
  from `free_collateral`**, capped per epoch by `MAX_REDEEM_FRACTION` (~25%); the remainder rolls
  forward. A bank-run therefore can't force the desk to unwind written positions at a loss (R4).
- **Bounded exit (F-LOCK-UNBOUNDED).** The naive lock can trap LPs for an *unbounded* number of
  epochs in exactly the stressed/one-sided regime where they most want out (illiquidity peaks when
  losses peak — the classic short-vol death spiral). Two fixes: (1) **bound write tenor to the epoch**
  — `draw_collateral` only writes series whose `MATURITY ≤ current_epoch_end`, so locked collateral
  is always freeable at the epoch's own settle (converts "wait for arbitrary maturity" into "wait at
  most one epoch"); and (2) a **never-lent `redemption_reserve`** = `MAX_REDEEM_FRACTION` of NAV that
  `draw_collateral` may never touch, guaranteeing one epoch's redemptions always clear. Disclose the
  residual honestly: in stress, exit can still take multiple epochs and NAV may fall while locked.
- **`settle_epoch()`** (permissionless, in SETTLE): for each open series, if matured → `settle()` then
  `redeem_p` (oracle-free); else mark conservatively and carry. Then compute boundary NAV/share, mint
  pending-deposit shares, pay queued redemptions up to `free_collateral·MAX_REDEEM_FRACTION`, accrue
  the fee, reset per-epoch `written_*`/`premium_collected`/caps. **The settle oracle read must be
  freshness-gated** (F-SETTLE-ORACLE): `OptionSeries.settle()` fixes `payout_p` off a one-shot
  `OracleHub.latest_price` whose hub gate is the 7-day heartbeat, with no round-completeness check —
  a stale/incomplete print poisons the pool mark. The vault must settle only via a guarded path that
  applies the `_assert_fresh`-grade check (answer>0, `answered_in ≥ round_id`, `updated_at ≤ now`,
  `now − updated_at ≤ DESK_MAX_STALENESS`) before relying on `payout_p`; the durable fix is to tighten
  the source (round-completeness in `OracleHub._read` and/or a settle-specific freshness bound).

### How it resolves the three killed-vault clusters (summary)

| Cluster (killed) | Resolution here | Honest caveat |
|---|---|---|
| 3 — net-long decaying N, short theta, pays carry | **Flipped:** writes the option, holds P + premium, short N, long theta. Confirmed in `fill_buy_n` code. | v1 is one-sided (no P1) = directional short-vol, not yet delta-balanced. |
| 1 — symmetric band drains | Directional vault-favorable **floor** reused verbatim from the desk (G5). | The loss-SIZE cap is NOT inherited — must build F-WRITER-CAP. |
| 2 — deposit/withdraw oracle + JIT arb | Epochs + boundary-only pricing + conservative two-sided marks + withdrawal lock. | Series mature off-epoch → boundary NAV is oracle-marked for carried positions (mitigated, not deleted). |

## 3. What it writes + P&L + the two-sided delta picture

### 3.1 Per-unit writer P&L (grounded in `OptionSeries.settle`)

Settlement is exact: `payout_p = min(1e18, STRIKE·1e18/x)`, `payout_n = 1e18 − payout_p`, and
`payout_p + payout_n == 1e18` (Halmos `check_redeemConservation`). For a written **call/N** at strike
ratio `r = STRIKE/x₀` (genesis), per unit:

```
writer P&L per unit = premium_N − payout_n(x) = premium_N − max(0, 1 − STRIKE/x)
  max gain   = premium_N        (ETH flat/down: N expires worthless, pool keeps premium + its P pays payout_p)
  max loss   = 1 − premium_N    (x → ∞: payout_n → 1; bounded by the locked collateral net of premium)
```

A **covered call**: bounded loss, fully pre-funded, never liquidated. At `r = 0.6` (2.5× leverage),
`premium_N ≈ 0.40·(1+min_edge)`.

Written **put/M** (P1 mirror, stable-collateralized): `writer P&L = premium_M − payout_m(x)`,
`payout_m` rising as ETH falls, max gain `premium_M`, loss bounded by posted stable collateral net of
premium. **The M-leg math is owed by P1 and referenced, not redefined, here.**

Per-epoch P&L (what NAV/share moves on):
`Σ premium − Σ payout_to_winners − fee` — positive (carry) when written options expire OTM, negative
when a big move pays winners out of the pool.

### 3.2 Delta / gamma / vega

- **Short call (written N):** `∂(−payout_n)/∂x = −STRIKE/x²` for x>STRIKE ⇒ **negative delta** (pool
  loses as ETH rises) = short ETH on the call wing.
- **Short put (written M):** payout rises as ETH falls ⇒ **positive delta** (pool loses as ETH falls)
  = long ETH on the put wing.

**Two-sided flow ⇒ near delta-neutral:** balanced written-N and written-M deltas cancel toward zero;
the book earns spread + premium (theta) with bounded directional risk. **Residual after balancing =
short gamma + short vega = short vol** — irreducible. A *large* move hurts the side it moves toward
faster than the other side helps; realized vol > implied means payouts exceed premium. The `min_edge`
spread is the cushion and must be sized ≥ the expected realized-vol cost (ported F-DRIFT discipline).

**One-sided flow breaks the balance (R-ONESIDE, the central red-team result).** Real RFQ flow is
correlated and one-sided — in a pump everyone buys N and nobody buys M, so the vault writes a pile of
N right before the move it is wrong on. **The negative-carry epoch and the one-sided-flow epoch are
the same epoch.** The vault must NOT respond by writing the *other* side with no buyer (that re-builds
the killed warehouse). It refuses the heavy side at the per-kind cap (`epoch_write_cap_N`),
progressively skews it dearer, and accepts a **capped, disclosed directional bet**. **Two-sidedness
cannot be assumed; it must be enforced.**

## 4. Economics + honest LP risk

### 4.1 The LP return identity

```
LP_return = spread_captured  +  (premium_collected − payouts_to_winners)  −  fee
```

- **Gross carry = premium + spread** — always ≥ 0, known at epoch start, the advertised "yield."
- **Writing P&L = premium − payouts** — the **short-vol term**, the only one that can be deeply
  negative. Positive when options expire OTM; negative when traders win.
- **spread_captured** — the desks' `min_edge` floor each side, the only reliably-positive margin; it
  is what makes this a market-maker, not a naked seller.

The LP is buying `spread + short-vol premium`, financed by bearing `payouts`. It is a **short-vol
yield** (selling tail insurance), **not** a deposit or a guaranteed rate.

### 4.2 LP outcome vs ETH move — v1 (one-sided CWV, r=0.6 / 2.5×, min_edge=1%)

**v1 is one-sided, so the breakeven is asymmetric and tight, not the ±16% a balanced book would have
(F-BREAKEVEN — the embedded ±16% used delta=2.5, the buyer leverage multiple, not the true genesis
delta ≈ 0.6).** The written-call book turns net-negative once `payout_n > premium`, i.e. at roughly
**+0.67% ETH** — but the loss is *small near the money and grows slowly* because the true delta is
~0.6:

| ETH move over epoch | call payout to buyers | LP epoch P&L (CWV) | NAV/share |
|---|---|---|---|
| −20% (crash) | 0 | **+ full premium** | accretes |
| 0% (flat) | ~0 | **+ full premium (carry)** | accretes |
| +0.67% (breakeven) | ≈ premium | **≈ flat** | ~flat |
| +5% | small | **slightly negative** | dips |
| +20% | larger | **≈ −16% of deployed capital** | drops |
| +50% (melt-up) | near-max | **≈ −33% of deployed capital** | drops hard, **bounded** |

Honest reading: **negative beyond ~+0.7%, but materially painful only on large +20%+ moves.** Once
P1/PWV is live and caps force balance, a *balanced* book survives ±~16% epochs roughly flat (winning
side's premium offsets the losing side's payout) — that ±16% figure is **v2-only** and must be gated
behind "PWV live."

### 4.3 Worst-case epoch (the number to disclose)

A **one-sided long book caught in an ETH rally** (or one-sided short book in a crash): the writing
loss runs to roughly the **full per-side directional cap** (`epoch_write_cap_N` of NAV-at-risk),
partially offset by all premium collected that epoch, **pro-rata across LPs, never more than
deposited, never liquidated.** **Single-epoch** max loss ≈ `epoch_write_cap − premium`; **cumulative**
loss over K consecutive one-sided epochs ≈ `K·(cap − premium)`, with the terminal bound = the full
deposit. The per-epoch cap bounds per-epoch *size*, **not** the LP's total at-risk capital over a
sustained one-sided regime — this must be disclosed (F-ONESIDE-CUM).

### 4.4 When to open it

- **Cold start is adverse-selection-dominated.** With no organic flow, the only counterparties are
  arbers picking off the thin desk → structural `premium < payout` every epoch. **Do not open the
  vault before P1 phase-1 operator desks show two-sided ORGANIC flow.** The operator desks (their own
  ~5 ETH) ARE the product until demand is proven; P3 is the scale-up *after* demand, not the bootstrap
  *for* it.
- **Launch wide, cap tiny.** Cold-start directional cap **≤ 20% of NAV** (not the 40% floated
  elsewhere — F-ONESIDE-CUM reconciles the two to one parameter), `min_edge ≥ 1%` (≥ the drift
  budget), small `MAX_FILL`; widen only across multiple epochs of observed two-sided flow.

## 5. Confirmed findings + fixes

Every confirmed finding, folded into the design above.

| # | Title | Sev | Fix (folded in) |
|---|---|---|---|
| **F-VERDICT** | Carry-sign flip is REAL in code for the N write, but v1 (CWV-only) ships the killed one-sided directional bet, and the desk's only directional cap (`max_nav_at_risk`, fires only `if proj_net > 0`) does NOT bound the writer (net-short-N) axis | **high** | The flip is sound and needs no change (confirmed `fill_buy_n` keeps P, ships N to buyer, goes net-short N). Gate the public pool on: (i) the new writer cap existing in the desk (F-WRITER-CAP), (ii) P1 live so the two-sided balance actually exists, (iii) observed two-sided organic flow. Ship v1 with the honest "one-sided directional short-vol bet" framing. |
| **F-WRITER-CAP** | The loss-bounding directional cap is NOT inherited — `max_nav_at_risk` is dead code on the writing direction; only the price FLOOR is inherited. Unset/mis-set ⇒ unbounded one-sided calls at a 1% edge | **high** | Stop claiming the cap is inherited. Add a symmetric written-exposure cap in `fill_buy_n` that fires when `proj_net < 0`: bound worst-case writer payout `Σ(1−payout_p) ≤ MAX_WRITTEN_AT_RISK` via a new `set_caps` field. Require all vault-backed split funding to come via `draw_collateral` (forbid the JIT-split from drawing on residual desk balance when `funding_source != empty`), so `epoch_write_cap_N` meters every write and is unbypassable. Re-prove the cap binds in the negative-`net_n` direction (Halmos). |
| **F-CONSV** | `route_premium`'s "claim kept == collateral locked" check is unverifiable as designed: the desk keeps P **untracked** (`net_n` tracks only N), fungible with operator P (`fund_p`) and mergeable/withdrawable before the vault pulls it — so the check has no on-chain source of truth and can be spoofed or bricked | **high** | Single atomic vault-orchestrated entrypoint: draw → split → ship N to buyer → transfer kept P **directly to the vault** in one tx (never rest P in the desk's commingled balance). Verify against the `transferFrom` **delta**, not `balanceOf`. Per-(vault, series) claim ledger only the vault credits/debits. Forbid `withdraw_token`/opportunistic `merge` from touching vault-backing P. Until built, R6/R7 are unproven. |
| **F-SELLN** | The desk can still go net-LONG N (re-warehouse the decaying leg) inside a vault epoch: `fill_sell_n` buys N and retains net-long N beyond available P (lines 408-424) = the exact killed pattern, now LP-funded; sized for the operator's ~3 ETH, not a pool | **high** | Make the vault coupling **write-only**: when `funding_source == vault`, `assert` disables `fill_sell_n`. The vault is a writing venue; holders sell N at the operator's own solo desk. Use JIT `draw_collateral` per write only (no standing LP balance the buy path could pay out). Add R-SELLN to disclosure. |
| **F-OWNER-RUG** | Making the VaultManager the OWNER of the desks concentrates a rug surface the solo desks never had: desk owner has uncapped `withdraw_eth` (line 480), no timelock — now over POOLED LP ETH under one admin key | **high** | DROP "VaultManager owns the desks." Back desks ONLY via `draw_collateral`/`route_premium` + conservation check; never by holding ownership + calling `withdraw_eth`. If a vault-owns-desk path is ever kept, harden first: `withdraw_eth` routes only to the immutable vault, VaultManager has no path sending collateral anywhere but desks' fund / the redemption queue, timelock `set_desk`/`set_caps`/`set_fee`, per-epoch outflow cap. |
| **F-NAV-IDENTITY** | The embedded §3 NAV identity double-counts: it subtracts `free_collateral` by the full 1 ETH lock AND adds back both premium and `claim_held·mark` AND subtracts worst-case max payout ⇒ marks every fresh write as a ~total loss and can underflow | **high** | Corrected identity (§2.3): `NAV = free_collateral + collateral_locked(face) + premium_collected − Σ payout_n_worst`. Count locked ETH **once** (recovery guaranteed by `P+N==1`); mark the short at its liability `−payout_n` with a 1-2% haircut, **not** a second full-notional subtraction. Invariant: a fresh write drops NAV by at most `(1 − premium)` per unit. |
| **F-ARCH** | The spec was internally incoherent — one vault with `kind=N/M` vs two segregated vaults vs a VaultManager that owns desks (three mutually exclusive designs) | **med** | Settled (§1): **two segregated vaults** (CWV WETH / PWV spUSD) coupled to the unchanged desks via `IVaultBacked` draw/route (NOT owning them, NOT one commingled contract). Delta-balance is portfolio-level. Drop the other two variants from all surfaces. |
| **F-SETTLE-ORACLE** | `settle()` fixes `payout_p` off a one-shot `OracleHub.latest_price` gated only by the 7-day heartbeat, no round-completeness vs the desk's `_assert_fresh` — a stale/incomplete print poisons the pool's settled mark | **high** | Vault settles only via a guarded path applying the `_assert_fresh`-grade check (answer>0, `answered_in ≥ round_id`, `updated_at ≤ now`, `≤ DESK_MAX_STALENESS`) before relying on `payout_p`; tolerate an already-fixed settle. Durable fix: add round-completeness to `OracleHub._read` and/or a settle-specific freshness bound (protects the DAO + solo desks too). Re-run Halmos `P+N` (unaffected — freshness gate on the x input). |
| **F-MARK-DRIFT** | `settle_epoch` strikes NAV / mints / redeems against a live-oracle boundary mark in the same permissionless call, and the keeper picks the block ⇒ residual JIT timing optionality (NOT "deleted") | **med** | Price mint/redeem ONLY off oracle-free realized values where possible (settle + `redeem_p`). For epochs with open carried positions, either carry the deposit/redeem to the next boundary where they've settled, or mark the asset side **also** at conservative worst-case for the transactor (floor the asset just as the liability is ceiling'd) so a fresh print only moves NAV against them. `MARK_HAIRCUT ≥` max plausible drift over one staleness window. Downgrade spec language from "deletes the JIT vector entirely" to "bounds residual boundary-mark drift." Call it F-MARK-DRIFT (sibling of F-DRIFT). |
| **F-CARRY-MARK / EPOCH-MISMATCH** | Series mature on the DAO roll cadence (~28d rolling / dated), NOT the 7-day epoch, so an epoch routinely closes with OPEN positions → boundary NAV is oracle-marked in the common case → the live oracle is back on the withdraw price path | **med** | Do NOT claim cluster 2 is "resolved by deletion." State that carried open positions are the NORMAL settle case. Strongest fix: pay redemptions pro-rata oracle-free from `free_collateral` (mirroring `TrackerDAO.redeem`/`StableQuoteFiller.operator_redeem`) and let the oracle mark gate ONLY the new-deposit share price. Plus F-LOCK-UNBOUNDED's MAX_WRITE_TENOR ≤ EPOCH_LEN so more positions actually settle within the epoch. Re-run the cluster-2 red-team for the carried-mark case. |
| **F-LOCK-UNBOUNDED** | Withdrawal lock + MAX_REDEEM_FRACTION does not bound the wait; in a sustained one-sided/stressed regime free_collateral stays low and exit can take an unbounded number of epochs while NAV falls — illiquidity peaks when losses peak | **med** | (1) `MAX_WRITE_TENOR ≤ EPOCH_LEN` + `draw_collateral` only writes series maturing within the epoch ⇒ exit waits at most one epoch. (2) Never-lent `redemption_reserve = MAX_REDEEM_FRACTION·NAV` that `draw_collateral` can't touch. (3) Disclose the multi-epoch-exit + falling-NAV worst case in LP copy and R4. (Phase-2: transferable share token for secondary-market exit.) |
| **F-ONESIDE-CUM** | One-sided controls (caps + skew + refuse-heavy-side) bound SIZE but not the already-written inventory's within-epoch payout, and the per-epoch cap does not bound CUMULATIVE loss across consecutive one-sided epochs; "categorically better than the killed warehouse" overclaims for a one-sided epoch | **med** | Add the cumulative bound to §4.3 (single-epoch ≈ cap−premium; K epochs ≈ K·(cap−premium); terminal = full deposit). Set the documented cold-start cap to **≤ 20% of NAV** (reconcile the 20% vs 40% to ONE parameter). Soften the headline: categorically better on CARRY SIGN + per-epoch capping, but a one-sided epoch is the same DIRECTIONAL bet. Promote TWO_SIDED_FLOW_GATE to a hard per-epoch invariant (defense-in-depth on accumulation). |
| **F-BREAKEVEN** | Headline "±16% breakeven" is ~24× off for v1: it used delta=2.5 (buyer leverage multiple), not the genesis delta ≈ 0.6; the one-sided book turns negative at ~+0.67% | **med** | Make the ONE-SIDED LP-outcome table (§4.2) the v1 headline; state breakeven ≈ +0.67% AND "materially painful only on +20%+ moves." Gate the ±16% balanced figure behind "PWV/P1 live + caps force balance." |
| **F-V1-WAREHOUSE** | v1 IS a one-sided warehouse — the mirror of the killed vault — not yet a categorical improvement; "flipped to positive carry" and "delta-balanced" are different claims, only the first holds in v1 | **high** | Relabel v1 throughout as a ONE-SIDED short-CALL directional short-vol product; move "delta-balanced / categorically better" under a v2-requires-P1 banner. Keep the true v1 differentiator (carry-sign flip is real even one-sided) but add: positive expected carry does NOT bound the realized one-sided tail. Hard launch gate on P1 live + two-sided flow. Fix the StableQuoteFiller mis-mapping (it is the spUSD-token desk, not the put writer). Interim venue = operator solo desks. |
| **F-OPDISCRETION** | Operator is simultaneously quoter, cap-setter, and fund manager — they choose when/how much one-sided risk LPs eat (e.g. open `epoch_write_cap_N`, self-buy calls at the floor before an anticipated rip, LPs pay the winner). "Compromised desk bounded by caps" fails when the operator legitimately controls the caps | **med** | Add red-team row R-OPDISCRETION distinct from R5. Separate roles: cap-setter ≠ quoter key; quoter may price but not raise caps. Immutable `EPOCH_WRITE_CAP_*_MAX` (≤20-25% NAV) the owner can't exceed + a ≥1-epoch timelock on increases so LPs can exit first. Scale writable kind to OBSERVED opposing organic flow (TWO_SIDED_FLOW_GATE on-chain). Publish per-epoch realized P&L + net-delta + per-side written face at `settle_epoch`. Add to the mandatory ack: "the operator chooses the direction, timing, and size of the bets this pool writes." Must-ship minimum: immutable cap ceiling + timelock + disclosure. |
| **F-IVAULTBACKED-SURFACE** | `IVaultBacked` atomic draw+route is NOT "inherited for free / zero new hot-path surface" — it rewrites the desk's funding/CEI core and adds a new vault↔desk call graph; a flaw in the conservation check breaks the loss-bound | **med** | Stop marketing it with the cold-path safety claim. Treat it as new AUDITED hot-path code: write the exact CEI ordering across `draw_collateral → split → route_premium` with all effects booked before each external call on each contract; design the cross-contract reentrancy model as a unit (desks' undecorated `__default__` + vault payable receive); make the whole thing atomic/revert-all-or-nothing via a single vault orchestration entrypoint; conservation check is a hard revert; re-run Halmos over the combined accounting. (The alternative cold-path VaultManager-owns-desks model is rejected by F-OWNER-RUG.) |
| **F-HALMOS-SCOPE** | R7 says "re-prove P+N for the vault" but P+N is ALREADY proven (`check_splitFullyCollateralized`/`check_splitMergeExact`) and is NOT the vault's risk — the vault's risk is the SHARE/NAV/QUEUE math, which Halmos has not been pointed at and is solver-harder (the suite notes the deep query is >13h intractable) | **low** | Re-scope to NEW vault-accounting theorems with no existing scaffolding: (1) `Σ shares·nav_per_share ≤ NAV` always (no over-issuance); (2) redeem partial-fill never pays > `free_collateral·MAX_REDEEM_FRACTION`/epoch and rolled remainder is conserved; (3) a write reduces marked NAV by at most its true worst-case at-risk (conservative liability ≥ real max payout); (4) `route_premium`'s `claim_amount == amount drawn` holds for every accepted route; (5) `nav_per_share` donation-immune (cite DEAD_SHARES). Budget a dedicated design→verify pass; cite the OptionSeries P+N proof as a reused dependency, not re-run. PWV held until the put series exists AND its `P′+M` conservation is independently proven. |
| **F-P1DEP** | PWV needs P1's mirror put series + a re-proven `P′+M` invariant; neither exists in `src/`; shipping puts before that re-opens collateral-solvency risk | **med** | PWV is a STUB until P1 lands and Halmos proves `P′+M` conservation over the deployed bytecode (mirroring `check_payoutBounded`/`check_redeemConservation`). Launch CWV-only; the book is one-sided (R-ONESIDE in full) — disclose the delta-balance benefit is a P1-dependent phase-2 unlock. Confirm/lock P1's M-leg interface (claim token, max-payout reserve formula) before building `draw/route` for `kind=M`. |
| **F-OPTICS-GATE** | Securities/fund optics are correctly NAMED but the gating is under-specced: a public pooled, fee-charging, profit-sharing, actively-managed vault is a collective investment in most jurisdictions; a typed checkbox + Beta label is not a control (no KYC/geo gate, deposit cap, accredited path) | **low** | Convert the gate from copy to code (v1-blocking): (a) hard-coded per-wallet AND total deposit cap on `request_deposit`, default small, un-raisable past a tiny ceiling until a named legal review clears mainnet (mirrors F6's `assert asset == empty(bytes32)`); (b) default **non-transferable / soulbound shares** for v1 (reduces secondary-market security optics AND closes a transfer-around-the-lock route) — re-enable transferability only post legal review; (c) §7 checklist gate: "operating entity + its liability for managing pooled funds is NAMED before any non-testnet deposit"; geo/KYC, if mainnet, must be code not copy. The typed ack is necessary but is NOT the gate. |
| **F-COLDSTART-GATE** | "Open only after phase-1 proves two-sided flow" is correct and load-bearing but stated as guidance, not a gate — and the solo desks themselves are built/deployed but UNFUNDED/not-live, so the prerequisite is un-started, not merely unproven | **low** | Add a single hard "Launch gate (ALL true before any vault deposit)": (a) N desk + stable desk FUNDED + live (`operatorDesks.json` published, real quoter key); (b) ≥ N epochs of recorded BOTH-SIDED organic (non-arb) volume above a stated threshold; (c) P1 put desk live AND `P′+M` proven. Keep cold-start caps as LOW set via `set_caps` (don't make them immutable deploy-time asserts — they must widen with flow; the `min_edge ≥ 1%` floor is already immutable and inherited). Optionally a one-bit `launch_armed` interlock on `request_deposit`. |

## 6. How it plugs in — the bootstrap unlock + the Earn tab

### 6.1 It funds the desks (and P2's menu) — the menu-liquidity unlock

The recurring problem — "the operator only has ~5 ETH / can't recruit a pro MM" — is solved by
swapping the **funding source** under desks that already work: one LP pool backs `SignedQuoteFiller`
(N/calls) across P2's strike menu and, once P1 lands, the short desk (M/puts). **LPs fund depth
instead of the operator.** No pro MM, no new venue, no new floor math — the buyer's trade surface,
routing, and trust label are identical whether the desk balance is the operator's 5 ETH or the pool's
50 ETH. This is what makes **P2's leverage menu actually liquid**: the menu is a set of desks, and the
vault funds all of them from one pool. Capital allocation across desks is a **single NAV budget**
(`Σ written ETH-equivalent + redemption_reserve ≤ NAV`), each desk's cap a *fraction* of the budget,
not full-size on each (the F-SHARED lesson scaled up).

### 6.2 Two trust relationships, kept separate

- **Trade trust (unchanged, reused verbatim).** A buyer hitting a desk trades against the operator's
  signed quote, floored on-chain. The existing mandatory label stands: *"Operator-quoted desk. Your
  counterparty is `0x…` (the operator), not the Gimbal protocol. Quotes are signed off-chain and
  filled at a price floored on-chain."* The buyer never sees the vault.
- **Fund trust (new — the disclosure this product owns).** An LP hands pooled capital to an
  operator-managed short-vol fund. The deposit button sits behind an explicit, un-pre-checked,
  **typed** risk acknowledgment ("Be the house"): you are the house / short volatility / collect
  premium up front / **you lose when traders win, paid from the pool** / capped upside, ETH downside /
  **you can lose principal** / never liquidated, capped at deposit / locked while trading (epoch
  boundaries only) / **the operator chooses the direction, timing, and size of the bets** (F-OPDISCRETION)
  / Beta, unaudited, Sepolia testnet, research code.

### 6.3 Earn tab + securities/optics

- Split the Earn surface: **Earn · Provide (LP)** (the existing pool-LP) and **Earn · Vault (Be the
  house)** (P3). Two very different risk profiles must not share one word.
- The Vault tab **must NOT**: show an APY/"expected yield" headline (show realized per-epoch P&L
  instead); offer instant withdraw while an epoch is open; style itself as a savings primitive; imply
  it is delta-neutral/hedged (v1 is unhedged one-sided short-vol). It **must** show NAV/share, epoch
  countdown + lock state, queued deposit/withdrawal, locked-vs-free split, net-delta + capacity
  gauges, and the typed "Be the house" ack on first deposit.
- **Optics, named loudly.** The solo desks deliberately DELETED pooled deposits/shares/NAV to dodge
  fund/securities optics; P3 re-introduces all of them on purpose, so it has the optics (and possibly
  the substance) of a collective investment. Frame as "be the house / be the counterparty," never
  "earn yield"; lead with "you can lose principal"; operator-managed, not protocol-guaranteed; keep it
  Beta/testnet/capped. Gating is **code, not copy** (F-OPTICS-GATE): deposit caps, non-transferable
  shares, named operating entity before any non-testnet deposit.

### 6.4 Discovery wiring

Extend the curated `operatorDesks.json` with a `kind:"vault"` entry
(`{tracker, kind:"vault", vault, operator, backsDesks[], collateralAssets[], epochSeconds, feeBps,
status:"beta", sinceBlock, label}`). Frontend keys Earn · Vault by `(tracker, kind:"vault")`;
cross-check on render that the vault is wired to the backed desks and each desk's `quoter()` matches
the listed operator; an unlisted vault gets a harder unverified gate than an unlisted desk (it is
pooled money). On-chain `VaultRegistry` enumeration is deferred to phase 2 (curated JSON in v1).

## 7. Components to build — v1 vs phase 2

**v1 (CWV-only; ships ONLY after the §8 launch gate clears — which it currently does not):**
1. `WriterVault.vy` (CWV, ETH-collateral) — epoch state machine (DEPOSIT/TRADE/SETTLE);
   `request_deposit`/`request_redeem`/`claim_redeemed`/`roll_epoch`/`settle_epoch`/`harvest`;
   conservative epoch-anchored NAV/share with the corrected identity (F-NAV-IDENTITY) + tight
   staleness gate (F-MARK-DRIFT) + guarded settle (F-SETTLE-ORACLE); `MAX_WRITE_TENOR ≤ EPOCH_LEN` +
   `redemption_reserve` (F-LOCK-UNBOUNDED); `DEAD_SHARES` bootstrap; **non-transferable shares**
   (F-OPTICS-GATE); per-wallet+total **deposit caps** (F-OPTICS-GATE); owner `set_desk`/`set_paused`/
   `set_caps`/`set_fee`, 2-step ownership, immutable `EPOCH_WRITE_CAP_N_MAX` + timelocked increases +
   cap-setter ≠ quoter (F-OPDISCRETION); undecorated payable `__default__`.
2. `IVaultBacked` extension to `SignedQuoteFiller` — `funding_source` immutable; **atomic
   draw→split→ship-N→route-P** single orchestration entrypoint with the `transferFrom`-delta
   conservation check (F-CONSV); the new **net-short-N writer cap** `MAX_WRITTEN_AT_RISK` on the
   `proj_net < 0` branch + all split funding via `draw_collateral` (F-WRITER-CAP); **`fill_sell_n`
   disabled when vault-backed** (F-SELLN). The G1-G6 floor is unchanged; this is new audited hot-path
   code (F-IVAULTBACKED-SURFACE), not a flag.
3. USD-only assert + tracker-oracle-wiring asserts (F6); EIP-5202 blueprint;
   `script/deploy-writer-vault.sh`.
4. Off-chain keeper: `roll_epoch`/`settle_epoch` at boundaries; the existing quoter unchanged.
5. Frontend Earn · Vault tab (§6.3) with the mandatory BETA / short-vol / "you can lose principal,
   capped at deposit, never liquidated, operator chooses the bets" copy + typed ack.
6. **Halmos vault-accounting theorems (F-HALMOS-SCOPE) — BLOCKING gate, not polish:** the five
   share/NAV/queue/conservation invariants; cite (don't re-run) the OptionSeries P+N proof.
7. "Sepolia testnet, research code, unaudited" everywhere.

**Phase 2 (gated on P1 live + flow):**
- `WriterVault.vy` PWV (spUSD-collateral, writes M via P1's short desk) — **only after** P1's put
  series exists and its `P′+M` conservation is independently Halmos-proven (F-P1DEP); two-sided
  writing ⇒ the delta-balance benefit; optional paired-deposit helper (one tx, both vaults, target
  delta-neutral split).
- On-chain best-ex so a single buy can split across vault-backed desk + pool; multiple writer vaults
  per peg; an `x_sign` deviation bound shared with the desks; transferable shares (post legal review);
  on-chain `VaultRegistry`; a short-vol risk dashboard (per-epoch realized-vs-implied); on-chain
  residual-delta hedge venue (only above a TVL where hedging beats capping).

## 8. Honest risks + bottom line + GO/NO-GO

### Honest risks (red-team residuals)

| # | Attack | Verdict | Resolution |
|---|---|---|---|
| R-ONESIDE | One-sided flow breaks the delta-balance; CWV becomes net-short-ETH with no offset | **confirmed, bounded** | Per-kind cap (≤20% NAV) + skew + refuse-heavy-side + TWO_SIDED_FLOW_GATE; bounds size, not already-written within-epoch payout (F-ONESIDE-CUM). The primary residual. |
| R-SHORTVOL | Short gamma/vega: a large realized move pays winners > premium even when delta-neutral | **irreducible — this IS the product** | Size `min_edge ≥` expected realized-vol cost; cap notional; "you can lose principal." Bounded by collateral, never < 0. |
| R-NAVARB | Deposit-before/withdraw-after a known settlement | **mitigated, not deleted** | Epochs + boundary-only pricing + conservative two-sided marks + lock; residual boundary-mark drift bounded by staleness window + haircut (F-MARK-DRIFT, F-CARRY-MARK). |
| R4 / run | Bank run forces loss-unwind | resolved | Redeem from `free_collateral` only, capped `MAX_REDEEM_FRACTION`/epoch; `MAX_WRITE_TENOR ≤ EPOCH_LEN`; `redemption_reserve`. Residual: multi-epoch exit in stress (disclosed, F-LOCK-UNBOUNDED). |
| R5 | Compromised desk contract/quoter | bounded | Desk floor + `epoch_write_cap_*` + `MIN_RESERVE` + conservation check + `set_desk(False)`/`set_paused`. |
| R-OPDISCRETION | Operator self-deals one-sided risk onto LPs at a 1% toll | **confirmed** | Immutable cap ceiling + timelocked increases + cap-setter ≠ quoter + flow-scaled writes + on-chain P&L publication + explicit disclosure (F-OPDISCRETION). |
| R6 | Mint-to-write re-imports orphan N | avoided | Never `deposit()`; writes via `split()`, routes N to buyer, keeps P; `fill_sell_n` disabled (F-SELLN); conservation check (F-CONSV). |
| R7 | Vault accounting solvency | **must prove** | New Halmos theorems (F-HALMOS-SCOPE), blocking gate. |
| R-OPTICS | Public pooled trading fund = securities optics | disclosed + coded | Deposit caps + soulbound shares + named entity (F-OPTICS-GATE); Beta framing everywhere. |
| R-COLDSTART | Thin/one-sided market = arbers pick off LPs | gated | Don't open before phase-1 two-sided flow; wide quotes, tiny caps (F-COLDSTART-GATE). |

### Bottom line

The Writer Vault realizes P3 as the carry reframe our own red-team endorsed: it pools the **writer /
premium-collecting side**, so the killed vault's structural KILLER (net-long the decaying N, short
theta, paying carry) is **flipped — confirmed in `fill_buy_n` code**: the pool holds **P + premium**,
is short N, long theta. It resolves cluster 1's *price* control by reusing the desk's directional
floor verbatim, and mitigates cluster 2 with epochs + conservative marks + withdrawal locks. It solves
the MM-capital bootstrap — **LPs fund depth instead of the operator's 5 ETH** — and is what makes P2's
menu liquid. **But three things are load-bearing and honest:** (1) **v1 is one-sided** (no P1 in
`src/`) = a directional short-call short-vol bet, the *mirror* of the killed vault, differing only in
carry sign and per-epoch capping — the "delta-balanced, categorically better" claim is a **v2 property
gated on P1**; (2) several controls the design leans on are **not built and not inherited** — the
writer loss-size cap (F-WRITER-CAP), the atomic conservation check (F-CONSV), write-only desk coupling
(F-SELLN), the corrected NAV identity (F-NAV-IDENTITY), the guarded settle (F-SETTLE-ORACLE), and the
vault-accounting Halmos proofs (F-HALMOS-SCOPE); (3) the residual is **short-vol — LPs CAN lose
principal (winners are paid from the pool); never liquidated; capped at deposit; can never go
negative.**

### GO / NO-GO recommendation

**Current status: NO-GO.** Do not open a public deposit today. The design is sound *on the side the
red-team endorsed*, but the prerequisites and the new safety controls are not in place:

**Ship only after ALL of the following are true (the launch gate):**
1. **P1 is LIVE** (the stable-collateralized put/short series + short desk exist in `src/`, are
   deployed, and their `P′+M` conservation is independently Halmos-proven) — so the two-sided
   delta-balance that justifies the design actually exists, not just CWV-only.
2. **P2 menu is live** and the operator-funded solo desks (N + stable + short) are **FUNDED and live**
   with **≥ N epochs of recorded two-sided ORGANIC (non-arb) flow** above a stated threshold. *(Today
   the desks are built/deployed but unfunded/not-live — the prerequisite is un-started.)*
3. **The new on-chain controls are built and audited:** the net-short-N writer cap (F-WRITER-CAP); the
   atomic draw→split→route conservation check (F-CONSV); `fill_sell_n` disabled when vault-backed
   (F-SELLN); the corrected NAV identity (F-NAV-IDENTITY); the guarded settle path (F-SETTLE-ORACLE);
   immutable cap ceiling + timelocked increases + cap-setter ≠ quoter (F-OPDISCRETION).
4. **The vault-accounting Halmos theorems pass** (F-HALMOS-SCOPE) — solvency, redeem-conservation,
   conservative-mark, route conservation, donation-immunity.
5. **The optics gate is code:** per-wallet/total deposit caps, non-transferable shares, named
   operating entity before any non-testnet deposit (F-OPTICS-GATE).

**Until then:** if the goal is liquidity now, the correct answer remains the **operator-funded solo
desks** (their own capital, their own bag, clean optics) — exactly the killed-vault verdict's "the
operator desks ARE the product until demand is proven." P3 is the scale-up that funds depth **after**
demand, with the new controls, not the bootstrap for it.

**Sepolia testnet, research code, unaudited. BETA — a public pooled trading fund; LPs are short
volatility and can lose principal, capped at deposit, never liquidated.**
