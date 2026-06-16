# Gimbal P2 — Leverage-tier menu (multi-strike dated series) (spec)

> **⤳ Unified into [`autonomous-vault-spec.md`](autonomous-vault-spec.md)** — the crowd-owned immutable end-state folds this in. This doc stays the detail for its piece; the master holds the architecture + the **GO/NO-GO** (prove demand on the *pausable* operated desks first, then freeze immutable — immutability is a one-way door).

> Build spec, not a sketch. **P2** of `split-derived-roadmap.md`. A **leverage market** layer that
> exposes Split's `[2,5,10,20]`-style menu — where **leverage is set by the option STRIKE/premium, not
> by margin** (`leverage = 1/(1−r)`, `r = STRIKE/x₀ = spot/premiumPerN`, exactly Split's formula) — by
> minting **DATED, standalone `OptionSeries`** at a fixed grid of strikes per asset, each with a short
> expiry, each fronted by a per-series RFQ desk. It reuses the entire built stack verbatim:
> `OptionSeries` (dated), `SeriesFactory`, `OracleHub`, and the `SignedQuoteFiller` desk + EIP-712 +
> guardrail skeleton (G1–G6). It composes with **P1** (the short/PUT series joins the same menu once it
> lands) and **P3** (the writer vault funds depth across the menu's series). House style follows
> `solo-rfq-spec.md` §5 and `stable-rfq-spec.md` §5/§7.
>
> **Sepolia testnet, research code, unaudited. Every tier is a short-dated, high-theta directional bet;
> capped loss = premium; no liquidation, no margin, no funding — by construction.**

---

## ⚠ Banner: the verdict, in one screen

**ROLLING vs DATED — the headline decision: DATED standalone series, NOT the rolling soft-peg DAO.**
The single most important finding, verified against the real contracts and the leverage math, is that
**the rolling `TrackerDAO` path structurally cannot do 5x/10x/20x, and the clean path for the leverage
menu is a registry of DATED standalone `OptionSeries` that are NOT wrapped in any rolling DAO.**

* The rolling DAO's **genesis-brick guard** is `assert strike_ratio * roll_trigger <= UNIT*UNIT*95//100`
  (`TrackerDAO.vy:170`). At the live `roll_trigger = 1.5e18` it pins the max rolling `strike_ratio` to
  `0.95/1.5 = 0.633` ⇒ a **~2.73x ceiling**, and the highest-leverage rolling series always sits a
  *constant 5%* of ETH-drawdown from its own roll trigger (hair-trigger, perpetual re-vintaging — the
  failure mode in `clear-n-findings.md`). The guard is load-bearing for the *roll* mechanic; it cannot
  be relaxed without re-introducing the self-roll brick.
* A **dated** `OptionSeries` never rolls. The guard lives only in `TrackerDAO.__init__` — neither
  `SeriesFactory.vy` nor `OptionSeries.vy` reads `roll_trigger`. `SeriesFactory.create_series` mints
  **any** strike (`assert strike > 0`, `SeriesFactory.vy:54`) for any registered asset, deduped on
  `(asset, strike, maturity)`. A dated `r=0.95` (20x) series is a perfectly legal `OptionSeries` that
  just expires at `MATURITY`: `settle()` once (`OptionSeries.vy:182`), then `redeem_n`/`redeem_p`, or
  `merge` oracle-free any time. Capped loss = premium; the genesis-brick guard never binds.

**THE REAL LEVERAGE CEILING for dated series is ~20x — and it is NOT the settle math.** `settle()`
computes `payout_p = STRIKE*1e18//x` capped at `1e18`, `payout_n = 1e18 − payout_p`
(`OptionSeries.vy:194-198`); conservation is exact and the integer-division error is **sub-wei even at
20x and beyond** (≈1e-17 relative at r=0.99). Rounding does not cap leverage. The real ceiling is a
stack of *economic / oracle / desk-mechanics* limits, every one of which says **20x is the honest
deployable maximum, 40x+ is degenerate**:

1. **Oracle-deviation amplification = `leverage × feed-deviation`.** `dN/N ≈ lev·(dx/x)`, so one
   Chainlink ~0.5% deviation tick moves N by `lev×0.5%` — **10% of N at 20x, ~20% at 40x.**
2. **The desk's hard 20% edge cap collides with the tier.** `MAX_MIN_EDGE = 10**18//5` (20%,
   `SignedQuoteFiller.vy:121`). Required `min_edge ≈ lev × within-staleness-drift`; at a 0.5% drift, 20x
   needs ~10% edge (fits), **40x needs ~20% (saturates the cap)** — a 40x desk cannot be deployed
   safely. This is a *contract-enforced* ceiling, not just config.
3. **High tiers are born inside the no-trade band.** A 20x series sits 5% above strike at genesis; the
   desk's near-strike band must be re-tuned far below the rolling desk's `roll_trigger`-pinned floor or
   the desk refuses to quote from block one (see §4 / F2).
4. **Theta / expiry-worthless rises as `1/lev`.** A 20x N is worthless after a 5% ETH drop *or* if ETH
   is flat at maturity. That is the product, not a bug — but it makes 20x a *bet*, not a *position*.

**Bottom line up front:** ship a `[2,3,5,10,20]` menu shape, **launch ≤10x** (2x via the existing
rolling desk, 3x/5x/10x dated), **20x is a marginal phase-2 tier**, **40x+ is refused at the registry**.
P2 is **orchestration + discovery + one thin dated-desk variant** — no new core math, capped loss =
premium throughout.

---

## 1. What it is

A **leverage market** = a permissionless, enumerable **registry** + a permissionless **keeper** that
mint **DATED, standalone** `OptionSeries` across a fixed strike grid per asset, plus **per-series RFQ
desks** (a dated variant of the deployed `SignedQuoteFiller`). Two new thin contracts, two reuses
unchanged, one desk generalization.

| Contract | Status | Role |
|---|---|---|
| `OptionSeries.vy` | **UNCHANGED** | The dated P/N primitive. High strikes are already legal & sound (§2). |
| `SeriesFactory.vy` | **UNCHANGED** | Mints/dedupes dated series at any strike. The keeper calls it. |
| `OracleHub.vy` | **UNCHANGED** (one optional 1-line hardening flagged, F-SETTLE-ROUND) | `x = ETH` in asset units; strike anchor + desk floor + settle index source. |
| `LeverageMenuRegistry.vy` | **NEW** (thin, enumerable, holds no funds) | Groups SeriesFactory series into per-asset **tiers** (2/3/5/10/20x) + maturities; enumerates the live menu for a UI; immutable allowed strike-ratio grid hard-capped below 40x; **keeper-only `_list`**; holds no funds, no admin over series. Mirrors `SeriesFactory`/`TrackerFactory`/`PeripheryFactory`. |
| `LeverageMenuKeeper.vy` | **NEW** (thin, permissionless, holds no funds) | Maintains the *live* menu: mints the next maturity's cohort before/at expiry (mint-fresh-on-expiry), advances the registry's active pointer, courtesy `poke_settle`. `TrackerDAO.sync()`-shaped minus all the roll logic. |
| `SeriesQuoteFiller.vy` | **NEW** (the desk, generalized by subtraction) | `SignedQuoteFiller` MINUS the `ITracker`/roll coupling, PLUS an immutable `SERIES`. EIP-712 + G1/G2/G4/G5/G6 verbatim. **This is the one real code deliverable** (the existing desk will not deploy against a dated series — F-BLOCKER). |
| `OperatorDeskRegistry.vy` | **EXTENDED** (from `solo-rfq-spec.md §7`) | Re-keyed to enumerate desks **per series** (and per tier) so a UI maps "10x spUSD desk → 0x…". |

The registry and keeper are as fund-less/admin-free as `PeripheryFactory` (they could be EIP-5202
blueprint-deployed and listed the same way). The desks stay **out** of `PeripheryFactory` — they
custody the operator's capital, exactly the reasoning the N and stable specs give.

**The menu is kept populated, not the user's position.** Each individual dated series just expires; the
keeper rolls the *cohort* (mint-fresh-on-expiry) so a "10x-spXXX is always available to buy" — but a
user's bought N is never silently rolled (that would re-introduce the vintage churn we rejected for
rolling). Continued exposure = re-buy the next series.

---

## 2. Leverage math, the strike→leverage→tenor table, and the ceiling

### 2.1 Leverage = strike, derived from our own settle math

At genesis spot `x₀` (ETH in asset units, 1e18) a tier at ratio `r` is minted with `strike = x₀·r`.
A unit of N at genesis is worth `intrinsic_n(x₀) = 1e18 − STRIKE·1e18//x₀ = (1−r)·1e18` ETH — this is
*exactly* `OptionSeries.settle()`'s `payout_n` (`OptionSeries.vy:194-198`) and the desk's `intrinsic_n`
(`SignedQuoteFiller.vy:223`). So **premium per N = (1−r) ETH** and **leverage on ETH = `x₀/premium =
1/(1−r)`** — Split's `leverage = spot/premiumPerN`, re-derived from *our* math, not copied.

### 2.2 The menu: strike → leverage → tenor → desk-safety

Tenor scales **down** with leverage (high tiers sit closer to strike, amplify oracle drift, and need a
tighter desk staleness, so they must live shorter). Desk safety scales **up** with leverage.

| tier | r = STRIKE/x₀ | leverage 1/(1−r) | premium/N = max loss (ETH) | ETH-drop→worthless (1/lev) | one 0.5% feed tick → % of N | recommended tenor | required `min_edge` ≈ lev×0.5% (vs 20% cap) |
|---|---|---|---|---|---|---|---|
| 2x | 0.500 | 2.0x | 0.500 | 50.0% | 1.0% | 30d (or the rolling peg) | 1% ✓ |
| **3x** | 0.667 | 3.0x | 0.333 | 33.3% | 1.5% | 21d | 1.5% ✓ |
| **5x** | 0.800 | 5.0x | 0.200 | 20.0% | 2.5% | 14d | 2.5% ✓ |
| **10x** | 0.900 | 10.0x | 0.100 | 10.0% | 5.0% | 7d | 5% ✓ |
| **20x** | 0.950 | 20.0x | 0.050 | 5.0% | 10.0% | 3d | 10% ✓ (half the cap) |
| (40x — **refused**) | 0.975 | 40.0x | 0.025 | 2.5% | 20.0% | — | **20% = saturates cap ✗** |

`SeriesFactory.MIN_TERM = 3600` (1h) and `MAX_TERM = 5y` (`SeriesFactory.vy:20-21`) bound every tenor
comfortably. Strikes are stored as **ratios `r` (1e18)**, not absolute strikes, so the keeper mints at
the *current* spot each maturity and the leverage label stays stable across vintages.

### 2.3 The real ceiling for dated series (verified, NOT settle rounding)

* **Settle rounding is a non-issue.** `payout_p = STRIKE*1e18//x` truncates ≤1 wei per 1e18; at 20x
  (`payout_n ≈ 0.05e18`) the relative error is ~1e-16, ~1e-15 even at r=0.99 (100x). Conservation
  (`payout_p + payout_n == 1e18`) is exact by construction. **The settle math does not cap leverage,
  and the genesis-brick analog (a self-roll brick) does not exist for a non-rolling dated series.**
* **Oracle-deviation amplification is the first real limit:** `lev × feed-deviation`. 10% of N per 0.5%
  tick at 20x, ~20% at 40x. This forces tier-scaled `min_edge`/`DESK_MAX_STALENESS`/`MAX_FILL` (§4).
* **The desk's 20% edge cap is the contract-enforced ceiling.** `MAX_MIN_EDGE = 10**18//5`
  (`SignedQuoteFiller.vy:121`); the floor asserts `q.min_edge >= MIN_EDGE and q.min_edge <= MAX_MIN_EDGE`
  (`SignedQuoteFiller.vy:316`). Required edge ≈ `lev × within-staleness-drift`; at a tame 0.5% drift, 20x
  needs ~10% (fits, half the cap), **40x needs ~20% (zero headroom — the deploy/fill reverts).** Raising
  `MAX_MIN_EDGE` would make every desk's spread untradeable and weaken taker protection, so it is not an
  option. **This is precisely what makes ~20x the contract-level maximum** — the registry hard-caps the
  grid below it.
* **Near-strike no-trade band shrinks a high tier's tradeable life** (§4 / F2). A 20x series is born ~5%
  above strike, almost inside the band; a 5% dip takes it to intrinsic≈0 and the desk goes dark.
* **Theta / expiry-worthless** is the economic co-limit, rising as `1/lev`. Genuine, not a bug; framed
  honestly per tier in the UX (§7).

**Net ceiling statement:** dated series settle a 20x strike cleanly (capped loss = premium); the limit
is (1) oracle amplification, (2) the 20% edge cap, (3) the near-strike band, (4) theta. `[2,3,5,10,20]`
is the menu shape; **20x is the honest practical ceiling; launch ≤10x; refuse 40x+ at the registry.**

---

## 3. Contracts (real signatures)

### 3.1 `LeverageMenuRegistry.vy` — the enumerable menu

`# pragma version ==0.4.3`. Permissionless, holds no funds. Groups dated series into a **market** =
`(asset, tier-set, term-schedule)`, keyed so a UI discovers the whole menu without a config file
(mirrors `SeriesFactory`/`TrackerFactory` enumeration and the `is_series`/`is_tracker` bytecode-trust
flag).

```vyper
struct Tier:
    label:  uint16      # 2,3,5,10,20 (the leverage badge; informational)
    ratio:  uint256     # r = STRIKE/x0, 1e18 (the canonical field; strike derived at mint)
    is_put: bool        # False = call/long; True = put/short (P1 — minted via the P1 short factory)

MAX_RATIO: constant(uint256) = 96 * 10**16   # r < 0.96  => leverage < 25x; REFUSES 40x+ (the edge-cap ceiling)
MAX_TIERS: constant(uint256) = 8

event MarketCreated:
    market_id: indexed(bytes32)   # keccak256(abi_encode(asset, term, is_put_set))
    asset:     indexed(bytes32)
    term:      uint256
    n_tiers:   uint256
    creator:   address

event SeriesListed:
    market_id: indexed(bytes32)
    series:    indexed(address)
    tier:      uint16
    strike:    uint256
    maturity:  uint256

# --- creation (permissionless; records the schedule, does NOT mint — the keeper mints) ---
def createMarket(asset: bytes32, tiers: DynArray[Tier, MAX_TIERS], term: uint256,
                 strike_tick: uint256) -> bytes32: nonpayable
    # asset is_registered in the hub; tiers strictly ascending by ratio, each 0 < ratio <= MAX_RATIO
    #   (this is the on-chain 40x refusal); term in [MIN_TERM, MAX_TERM]; dedupe on market_id.

# --- enumeration (the UI menu) ---
def marketCount() -> uint256: view
def marketAt(i: uint256) -> bytes32: view
def market(market_id: bytes32) -> (bytes32, uint256, uint256): view     # (asset, term, n_tiers)
def tiers(market_id: bytes32) -> DynArray[Tier, MAX_TIERS]: view
def activeSeries(market_id: bytes32) -> DynArray[address, MAX_TIERS]: view   # the live front cohort
def activeMaturity(market_id: bytes32) -> uint256: view
def listSeries(market_id: bytes32) -> DynArray[address, MAX_LISTED]: view    # live + recent (term ladder)
def seriesAt(market_id: bytes32, tier: uint16, maturity: uint256) -> address: view
def tierOf(series: address) -> (bytes32, uint16): view                  # reverse lookup
def is_listed(series: address) -> bool: view                            # menu/bytecode-trust flag

# --- keeper-only writer (the registry trusts the keeper; the keeper only ever lists a series
#     SeriesFactory.is_series[series] confirms, so a griefer cannot inject a junk series) ---
def _list(series: address, tier: uint16, maturity: uint256): nonpayable   # internal, keeper-gated
```

**Strike legibility / dedupe stability:** the keeper snaps `strike = round_to_tick(x_at_mint·r,
strike_tick)` (e.g. $50 for USD). Snapping makes the trader-facing symbol clean (`N-USD-1900-260710`,
from `OptionSeries._strike_str`, `OptionSeries.vy:136`) **and** keeps the `SeriesFactory`
`(asset,strike,maturity)` dedupe deterministic across keepers.

### 3.2 `LeverageMenuKeeper.vy` — mint-fresh-on-expiry, the live menu

`# pragma version ==0.4.3`. Permissionless, holds no funds. The only new control logic — a *cohort*
roll at the registry/UI layer, **never** an `OptionSeries` roll.

```vyper
interface ISeriesFactory:
    def create_series(asset: bytes32, strike: uint256, maturity: uint256) -> address: nonpayable
    def is_series(addr: address) -> bool: view
interface IOracleHub:
    def latest_price(asset: bytes32) -> uint256: view
interface IOptionSeries:
    def MATURITY() -> uint256: view
    def settled() -> bool: view
    def settle(): nonpayable

ROLL_AHEAD: constant(uint256) = ...   # mint the next cohort this long before the front matures

def bootstrap(market_id: bytes32) -> DynArray[address, MAX_TIERS]: nonpayable   # first cohort
def refresh(market_id: bytes32) -> DynArray[address, MAX_TIERS]: nonpayable     # heartbeat (idempotent)
def poke_settle(series: address): nonpayable                                    # courtesy settle() wrapper
```

`refresh`/`bootstrap` mechanics:
1. **Registry-first convergence (F-KEEPER-RACE):** look up `seriesAt(market_id, tier, M)` first; if
   present, return it. Only the *first* minter of a `(tier, cohort)` ever reads the oracle or calls
   `create_series` — this mirrors `TrackerDAO.sync()`'s "mint only if the stored pointer is empty"
   guard and makes per-block oracle drift irrelevant to dedupe.
2. read `x₀ = OracleHub.latest_price(asset)` (the hub's freshness assert applies);
3. choose `M = align(block.timestamp + term, MATURITY_GRID)` (snap to a fixed weekly/biweekly UTC
   boundary per tier so all tiers in a cohort share one expiry and dedupe is stable across keepers);
4. per tier: `strike = round_to_tick(x₀·tier.ratio//UNIT, strike_tick)`;
   `series = SeriesFactory.create_series(asset, strike, M)`;
5. `registry._list(series, tier.label, M)`; set `active_series`/`active_maturity`.

**Overlap window (no menu gap):** mint the next cohort `ROLL_AHEAD` *before* the current one matures, so
`activeSeries()` always returns a cohort with real time-to-expiry and the desks' `PRE_MATURITY_BUFFER`
never forces the whole menu dark. The keeper has **zero privilege over value**: `settle()` is already
permissionless; worst-case keeper bug = a stale `active_maturity` pointer, self-healed by any caller
re-running the idempotent `refresh`.

### 3.3 `SeriesQuoteFiller.vy` — the desk, generalized by subtraction (the one real code deliverable)

The deployed `SignedQuoteFiller` **will not deploy against a dated series** — `__init__` does
`roll_trigger = staticcall ITracker(tracker).ROLL_TRIGGER()` then `assert strike_proximity >=
roll_trigger` (`SignedQuoteFiller.vy:190-191`); a dated `OptionSeries` has no `ROLL_TRIGGER()`, so the
deploy reverts. G3 reads `ITracker.pending_series()/active_series()` (`:292-295`); a dated series has no
tracker. This is a **hard blocker (F-BLOCKER)**, not config. The fix is a sibling contract that
generalizes by *subtraction*:

| `SignedQuoteFiller` (rolling N desk) | `SeriesQuoteFiller` (dated menu desk) |
|---|---|
| `TRACKER` immutable + `ITracker` interface | **deleted** — `SERIES` immutable instead |
| `__init__` reads `ROLL_TRIGGER`, asserts `strike_proximity >= roll_trigger` (`:190-191`) | **delete both lines**; `strike_proximity` a direct ctor param, asserted `> UNIT and <= SP_CEILING` (e.g. `1.1e18`) so the band still excludes `x<=STRIKE` (§4 / F2) |
| G3: `target = pending/active_series(); assert q.series == target` (`:292-295`) | G3: `assert q.series == SERIES` (one constant compare; vintage-safe by construction — a dated series never rolls) |
| `Quote.series` signed (roll-safety) | **keep `Quote.series`** so the EIP-712 digest shape + frontend/quoter ABI stay byte-identical (equals `SERIES`; belt-and-suspenders) |
| `net_n: HashMap[address,int256]` per-vintage | keep the HashMap shape (one live key = `SERIES`) so merge/redeem wind-down is byte-for-byte reused |
| `NAME_HASH = keccak256("Gimbal Solo RFQ Desk")` | distinct `NAME_HASH = keccak256("Gimbal Series RFQ Desk")` (F-DOMAIN discipline, per the stable spec) |
| `PRE_MATURITY_BUFFER` + permissionless settle | **unchanged but now load-bearing** — a dated series *will* reach maturity (it never rolls away first), so the buffer + `operator_redeem_n` after `settled()` is the *normal* end-of-life, not an edge case |

**Kept verbatim:** the EIP-712 domain (recomputed, includes `self`, fork-safe `_digest`), G1 (sig is the
only fill authority), G2 (replay/deadline/taker, CEI nonce consume), G4 (tight `DESK_MAX_STALENESS` +
`_assert_fresh`, including the F5 `answered_in >= round_id` completeness check at `:265`), G5 (directional
floor + no-trade band + truncation corner), G6 (`MAX_FILL`/`MAX_NAV_AT_RISK`/`MIN_ETH_FLOAT`/outflow
window), the `split`/`merge` recycle, `@nonreentrant`, and the undecorated payable `__default__`.

```vyper
def __init__(owner, series, hub, asset, quoter, min_edge, desk_max_staleness,
             pre_maturity_buffer, strike_proximity, outflow_window,
             max_fill, max_nav_at_risk, min_eth_float, outflow_cap)
    # vs SignedQuoteFiller: `tracker` -> immutable `series`; DROP the ROLL_TRIGGER read;
    # assert strike_proximity > UNIT and strike_proximity <= SP_CEILING (NOT >= roll_trigger);
    # assert asset == empty(bytes32)  (USD-only v1, single-feed freshness, F6)

def fill_buy_n(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256: payable   # taker buys N (desk sells)
def fill_sell_n(q: Quote, v: uint8, r: bytes32, s: bytes32) -> uint256           # taker sells N (desk buys)
# views/ops UNCHANGED: intrinsic_n / quote_digest / fund / fund_p / withdraw_eth / withdraw_token /
#   set_paused / set_quoter / set_caps / operator_merge / operator_redeem_n /
#   transfer_ownership / accept_ownership / __default__
```

**Frontend ABI is unchanged** (same `Quote` tuple, `fill_buy_n`/`fill_sell_n`, same views). The builder
codes against the existing ABI; the operator deploys the dated bytecode.

### 3.4 `OperatorDeskRegistry` extension (desks per tier)

Extend the registry from `solo-rfq-spec.md §7` to key desks by **series** and carry the tier:

```vyper
def deploy_desk(series: address) -> address              # blueprint-deploys a SeriesQuoteFiller; msg.sender = operator
def is_desk(addr: address) -> bool                        # bytecode-trust (NOT funds-safety)
def operator(desk: address) -> address
def deskForSeries(series: address, i: uint256) -> address
def desksForMarket(market_id: bytes32) -> DynArray[address, MAX_LISTED]   # the whole menu's desks
```

`operatorDesks.json` gains `series`, `strike`, `maturity`, `leverageTier`, `kind` (`dated|rolling`),
`strikeRatioAtList` alongside the existing `leg` field; the UI keys by `(asset, leg, series)` and
**groups by `(asset, leg)` into a tier menu**.

---

## 4. Pricing + guardrails

Identical shape to `solo-rfq-quoter-spec.md §4`, applied per series with **tier-scaled edge**:

```
fair_n(s)   = max(0, 1e18 − STRIKE(s)·1e18 // x)          # = OptionSeries payout_n, fresh oracle
leverage(s) = x // (x − STRIKE(s))                         # = 1/(1−r); the menu label
min_edge(s) = max(MIN_EDGE, MIN_EDGE_BASE · leverage(s) // 2)   # F-EDGE: scale edge with the tier
util(s)     = clamp(net_n[s] / cap_n[s], 0, 1)
DESK SELLS N(s): price >= fair_n(s)·(1 + min_edge(s))     # sell dear
DESK BUYS  N(s): price <= fair_n(s)·(1 − min_edge(s))     # buy cheap; refuse at util(s) >= 1
```

The on-chain floor (G5) re-derives `fair_n(s)` from a **fresh per-series oracle read** and asserts the
directional bound. The **one genuinely new safety requirement** is that `min_edge` must scale with the
tier — a flat `MIN_EDGE` safe at 2x is *free money* at 20x (one 0.5% tick = 10% of N vs a 1% floor).

* **Per-series desk (v1): no code change — config the deployer must get right.** Each desk is one tier,
  so set the immutable `MIN_EDGE` at deploy to `>= MIN_EDGE_BASE·lev//2` (≈ `lev × max-drift-over-
  DESK_MAX_STALENESS`), plus a **shorter `DESK_MAX_STALENESS`** (toward the `MIN_STALENESS=30`s floor,
  `SignedQuoteFiller.vy:122`) and **smaller `MAX_FILL`/`MAX_NAV_AT_RISK`** on higher tiers. The existing
  immutable floor (`:316`) backstops a stolen key down to `MIN_EDGE`, so correct config fully closes it.
  The foot-gun is deploying a 20x desk with a 2x desk's `MIN_EDGE` — so **enforce it at deploy or
  list-time** (F-EDGE): either bake a leverage-derived floor into the dated ctor
  (`assert MIN_EDGE >= MIN_EDGE_BASE * genesis_lev // 2`, where `genesis_lev = x_anchor//(x_anchor −
  STRIKE)`), or have the registry/keeper refuse to list a desk whose `MIN_EDGE` is too thin for its
  strike. The existing `MIN_EDGE <= MAX_MIN_EDGE = 20%` cap then naturally bricks 40x+ (F-CEILING).
* **Multi-series desk (phase 2): one on-chain assert** in `_verify_and_guard` after `intrinsic` is
  computed (where `lev = x//(x−strike)` is already derivable): `assert q.min_edge >= MIN_EDGE_BASE * lev
  // 2`, keeping the flat `assert q.min_edge >= MIN_EDGE` as the absolute floor. Base 1% gives
  1%/2.5%/5%/10% floors at 2x/5x/10x/20x vs needed ~0.5%/2%/4.5%/9.5%.

**The near-strike band (G5, `:314`) is the high-tier safety control — but it must be re-tuned.** With
the rolling desk's `strike_proximity >= roll_trigger = 1.5`, a 5x series is born at `x = STRIKE/0.8` ⇒
−20% inside the band, 10x at −35%, 20x at −42.5%: **all high tiers would be un-quotable from birth**
(F2/F-DEAD-DESK). The dated `SeriesQuoteFiller` must **delete the `>= roll_trigger` assert** (a dated
option has no roll danger zone) and set `strike_proximity ~1.02–1.05` (e.g. `1.05e18`): then 10x is born
with ~+5.5% headroom and 20x with ~+0.25% (marginal — its whole life is one dip from the band, which is
exactly why v1 caps at 10x). The line-`317` truncation-corner guard (`intrinsic·q.min_edge//UNIT > 0`)
and the band itself are **kept** (they block the near-strike degenerate-floor corner); only the
`roll_trigger` pin is removed. **Recommended `strike_proximity` per tier: `< 1/r`** (e.g. 1.04 keeps
20x@r=0.95 quotable at genesis since 1/0.95 = 1.0526). Operators must NOT copy the rolling desk's 1.5.

---

## 5. MM / liquidity — fragmentation, launch tier set, dependence on P3

### 5.1 The fragmentation problem and desk topology

The menu is `tiers × maturities` series, each its own `OptionSeries` with its own P/N tokens, intrinsic
curve, and merge-pair. This **fragments the operator's one capital pool across many thin books.**

| Topology | Verdict |
|---|---|
| **One desk per series** | physical partition — 5 ETH ÷ 12 series = 0.42 ETH/series, useless depth; N× the deploy/fund/quoter ops. **NO** as the *only* model — but it IS the v1 shape for a *small* tier set (blast-radius isolation, re-deploys the audited single-series contract). |
| **One multi-series desk per (asset, leg)** ⭐ | one shared ETH/inventory pool the quoter allocates across the live column; per-series `net_n` book; one EIP-712 surface (`series` already in `Quote`). The phase-2 capital-efficiency option and the natural P3 shape. Needs a **global `MAX_TOTAL_NAV_AT_RISK`** (every tier is long-ETH, so they crash together — F-MENU-CAP) and a **global outflow/float budget** (else a leaked key gets N× the blast radius). |
| **One desk for the whole grid (all assets)** | cross-asset oracle coupling, one pause kills everything. **NO** — keep per-asset isolation. |

**v1 = one `SeriesQuoteFiller` per series** for the small launch tier set (isolation, zero new state
machine). **Phase 2 = one multi-series `LeverageMenuDesk` per (asset, leg)** with the global caps, when
flow + P3 justify the larger surface. The 2x tier is *already* served by the live rolling-DAO N desk
(`SignedQuoteFiller`); the menu adds the dated 3x/5x/10x tiers alongside it.

### 5.2 The decisive constraint: capital depth → the full menu is a P3 problem

One operator with ~5 ETH (≈3 ETH NAV-at-risk budget + 2 ETH float) **cannot give real depth to a
`[2,3,5,10,20] × multiple-maturities` grid:**

| Menu scope | series | risk budget/series | useful depth? |
|---|---|---|---|
| 1 tier, 1 maturity (today) | 1 | 3.0 ETH | yes |
| 3 tiers (2/5/10x), 1 maturity | 3 | 1.0 ETH | thin but real |
| 4 tiers (+20x), 1 maturity | 4 | 0.75 ETH | marginal |
| 4 tiers × 2 maturities | 8 | 0.375 ETH | **too thin** |
| 4 tiers × 3 maturities | 12 | 0.25 ETH | **useless (depth-theater)** |

**Operator-funded credibly backs 2–3 tiers at ONE maturity. Past that the menu is depth-theater** — a
UI of 12 tiers each with ~$400 backing, every fill bouncing off `inventory-full`/`over-max-fill`. The
full menu's depth is **structurally a P3 deliverable**: the writer vault pools LP collateral to write N
across the whole grid. The desk is built **funder-agnostic** so P3 drops in cleanly — P3's vault either
becomes a privileged `fund`/`fund_p` funder, or owns the desk with shares on top — **an
ownership/config change, not a rewrite.**

**Same carry truth as the N desk:** every tier is short-theta net-long-N (the killer, neutralized only
by *who bears it*). Higher tiers bleed faster. Without P3 the operator eats it on ≤3 tiers; with P3 the
crowd bears it on the *writer* side, knowingly.

---

## 6. Confirmed findings + fixes

| # | Title | Sev | Fix (folded in) |
|---|---|---|---|
| **F-BLOCKER** | `SignedQuoteFiller` will not deploy against a dated series — `__init__` reads `ITracker.ROLL_TRIGGER()` and asserts `strike_proximity >= roll_trigger` (`:190-191`); G3 reads `pending/active_series()` (`:292-295`). The live desk was deployed with `strike_proximity = spUSD ROLL_TRIGGER` (deployments.md:111), so the coupling is exercised in production. "Reuse verbatim" understates it — it is a hard blocker. | med | Build `SeriesQuoteFiller.vy` (§3.3): immutable `SERIES` replacing `TRACKER`; delete the `ROLL_TRIGGER` read + the `>= roll_trigger` assert; G3 → `assert q.series == SERIES`; keep all of G1/G2/G4/G5/G6 + buffer + `operator_redeem_n` + EIP-712 (distinct `NAME_HASH`). Keep `Quote.series` for byte-identical digest/ABI. Do **not** attempt to deploy the existing desk against a dated series. |
| **F-DEAD-DESK / F2** | On the existing desk **every tier above 2x is born inside the no-trade band**: with `proximity = 1.5`, 5x is born at −20% headroom, 10x −35%, 20x −42.5% — refused from block one, stranding buyers with no exit while `settle()` stays alive and amplified. | **high** | In the dated variant: delete the `>= roll_trigger` floor (a dated option never rolls); accept `strike_proximity` directly, `assert strike_proximity > UNIT and <= SP_CEILING` (~1.1); recommend `~1.02–1.05` (10x ~+5.5% headroom, 20x ~+0.25%). **KEEP** the line-314 band + the line-317 truncation-corner guard; do NOT widen proximity with leverage. Gate tiers by tradeable window: **launch ≤10x; 20x is marginal phase-2.** Flag the 1.5 copy-paste trap explicitly. |
| **F-EDGE** | Tier-scaled `min_edge` is the **one genuinely new safety requirement** — a flat `MIN_EDGE` (one immutable, `:139/:316`) safe at 2x is free money at 10x/20x: an ETH move δ moves intrinsic by `δ·lev`, so a single 0.5% tick is 10% of N at 20x vs a 1% floor. The specs call it "config, not code"; that is right ONLY if the deploy/list path enforces it. | **high** | Per-series (v1): set the immutable `MIN_EDGE >= MIN_EDGE_BASE·lev//2` at deploy + shorter `DESK_MAX_STALENESS` + smaller caps; **enforce on-chain** — bake `assert MIN_EDGE >= MIN_EDGE_BASE * genesis_lev // 2` into the dated ctor (read `STRIKE()` + an anchor spot), or have the registry refuse a too-thin desk. Multi-series (phase 2): one `_verify_and_guard` assert `q.min_edge >= MIN_EDGE_BASE * lev // 2` keeping the flat floor as the absolute. Quoter computes the same so signed quotes never under-price the floor. |
| **F-CEILING** | **20x exactly saturates the desk's hard-coded 20% edge cap; 40x is structurally unquotable** — a contract-level ceiling, not config. `MAX_MIN_EDGE = 10**18//5` (`:121`); required edge ≈ `lev × drift`. At 0.5% drift 20x needs ~10% (fits), 40x needs ~20% (zero headroom). Raising the cap = untradeable spread + weaker taker protection. | med | Registry hard-caps the strike grid at `r < 0.96` (≈25x), documented as the edge-cap collision (not just oracle amplification). Set `DESK_MAX_STALENESS` aggressively short on high tiers (30–120s) so within-window drift stays ~0.5%, keeping 20x's ~10% comfortably under the cap. Add a deploy-time assert tying deployable tier to the cap so a 40x desk fails loudly. Correct the prior "raising MAX_MIN_EDGE degrades low-tier worst-case" wording — `MAX_MIN_EDGE` is a ceiling; each desk's floor is its own immutable. |
| **F-SETTLE-STALE** | **`settle()` uses the LOOSE up-to-7200s hub heartbeat, not the tight desk staleness** — a stale/timed settle print is leverage-amplified into the N payout. `OptionSeries.settle()` reads `OracleHub.latest_price()` (`:192`) at the registered heartbeat; the desk's tight `DESK_MAX_STALENESS` does not apply at settlement. A 20x series settling off a 90-min-old, 1%-low feed pays N holders ~19% less, with no recourse (`merge` needs both legs; `redeem_n` pays the fixed wrong share). | **high** | The settle feed's heartbeat × drift-rate × leverage is the *true* ceiling. (1) Keeper `poke_settle` reads `latestRoundData()` and refuses to settle a high-tier series when age > a tier-scaled bound (blocks honest-staleness settles, not an adversary calling `settle()` directly). (2) **Registry refuses high tiers against the USD sentinel** for any tenor whose required settle-freshness < the immutable 7200s `ETH_USD_HEARTBEAT`; the sentinel heartbeat cannot be tightened per-id. (3) For a genuinely tight USD settle: redeploy `OracleHub` with a smaller `ETH_USD_HEARTBEAT` for this deployment, **or** add an optional per-series `max_settle_staleness` immutable to `OptionSeries` (asserted in `settle()`) so dated high-tier series carry their own tight gate without touching the rolling soft-peg. (4) Document: 10x/20x are unsafe on the 7200s sentinel; the menu must not list them against it. |
| **F-SETTLE-TIMING** | **Permissionless one-shot `settle()` is a leverage-amplified free timing option** — first-valid-caller-wins picks the most favorable fresh block. Near a flat-to-strike expiry, a ±1% feed band swings `payout_n` 0→0.0099 ETH/N = **~2% of premium at 2x but ~20% at 20x**; the N-writer (operator) monitoring the feed calls `settle()` on a downtick, the N holder cannot symmetrically pre-empt. Settle-time *manipulation* of the single read moves N by `lev×δ` (harder on mainnet ETH/USD, easier on thin Sepolia/RWA feeds, multiplied by the roadmap's two-feed RWA path). Capped loss protects the *downside* (max loss = premium) but NOT the settle-time *value* of an ITM high-tier N. | med | (1) Operate a prompt deterministic keeper that calls `settle()` at the first fresh block at/after `MATURITY`, collapsing both sides' discretion to one unbiased first-print; stagger maturities so settlements don't cluster. (2) UX: state explicitly that settlement is a single fixed oracle print at/after maturity, not an average, and is a coin-flip near strike the holder doesn't control (extend the "high-theta bet" copy). (3) For RWA/20x, register a tight-heartbeat content-addressed asset id and pin high tiers to it (does NOT help the v1 USD sentinel — its heartbeat is a hub immutable). (4) Only if high tiers prove exploitable, consider a high-tier-only settle guard (short TWAP / N-in-bound rounds) — a *core* change, so flag it as a tradeoff vs "OptionSeries ships unchanged," do not ship by default. |
| **F-SETTLE-ROUND** | `settle()`'s `OracleHub._read` (`:124-138`) **omits the carried-over-round completeness check** the desk enforces — a stuck round (`answeredInRound < roundId`, `updated_at` still inside heartbeat) reverts a *fill* (`SignedQuoteFiller.vy:265`) but is *accepted* by `settle()`, fixing `payout_n` off a carried stale value, amplified ~lev×. | low | Fold the check into `OracleHub._read` so every consumer (settle, register, sync, desks) inherits it: after the existing asserts add `assert answered_in >= round_id, "incomplete round"` (`answered_in` is already destructured at `:132`, just unused). A small safe core hardening, free on healthy mainnet feeds, strictly better than a keeper pre-check because `settle()` is permissionless (a guard outside the executed path cannot stop a griefing caller). |
| **F-KEEPER-RACE** | The keeper strike-snap is **not idempotent across blocks** — `strike = round_to_tick(latest_price·r)` reads live oracle x; two keeper calls in different blocks read different x ⇒ different rounded strikes ⇒ different `(asset,strike,maturity)` keys ⇒ the `SeriesFactory` dedupe (`:58`) does NOT collapse them ⇒ two distinct series per logical tier+cohort, fragmenting liquidity. The "dedupe makes concurrent keepers safe" claim has a real hole. | low | Make the **registry the convergence authority** (§3.2 step 1): `refresh`/`bootstrap` check `seriesAt(market_id, tier, M)` BEFORE reading the oracle; the first minter is authoritative, a second keeper reads the registry and never the oracle — per-block drift is irrelevant. Mirrors `TrackerDAO.sync()`'s "mint only if empty" guard (proven race-safe in production). Keep the deterministic maturity-grid snap; demote the `SeriesFactory` dedupe to a backstop. A losing concurrent keeper burns one cheap revert. |
| **F-MENU-CAP** | (multi-series desk only) Per-series NAV-at-risk caps **sum** far above the 5-ETH reserve, and every tier is long-ETH so a correlated crash hits all books at once; per-window outflow + `MIN_ETH_FLOAT` applied per-series gives a leaked key N× the blast radius. | high (phase 2) | Add a **global `MAX_TOTAL_NAV_AT_RISK`** asserted on every buy-N across all series (books compete for one budget; at the cap the desk goes sells-only menu-wide) and make the **outflow window + `MIN_ETH_FLOAT` global**. Per-series caps still enforced; higher tiers get smaller per-series caps. v1's one-desk-per-series sidesteps this (physical isolation); it binds only when the multi-series desk ships. |
| **F-MERGE-VINTAGE** | Merge-recycle is **per-vintage**: P of a 5x series cannot merge against N of a 10x series (different `OptionSeries` contracts), so the desk's oracle-free capital recovery is fragmented across the menu. | med | Quoter prefers immediately-mergeable fills *within the same series*; `fund_p(series,…)` per tier where flow concentrates. Cross-tier inventory is not a merge pair — only `redeem_n` after settlement or same-series `merge` recovers it. Keep caps small so the un-mergeable bag stays small. |
| **F-THETA-UX** | High tiers are born ~5% above strike (20x) and decay to 0 on a small ETH drop *or* on flat ETH at expiry; users see "leverage" and miss the theta. | med | Mandatory per-tier honest framing + distance-to-worthless + expiry countdown (§7); 20x deferred to phase 2 with the strong copy. Theta is the *product* (capped loss = premium), not a leak — say so loudly. |
| **F-EXPIRY-STRAND** | Dated positions don't auto-roll; a user who ignores expiry holds N the desk stops quoting inside `PRE_MATURITY_BUFFER` and may forget to redeem. | med | Full expiry state machine (§7) with near-expiry/desk-dark warnings, permissionless `settle()` + always-available `merge()`/`redeem_n` escapes, loud expired-unredeemed portfolio state. |
| **F-PHANTOM-POOL** | The deployed `LeverageRouter`/pool is wired only to the legacy 2x rolling series; the new menu strikes have no P-sink pool, so a best-ex UI might show a phantom Uniswap fallback. | med | v1 rule: **menu N is RFQ-exclusive (buy AND sell)**; show "RFQ only — no pool route for this strike." Only the legacy 2x tier keeps a pool fallback (§7). |
| **F-XTIER-ROUTE** | Best-ex "improving" a 5x buy onto the 10x desk silently changes the user's instrument (different strike, payoff, max loss). | med | Tiers are **siblings, not substitutes** — never cross-route between strikes. Router scopes to one `(tier, side)` (§7). |
| **F-STALE-LABEL** | `leverageTier` in discovery is genesis r; live leverage drifts with spot, so the static label misleads after a move. | low | Show genesis label + **live** leverage recomputed `1e18·x//(x−S)`; "—" inside the no-trade band. |
| **F-SHORT** | Once P1's PUT/short series land they must dodge the `mint-to-sell`→orphan trap (`stable-rfq-spec.md` F-ORPHAN) and use stable (not ETH) collateral (collateral must not fall with the thing shorted). | low | Short desk is its own contract (mirror settle math, stable collateral, inventory-based stable leg); reuses this MM topology + the global-cap/tier-scaled-edge findings. The menu's discovery carries a `leg ∈ {N-long, N-short}` discriminator from day one so shorts slot in. |
| **F-SHARED-CAPITAL** | One operator funding N tiers + spUSD + (later) shorts double-counts the reserve across desks. | low | Allocate the reserve across desks; don't apply full per-desk sizing to each (per `stable-rfq-spec.md` F-SHARED). Document partial-offset, not a hedge. |

---

## 7. How it plugs in (routing, UX, compose with P1/P3)

### 7.1 Routing — per `(tier, side)`, RFQ-exclusive

Reuse `solo-rfq-routing-spec.md` **per tier**. Each tier is an independent market with its own desk;
the router builds `quote(tier, side, size)` per tier. **Menu N is RFQ-exclusive (buy and sell)** —
the new strikes have no P-sink pool (F-PHANTOM-POOL); only the legacy 2x rolling tier shows a Uniswap
buy-N fallback. **Never cross-route between tiers** (F-XTIER-ROUTE): a 5x and a 10x are different
instruments. Capacity hints per tier from each desk's `net_n`/`max_fill`/`max_nav_at_risk`; treat the
quoter's `over-max-fill`/`inventory-full`/`near-strike`/`near-maturity` as truth.

### 7.2 UX — the Split-style tier picker + the new expiry surface

* **Tier picker** (one card per tier under each asset's Leverage tab): live leverage (`1e18·x//(x−S)`)
  + genesis label, premium per N (= the capped max loss), distance-to-worthless (`(x−S)/x`), breakeven,
  **liquidation: none** (the brand), expiry + countdown.
* **Mandatory honest framing per tier**, strong on the high tiers: *"20x = a short-dated high-theta bet.
  Max loss = the premium (0.05 ETH/N), no liquidation — but N goes to zero if ETH falls just 5%, or if
  it doesn't rise before expiry. Higher leverage = thinner safety band + faster decay."* Soften on low
  tiers; never imply leverage is decay-free.
* **Trust label on every tier** (verbatim from the existing handoffs): "Operator-quoted desk — your
  counterparty is 0x… (operator), not the Gimbal protocol; quotes signed off-chain, filled at a price
  floored on-chain," cross-checked against `operatorDesks.json` + on-chain `quoter()`. "Sepolia
  testnet, research code, unaudited" globally.
* **Buy/sell flow = the existing signed-quote flow unchanged**, keyed to the tier's `series` +
  `quoterUrl`: `POST {quoterUrl}/quote {side, series, n_amount, taker?}` → signed `Quote` + `v,r,s` →
  `fill_buy_n{value: floor(amount·price/1e18)}` or `approve(desk,amount)` + `fill_sell_n`.
* **Expiry state machine (the biggest net-new UX — dated positions expire):**
  `live → near-expiry (T − PRE_MATURITY_BUFFER, "desk stops quoting in Nd") → expired-unsettled (surface
  permissionless settle() or a keeper) → settled-redeemable (one-click redeem_n)`. Exit paths confirmed
  in `OptionSeries.vy`: **close early** (sell N to the desk, or `merge()` if holding both legs,
  oracle-free, `:167`), **roll forward** (manual two-quote: sell expiring N + buy next-term N same tier),
  **settle** (permissionless, `:182`), **redeem** (`redeem_n`, `:218`). Always-available escapes:
  `merge()` (if holding P) + post-settle `redeem_n`. Loud expired-unredeemed portfolio state.
* **Long/short toggle** present but gated ("shorts coming with P1") until the put series lands.

### 7.3 Compose with P1 (shorts) and P3 (writer vault)

* **P1 — shorts join the same menu for free.** `Tier.is_put` already discriminates; P1's
  stable-collateralized PUT series register under the same registry/keeper/enumeration (the layer is
  instrument-agnostic: it groups `(asset, tier, maturity) → series` regardless of call/put). A short
  `SeriesQuoteFiller` sibling attaches per series via the same `OperatorDeskRegistry`; the long/short
  toggle, tier menu, honest framing, expiry UX, and routing are all reused. Until P1 ships, the toggle
  is gated.
* **P3 — the writer vault funds depth across the menu.** P3's vault becomes the **funder/operator**
  behind the per-series desks (privileged `fund`/`fund_p` rights, or owns the desk with shares on top),
  turning operator-funded ≤3 tiers into crowd-funded full-grid depth. Capacity hints and the routing
  capacity logic are the *same code*; only the depth grows. The desk is built funder-agnostic so this is
  an ownership/config change, not a rewrite. P3 depends on P1+P2 live with real flow, so the menu ships
  first and P3 plugs into its discovery + capacity surfaces.

---

## 8. Components to build — v1 vs phase 2

**v1 (operator-funded, narrow menu, USD-only, longs):**
1. **`SeriesQuoteFiller.vy`** — the dated desk (§3.3): immutable `SERIES`; delete the `ROLL_TRIGGER`
   read + `>= roll_trigger` assert; G3 → `assert q.series == SERIES`; `strike_proximity` direct ctor
   param (~1.05); enforce `MIN_EDGE >= MIN_EDGE_BASE·genesis_lev//2` at deploy (F-EDGE); keep all of
   G1/G2/G4/G5/G6 + buffer + `operator_redeem_n` + distinct `NAME_HASH`. Frontend ABI unchanged.
2. **`LeverageMenuRegistry.vy`** — `createMarket` + enumeration; immutable strike-ratio grid `r < 0.96`
   (refuses 40x+, F-CEILING); keeper-only `_list` (only series `SeriesFactory.is_series` confirms);
   dedupe on `market_id` and `(market_id,tier,maturity)`. Holds no funds.
3. **`LeverageMenuKeeper.vy`** — `bootstrap`/`refresh`/`poke_settle`; **registry-first convergence**
   (F-KEEPER-RACE); live-spot strike snapped to tick; maturity-grid align; overlap mint `ROLL_AHEAD`
   before expiry; `poke_settle` refuses honest-stale high-tier settles (F-SETTLE-STALE). Holds no funds.
4. **`OperatorDeskRegistry`** (extend) — key desks by `series`; `deployDesk(series)`, `desksForMarket`;
   carry `tier`. `operatorDesks.json` gains `series`/`strike`/`maturity`/`leverageTier`/`kind`.
5. **Mint + deploy** the v1 series via `SeriesFactory.create_series(USD-sentinel, strike, maturity)` at
   `r = 0.667/0.8/0.9` (3x/5x/10x), **one short maturity** (~2–4 weeks); one `SeriesQuoteFiller` per
   series with tier-scaled `MIN_EDGE`/`DESK_MAX_STALENESS`/caps; `set_quoter`/`fund`/`fund_p`/`set_caps`.
6. **Quoter service** (generalize `solo-rfq-quoter-spec`): one endpoint per tier; `fair = intrinsic_n`,
   tier-scaled `min_edge = max(MIN_EDGE_BASE·lev//2, MIN_EDGE)`, global-util skew, prefer same-series
   mergeable fills; `GET /menu` returns the live tier set + per-tier capacity.
7. **UI**: tier picker, mandatory honest framing, trust labeling, expiry state machine + near-expiry/
   desk-dark warnings, manual roll, portfolio grouped by `(asset, tier, expiry)`, long/short toggle
   gated; "Sepolia testnet, research code, unaudited" everywhere.
8. **Launch tier set = [2x (existing rolling desk, unchanged), 5x, 10x (both dated)]** at ONE near
   maturity. 3x optional 4th dated tier; **20x and multi-maturity disabled** pending flow + P3.
9. **Optional core hardening (F-SETTLE-ROUND):** one-line `assert answered_in >= round_id` in
   `OracleHub._read` — flag as a tradeoff vs "core ships unchanged."
10. **Adversarial review targets:** the keeper's registry-first convergence (F-KEEPER-RACE), the
    registry's `r < 0.96` cap + keeper-only writer (F-CEILING / junk-series), the dated desk's near-strike
    band sizing (F-DEAD-DESK) + tier-scaled `min_edge` (F-EDGE), the settle-staleness/timing surface
    (F-SETTLE-STALE/F-SETTLE-TIMING), the cohort-overlap window (no menu gap, no double-active pointer).

**Phase 2 (with flow / P3):**
* Add **20x** (tightest edge/staleness/cap profile, strong high-theta framing) + **multiple staggered
  maturities** + **cross-asset** (spXAU/spBTC, gated on the F6 two-feed freshness fix).
* **Multi-series `LeverageMenuDesk`** per (asset, leg) — one shared pool, per-series books, **global
  `MAX_TOTAL_NAV_AT_RISK`** + global outflow/float (F-MENU-CAP), on-chain tier-scaled `min_edge` assert.
* **P1 short-leg sibling desk** (F-SHORT) via the long/short toggle.
* **P3 writer vault as the funder** — the full-grid depth unlock; menu tiers gain the pool/vault fallback.
* **On-chain best-ex router** across tiers; opt-in **auto-roll keeper**; on-chain `OperatorDeskRegistry`
  enumeration; optional per-series `max_settle_staleness` on `OptionSeries` for tight USD settles.

---

## 9. Honest risks + bottom line

* **High tiers are thin by nature.** 20x N is a 5%-buffer, decay-to-zero bet; the desk must quote wide
  and small, and capacity is limited until P3 funds depth. The menu *exists* at 20x; *liquidity* at 20x
  is a flow/funding problem, not a contract one.
* **Theta is the product, not a leak.** A worthless-at-expiry high-tier N is capped loss = premium,
  exactly as designed — the UI must say so loudly.
* **Settlement is leverage-amplified** (F-SETTLE-STALE/TIMING/ROUND). The v1 USD path settles off the
  7200s hub heartbeat, so 10x/20x are unsafe against the sentinel without a tighter settle gate — the
  honest v1 launch is ≤10x with a prompt keeper, and a tight USD settle (smaller `ETH_USD_HEARTBEAT` or
  a per-series settle gate) is required before high tiers. Capped loss and full collateralization are
  unaffected by any of these; the exposure is the settle-time *value* of an ITM high-tier N, not the
  buyer's downside.
* **Keeper liveness.** A missed `refresh` ages the front cohort; the overlap window + permissionless
  pokes (UI/cron/any caller) make it self-healing, but a fully-dead keeper eventually leaves only
  near-maturity series (desks go dark via `PRE_MATURITY_BUFFER`). Mitigate with multiple cron pokers + an
  optional phase-2 mint bounty.
* **Per-tier desk capital.** v1 realistically launches 2–3 middle tiers (5x/10x), not all four, until
  P3. The architecture supports all four; funding is the gate.
* **The sharpest foot-guns** are deploying a high-tier desk with a low-tier `MIN_EDGE` (F-EDGE) or the
  rolling desk's `strike_proximity = 1.5` (F-DEAD-DESK) — both must be enforced/refused at deploy or
  list-time, not left to the operator.

**Bottom line.** The leverage menu is **pure orchestration over primitives we already have**:
`SeriesFactory`/`OptionSeries` mint dated series at any strike **unchanged**; a thin permissionless
**registry** groups them into a Split-style `[2,3,5,10,20]` tier menu per asset and enumerates it; a thin
permissionless **keeper** rolls the *cohort* forward (mint-fresh-on-expiry) while each individual series
just expires; and the deployed N desk generalizes by **subtraction** (drop the tracker, bind a static
series) into a per-tier `SeriesQuoteFiller` — the one real code deliverable, since the existing desk is
hard-coupled to a rolling tracker and **will not deploy against a dated series**. The rolling soft-peg
DAO is deliberately NOT used (its genesis-brick guard caps it at ~2.73x); dated standalone series have no
such ceiling and reach ~20x — bounded by **oracle amplification, the 20% edge cap, the near-strike band,
and theta**, not by the settle math. The decisive constraint is **capital depth**: ~5 ETH credibly backs
2–3 tiers at one maturity; the full grid fragments below useful depth and is structurally a **P3
(writer-vault) problem**. Recommended launch: **a small dated tier set [2x existing, 5x, 10x], ONE near
maturity, operator-funded, RFQ-only**, built funder-agnostic so P3 drops in without a rewrite. It
composes cleanly — P1's shorts slot into the same registry via `is_put`, P3's vault becomes the menu's
funding operator. **Sepolia testnet, research code, unaudited; options not debt — no liquidation, no
margin, capped loss = premium.**
