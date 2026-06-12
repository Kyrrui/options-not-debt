# App Specification — options-not-debt frontend + operator backend

> Self-contained spec for building the web UI (§0–§11) and the operator
> backend (§12: keeper, indexer, API, optional market-making). Hardened by a
> five-perspective review (saver UX, market-maker UX, integrator UX, frontend
> architecture, contract-completeness audit) against the actual contracts.
> The implementing session should read this file plus `README.md`,
> `docs/deployments.md`, and `test/Interfaces.sol` (exact protocol ABIs).
> Contracts: `src/*.vy`. Sepolia addresses + params: `docs/deployments.md`.
>
> Suggested repo shape: a TypeScript monorepo —
> `packages/protocol` (ABIs, addresses, every §5 formula/predicate as pure
> bigint functions, tested once against fixtures from the Foundry tests),
> `apps/web` (frontend), `apps/keeper` (backend worker + API). The §5
> math being a single shared package is load-bearing: UI previews and
> keeper decisions must never disagree.

## 0. Product framing

**Brand: Gimbal.** The frontend and operator stack ship under the name
"Gimbal" (a gimbal keeps its payload level while everything around it
pitches and rolls — what the wrapper does to your exposure while ETH swings
and strikes roll underneath). Tagline: **"Stable through every swing."**
ENS: `gimbal.eth` (secure it before launch; trademark screen still
recommended). Tracker tokens keep the deployed scheme — **spUSD, spXAU,
spNVDA** ("sp" = soft peg) — productized as "spXAU — Soft Peg Gold". The
protocol layer remains unbranded/neutral in copy ("built on options, not
debt" in the footer, linking the contracts repo and the ethresear.ch
thread); Gimbal is *a* frontend to a permissionless primitive, not its
owner — keep that separation in all wording.

Three jobs, in priority order:

1. **Trust through legibility** — every safety claim (full collateralization,
   no liquidations, oracle-free exit, bounded drift) must be *visible as live
   data*. The flagship visual is the peg chart: share price vs target through
   real volatility.
2. **Saver flows** — deposit ETH into a tracker, hold a soft peg, redeem.
3. **Market-maker / keeper flows** — auctions and `sync`/`settle` calls keep
   trackers healthy; these users are the circulatory system. Pro surface.

Education is not a docs page: the mental model is unfamiliar even to DeFi
natives, so explainers live in tooltips, previews, and diagrams at the point
of action.

## 1. Protocol mental model (what the UI must teach)

- Index **x = price of 1 ETH in tracked-asset units**, 1e18-scaled. Never
  show raw x; display both directions ("1 ETH = 0.397 oz" / "1 oz = 2.52 ETH").
- `split`: lock ETH at a series → equal P (tracking leg) + N (leveraged-ETH
  leg). `merge` burns equal P+N → exact ETH back, ANY time, even after
  settlement, no oracle.
- Settlement: lazy one-shot, anyone calls at/after maturity while feeds
  fresh. P gets `min(1, S/x)` ETH/unit; N the exact remainder.
- TrackerDAO holds only deep-ITM P; rolls down-strike via auctions.
- **Deposit returns TWO things** — shares AND N tokens (amount = deposited
  wei, exactly). See §3.1 for the mandatory value-split preview.
- **Exit mechanics must be disclosed at deposit time**: redeeming returns
  mostly P tokens, which convert to ETH at the next settlement (up to TERM
  away), or earlier via merge (needs matching N) / selling to the DAO's
  auction (needs a live buffer) / secondary markets (none in v1).
- Drift: above strike the peg is exact; below, share ≈ x/S of target.
  Peg headroom = `1 − S/x`. Show both thresholds: roll triggers at
  `x = S × ROLL_TRIGGER` (−33% at deployed params — "the system working"),
  drift begins at `x = S` (−50%).

## 2. CRITICAL implementation rules (read first — each one was a
##    would-have-shipped-broken finding)

### 2.1 Price-dependent view calls REVERT when feeds are stale
`OracleHub.latest_price` asserts `"stale price"`, and `share_price()`,
`nav()`, `roll_quote()`, `p_quote()` all route through it. The landing page
wired naively to `share_price()` breaks every weekend (XAU idles when gold
markets close). Rules:
- All price-dependent views called via multicall with `allowFailure: true`.
  On revert: render last-known-good cached value with an "as of \<time\>"
  badge and the stale state. Reverting quote views are *idle/stale states,
  not errors*: `"no roll"` → "no active roll", `"no auction"` → "ramp not
  anchored — sync to start", `"stale price"` → "quotes resume on next oracle
  update".
- **Freshness is computed client-side from the aggregators directly**
  (`latestRoundData().updatedAt` never reverts): asset feed + heartbeat from
  `hub.feeds(DAO.ASSET())`, ETH leg from `hub.ETH_USD_FEED()` /
  `hub.ETH_USD_HEARTBEAT()`. **Both feeds must be fresh**; indicator =
  max(age/heartbeat) over the two; name the stale feed in the reason.
- **USD sentinel**: `ASSET == bytes32(0)` has NO `feeds()` entry (empty
  struct). Resolve it client-side to {symbol "USD", aggregator
  `ETH_USD_FEED`, heartbeat `ETH_USD_HEARTBEAT`}; freshness is the ETH feed
  alone. Exclude USD from the register form; include it in series-creation
  pickers (`is_registered(0x0)` is always true).
- Display-path NAV/share price must be computable WITHOUT the hub: compute
  client-side from public getters (`eth_buffer`, `p_bal(active)`,
  `p_bal(pending)`, series `STRIKE`/`settled`/`payout_p`, `totalSupply`) +
  raw feed answers (§5 formulas). Hub/DAO views are for *action previews*,
  where stale correctly disables the action.
- No fake countdowns: when stale, show time-since-update + market-hours copy
  ("XAU/USD pauses while gold markets are closed; resumes Sunday ~22:00
  UTC") + reassurance that redeem/merge/transfers still work. Countdowns are
  only legitimate pre-staleness (time until the feed *would* go stale).

### 2.2 The peg chart cannot be built from events + localStorage
No event carries the index x; localStorage is empty for first-time visitors
(the exact audience the chart exists for). v1 mechanism (mandated):
- Replay holdings state (`p_bal`, `eth_buffer`, supply) from events
  (§4 list — note DAO share-token `Transfer` logs are required for
  supply(t)), and reconstruct historical x by **walking Chainlink
  `getRoundData`** on both aggregators (handle proxy phase-id round encoding;
  rounds before a phase boundary revert/return zero timestamps — skip).
  Recompute NAV/share price per sample via §5 formulas.
- Works on Sepolia live feeds; does NOT work against `MockV3Aggregator`
  (no round history) — on anvil, charts may be empty; gate with a fixture
  flag.
- **Primary source: the operator backend's snapshot API (§12.3)** — the
  keeper samples NAV/share-price continuously and serves history, solving
  the first-visitor problem outright. Client-side round-walking is the
  degraded mode when the API is unreachable (the UI must not hard-depend on
  the backend; see §12.4).
- Gaps where feeds were stale render as dashed segments, not interpolation.

### 2.3 Custody trap: never route writes through Multicall3-style contracts
`split()` mints to msg.sender; `fill_roll`/`sell_p` pull via `transferFrom`
from msg.sender. A shared aggregator contract becomes the token owner —
funds stranded/sweepable. Rules: sequential tx stepper from the EOA is the
baseline; wallet-level batching (EIP-5792 `wallet_sendCalls` / EIP-7702)
only when the wallet advertises it (calls originate from the user account —
safe). A purpose-built periphery router (`splitAndFill`, `syncAndDeposit`)
is future work, noted in §10.

### 2.4 Quote → execution races (no slippage params on-chain)
`fill_roll(amount_old)` and `sell_p(amount)` recompute price at execution
from live oracle + timestamp; neither takes min-out/max-in.
- **fill_roll**: required_new falls with time (edge grows) but rises on
  adverse oracle moves. **Mandate exact-amount approvals (never infinite)**
  — the allowance doubles as the slippage guard: adverse move → `transferFrom`
  underflow revert → map to "price moved against you — re-quote". While
  x ≥ S_old and x ≥ S_new (normal deep-ITM state), required_new =
  amount_old × S_old/S_new × (1−edge) is oracle-independent — surface this
  ("quote insensitive to price while both strikes are in the money").
- **sell_p**: no on-chain minimum; show quote as-of block + oracle round,
  re-simulate immediately before send, warn ETH-out can drop if the oracle
  updates in flight.
- Stepper flows (split → approve → fill) span ≥3 blocks: re-quote at every
  step; size the split with configurable headroom (quote × 1.005; surplus
  P+N is mergeable back to ETH); final step offers "fill max coverable by
  balance/allowance".

### 2.5 Token metadata (RESOLVED on-chain in the v3 deployment)
P/N tokens now self-describe: symbols are composed on-chain at series
creation as `P-<ASSET>-<STRIKE>-<YYMMDD>` / `N-...` (e.g.
`P-XAU-0.198-260710`), names as "Tracking P …"/"Leverage N …" — vintages
from different rolls never collide in wallets. UI rules that remain:
offer `wallet_watchAsset` after deposit (now safe and useful); UI labels
may still enrich (add the tracker name, USD value); resolve token → series
via `MINTER()` when needed. The strike in the symbol is 3-decimal
truncated — for exact terms always read `STRIKE()` from the series, never
parse the symbol.

### 2.6 Empty-revert-data failures (Vyper checked arithmetic)
The most common real failures produce NO revert string: insufficient
allowance/balance hits the token's checked-subtraction underflow *before*
any DAO assert (`"pull failed"` is effectively unreachable). Rule: pre-check
balances/allowances client-side before simulating; label reasonless
simulation reverts "insufficient balance or allowance" with the specific
failed precheck named.

## 3. Personas and screens

### 3.A Saver (default experience)

**Trackers list (landing)** — card per DAO, enumerated from the
TrackerFactory (see §3.C "Tracker discovery"; canonical pegs pinned first):
- share price vs 1.000 target + 30d sparkline (per §2.2 pipeline)
- TVL (ETH + asset units + **USD value** — read the asset's USD feed
  directly; savers think in USD even for gold)
- peg headroom gauge with both thresholds (§1)
- status badge precedence: `oracle stale` > `roll pending` > `sync needed` >
  `healthy` (the maturity half of needs-roll evaluates without an oracle, so
  partial badge logic works while stale)
- **uninitialized state** (spUSD on Sepolia is live but unseeded:
  `active_series == 0`, supply 0, `share_price()` returns 1e18 via the
  supply==0 branch): show "not yet seeded — be the first depositor" CTA,
  gated on oracle freshness; preview strike as `x × STRIKE_RATIO / 1e18`
  (the series is created inside the first deposit tx).
- No APY stat in MVP. If added later: trailing 30d share-price change,
  labeled "peg performance — not yield", never the word APY.

**Tracker detail**
- Peg chart hero (§2.2).
- Position panel: user's shares; value in asset units, ETH, and USD; drift
  since entry. Plus a **"my legs" panel**: the user's P/N balances across
  all series this DAO has touched (enumerate via `RollStarted` events +
  factory), each labeled per §2.5 with intrinsic value and contextual
  actions (merge if both legs held; redeem_p/redeem_n if settled).
- **Deposit flow** (the make-or-break screen):
  - Preview MUST show the value split, reconciling to the deposit:
    "1 ETH → 0.198 spXAU (≈0.5 ETH) + 1.0 N-token (≈0.5 ETH, returned to
    your wallet — leveraged-ETH leg, sell or keep)". N amount = deposit wei;
    N intrinsic = `1 − min(1, S/x)` ETH/unit. Without this, the deposit
    reads as an instant 50% loss.
  - Preview targets `pending_series` if a roll is open, else active; label
    it ("depositing into the new series S=…, matures …").
  - Exit-mechanics disclosure (§1) before confirm.
  - `"sync required"` revert → offer sync-then-deposit stepper.
  - `"matured"` on deposit during a stalled roll → "roll stalled — call
    sync" (sync only auto-settles the ACTIVE series).
- **Redeem flow**: basket is structurally ≤ 3 rows — `p_bal(active)`,
  `p_bal(pending)`, `eth_buffer`, each × shares/supply floor-divided, supply
  read pre-burn. Show maturity countdown per P row and an **availability
  matrix** for follow-ons: merge (needs matching same-series N — gate on
  actual balance; usually unavailable after a roll), sell-to-DAO (needs live
  buffer auction, unsettled pre-maturity target series), hold-to-settlement
  (countdown). Redeem itself never touches an oracle — say so prominently.

### 3.B Market maker / keeper (Pro)

**Auctions dashboard** (cross-DAO):
- Roll auction card: old→new series, rate vs oracle-fair, edge now/max,
  time-to-max (anchor: `roll_started`, public), **hard deadline = old-series
  maturity countdown** (fill_roll dies at settlement: `"settled: use sync"`
  → card transitions to "expired — awaiting harvest" keeper state),
  "saturated at max edge" state, size remaining = live `p_bal(active)` reads
  (NEVER event-derived — redeems shrink it without auction events).
- **Fill calculator** — exact identities (all bigint, floor division):
  - pay: split `required_new` ETH → receive `required_new` P_new +
    `required_new` N_new; deliver P_new; receive `amount_old` P_old.
  - marked profit (ETH) = `edge × amount_old × val_old / x`, decomposed:
    [P_old received: `amount_old·val_old/x`] + [N_new retained:
    `required_new·(1 − val_new/x)`] − [ETH split: `required_new`] − gas.
    Omitting the retained N leg makes every fill look ruinously negative.
  - label "marked to oracle intrinsic, not realized"; show **capital
    lockup**: P_old converts to ETH only at old-series settlement (countdown);
    N_new has no v1 venue; show post-fill portfolio + net ETH-delta.
- sell_p card: subject series = `pending_series` if set else active (label
  it — splitting at the wrong series → dead `transferFrom`); buffer size;
  bid multiplier position on ramp (anchor `buy_started` — re-anchored by
  every harvest, zeroed when buffer empties; read the getter, not Harvested
  timestamps); gates: `buy_started > 0`, buffer > 0, target unsettled and
  pre-maturity. Profit: net = `amount × pp × (mult − 1e18) / 1e36`, retained
  N valued `amount × (1 − pp/1e18)` ETH; show breakeven ramp time + gas.
  When a roll and a buffer auction run simultaneously, present together —
  one split at the pending series sources inventory for both.
- **Keeper panel** — client-side predicates (no on-chain views exist; §5.3):
  needs-roll, settle-able, harvest-available, finalize-pending,
  buffer-unrotated (`eth_buffer > 0 && buy_started == 0` — itself a keeper
  CTA since sell_p quotes revert until someone syncs). One-click
  sync()/settle() with gas estimate. **State plainly: keeper calls are
  unpaid** (gas donations). Watch-mode notifications split into
  *profitable* (RollStarted, edge ≥ threshold net of gas, sell_p mult
  crossing 1.0, stale→fresh transition unlocking a fill) vs
  *needed/altruistic* (needs-roll, matured-unsettled, buffer unrotated).

**Series explorer**: all factory series (`series_count`/`series_list`),
state badge (`open`/`matured`/`settled`), P/N supplies, locked ETH
(= `eth_getBalance(series)` — no view exists), settlement index + payouts
(payout_n = `1e18 − payout_p`, not exposed on-chain), actions per state.
**Split page**: pick series, ETH → P+N; primary inventory-sourcing tool.

### 3.C Integrator (advanced)

**Registry browser**: rows grouped by aggregator with heartbeat as the
distinguishing column (content-addressed ids: same feed + different
heartbeat = distinct asset universes — explain this; ids from
`docs/deployments.md` marked canonical). Sentinel USD row synthesized per
§2.1. Symbols are first-registrant cosmetic strings — render as
untrusted/labels-only.

**Register form**: live validation preview (calls the feed: decimals,
answer, updatedAt). **Quote-currency check**: read the aggregator's
`description()` (standard on Chainlink proxies) and block/warn unless it
ends "/ USD" — registering an ASSET/ETH feed silently yields a garbage
index and no contract check catches it (override requires an explicit
checkbox). Cadence guidance: link the Chainlink docs page for the feed
rather than attempting on-chain cadence inference (requires getRoundData
phase-walking; skip in v1).

**Create series form**: strike entered in human terms with live index and a
**moneyness preview** (strike as % of index; intrinsic P/N split at
creation; warn when strike ≥ index — P would be at/out of the money, wrong
for tracking). "Similar series exist" search (same asset, strike ±X%,
maturity ±N days from `SeriesCreated` logs) instead of exact-collision-only
dedupe (exact dedupe essentially never fires since maturity is
timestamp-precise); offer maturity rounding to 00:00 UTC to encourage
convergence on shared series.

**Create-a-peg wizard** (NOW v1.1, not v2 — the `TrackerFactory` contract
makes it a single transaction): the wizard calls
`TrackerFactory.create_tracker(name, symbol, asset, term, roll_window,
roll_trigger, strike_ratio, auction_dur, max_edge)` from the user's wallet
(their gas, ~3.5M). No initcode shipping, no deployContract. The factory
enforces on-chain what the TrackerDAO constructor cannot: asset must be
registered in the hub, the hub is injected (never caller-chosen), term fits
the series factory's bounds. It also dedupes on the parameter set
(name/symbol are cosmetic, excluded from the key — surface this: "a tracker
with these parameters already exists as <addr>; yours would be the same
contract"). The TrackerDAO constructor's own asserts (§7) still apply and
revert through the factory — mirror them client-side for inline UX.
Economic-sanity warnings stay client-side: `roll_window > term/2`
(perpetual re-roll churn), `auction_dur > roll_window`; pre-deploy summary
computes "expected time-driven rolls/year ≈ 365d/(term−roll_window);
worst-case annual edge drag ≈ rolls/yr × max_edge". Defaults = the
canonical spUSD params. Note Vyper String[64]/String[32] name/symbol limits
are byte lengths. After creation, route the user straight into the
first-deposit ("seed this tracker") flow.

**Tracker discovery — NO static config needed**: the trackers list is
enumerated from the factory (`tracker_count` / `tracker_list(i)`, or
`TrackerCreated` events for creator/metadata), and `is_tracker(addr)` is
the trust check — factory-created means exact-blueprint bytecode, no
"unvetted" badge required. User-created pegs appear for every user
automatically. Curate the default view (canonical spUSD/spXAU pinned
first, community pegs below, sorted by TVL) but never hide entries.

### 3.D Uniswap pools on tracker cards (secondary market for sp tokens)

**Scope rule (hard):** pools are surfaced and creatable for **tracker (sp)
tokens only — never for P/N series legs.** P/N expire and re-mint every
roll; AMM pools on expiring assets fragment liquidity and strand LPs on
dead vintages. The venue for P/N is the DAO's own auctions (§3.B). Any
pool UI on a series page is a spec violation.

**Pool detection & display (build FIRST — v1):**
- Detect via Uniswap v3 `factory.getPool(spToken, WETH, fee)` across fee
  tiers [500, 3000, 10000]; if several exist, feature the deepest by
  in-range liquidity and list the rest. Pull the chain's canonical Uniswap
  v3 addresses (factory, NonfungiblePositionManager, WETH9) from Uniswap's
  official deployments registry into config — do not hardcode from memory.
- Tracker card/detail shows, side by side and clearly labeled:
  - **Market**: pool spot price + 30-min TWAP (from `slot0` /
    `observe`), pool TVL, fee tier.
  - **NAV**: `share_price()` via the §2.1 stale-safe path.
  - **Basis**: (market − NAV)/NAV as "x.x% discount/premium to NAV" with
    an explainer tooltip (mandatory copy, see below).
  - Swap deep-link to the Uniswap app with chain + token addresses
    prefilled (deep-link in v1; an embedded swap widget is v1.1+ at the
    builder's discretion).
- **Mandatory basis explainer** (verbatim or equivalent): "Market price
  can drift from NAV. Above NAV it corrects fast (anyone can mint at NAV
  and sell). Below NAV it corrects slowly (redemption yields P tokens
  that pay out at series settlement). A small, persistent discount under
  stress is normal arbitrage mechanics — not a depeg." Without this,
  every visible discount becomes a support ticket.
- **Peg chart**: once a pool exists, add a second line — market price vs
  the NAV line — sourced from the backend (§12.3 addition below). This
  is the strongest trust artifact the UI has; treat gaps/divergence as
  first-class data, never smooth them.
- No-pool state: "No market yet — be the first to seed liquidity" CTA
  into the create flow. Pool-exists-but-empty (zero in-range liquidity):
  treat as no-market, show seed CTA, hide spot price (a priceless pool
  renders garbage numbers).

**Pool creation/seed flow (v1.1):** wallet-direct through Uniswap's
canonical NonfungiblePositionManager (designed for EOA calls — the §2.3
custody trap does not apply, but ONLY the canonical NPM is exempt):
1. Gate on oracle freshness; derive the init price from `share_price()`
   NAV. Compute `sqrtPriceX96` with full-precision bigint, respecting
   v3's token0/token1 address-sort order (price may need inversion —
   classic footgun, unit-test it). HARD warning before signing: "a pool
   initialized at the wrong price is arbitraged within one block; you
   will lose the difference."
2. Single transaction via NPM `multicall`:
   `createAndInitializePoolIfNecessary` + `mint`. Default: 0.3% fee tier
   (sp/WETH is structurally a volatile USD-vs-ETH pair, NOT a stable
   pool — do not offer the 0.05% "stable" framing), full-range position
   (min/max usable ticks for the tier). Custom range behind an
   "advanced" toggle with an out-of-range-drift warning.
3. UI computes the NAV-ratio amounts of spToken + WETH, offers an ETH→
   WETH wrap step, takes exact approvals to the NPM, applies user
   slippage settings on mint.
4. Disclosures before signing: LPing sp/WETH carries ~50% ETH exposure
   (this is not a stable position); below-strike drift affects the pool
   too; testnet tokens have no value.

**Backend additions (§12.3 / §12.4):** the indexer samples, per tracker
per snapshot tick: pool address, spot, 30-min TWAP, in-range liquidity,
basis vs NAV — persisted into the history series and returned in
`/api/trackers` (`pool: {address, feeTier, tvl, spot, twap30m, basis}`
or `null`) and `/api/trackers/:addr/history` (market series alongside
NAV). New alert: |basis| > 3% sustained for > 1h. The keeper does NOT
trade pools — display and alerting only; any pool market-making is a
future operator-MM concern, out of scope.

## 4. Architecture

- **Stack**: Vite + React + TS, wagmi v2 + viem, RainbowKit/ConnectKit,
  TanStack Query, Tailwind + shadcn/ui, lightweight-charts (peg/index) +
  recharts (small stats).
- **Reads**: viem multicall with `allowFailure: true` (§2.1); poll per block
  (~12s) on active screens, 60s elsewhere. Read-only mode fully functional
  without a wallet.
- **ABIs**: protocol ABIs from `out/` artifacts (vendor into the UI repo);
  ADDITIONALLY vendor Chainlink `AggregatorV3Interface` **including
  `getRoundData` and `description`** (the protocol's internal interface
  lacks both; `MockV3Aggregator` lacks both — cadence/chart features are
  Sepolia-only, fixture-flag them).
- **Config**: typed `deployments.ts` generated from `docs/deployments.md` —
  **including per-contract deployment block numbers** (add them to
  deployments.md; required for log scans). Tracker discovery is on-chain
  via the TrackerFactory (§3.C); config carries only the singleton
  addresses (hub, factories) and pinned/canonical tracker ordering.
- **Logs**: chunked `getLogs` (free Sepolia RPCs cap ranges ~10k blocks
  regardless of result size) with incremental caching of highest-scanned
  block. Event list: DAO `Deposit, Withdraw, RollStarted, RollFilled,
  RollFinalized, Harvested, PBought, Transfer` (Transfer needed for
  supply(t)); series `Split, Merge, Settled, Redeem`; factory
  `SeriesCreated`; hub `AssetRegistered`. Events are for history only —
  live figures (auction size, balances) always from state reads.
- **Tx UX**: viem `simulateContract` before send; decoded reverts per §8;
  empty-data rule per §2.6; pending/confirmed states; explorer links
  (Blockscout — contracts are verified there).
- **Numbers**: bigint everywhere; mirror floor-division order exactly (§5);
  display 2–4 dp asset / 4–6 dp ETH, full precision on hover/copy; never
  round in tx-feeding previews.

## 5. Exact formulas & predicates (client-side mirrors; view calls are
##    truth for action previews when fresh)

**5.1 Pricing primitives** (all 1e18-scaled, floor division)
- `x = ethUsd_norm * 1e18 / assetUsd_norm` where `_norm = answer × 10^(18−decimals)`;
  USD sentinel: `x = ethUsd_norm`.
- `val_p(series)` [asset units/unit]: unsettled `min(x, STRIKE)`; settled
  `payout_p × x / 1e18`.
- `pp(series)` [wei/unit, ETH-denominated intrinsic — sell_p uses THIS, not
  val_p; confusing them mis-prices by ~x]: `min(1e18, STRIKE × 1e18 / x)`.
- N intrinsic [wei/unit] = `1e18 − pp`.
- `NAV` [asset units] = `eth_buffer×x/1e18 + Σ_{s∈{active,pending}} p_bal(s)×val_p(s)/1e18`.
- share price = `NAV × 1e18 / totalSupply` (supply==0 → 1e18).

**5.2 Action math**
- Deposit: `value_in = amount × val_p(target) / 1e18`;
  `shares = value_in × totalSupply / nav_before` (NAV **before** the split);
  first deposit: `shares = value_in − 1000` (dead shares), requires
  `value_in > 1000`.
- Roll fill: `edge = MAX_EDGE × min(now − roll_started, AUCTION_DUR) / AUCTION_DUR`;
  `required_new = amount_old × val_old // val_new × (1e18 − edge) // 1e18`
  (exact order). Profit identities: §3.B.
- sell_p: `mult = 1e18 − MAX_EDGE + 2×MAX_EDGE×min(now − buy_started, AUCTION_DUR)/AUCTION_DUR`;
  `eth_out = amount × pp // 1e18 × mult // 1e18`.
- Redeem basket: §3.A (≤3 rows, floor, supply pre-burn).

**5.3 Keeper predicates** (no public views; compute client-side)
- needs-roll = `pending == 0 && (x×1e18 < STRIKE(active)×ROLL_TRIGGER
  || now + ROLL_WINDOW >= MATURITY(active))` (note `>=`).
- settle-able = `now >= MATURITY && !settled && bothFeedsFresh`.
- harvest-available = `pending != 0 && active.settled && p_bal(active) > 0`.
- finalize-pending = `pending != 0 && p_bal(active) == 0`.
- buffer-unrotated = `eth_buffer > 0 && buy_started == 0`.
- sell_p-live = `buy_started > 0 && eth_buffer > 0 && !target.settled
  && now < target.MATURITY`.
- "sync needed" badge = needs-roll OR (active matured && !settled) OR
  harvest-available OR finalize-pending OR buffer-unrotated.

## 6. State machines
- **Series**: `open` (split/merge) → `matured` (merge, settle-when-fresh;
  splits now revert `"matured"`) → `settled` (redeem_p/redeem_n, merge).
- **TrackerDAO**: `uninitialized` → `healthy` ⇄ `roll-pending` (deposits →
  pending series; fill_roll live until old-series settlement, then
  `expired-awaiting-harvest` until sync harvests+finalizes). Max TWO series
  tracked at any time (active + pending) — hard invariant; collapses
  holdings/redeem UIs to fixed layouts.
- **Oracle (per tracker)**: fresh / stale, dual-feed rule (§2.1). Stale
  affects deposit, sync, settle, auctions, and *price-dependent view calls*;
  never affects redeem, merge, transfers — surface the asymmetry, it's the
  design's selling point.

## 7. Constants appendix (assert-only; no getters — hardcode)
- OracleHub: heartbeat ∈ [60s, 7d]. ETH/USD heartbeat (Sepolia): 7200s.
- SeriesFactory: maturity ∈ [now+1h, now+5y]; MAX_SERIES 2^32.
- TrackerDAO constructor: term > roll_window > 0; term ≥ 2h;
  roll_trigger ∈ [1e18, 4e18]; strike_ratio ∈ (0, 1e18);
  strike_ratio×roll_trigger ≤ 0.95e36; auction_dur ∈ [600s, 30d];
  max_edge < 0.2e18; hub/factory nonzero.
- Deployed params (both DAOs): term 28d, window 7d, trigger 1.5e18,
  ratio 0.5e18, auction 1d, edge 0.02e18. DEAD_SHARES 1000.

## 8. Error-string mapping (authoritative — from `grep assert src/*.vy`;
##    key mappings by (contract, string))

**TrackerDAO**: `sync required` → "tracker needs a sync first — run it (or
sync+deposit)"; `zero shares`/`zero value`/`zero amount` → amount too small;
`initial deposit too small` → below dead-share floor; `zero nav` → tracker
holdings are worthless (post-crash edge); `no roll` → auction over/none —
refresh; `settled: use sync` → auction ended at settlement — switch to
harvest flow; `bad amount` → partial fill shrank the auction — re-quote,
offer fill-max; `dust` → size up; `worthless new leg` → pending strike
above index (crashed mid-roll) — wait/sync; `no auction` → ramp not
anchored — sync first; `no series`/`settled`/`matured` (sell_p) → auction
closed for this series; `buffer too small` → size down to buffer;
`pull failed`/`push failed`/`n transfer`/`p transfer` → token transfer
failed (usually shadowed by §2.6 empty reverts — precheck);
`roll into self`/`zero strike`/`trigger overlaps genesis` + constructor
strings (`bad term/trigger/ratio/auction/edge`, `term too short`,
`zero address`) → wizard validation.
**OptionSeries**: `matured` (split too late), `not matured`,
`already settled`, `not settled`, `zero value`, `zero amount`,
`zero index`, `past maturity`, `zero hub`, `zero strike`.
**OracleHub**: `stale price` (idle state, §2.1), `unregistered`,
`zero index`, `bad answer`, `future update`, `decimals`, `bad feed`,
`heartbeat`, `zero feed`, `sentinel collision`.
**SeriesFactory**: `unregistered asset`, `zero strike`,
`term too short`/`term too long` (≠ DAO's `term too short`),
`too many series`.
**OptionToken**: `not minter`, `zero receiver`.
There is no `"roll in progress"` string anywhere — do not invent it.

## 9. Testing
- vitest property-tests for every §5 formula against fixtures exported from
  the Foundry tests (same numbers, bigint exact).
- Playwright against an anvil fork via `script/deploy-local.sh`. **Fixture
  rule**: after every `evm_increaseTime` warp, call
  `MockV3Aggregator.setAnswer(samePrice)` on BOTH feeds before acting —
  otherwise everything reverts `stale price` (local heartbeats: ETH 3600s,
  XAU 86400s). Use `setRaw(answer, pastTimestamp)` to deliberately stage
  every stale-UI state from §2.1 — the staleness UX is fully testable on
  anvil. Chart/cadence features (getRoundData, description) are NOT testable
  on mocks — fixture-flag.
- Stage and screenshot-test every DAO state: uninitialized, healthy,
  roll-pending, expired-awaiting-harvest, harvested-buffer, stale-oracle.

## 10. MVP cut
- **MVP**: trackers list + detail (peg chart fed by the §12.3 snapshot API;
  uninitialized + stale states), deposit (value-split preview, exit
  disclosure) / redeem (3-row basket + availability matrix), "my legs"
  panel, keeper sync/settle buttons + badges, series explorer (read +
  settle/merge/redeem), error mapping, read-only mode, Sepolia config —
  plus the backend MVP (§12.8): keeper loop, indexer/snapshots, API,
  alerts. Build `packages/protocol` first; both apps depend on it.
- **v1.1**: full auctions dashboard with calculators + lockup disclosure,
  split page, registry browser + register/create-series forms, watch-mode
  notifications, EIP-5792 batching where supported.
- **v2**: deploy-tracker wizard (+ minimal DAO-registry contract or indexer
  as its prerequisite), Ponder indexer, periphery router contract
  (splitAndFill/syncAndDeposit), multi-chain, N-leg secondary venue
  integrations, embeddable public peg-status page.

## 12. Operator backend (keeper + indexer + API + optional market-making)

**Framing — read this first.** The protocol has NO privileged operator:
every maintenance call (`sync`, `settle`) is permissionless and the
contracts grant the backend nothing. The backend is an *operator
convenience* that (a) keeps trackers healthy without waiting for altruists,
(b) produces the historical data the frontend's trust surfaces need, and
(c) optionally market-makes the auctions (the "be your own counterparty"
bootstrap strategy). Spec it so a third party could run their own instance
unmodified — "anyone can run the infrastructure" is part of the trust story
and the keeper binary should be advertised in the repo README.

### 12.1 Worker shape
- `apps/keeper`: a single long-running Node process (viem wallet client +
  public client), plain loop — no job framework. Structured logging (pino).
- Storage: SQLite file (better-sqlite3) for events, snapshots, tx journal.
  No external infra; the whole backend is one process + one file.
- Serves the read-only HTTP API (§12.4) from the same process (fastify).
- Config via one typed env/file: RPC URLs (primary + fallbacks, rotated on
  failure), poll interval (default 30s), tracker addresses (default: import
  from `packages/protocol` deployments), gas policy, filler settings,
  alert webhooks, API port, `DRY_RUN`, kill-switch file path.

### 12.2 Keeper duties (per tracker, every tick)
1. **Read state bundle** in one multicall (`allowFailure: true`):
   active/pending series, their STRIKE/MATURITY/settled/payout_p,
   p_bal(both), eth_buffer, buy_started, roll_started, totalSupply, plus
   raw `latestRoundData` from both aggregators (freshness per §2.1,
   dual-feed rule, USD-sentinel resolution).
2. **Decide** with the §5.3 predicates (from `packages/protocol` — never
   reimplement). Policy: if the "sync needed" composite predicate is true →
   the action is `sync()` (it batches settle + roll-start + harvest +
   finalize + auction-anchor in one call; never call `settle()` directly on
   a DAO-managed series). One in-flight tx per tracker, max.
   **Stalled-roll nuance** (verified against the code): `sync()` settles
   only the ACTIVE series. If a roll goes completely unfilled and the
   pending series also matures, recovery takes *consecutive* sync passes —
   each pass settles+harvests the current active and finalize promotes the
   matured pending into the settle path (active always matures before
   pending, so this converges; deposits revert `"matured"` during the
   window). The keeper must therefore re-evaluate immediately after each
   confirmed sync rather than waiting a full tick, and alert if a tracker
   needs more than 3 consecutive passes.
3. **Simulate before send** (`eth_call`). Simulation revert → log INFO and
   skip the tick. Expected, non-error reverts: another keeper won the race
   (`already settled`), oracle went stale between read and send
   (`stale price`). A predicate-true/simulation-revert disagreement that
   persists ≥3 ticks is a bug → alert.
4. **Send** with serial nonce management (one key = one instance), gas =
   estimate × 1.2 under an EIP-1559 fee cap, stuck-tx replacement (same
   nonce, +12.5% fees) after N blocks, 2-block confirmation, full journal
   row (intent, sim result, hash, outcome, gas spent).
5. **Idempotency is free**: predicates derive from chain state, so restarts
   and concurrent instances are safe — the loser of any race burns one
   cheap revert. Never queue intents; recompute every tick.
6. **Non-DAO series** (created by third parties via the factory) are NOT
   the keeper's job in MVP; settlement of those is permissionless and
   anyone holding their P/N is incentivized to call it.

### 12.3 Indexer + snapshot duties (same process)
- **Event ingestion**: chunked `getLogs` from per-contract deployment
  blocks (§4), persisted cursor, idempotent upserts. Tables mirror the §4
  event list (including DAO share `Transfer` for supply history).
- **Snapshot sampler**: every 10 min AND after every ingested DAO event:
  compute x (raw feeds), NAV, share_price, p_bal, eth_buffer, badges per
  tracker via `packages/protocol` math → append to `snapshots`. While
  feeds are stale, snapshot with the last-good x and a `stale: true` flag
  (renders as dashed segments).
- **Backfill on first run**: seed history by round-walking `getRoundData`
  (phase-boundary handling per §2.2) combined with event-replayed holdings;
  best effort, gaps acceptable.
- This makes the backend the **primary chart source** for §2.2; the API
  responses carry `as_of` block + timestamp on every figure.

### 12.4 HTTP API (read-only, public, CORS for the web app)
- `GET /api/trackers` — card data: latest snapshot, badges, freshness per
  feed, stale-safe share price/NAV with `as_of`.
- `GET /api/trackers/:address/history?from&to&resolution` — chart series.
- `GET /api/trackers/:address/events?cursor` — activity feed.
- `GET /api/auctions` — live roll/sell_p auctions with current quotes,
  edge, deadlines, size-remaining (live reads, not events), `as_of` block.
- `GET /api/health` — keeper liveness, last tick, last action, wallet gas
  balance, RPC status, DRY_RUN flag.
- **No write endpoints, no auth, no user data — ever.** All writes go
  user-wallet → chain. The frontend must degrade gracefully to direct-chain
  reads (minus history) when the API is down.

### 12.5 Optional market-making module (off by default; v1.1)
The operator-as-counterparty strategy. Capital: a configured float on the
keeper key (or a second key), hard caps: `maxEthPerFill`,
`maxTotalInventoryEth`, `dailyGasCapEth`.
- **Roll filler**: when a roll is live and
  `edge_net = edge − gas/notional ≥ minEdgeBps`: re-quote `roll_quote`
  (view = truth), split `required_new × (1 + headroom)` ETH at the pending
  series, approve **exact**, `fill_roll`. Post-fill inventory: old-P (hold;
  redeem after old-series settlement) + new-N (hold; leveraged-ETH
  exposure — counted against inventory cap).
- **Buffer filler (sell_p)**: when sell_p is live and `mult ≥ 1e18 +
  minEdgeBps` (DAO paying a premium): split, approve exact, `sell_p`.
- **Inventory housekeeping** (each tick): merge any matching same-series
  P+N pairs back to ETH (free exit); `redeem_p`/`redeem_n` any holdings of
  settled series; mark remaining inventory to oracle intrinsic and report
  PnL in `/api/health`.
- Risk framing in config docs: the filler is structurally long ETH via N;
  caps are the only risk control; this module is for bootstrap, not yield.

### 12.6 Keys, safety, alerting
- Hot key holds gas + optional filler float ONLY. The protocol grants it no
  privileges; compromise loses the float, nothing systemic. Keystore or env
  PK; never commit; document rotation (just swap the key — no on-chain
  state).
- `DRY_RUN=true` logs every intended tx without sending — the default in
  CI and the first deploy.
- Kill switch: touch-file or env flag checked every tick.
- Alerts (Discord/Telegram webhook): needed-action unexecuted > X min;
  wallet below gas floor; feed stale beyond expected market-hours window;
  share_price < drift threshold (default 0.97 — peg stress, page a human);
  persistent sim/predicate disagreement; filler cap breaches; RPC failover
  events.

### 12.7 Backend testing
- Same anvil fixtures as §9 (`script/deploy-local.sh` + warp + re-poke
  feeds). Integration tests drive the scenarios and assert keeper behavior:
  roll trigger → one sync; maturity → settle+harvest+finalize in one sync;
  healthy → zero txs; stale feeds → zero txs + alert; two keepers racing →
  exactly one effective action, loser logs INFO.
- Chaos: kill RPC mid-tick (resume from cursor, no duplicate snapshots),
  restart mid-roll (no duplicate intents).
- Filler: simulated fills must reproduce §3.B profit identities to the wei.

### 12.8 Backend MVP cut
- **MVP**: keeper loop (sync policy) + event ingestion + snapshot sampler +
  the five API routes + staleness/gas/drift alerts + DRY_RUN + kill switch.
- **v1.1**: market-making module + inventory housekeeping + PnL reporting.
- **v2**: multi-instance redundancy (per-key), Prometheus metrics,
  multi-chain, public "run your own keeper" docker image + docs.

## 13. Resolved decisions (were open; now settled by review)
1. Batching: sequential stepper baseline; EIP-5792 when available; NO
   generic multicall for custody flows (§2.3). Periphery router = v2.
2. Returned N legs: v1 ships "keep" + explainer + "my legs" panel; no
   auto-sell (no venue).
3. Chart data: §2.2 pipeline; hosted snapshot/indexer pulled INTO MVP if
   round-walking is unreliable on the chosen RPC.
4. Naming: the app is **Gimbal** (gimbal.eth; tagline "Stable through
   every swing"); tracker product names "spXAU — Soft Peg Gold" etc.;
   footer credits the unbranded protocol layer ("built on options, not
   debt") with repo + thread links. See §0.
