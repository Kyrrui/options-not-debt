# Gimbal — Immutable Autonomous Vault (crowd-owned house) (spec)

> Build spec, not a sketch. ONE **immutable, ownerless, on-chain-priced** Vyper 0.4.3 vault that IS the house for every leg of Gimbal: it writes and sells the leveraged-long leg (N, ETH-collateralized calls across the dated leverage menu) and — phase 2 — the leveraged-short leg (M, USDC-collateralized puts). Crowd LPs fund it through the **Earn tab only**; the vault prices its own writes on-chain (oracle intrinsic + a formulaic, leverage-and-inventory-scaled spread, **no signer**), keeps the premium-collecting leg, ships the decaying leg to the buyer, and is maintained by a **permissionless, incentivized keeper**. Income splits two tiers: a fixed spread slice → **senior staked-spUSD** (smoothed, always-≥0 yield, loss-protected); the variable trading P&L → **junior LP shares** (the actual house — real upside, real downside, capped at deposit, never liquidated).
>
> **This SUPERSEDES the operator-RFQ desk model** (the deployed `SignedQuoteFiller` `0x48c93eD52507DEe37d79eA37Df9ed7fAF739C8F1` and `StableQuoteFiller` `0x520089CCFCB62cd79971afeBB3A3EA2E973E29cc`, each carrying an `owner` + a privileged `quoter` signer = two centralization points) and **unifies P1 (short put series), P2 (dated leverage menu), and P3 (writer vault)** into one bytecode. The precedent that ownerless + signer-less is feasible is in our own code: `TrackerDAO` has no owner and no signer — it prices `sell_p`/`fill_roll` as `MAX_EDGE`-bounded ramped auctions off the oracle intrinsic and is maintained by a permissionless `sync()`.
>
> **Sepolia testnet, research code, unaudited. v1 is fully immutable BY CHOICE — a bug's only recourse is redeploy-v2 + LP migration; nothing can stop, pause, or patch the live contract. A mandatory mainnet-revisit note (timelock guardian) is in §5. A named legal entity accountable for the pooled funds must be established before any non-testnet deposit — ownerlessness removes the answer to "who is liable," not the question.**

```
ARCHITECTURE BANNER
  IMMUTABLE          no owner · no admin · no pause · no upgrade · every knob a ctor immutable
  ON-CHAIN PRICED    price = oracle intrinsic ± formulaic spread; NO signer, NO ecrecover, NO nonce
  EARN-ONLY FUNDED   crowd LP deposit is the only inflow; LP redeeming own shares is the only outflow
  PERMISSIONLESS     poke() keeper (TrackerDAO.sync shape); liveness depends on no single party
  SENIOR / JUNIOR    staked-spUSD = senior fee tranche (≥0, loss-protected); LP shares = junior house P&L
  TWO INSTANCES      one bytecode, immutable COLLATERAL: CWV (WETH/N, v1) + PWV (USDC/M, phase-2 gated)
  SUPERSEDES         SignedQuoteFiller + StableQuoteFiller desks · the off-chain quoter · signed-quote FE
  UNIFIES            P1 short-series + P2 leverage-menu + P3 writer-vault → one contract
```

---

## 1. What it is

`GimbalWriterVault.vy` — `# pragma version ==0.4.3`. ONE immutable bytecode, parameterized at construction by an immutable `COLLATERAL` address + `COLLATERAL_KIND`, deployed as **two segregated instances**:

- **CWV** — WETH/ETH collateral, writes **N** (the leveraged-long call leg) across the dated leverage menu. **Ships v1.**
- **PWV** — USDC collateral, writes **M** (the leveraged-short put leg via `PutOptionSeries`). **Phase-2, deploy-gated** on P1 landing.

It is the house for **leveraged LONGS** (sells N to longs across a menu of dated strikes ≈2x..20x; 40x is structurally unquotable per the 20% edge ceiling) and — phase 2 — **leveraged SHORTS** (sells M to shorts via USDC-collateralized puts). It folds the desks' guardrail *math* (the directional floor, the tight `_assert_fresh` gate, the caps, strict CEI) into an ownerless contract that prices on-chain.

**Why "one house" is one bytecode, two instances.** The operator wants ONE house for both legs; the physics forbid one *instance* holding both. A written call/N owes ETH-as-ETH-rises (back it with ETH); a written put/M owes USD-value-as-ETH-falls (back it with USDC). Collateral asset, NAV unit, withdrawal asset, and risk axis all differ; commingling re-creates the writer-vault-spec F-ARCH blast-radius problem and makes NAV a two-unit mess. Resolution that satisfies both "one house" and "segregated + immutable": one immutable bytecode whose collateral family is a constructor immutable, deployed twice. Same audited code, same proofs, same keeper, same senior fee sink — segregated balance sheets. The Earn tab presents them as one "house" product with two collateral pools.

**The reuse boundary, stated honestly (finding F-V1-SCOPE).** "REUSE `SeriesFactory`" means reuse of the bare `create_series` primitive ONLY — it takes an arbitrary `(strike, maturity)` with no tier grid, no strike-snap, no registry. The dated-series *menu* logic that P2 specified but never built (strike-snapping, the `r < 0.96` immutable tier-leverage grid, tier enumeration, mint-fresh-on-expiry cohort roll, registry-first keeper convergence) is **net-new immutable code** that lives inside this vault. So v1 ≠ "reuse + a thin vault"; v1 = the P2 menu mechanics + the vault epoch/NAV/queue machine + the on-chain pricer + the keeper, all from scratch and immutable. See §8 for the full build surface and the de-risking decision.

---

## 2. The vault core — deposit / redeem / epochs / NAV + on-chain write/sell

### 2.1 The immutable parameter list (nothing is settable)

There is NO `set_caps`, NO `set_fee`, NO `set_quoter`, NO `set_paused`, NO `transfer_ownership`, NO `withdraw_eth`. Every knob the desks made owner-settable is frozen at construction and asserted into safe ranges (the `TrackerDAO.__init__` discipline, `TrackerDAO.vy:161-183`):

```
COLLATERAL, COLLATERAL_KIND, COLLATERAL_DECIMALS   # WETH/18 (CWV) | USDC/6 (PWV); asserts <= 18
HUB, ASSET (== empty(bytes32), USD-only v1), SERIES_FACTORY, ORACLE_FEED (cached ETH_USD_FEED)
SP_USD_SINK                                        # senior staked-spUSD receiver (phase-2; see §4)
LEG_KIND                                           # LEG_N (CWV) | LEG_M (PWV)
# formulaic pricing (replaces the signer) — see §3
BASE_EDGE, MAX_EDGE (<= UNIT//5 = 20%), DRIFT_BUDGET, EDGE_INVENTORY_SLOPE (SKEW_MAX), SAFE_LEV, FEE_EDGE_BPS
# risk caps (the F-OPDISCRETION fix: no owner can ever widen them)
MAX_WRITTEN_AT_RISK_BPS (<= 2000 cold start), EPOCH_WRITE_CAP_BPS, MAX_FILL, MIN_WRITE_SIZE, MAX_OPEN,
REDEMPTION_RESERVE_BPS (== MAX_REDEEM_FRACTION_BPS), MAX_REDEEM_FRACTION_BPS, MAX_OUTFLOW_PER_BLOCK,
OUTFLOW_WINDOW + outflow_cap, PER_WALLET_CAP, TOTAL_DEPOSIT_CAP
# oracle / lifecycle
DESK_MAX_STALENESS (in [30,3600]s), EPOCH_LEN, DEPOSIT_WIN, SETTLE_WIN, MIN_TRADE_WIN,
MAX_WRITE_TENOR (<= EPOCH_LEN), STRIKE_PROXIMITY, PRE_MATURITY_BUFFER, MAX_SETTLE_PER_CALL,
KEEPER_TIP, MARK_HAIRCUT, DEAD_SHARES (1e3), GRACE
```

Constructor cross-asserts that close the self-brick corner (finding F-CTOR-BRICK): `MAX_EDGE <= UNIT//5`; `DESK_MAX_STALENESS in [30,3600]`; `MAX_WRITE_TENOR <= EPOCH_LEN`; `REDEMPTION_RESERVE_BPS == MAX_REDEEM_FRACTION_BPS`; `COLLATERAL_DECIMALS <= 18`; **`DEPOSIT_WIN + SETTLE_WIN + MIN_TRADE_WIN <= EPOCH_LEN`** (a non-empty TRADE window); **`MAX_WRITE_TENOR + SETTLE_WIN <= EPOCH_LEN`** (written collateral always has settle headroom inside its epoch). For PWV: `LEG_KIND == LEG_M`, `SERIES_FACTORY` is the P1 `PutSeriesFactory`, and a build-time `assert` that P1 exists (deploy IS the gate).

### 2.2 State

```
# ERC20-ish share token, NON-TRANSFERABLE in v1 (soulbound; only mint/burn — no transfer externals)
totalSupply, balanceOf
# epoch machine (phase DERIVED from now vs epoch_start; no setter)
epoch_id, epoch_start, boundary_nav, boundary_supply
# collateral pools
free_collateral, collateral_locked (face), premium_collected
# written inventory per series vintage (mirrors SignedQuoteFiller.net_n shape, vy:151)
written_units[series], claim_held[series], open_series: DynArray[address, MAX_OPEN], epoch_written_face
settle_cursor                                         # incremental-settle persisted cursor (§5)
# deposit/redeem queues (priced at the NEXT boundary)
pending_deposit[addr], pending_deposit_total, redeem_escrow[addr], redeem_queue_total
# senior accounting
senior_escrow                                         # owed to SP_USD_SINK; debited ONLY by the senior payout path
```

### 2.3 Epoch lifecycle

Phase is DERIVED, never set, and the derivation is **total / never-reverting** over all timestamps (finding F-CTOR-BRICK): `DEPOSIT` = first `DEPOSIT_WIN`; `TRADE` = until `EPOCH_LEN - SETTLE_WIN`; `SETTLE` = last `SETTLE_WIN`. Deposits and redeem-requests are *queued* in DEPOSIT and priced at the **next boundary**; writes happen in TRADE; the boundary roll runs in SETTLE. Intra-epoch `nav()` is display-only — every deposit/redeem prices at `boundary_nav` fixed once per epoch (resolves the JIT-NAV arb; F-MARK-DRIFT). **`request_redeem` / `claim_redeemed` / `nav()` never call `phase()`**, so a misconfig can never trap the exit.

### 2.4 NAV / share (corrected identity)

The two prior facets disagreed on whether `senior_escrow` sits inside junior NAV. **Canonical, single junior identity (finding F-NAV-DOUBLECOUNT):**

```
junior_NAV = free_collateral + collateral_locked(FACE) + premium_collected
           − Σ_open worst_case_liability(series)        # short marked at WORST case + MARK_HAIRCUT
           − senior_escrow                               # senior is a first claim, NOT junior equity
```

Implemented by debiting the senior slice **at write time** so `premium_collected` never holds the senior dollars (`premium_collected += cost − fee; senior_escrow += fee`), making the subtraction mechanical and the §0 waterfall consistent. `collateral_locked` is counted ONCE at face — the kept P/L is the *other half* of it; do not add a separate `claim_held*mark` term (that double-counts, the inverse error F-NAV-IDENTITY fixed). A fresh write drops NAV by at most `(1 − premium)` per unit; `nav()` cannot underflow. `boundary_nav` is struck AFTER `senior_escrow` is debited, so minted/redeemed shares never embed dollars owed to staked-spUSD. `DEAD_SHARES` minted to `0xdead` on first deposit (donation-immune NAV/share, the `TrackerDAO.deposit` pattern `:347-350`).

### 2.5 The write/sell path + function signatures (real sigs)

Single atomic orchestration, strict CEI (effects before the external `split`), so the kept claim is provably vault-owned via the split delta — trivially true here because the vault IS the splitter, not a separate desk handing P around (F-CONSV). The vault is **WRITE-ONLY**; buyback is **merge-only against a held pair** (see §3 and finding F-SELLN).

```
buy_n(series, amount, max_cost) -> cost   (CWV, @payable):
  assert phase == TRADE
  assert LeverageMenuRegistry.is_listed(series)        # BOUNDED set (keeper-gated cohort), NOT bare is_series (F-DUST)
  assert open_series.length < MAX_OPEN and amount >= MIN_WRITE_SIZE   # entry-count + dust caps (F-DUST)
  _assert_fresh(); _assert_tier_fresh(lev, updated_at)  # §3
  assert x > STRIKE * STRIKE_PROXIMITY // UNIT, "near strike"
  price = intrinsic_n * (UNIT + ask_hs) // UNIT          # §3 formula; NO q.price, NO signer
  cost  = amount * price // UNIT; assert cost <= max_cost, "slippage"
  ... writer-cap + epoch-cap + reserve + per-block outflow asserts (EFFECTS first, CEI) ...
  free_collateral -= amount; collateral_locked += amount
  written_units[series] += amount; claim_held[series] += amount
  fee = FEE_EDGE_BPS * (cost − intrinsic_part); premium_collected += cost − fee; senior_escrow += fee
  # INTERACTIONS last:
  ISeries(series).split(value=amount)                    # locks amount ETH -> amount P + amount N to vault
  IERC20(N).transfer(buyer, amount)                      # ship the decaying leg; vault keeps P
```

```
@external @payable                def buy_n(series, amount, max_cost) -> uint256       # CWV
@external                         def buy_m(put_series, amount, max_cost) -> uint256   # PWV (P1-gated): transferFrom USDC, 6->18 round-down, flipped band p<K
@external @nonreentrant @payable  def request_deposit() -> uint256                     # CWV: queue msg.value; PER_WALLET_CAP/TOTAL_DEPOSIT_CAP + DEAD_SHARES
@external @nonreentrant           def request_deposit_usdc(amount) -> uint256          # PWV deposit
@external @nonreentrant           def request_redeem(shares)                           # escrow shares for next-boundary clearing
@external @nonreentrant           def claim_redeemed() -> uint256                      # normal boundary-priced exit (reads boundary_nav)
@external @nonreentrant           def force_redeem(shares) -> uint256                  # UNCONDITIONAL in-kind escape (see §5); reads NO boundary_nav, NO mark, NO oracle
@external @nonreentrant           def settle_epoch()                                   # == poke(); permissionless keeper (§5)
@external @nonreentrant           def buyback_n(series, amount, min_proceeds) -> uint256  # bounded by claim_held[series]; merge-recycles oracle-free (F-SELLN)
@external @view                   def quote_buy_n(series, amount) -> uint256           # on-chain price preview (replaces POST /quote)
@external @view                   def nav() -> uint256 ; def share_price() -> uint256  # display-only intra-epoch
@external @payable                def __default__()                                    # UNDECORATED (CWV) — accepts series merge/redeem ETH callbacks (TrackerDAO.vy:575 pattern); PWV has none
@deploy                           def __init__(... every knob frozen, asserted ...)
# NO owner functions. NO set_*. NO withdraw_*. NO transfer/transferFrom (shares soulbound).
```

The ONLY collateral outflow is an LP redeeming its own shares (`request_redeem`→`claim_redeemed`, or `force_redeem`) or a buyer/series settlement payout. The `withdraw_eth` rug surface the desks carried (`SignedQuoteFiller.vy:480`) **does not exist.**

---

## 3. On-chain pricing formula + the MEV/oracle hardening (the no-signer cost)

The desks priced with an off-chain EIP-712 quote (smart, tight, inventory-aware) bounded by an on-chain floor. **Deleting the signer means the contract produces the price itself.** The floor is no longer a backstop under a smart price — it **IS** the price. Everything here follows from that one fact. The precedent is `TrackerDAO.sell_p`/`fill_roll` (`:468-535`): price = oracle intrinsic, with a deterministic edge the contract computes, bounded by `MAX_EDGE < UNIT//5` (`:172`), no signer. We generalize that from a time-ramp to an inventory+leverage scaling.

**Fair value** (fresh oracle per call, gated by `_assert_fresh`):
```
x = HUB.latest_price(ASSET)                                  # ETH/USD, single feed, USD-only
fair_n = max(0, UNIT - STRIKE * UNIT // x)                   # == OptionSeries payout_n / SignedQuoteFiller.intrinsic_n (vy:217-223)
fair_m = max(0, UNIT - p * UNIT // K)                        # PWV put mirror (short-series-spec)
```

**The half-spread `hs` — the one number that replaces the signer:**
```
lev          = x // (x - STRIKE)                             # live leverage = 1/(1-r); for M: K//(K-p)
base_spread  = BASE_EDGE                                     # immutable MEV/gas floor (>= ~0.0075e18 = 75 bps)
leverage_amp = (lev * DRIFT_BUDGET) // UNIT                  # F-EDGE, NOW ON-CHAIN
util         = written_at_risk[series] * UNIT // cap_value   # value-weighted directional fill, 0..1e18
inv_skew     = SKEW_MAX * util // UNIT
ask_hs       = min(base_spread + leverage_amp + inv_skew, MAX_EDGE)    # vault SELLS dear
price_ask    = fair * (UNIT + ask_hs) // UNIT
```
`leverage_amp` is the load-bearing new logic: because oracle-deviation amplification = leverage (`dN/N ≈ lev·dx/x`), a flat spread safe at 2x is free money at 20x. With `DRIFT_BUDGET = 0.5%`: 2x→1%, 5x→2.5%, 10x→5%, 20x→10%; at 40x it saturates `MAX_EDGE` (20%), so the clamp **plus** the registry `r < 0.96` cap make 40x structurally unquotable (F-CEILING) with no privileged actor. This promotes the spec's "F-EDGE is quoter config the deployer must get right" into an immutable on-chain term — correct, because there is no deployer to re-tune and no quoter to compute it.

**Why a deterministic on-chain quote is exploitable, and the minimum safe spread.** A signed quote commits to a price the operator chose after seeing the book; an attacker can't improve their fill by reordering the chain. A pure formula `price = f(x_live, inventory)` has neither protection — the attacker controls ordering and can influence `x`/inventory in-block. Three exploits and their defenses:

- **(a) Oracle-tip / stale-edge front-run.** Between the real market price and the on-chain `updated_at`, the formula prices off a known-stale `x`. Edge available ≈ `lev × (drift over DESK_MAX_STALENESS)`. **⇒ spread must be ≥ `lev × DRIFT_BUDGET`** — exactly `leverage_amp`. Tighten staleness → smaller `DRIFT_BUDGET` → tighter spread.
- **(b) Sandwich of the inventory term.** Profitable only if a single victim moves the price more than `2·hs`. Defense: `MAX_FILL` caps single-fill size so one trade can't displace `util` past the round-trip toll; `SKEW_MAX` sized so the full util sweep is a few percent, never a cliff.
- **(c) Oracle manipulation (thin feed).** The formula pays on the manipulated print. Defense: the freshness gate bounds staleness not manipulation, so the only on-chain defenses are the spread + the per-block and per-epoch outflow caps (bounding total extractable per block) + USD-only against the canonical hard-to-move ETH/USD feed.

```
hs >= BASE_EDGE + lev * DRIFT_BUDGET, then min(., MAX_EDGE)
v1 (DESK_MAX_STALENESS=60s, DRIFT_BUDGET=0.5%, BASE_EDGE=0.75%): 2x→1.75% 5x→3.25% 10x→5.75% 20x→10.75%
```
The formulaic vault MUST quote structurally WIDER than a smart signer and is MEV/oracle-tick exposed — **the accepted, mandate-level price of ownerlessness.** The compensations are caps, not cleverness.

**The freshness gate — copied VERBATIM from `SignedQuoteFiller._assert_fresh` (`vy:251-267`)**, run on every fill:
```
feed = HUB.ETH_USD_FEED(); (round_id, answer, _, updated_at, answered_in) = feed.latestRoundData()
assert answer > 0
assert answered_in >= round_id        # F5 — the round-completeness check OracleHub._read OMITS (vy:124-138)
assert updated_at <= block.timestamp
assert block.timestamp - updated_at <= DESK_MAX_STALENESS    # tight; immutable; far below the hub's 7d heartbeat
```
With a signer, a stale feed merely meant the operator wouldn't sign; here the gate is the only thing between a stale print and a leverage-amplified mis-price, and **no owner can pause if it misbehaves.**

**Leverage-scaled freshness refusal (the sharpest ownerless control).** The stale-edge exploit scales as `lev × age`, so tolerable staleness scales as `1/lev`:
```
allowed_age = DESK_MAX_STALENESS * SAFE_LEV // lev; assert now - updated_at <= allowed_age, "tier-stale"
```
With `DESK_MAX_STALENESS=600s, SAFE_LEV=2x`: 2x tolerates 600s, 5x→240s, 10x→120s, 20x→60s. A 20x series simply reverts ("goes dark") whenever the feed is older than 60s — correct, because a 20x quote off a stale feed is a free leverage-amplified option and there is no owner to pause it.

**Outflow caps + slippage (the structural backstops).** Value can only leave via a fill, and that exit must self-limit: a NEW **per-block** cap `block_spent[block.number] + out <= MAX_OUTFLOW_PER_BLOCK` (a deterministic price is exploitable atomically in one block — the desks only had a per-*window* cap, `SignedQuoteFiller.vy:332-343`); the kept tumbling per-epoch `outflow_cap`; and a **mandatory slippage bound on every taker call** (`max_cost`/`min_proceeds`) — the signed `q.price` *was* the slippage bound; deleting the signer means the taker supplies their own or eats whatever the moving oracle does between simulate and mine.

---

## 4. Senior / junior economics — staked-spUSD vs LP shares

### 4.1 The core principle: a WATERFALL, not a shared pool

On every settled epoch the house runs a strict waterfall, and the senior slice is carved from a quantity that is structurally `>= 0`:

```
GROSS = Σ premium_collected (>=0) + Σ spread_captured (>=0 by the on-chain floor)
(1) SENIOR  = min(SENIOR_TAKE · Σ spread_captured, Σ spread_captured)   -> senior_escrow -> staked-spUSD
(2) KEEPER  = KEEPER_BPS · GROSS                                        -> permissionless keeper tip
(3) JUNIOR  = GROSS − senior − keeper − Σ payouts_to_winners            -> LP NAV (CAN be < 0)
```
Senior is bounded by `Σ spread_captured` (never negative — every write crosses the floor). **Payouts to winners are subtracted ONLY in step 3** — they hit junior, never senior. That ordering IS the senior loss-protection guarantee, and it is a code invariant. Senior is funded from **spread, not premium**: premium is the option's fair value and the exact pot winners are paid from; routing it to senior would re-mingle the tranches. Spread (the edge *above* intrinsic) is the genuine MM margin independent of who wins the bet.

### 4.2 The two instruments

| | **SENIOR — staked-spUSD (`stspUSD`)** | **JUNIOR — house LP shares (`hsETH`/`hsUSDC`)** |
|---|---|---|
| Underlying | spUSD (which itself stays $1) | ETH (CWV) / USDC (PWV) at NAV/share |
| Receives | step (1): a fixed slice of epoch **spread only** | step (3): premium − payouts + residual spread |
| Carry sign | **≥ 0 always** (skim of a non-negative quantity) | **±** — the actual house P&L |
| Bears trading loss? | **NO** (paid before payouts) | **YES** (winners paid from junior NAV) |
| Principal risk | spUSD de-peg only | full short-vol downside, **bounded to deposit** |
| Liquidation | none | **none** (P+N==1 / M+L==1, fully collateralized) |
| Peg | spUSD = $1 soft peg (unchanged) | NAV/share floats (no peg, by design) |

### 4.3 Peg-safety: how staked-spUSD accrues without spUSD leaving $1

`stspUSD` is a **non-rebasing ERC-4626-style wrapper** over spUSD with a monotonic exchange rate (the sDAI/wstETH pattern): `rate = spUSD_held / stspUSD_supply`, starts at 1.0, only ever rises. Yield is delivered as *more spUSD per stspUSD*, never as a changed spUSD balance or NAV — **plain spUSD stays $1; only stakers' rate moves.** The escrow it converts is `>= 0`, so `rate` is monotonically non-decreasing (a no-flow epoch is flat, never down). **Honest residual:** stspUSD is protected from the *vault's trading loss*, not from a spUSD de-peg — it is spUSD underneath. Disclosure must say so.

### 4.4 Junior return vs the tail (one-sided CWV, min_edge 1%)

| ETH move / epoch | call payout to buyers | JUNIOR epoch P&L | SENIOR accrual |
|---|---|---|---|
| −20% (crash) / 0% (flat) | ~0 | **+ full premium + spread** | + spread skim (≥0) |
| +0.67% (junior breakeven) | ≈ premium | ≈ flat | + spread skim (≥0) |
| +20% | larger | ≈ −16% of deployed | + spread skim (≥0) |
| +50% (melt-up) | near-max | ≈ −33% of deployed, **bounded** | + spread skim (≥0) |

Per-unit: `junior_PnL_call = premium − payout_n ∈ [premium − 1, premium]`; max loss `1 − premium` is finite and pre-funded (the winner's collateral is already locked) — nothing to liquidate, no negative equity. Across every column the senior accrual is `≥ 0`. **Two-sided flow (phase 2) bounds junior DIRECTIONAL risk toward neutral** (short-call negative delta + short-put positive delta cancel to the imbalance); it does NOT remove short gamma/vega = short-vol, which is irreducible and IS the product. One-sided flow is handled mechanically by the formulaic skew + the hard per-epoch write cap (no discretionary refusal exists since immutable/no-signer).

### 4.5 The senior tile is deferred (finding F-SENIOR-COLD)

Spread is captured only on a write; writes need buyer flow. With no funded interim desk and no organic flow, realistic first-epochs spread is ~0, so a "Stake spUSD → earn" tile accrues nothing for an indefinite cold-start period — an optics trap (it *looks* like a stablecoin yield product, the most-scrutinized DeFi category) that pays only realized, volume-contingent crumbs and adds a securities-shaped, MEV-bearing, Halmos-burdened, immutable surface for ~no v1 benefit. **Decision: defer the entire stspUSD senior tranche to phase 2**, gated on the same launch gate as PWV (P1 live + measured two-sided organic flow that makes a non-zero spread real). **Ship v1 junior-only.** Senior economics is purely additive — junior-only loses nothing by waiting, and adding stspUSD later is a fresh deploy, not a state migration. If the operator insists on shipping it anyway: it must never appear under a yield/APY/"earn" affordance, copy must literally state "accrues only when the house trades; rate is 0 in no-flow epochs; not a savings product," and the `autonomous_convert` spUSD purchase (the highest-surface, lowest-value piece — see F-CONVERT) must be deferred regardless.

---

## 5. Immutability + the permissionless keeper + migration/exit + the MANDATORY mainnet-revisit

### 5.1 The permissionless, incentivized keeper — `poke()` / `settle_epoch()`

Not a contract, not a privileged role: one permissionless external function, modeled on `TrackerDAO.sync()` (`:400-446`). It does all time-driven maintenance and has **zero privilege over value** — it cannot move LP funds, price a trade, or change a parameter. Idempotent and convergent (do only what the clock permits this block). Registry-first convergent (F-KEEPER-RACE): check the cohort pointer BEFORE reading the oracle/factory, so two pokers can never mint two series for one logical tier+cohort.

| Step | Trigger | Action |
|---|---|---|
| settle matured | `now >= MATURITY and not settled` | **guarded** `settle()` (§5.2) then `redeem_p`/`redeem_l` → recover collateral oracle-free, **skip-on-failure** |
| roll the epoch | `now >= epoch_end` | fix `boundary_nav`/`supply` once, mint queued deposits, pay queued redemptions from free collateral (capped), debit `senior_escrow`, reset write meters, advance `epoch_id` |
| mint-fresh-on-expiry | front cohort within `ROLL_AHEAD` of maturity | `create_series(...)` the next tier cohort at the snapped live strike; list it in the registry |
| advance pointers | always | set `active_series[tier]` to the freshest non-near-maturity cohort |
| tip the caller | a step did real work | pay `KEEPER_TIP` from a dedicated reserve (senior carve-out, never junior principal); **no-op tip if nothing was due** |

**Incremental / idempotent settle (finding F-DUST).** Settle/harvest at most `MAX_SETTLE_PER_CALL` series per call, advancing `settle_cursor`, so the backlog drains over multiple pokes and a single call can never exceed the block gas limit. Combined with the bounded writable set (registry `is_listed`, not bare `is_series`), `MAX_OPEN`, and `MIN_WRITE_SIZE`, a dust-griefer cannot wedge the roll. **Decouple settle from the boundary roll (finding F-SETTLE-WEDGE):** never gate `boundary_nav`/deposit-mint/redemption-clear on a settle succeeding; a matured-but-unsettleable series is carried at the conservative worst-case mark (+`MARK_HAIRCUT`), sound because §2.4 already under-marks open exposure. Run the boundary roll unconditionally; recovered collateral from any series that DID settle simply augments `free_collateral`.

**If nobody ever calls `poke()` — graceful degradation, never stuck funds.** Series `settle()` is already permissionless (`OptionSeries.vy:182`) so any buyer/LP can settle directly; LP redeem pays oracle-free from free collateral (`TrackerDAO.redeem` posture, `:360-385`), the rest frees as written series mature; the menu just goes stale (no new writes for an aging tier) without bricking; `MAX_WRITE_TENOR <= EPOCH_LEN` guarantees all collateral becomes freeable within one epoch.

### 5.2 Guarded settle + the durable core fix (findings F-SETTLE-ROUND, F-SETTLE-STALE)

`OptionSeries.settle()` (`vy:190-200`) fixes `payout_p` off `OracleHub.latest_price`, gated only by the loose registered heartbeat (USD sentinel 7200s) with **no round-completeness check** — `OracleHub._read` destructures `answered_in` (`vy:131-132`) but never asserts `answered_in >= round_id`. A stale/incomplete print poisons the settled mark, leverage-amplified on high tiers, and `settle()` is **permissionless** — a griefer can call the raw series settle directly, bypassing the vault's keeper guard, and a malicious keeper can PICK the settlement tick within the freshness window (a one-shot, irreversible mis-mark no owner can undo). The keeper's guarded settle (`_assert_fresh`-grade check before trusting `payout_*`) is **necessary but NOT sufficient**. Pick ONE before bytecode freeze:

1. **(Preferred, durable)** Add an immutable per-series `max_settle_staleness` to a hardened `OptionSeries` blueprint, asserted INSIDE `settle()` (and fold `assert answered_in >= round_id` into the read), so EVERY permissionless settle — including a direct griefer call — refuses a stale/incomplete print. The vault points `SERIES_FACTORY` at this blueprint. For high tiers, settle off a multi-round median (round-walk `getRoundData`) rather than a single `latestRoundData` to remove single-tick selection.
2. **(Alternative)** Deploy a new `OracleHub` with the round-completeness assert + a tight ETH/USD heartbeat, point the vault's series at it.
3. **(Fallback, no core change)** Cap writable tiers to the leverage where `7200s × drift × lev` is tolerable (strictly-safe ≲2-3x) enforced by the registry grid / a ctor assert tying deployable `r` to the settle-freshness budget — i.e. explicitly DO NOT write the [5,10,20]x menu against the 7200s USD sentinel.

The one-line `assert answered_in >= round_id` in `OracleHub._read` is independently worth landing (it benefits every consumer — `latest_price`, `register`, `settle`, `sync`, `poke`) but must NOT be mistaken for the F-SETTLE-STALE fix: it rejects carried/stuck rounds, not an in-heartbeat-but-stale print.

### 5.3 Migration / exit — and the honest decoupling (findings F-MIGRATION-WEDGE, F-EXIT-COUPLING)

With no pause/upgrade, the only recourse for a bug is deploy v2 + LP migrate, so exit must be wedge-proof. **The honest fact:** the normal `claim_redeemed` path is NAV-priced, capped, and epoch-gated — it reads `boundary_nav` (computed off conservative marks in the boundary roll) and waits on `settle_epoch` freeing `collateral_locked`, so it **IS coupled** to the mark/NAV/waterfall logic. Do not claim, via the `TrackerDAO.redeem` analogy, that it is decoupled (that analogy holds only for TrackerDAO's NAV-free pro-rata redeem). Therefore:

- **`force_redeem` is the canonical never-trapped primitive.** Ignoring epoch/boundary/marks/`MAX_REDEEM_FRACTION`, it burns shares and pays a strict pro-rata of (a) `free_collateral` and (b) the LP's pro-rata slice of each held P/L token **transferred in-kind** (the exact `TrackerDAO.redeem` pattern, `:372-384`). Pricing depends ONLY on `totalSupply`/`balanceOf`/`free_collateral`/in-kind token balances — never `boundary_nav`, never `worst_case_liability`, never the oracle. The exiting LP self-settles/merges the received P/L at their own pace (the residual one-time oracle dependency is theirs). It is an **opt-in "raw exit at a haircut"** — you accept worst-case marks and give up the cap protection — NOT an uncapped strictly-better path, with a fairness guard so a redeemer cannot extract P/L worth more than their pro-rata NAV share (or it griefs remaining LPs).
- **Migration is exit-then-deposit:** `force_redeem`/`claim_redeemed` on v1 → `request_deposit` on v2; discovery flips the "canonical house" pointer to v2 and marks v1 `redeem-only`. No funds are ever locked to v1. Disclose real latency: calm-case full `claim_redeemed` exit ≥ `ceil(1/MAX_REDEEM_FRACTION)` epochs; **`force_redeem` is the only prompt, unconditional exit.**
- **The locked-collateral caveat (finding F-DEAD-ORACLE, CRITICAL).** Locked collateral is recoverable oracle-free only while the oracle is alive at the written series' settlement. A permanently sunset/dead Sepolia feed past maturity makes `settle()` revert forever, `redeem_p` revert (not settled), and the locked slice **permanently trapped** — no owner to re-point. Required mitigations: keep `MAX_WRITE_TENOR` small (shrink the dead-feed window); ship `force_redeem`'s in-kind P/L distribution (the dead-feed risk then sits with the exiting LP, not the frozen pool); and, durably, add a permissionless `settle_fallback()` to the hardened `OptionSeries` blueprint that, once `now − MATURITY > GRACE` and `settle()` has not succeeded, settles to `payout_p = UNIT` (P full, N worthless — the LP-favorable bound since the write-only vault holds P) so collateral becomes oracle-free redeemable after the grace period. **DOWNGRADE all design language** accordingly: "oracle-free exit for free collateral always; locked collateral recoverable only while the oracle remains alive at settlement — a permanently dead feed permanently traps the locked slice." The Halmos never-trapped theorem must be re-scoped to this (it cannot be proven against current `settle()`/`redeem_p`).

### 5.4 What immutability deletes vs the desks

| Surface on the deployed desks | In the autonomous house |
|---|---|
| `owner`/`pending_owner`/2-step ownership | **DELETED** |
| `withdraw_eth(amount)` uncapped (`SignedQuoteFiller.vy:480`, F-OWNER-RUG) | **DELETED** — only an LP redeeming own shares or a settlement payout |
| `set_paused`/`paused` | **DELETED** |
| `set_quoter`/`quoter` (the privileged signer) | **DELETED** — pricing is formulaic on-chain |
| `set_caps`/`set_fee`/`set_desk` | **DELETED** — every cap/edge/fee is an immutable ctor constant |
| `transfer_ownership` | **DELETED** |

### 5.5 MANDATORY mainnet-revisit note (required deliverable)

> **MAINNET-REVISIT (required, not optional).** v1 is fully immutable BY CHOICE for the Sepolia research phase — immutability is the cleanest proof of "no centralization risk" and the value at stake is testnet. For mainnet, full immutability of a contract that custodies pooled real funds and prices its own writes is **too sharp**: one undiscovered bug has no recourse but a disruptive v2 migration during which LPs bear the broken contract. Before any mainnet deployment, add the **minimal** governance that preserves "no centralization risk" while restoring a safety brake:
> - a **timelocked guardian** whose ONLY powers are (a) `pause_new_writes` (freeze the write/trade path; **redeem — including `force_redeem` — stays permanently open and un-pausable**, the brake never traps funds) and (b) a long-timelock cap-ratchet that can only narrow caps, **never a value-extraction path (no `withdraw`, ever)**;
> - behind a **timelock ≥ one epoch + multisig (or token vote)** so LPs can always exit before any change takes effect;
> - publish the guardian's exact ABI and the hardcoded bounds so the powers are legibly bounded.
>
> Carried in the v1 README header, the Earn-tab disclosure, and the deploy-script header, so no one mistakes "immutable v1 on testnet" for "immutable forever on mainnet." Additionally: because immutability forecloses ever adding KYC/geo/transfer gating, any mainnet path must bake those controls (or hooks to add them) into the deployed v2 from the start — they can never be retrofitted onto an immutable v1. And per F-OPTICS-GATE, **a named legal entity accountable for the pooled funds, and its liability, must be established before any non-testnet deposit** — ownerlessness does not dissolve the legal question, it only removes the answer.

---

## 6. Confirmed findings + fixes (every finding folded in)

| # | Finding (severity) | Fix (folded into) |
|---|---|---|
| 1 | `OracleHub._read` omits `answered_in >= round_id` — carried stale round settles (**high**) | One-line `assert answered_in >= round_id, "incomplete round"` after the `answer>0` check; `answered_in` already destructured (`vy:131-132`), zero new reads. Inherits to every permissionless settler (settle/sync/poke/latest_price). §5.2 |
| 2 | Locked collateral NOT recoverable oracle-free — a dead/sunset feed past maturity traps the backing forever, no owner to rescue (**critical**) | Durable: permissionless `settle_fallback()` in a hardened `OptionSeries` (after `GRACE`, `payout_p=UNIT`). Vault-only: `force_redeem` distributes held P/L in-kind. Small `MAX_WRITE_TENOR`. Downgrade "never trapped" language; re-scope the Halmos theorem. §5.3 |
| 3 | `settle_epoch`/`roll_epoch` can wedge a full epoch on a transient stale oracle; tighter guarded-settle makes reverts MORE likely (**medium**) | Per-series settle skip-on-failure; carry matured-but-stale at the conservative mark; NEVER gate `boundary_nav`/mint/redeem on a settle succeeding; run the roll unconditionally. §5.1 |
| 4 | Permissionless `settle()` lets a malicious keeper PICK the settlement tick within the freshness window — one-shot irreversible mis-mark (**medium**) | Settle-specific tight staleness (≤60-120s) and/or multi-round median in the hardened `OptionSeries`; must live in the settlement primitive (the vault can't wrap a direct call). Disclose buyer-favorable-tick risk for junior. §5.2 |
| 5 | Dust / many-open-series griefing pushes `settle_epoch`/`nav()` past the block gas limit, wedging the roll (**medium**) | Gate writes to the bounded registry `is_listed` (not bare `is_series`); immutable `MAX_OPEN` + `MIN_WRITE_SIZE`; incremental `MAX_SETTLE_PER_CALL` settle with a cursor; decouple `claim_redeemed` from the Σ_open loop. §5.1, §2.5 |
| 6 | "Redeploy-v2 + migrate" is only as clean as `claim_redeemed`, which inherits every wedge above (**high**) | `force_redeem`: unconditional in-kind escape reading none of {`boundary_nav`,`worst_case_liability`,oracle}; Halmos-prove that independence; disclose real exit latency; make "redeem roll/oracle-independent" an invariant of the mainnet guardian. §5.3 |
| 7 | Constructor immutability can self-brick at deploy with no recourse (window overflow, underflowing TRADE phase) (**low**) | Ctor cross-asserts `DEPOSIT_WIN+SETTLE_WIN+MIN_TRADE_WIN <= EPOCH_LEN` and `MAX_WRITE_TENOR+SETTLE_WIN <= EPOCH_LEN`; total never-reverting `phase()`; redeem path never calls `phase()`; Halmos `phase()` totality + redeem reachability. §2.1, §2.3 |
| 8 | "CWV-only" is not buildable as scoped — silently depends on unbuilt P2 (registry/keeper/snap/grid) on top of absent P1 (**high**) | State the TRUE build surface (§1, §8): P2 menu mechanics are net-new immutable code, not "reuse." De-risk by operating P2 under a pausable owner first, OR collapse into one immutable deploy gated behind the full menu-logic Halmos suite + tiny caps + a note that immutability now covers never-operated dated-series machinery. §8 |
| 9 | Settlement reads the loose 7200s hub heartbeat; the immutable vault CANNOT fix it — high-lev NAV poisoned with no recourse (**high**) | Choose one BEFORE freeze: hardened `OptionSeries.max_settle_staleness` (preferred); new tight `OracleHub`; or cap writable tiers to the settle-safe leverage (≲2-3x on 7200s). Keeper guard is necessary, not sufficient (settle is permissionless). §5.2 |
| 10 | Symmetric sell-back (`fill_sell_n/m` enabled) re-opens the killed F-SELLN net-long-N warehouse, now LP-funded + un-pausable (**high**) | DELETE `fill_sell_n/m` as open entrypoints. Keep only `buyback_n/m` bounded on-chain by `claim_held[series]` so every buyback pairs with held P/L and immediately `merge()`s oracle-free — vault can NEVER end a tx net-long the decaying leg. Net-long impossible, not merely capped. Reconcile both facets to this rule; disclose buyer-exit via secondary market. §2.5, §3 |
| 11 | Two-tier waterfall yields positive senior only on realized spread, which is ~0 in exactly the cold-start regime the senior tile is marketed for (**medium**) | Defer the entire stspUSD senior tranche to phase 2 (same gate as PWV); ship v1 junior-only. Removes the wrapper, `autonomous_convert`, fee-skim, and the tranche-separation theorem from immutable v1. §4.5, §8 |
| 12 | `autonomous_convert` (senior yield → spUSD) is an un-owned MEV-exposed cross-asset swap with no robust venue + under-specified slippage band (**medium**) | Do not build on-chain auto-convert in immutable v1. Drop the senior tranche (preferred), or denominate the senior fee in native collateral (ETH/USDC) and let conversion happen off-chain at the staker's discretion — no AMM path in the contract. The thin/mispriced spUSD/WETH pool makes a deterministic immutable convert a free sandwich or a permanent revert. §4.5 |
| 13 | The vault-accounting + tranche-separation Halmos theorems are the real solvency proof, have NO scaffolding, and the monolithic form is solver-intractable (>13h) (**medium**) | Decompose into single-mul-div lemmas mirroring the existing `check_payoutBounded`→`check_redeemConservation` chain (`Halmos.t.sol:61,87`), installing settled/boundary state via `vm.store`: no-over-issuance, redeem partial-fill conservation, conservative-mark ≥ worst case, waterfall/route conservation, donation-immunity + `nav()≥0`. Hard pre-deploy gate + an independent paid audit scoped to the share/NAV/queue/waterfall core. Tiny launch caps are the interim blast-radius bound, not a substitute. §8 |
| 14 | "Bug ⇒ redeploy" safety needs redeem provably independent of the write/price bug, but the shared epoch/NAV machine couples them (**low**) | Correct the over-claim: `claim_redeemed` IS coupled (the `TrackerDAO.redeem` analogy holds only for NAV-free pro-rata redeem). The honest invariant: collateral always recoverable (P+N==1 / M+L==1), but exit PRICE/PROMPTNESS depend on the mark/settle machine. `force_redeem` is the decoupled path; Halmos-prove it reverts only on share underflow. §5.3 |
| 15 | NAV double-count/underflow once `senior_escrow` is both an asset and a claim — junior could be credited dollars owed to staked-spUSD (**medium**) | One canonical junior identity that subtracts `senior_escrow` as a first claim; debit the senior slice at write time so `premium_collected` never holds it; strike `boundary_nav` after the debit; strengthen Halmos to `junior_NAV + senior_escrow <= recoverable` and `nav()>=0`. §2.4 (moot in v1 since the senior tranche is deferred, but pinned for phase 2) |

---

## 7. What it supersedes / keeps from P1·P2·P3 + retired desks + the simplified frontend

**Supersedes (the operator-RFQ era):** the deployed `SignedQuoteFiller` (`0x48c9…`) and `StableQuoteFiller` (`0x5200…`) become **deprecated**; the entire off-chain quoter (`solo-rfq-quoter-spec.md`, `stable-rfq.env.example`, `solo-rfq.env.example`), the signed-quote frontend plumbing (`solo-rfq-frontend-handoff.md`), and the cross-venue routing logic (`solo-rfq-routing-spec.md`) are **superseded and deleted**. Best-ex collapses to **vault vs pool**:

| Trade | OLD (operator-RFQ) | NEW (autonomous house) |
|---|---|---|
| Buy N | RFQ desk (signed quote) vs `LeverageRouter` pool, FE SOR picks | **Vault** `buy_n(series, amount, max_cost)` priced formulaically vs the same pool path; no signed quote, no TTL, no quoter API |
| Sell N | RFQ-only, "unavailable if desk down" | **Vault is WRITE-ONLY** — exit a leg by holding to settlement + `redeem_n` (permissionless, oracle-free), `merge()` if you hold both legs, or a secondary market. No bare buy-N warehouse (F-SELLN) |
| Buy/Sell M | RFQ-only short desk, no fallback | **Vault** `buy_m`/bounded `buyback_m` (phase 2, P1-gated) |
| Buy/Sell spUSD (Hold) | `StableQuoteFiller` RFQ vs pool vs deposit/redeem | `StableQuoteFiller` **retired**; spUSD stays a two-venue leg: the spUSD/WETH pool + `TrackerDAO.deposit/redeem`. The house does NOT quote spUSD-vs-ETH |

**Keeps / reuses (unchanged primitives):** `OptionSeries` (dated calls; `split`/`merge`/`settle`/`redeem_p`/`redeem_n`, P+N==1 Halmos-proven), the P1 `PutOptionSeries` (dated USDC puts, M+L==1 — phase 2), `SeriesFactory`/`PutSeriesFactory` (bare `create_series` only), `OracleHub` (+ the F-SETTLE-ROUND hardening), the `TrackerDAO` auction-pricing + permissionless-`sync()` patterns, and the desks' guardrail math (`_assert_fresh`, directional floor, no-trade band, outflow/fill caps) — now living in an OWNERLESS contract that prices on-chain.

**Simplified frontend (Earn-only, no quoter service):** the three-role nav stays (`Hold · Leverage · Earn`). **Earn is the ONLY funding path** — `request_deposit` (WETH→CWV junior shares; USDC→PWV phase-2) with a mandatory typed "Be the house" ack (short vol / collect premium up front / you can lose principal, paid from the pool when traders win / capped at deposit / never liquidated / immutable & ownerless: no pause, no admin, a bug means migrate to v2 / epoch lock / Sepolia, unaudited). No operator `fund()` path. The "Stake spUSD" senior tile is **deferred to phase 2** (§4.5). Trade tabs read the vault's `quote_*` view on-chain and submit `buy_*` with `minOut`/`maxIn` — **no quoter service, no EIP-712 signing, no RFQ API**, the major dapp-builder simplification: plain view+write contract calls plus the existing `LeverageRouter` for the buy-N pool comparison. A "Refresh menu (tip)" button surfaces `poke()`. Trust label: *"Your counterparty is the Gimbal House — an immutable, ownerless on-chain vault funded by crowd LPs. No operator, no admin, no pause. Prices are computed on-chain from the oracle plus a formulaic spread. (Sepolia testnet research stance; mainnet requires a named accountable entity + a timelocked governance brake — see mainnet-revisit note.)"*

---

## 8. Components to build — v1 vs phase 2

**v1 (CWV-only, junior-only) — the true build surface (F-V1-SCOPE, F-SENIOR-COLD):**
1. **The P2 dated-series menu mechanics** (net-new immutable code, NOT reuse): strike-snapping, the immutable `r < 0.96` tier-leverage grid, tier enumeration, a `LeverageMenuRegistry` (`is_listed` bounded cohort), mint-fresh-on-expiry cohort roll, registry-first (F-KEEPER-RACE) convergence.
2. **The vault epoch/NAV/queue machine** (§2): deposit/redeem queues, boundary pricing, soulbound shares, `DEAD_SHARES` bootstrap, `force_redeem`.
3. **The on-chain formulaic pricer** (§3): `buy_n`, bounded `buyback_n`, `quote_buy_n`, `_assert_fresh` (verbatim incl. F5), `_assert_tier_fresh`, the per-block + per-window outflow caps.
4. **The permissionless keeper** `poke()`/`settle_epoch()` (§5): incremental skip-on-failure settle, unconditional boundary roll, tip from a deploy-time-endowed reserve.
5. **A hardened `OptionSeries` blueprint** (the core dependency from F-SETTLE-STALE / F-DEAD-ORACLE): `max_settle_staleness` + `answered_in >= round_id` + `settle_fallback()`. The vault points `SERIES_FACTORY` at it.
6. The decomposed **Halmos vault-accounting suite** (F-HALMOS-SCOPE) + an independent paid audit of the accounting core — a HARD pre-deploy gate.

**Phase 2 (gated on P1 live + M+L Halmos-proven + observed two-sided organic flow):** PWV (USDC/M put writing); the two-sided delta-balance; the **senior staked-spUSD tranche** (`stspUSD` wrapper, fee-skim, `autonomous_convert` only against a deep NAV-priced spUSD venue — never the current thin pool); the tranche-separation theorem; the Earn "Stake spUSD" tile; an on-chain `HouseRegistry` (curated JSON in v1).

**De-risking decision (F-V1-SCOPE).** Preferred: build and operate the P2 dated-series mechanics first as standalone **pausable, owner-controlled** contracts (per `leverage-menu-spec`, with kill switches) so the strike-snap / tier-cap / keeper-race logic is exercised under an owner before it is frozen into immutable bytecode. Only then collapse into the immutable vault. If instead collapsing directly into one immutable deploy, it MUST be gated behind the full menu-logic Halmos suite + tiny launch caps + an explicit note that the immutability/no-kill-switch claim now covers from-scratch, never-operated dated-series machinery — the riskiest possible thing to freeze.

---

## 9. Honest risks + bottom line + GO/NO-GO

**Risks, stated plainly.**
- **No-signer adverse selection (PRIME).** A deterministic on-chain price off a fresh oracle is sandwich/oracle-tip exploitable in exactly the way a smart signer avoided. The formula quotes structurally wider (5-8× a signer's edge) and the cumulative MEV bleed to searchers is a junior-LP cost; the floor + tight staleness + per-block/per-window caps bound the per-block loss but do not eliminate the bleed. Safe-but-wide at ≲5x; **unsafe ≥10x on the 7200s Sepolia feed** until F-SETTLE-STALE is resolved (§5.2).
- **Cold start.** Mechanically self-bootstrapping (`DEAD_SHARES`, no seed tx, no owner), but economically adverse-selection-dominated with no operator seed and no flow — and the formulaic quote is *easier* to pick off than a smart signer. Early junior epochs may be net-negative.
- **v1 is one-sided.** Without P1/PWV, v1 is a directional short-call short-vol house — the mirror of the killed vault, honestly framed: capped per-epoch by the immutable writer cap, capped at deposit, never liquidated, but a sustained one-sided regime walks junior NAV toward zero over K epochs.
- **Dead-oracle trap (CRITICAL, F-DEAD-ORACLE)** and **immutable un-patchability**: a bug or a sunset feed has no pause, no admin, no upgrade — only `force_redeem` + redeploy-v2.

**Bottom line.** The junior is a genuinely-collateralized, never-liquidated, capped-loss short-vol position with real positive carry — an attractive "be the house" product **only** post-P1 two-sided flow, with tiny caps, and with honest "you can lose principal, the formula chooses the bets, it quotes wide and is MEV-exposed because it has no operator to dodge a known rip" framing. It is **not a yield product.** The senior staked-spUSD tranche is structurally sound and loss-protected but ~zero until flow exists, so it is correctly deferred.

**GO / NO-GO on shipping an IMMUTABLE v1:**

- **NO-GO** on freezing immutable bytecode that writes the [5,10,20]x menu against the unhardened settlement path. F-DEAD-ORACLE (critical) and F-SETTLE-STALE (high) are un-patchable in an immutable contract; the keeper guard cannot protect a direct permissionless `settle()`. These MUST be resolved in a hardened `OptionSeries` blueprint (or the writable leverage capped to the settle-safe ≲2-3x) **before** freeze.
- **NO-GO** on freezing before the decomposed vault-accounting Halmos suite (F-HALMOS-SCOPE) AND an independent audit of the accounting core close — for an un-patchable contract custodying pooled funds, proof + audit are the only safety net.
- **GO**, conditionally, on this path: **first prove demand and exercise the dated-series + keeper-race mechanics on the operated, pausable P2 contracts** (kill switches intact), with the operator desks as the seeded interim venue. This is the recommended sequence — it converts the biggest unknowns (does organic two-sided flow exist? does the strike-snap/keeper logic converge under load?) into observations *before* anything is frozen. Then collapse to the immutable, junior-only CWV vault with tiny caps (write cap ≤20% NAV, small `MAX_FILL`, short outflow window), the hardened settlement primitive, `force_redeem`, the full Halmos suite + audit, and the mainnet-revisit + named-entity disclosures carried in README/Earn/deploy-header.
- **Do NOT** ship the senior staked-spUSD tranche, `autonomous_convert`, or PWV in immutable v1 (F-SENIOR-COLD, F-CONVERT) — all are additive phase-2 fresh deploys gated on P1 + measured flow.

Net: immutable v1 is the right *eventual* shape (it is the cleanest proof of "no centralization risk"), but immutability is a one-way door — prove demand and harden the settlement primitive on operated, pausable contracts first; freeze only the junior-only CWV vault, only after the settlement and accounting gates close.

*Sepolia testnet, research code, unaudited.*