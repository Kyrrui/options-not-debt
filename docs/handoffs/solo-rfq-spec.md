# Gimbal Solo RFQ Desk — operator-run market making for the legs (spec)

> Build spec, not a sketch. A **single-operator**, self-funded RFQ desk that is the
> counterparty for Gimbal's N leg (buy *and* sell) and, in phase 2, the spUSD leg.
> The operator funds it with their *own* ~5 ETH, signs EIP-712 quotes off-chain, and
> only those quotes fill on-chain — bounded by a directional, vault-favorable edge
> floor that survives a stolen quoter key. It is the surviving clean half of the
> killed crowd-vault (`mm-vault-spec.md`): keep the one good mechanism (directional
> floor + signed quotes), delete the two structural problems (pooled capital, NAV
> arb) by making the capital *and the risk* the operator's own.
>
> **Sepolia testnet, research code, unaudited. This is the operator's own expendable
> bootstrap capital, not a yield product, not a pooled fund — no third-party
> deposits, no shares, no NAV-per-share.**

## ⚠ Why this is sound where the crowd-vault was KILLED

The MM vault (`mm-vault-spec.md`) died on **29 findings, three clusters.** The solo
desk is *the same filler minus the vault*, and that deletion is the whole argument:

1. **Cluster (1) — the price band is the wrong control → KEPT, as the core control,
   in its fixed form.** Not a symmetric ±X% band (which licensed a continuous
   within-band drain), but a **directional, vault-favorable edge FLOOR**: the desk
   buys N at `≤ intrinsic·(1−min_edge)` and sells N at `≥ intrinsic·(1+min_edge)` —
   it always *takes* spread, exactly like the DAO's `sell_p`/`fill_roll` `MAX_EDGE`
   auctions (`TrackerDAO.vy`). Re-derived on-chain from a fresh oracle read, so even
   a *compromised* quoter key cannot sign a fill that loses the desk more than the
   edge per unit.
2. **Cluster (2) — deposit/withdraw oracle + JIT NAV/share arb → VANISHES.** There
   is no NAV, no share price, no deposit/withdraw at NAV. The operator funds and
   defunds via plain owner-only `fund()`/`withdraw_*()`; there is nothing to
   sandwich. The single hardest engineering surface of the vault spec (§4.5, §5 —
   conservative marks, withdrawal delays/epochs/friction) is *deleted*, not
   mitigated.
3. **Cluster (3) — THE KILLER (short-theta net-long-N bag foisted on retail) →
   NEUTRALIZED by *who bears it*, not by plumbing.** The net-long-N / short-theta
   exposure still exists, but it is now the **operator's own knowing, capped,
   hedgeable** position on expendable capital, withdrawable at any time. It is no
   longer the disproven *"relocate the orphan into an unwilling warehouse"*
   anti-pattern (`clear-n-findings.md`, C1) — the warehouser is willing, deliberate,
   and bears their own loss. The buy-side floor even buys N *below* intrinsic, so the
   desk does not pay the option's time value; the residual cost is *directional*
   (captured by the NAV-at-risk cap), not a continuous theta drip.

So the solo desk **confirms** the clear-N conclusion rather than escaping it: it is a
**matching + warehousing venue**, not a demand source. It clears N up to (real
leverage demand) + (the operator's own capped appetite to warehouse). That is exactly
what a solo RFQ is for, and the spec is honest about it.

---

## 1. What it is

`SignedQuoteFiller.vy` — `# pragma version ==0.4.3`, one periphery-style contract per
operator-per-tracker, deployable from an EIP-5202 blueprint with the same conventions
as the rest of `src/periphery/` (`raw_call` ETH-out, undecorated payable `__default__`
for `merge`/`redeem_n` ETH callbacks, transient reentrancy guard mirroring
`FlashLeverageRouter.vy`).

- **Solo.** ONE operator funds it with their OWN ETH + P/N inventory. ONLY quotes
  signed by the operator's approved quoter key can be filled.
- **No public deposits, no vault shares, no NAV-per-share, no `share_price` on any hot
  or cold path.** That deletion is the point (clusters 2 & 3 above).
- **Operator controls everything:** `fund()`, `fund_p()`, `withdraw_eth()`,
  `withdraw_token()`, `set_paused()`, `set_quoter()`, `set_caps()` — all owner-only,
  any time. No third party can move desk funds.
- Mechanically it is `FlashLeverageRouter` (payable, merge/split-aware,
  immutable-wired) **plus** an inventory book and an EIP-712 verifier — and **minus**
  the "holds nothing between calls" property, which is the whole reason it does **not**
  belong in `PeripheryFactory` (§7).

The only "position" accounting is a single signed int, `net_n` (units of N the desk is
net-long; `+` = long), not a share ledger.

## 2. How it trades the legs

Confirmed against the real contracts (`OptionSeries.vy`, `TrackerDAO.vy`,
`OracleHub.vy`):

- **N intrinsic per unit (wei of ETH):** `intrinsic_n(x) = max(0, 1e18 − STRIKE·1e18//x)`
  where `x = OracleHub.latest_price(ASSET)` (ETH priced in asset units, 1e18-scaled).
  This is *exactly* `OptionSeries.settle()`'s `payout_n = 1e18 − payout_p` with
  `payout_p = min(1e18, STRIKE·1e18//x)`, and `TrackerDAO._p_quote`'s N-complement —
  so the on-chain edge floor matches protocol settlement math. Read **FRESH** per fill.
- **`split()` / `merge()` live on `OptionSeries`, not the tracker.**
  `ISeries(series).split(value=amt)` mints `amt` P **and** `amt` N to the desk;
  `ISeries(series).merge(amt)` burns `amt` P + `amt` N → `amt` ETH back, **any time,
  oracle-free** (`OptionSeries.vy:153/167`). This is the value-add engine. The desk
  uses raw `split()` (keeps the P, controls both legs) rather than `TrackerDAO.deposit()`
  (which keeps P but hands N *away* — wrong direction).

The desk does four things:

1. **Sell N** (taker buys N — leverage buyer): taker sends ETH; the desk delivers N
   from inventory, or JIT-mints via `split` (funding the full 1 ETH/unit from its own
   balance and keeping the P). This is the existing `LeverageRouter` story at an
   operator-quoted price.
2. **Buy N** (taker sells N — *impossible anywhere today*): taker delivers N; the desk
   pays ETH, pairs the bought N with matching inventory P of the **same series**, and
   `merge()`s → ETH, **oracle-free**. This is the first and only sell-N venue in
   Gimbal — the desk buys N below intrinsic and recovers `1 ETH − P_value` of capital
   instantly, `net_n` stays near flat instead of accumulating the decaying leg.
3. **Recycle / wind-down:** `merge(min(p_held, amount))` on every buy-N fill;
   `redeem_n(amount)` after a series `settled()` to convert leftover N → ETH at the
   settled value; `TrackerDAO.redeem(shares)` (oracle-free, pro-rata P + ETH) to refill
   mergeable P on demand.
4. **(phase 2) Buy/sell spUSD** vs ETH at the operator's quote, complementing the AMM
   pool. spUSD is the premium-collecting side (no theta, no merge-floor concern); ship
   disabled by default — the killer-dodging story is cleanest N-only.

## 3. Pricing: signed EIP-712 RFQ + the on-chain directional edge floor

Two layers, same shape as the vault but with the trust model **inverted** — there are
no depositors to protect, so the guardrails exist solely to bound the *operator's own*
loss from a stolen hot key or an oracle tick.

- **Off-chain quoter** (the MM brain, §8): reads `x`, live `STRIKE`/`MATURITY`/`settled`,
  and the filler's on-chain `net_n`/balances; computes
  `fair = max(0, 1e18 − STRIKE·1e18//x)`, adds a base spread and an inventory-skew term
  (widens and goes one-sided as `net_n` nears the cap), clamps so the quote is **always
  ≥ min_edge favorable to the desk**, then EIP-712-signs an absolute
  `(n_amount, eth_amount)` pair — not a rate. Invariant: `base_spread_bps ≥ min_edge_bps`,
  so a correct quote is comfortably inside the floor and the floor is only a backstop.
- **On-chain floor** (the only thing the chain trusts): the filler **independently
  recomputes** `fair` from its *own* fresh oracle read and rejects any quote more
  favorable to the taker than `fair·(1±min_edge)`. The signature buys a tight, smart
  price; the directional floor caps the worst case. There is no symmetric band, so no
  within-band drain.

**EIP-712 domain + Quote** (`DOMAIN_SEPARATOR` computed once in `__init__`, binds
`chain.id` + `self` → no cross-chain / cross-desk replay):

```
struct Quote:
    side:     uint8      # 0=BUY_N (desk buys N), 1=SELL_N (desk sells N), 2/3=spUSD (phase 2)
    taker:    address    # empty(address) = open; else only this taker
    series:   address    # exact OptionSeries vintage the quote is priced for (roll-safe, C4)
    amount:   uint256    # N units
    price:    uint256    # ETH wei per 1e18 units
    min_edge: uint256    # 1e18-scaled vault-favorable floor the quoter commits to (>= MIN_EDGE)
    nonce:    uint256     # single-use
    deadline: uint256     # unix; fill must land at/before

QUOTE_TYPEHASH = keccak256(
  "Quote(uint8 side,address taker,address series,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)")
digest = keccak256(concat(0x1901, DOMAIN_SEPARATOR,
           keccak256(abi_encode(QUOTE_TYPEHASH, q.side, q.taker, q.series,
                                q.amount, q.price, q.min_edge, q.nonce, q.deadline))))
signer = ecrecover(digest, v, r, s)   # assert signer != empty(address) and signer == self.quoter
```

`series` is **signed into** the quote (not re-derived at fill) so a `sync()` roll cannot
move the fill onto a vintage the quoter didn't price — the C4 fix.

## 4. The on-chain guardrails (survive a stolen quoter key)

A single internal `_verify_and_guard(q, v, r, s)` runs at the top of every `fill_*`.
The six controls — each one (or few) `assert` line(s):

- **G1 — Signature == approved quoter.** `ecrecover` must return the live `self.quoter`
  (non-zero). The signature is the only authority to fill.
- **G2 — Replay / freshness / binding.** `not used_nonce[q.nonce]`; `block.timestamp ≤ q.deadline`;
  `q.taker == empty(address) or q.taker == msg.sender`. Mark `used_nonce[q.nonce] = True`
  as an **effect before any external call** (CEI). Chain id + verifyingContract already
  bound in `DOMAIN_SEPARATOR`.
- **G3 — Roll-safe vintage (C4).** `target = pending_series(); if 0: active_series()`;
  `assert q.series == target` (roll-safe), `not ISeries(q.series).settled()`,
  **and a buffered maturity cutoff** `assert block.timestamp + PRE_MATURITY_BUFFER < MATURITY`
  (so a leaked key cannot load near-maturity N exposed to settle-race intrinsic drift).
- **G4 — Oracle freshness, TIGHT.** Read `x` (the hub reverts if a feed is staler than
  *its* heartbeat) **and** assert an independent, far-tighter desk bound:
  `block.timestamp − updated_at ≤ DESK_MAX_STALENESS` (≈300–900 s), read from the
  aggregator's `latestRoundData()` (or a new `OracleHub` `price_with_age`/`latest_price_with_age`
  view). The hub's `MAX_HEARTBEAT` is **7 days**; this guard is the load-bearing fix
  for the stale-but-within-heartbeat window (Findings F1, F4, F5, F8, F9, F15). Defense
  in depth: quoter signs `x_sign` into the quote, assert `|x_fill − x_sign|/x_sign ≤ max_dev`.
- **G5 — Directional edge FLOOR + no-trade band.** `assert q.min_edge ≥ MIN_EDGE`
  (immutable hard floor, e.g. `2e16` = 2%); `assert intrinsic_n > 0` (**hard no-trade
  band** when `x ≤ STRIKE`, ideally `x > STRIKE·STRIKE_PROXIMITY//UNIT` with
  `STRIKE_PROXIMITY ≥ roll_trigger`) and `assert intrinsic_n·q.min_edge//UNIT > 0`
  (kills the truncation corner). Then:
  `BUY_N → assert q.price ≤ intrinsic_n·(UNIT−q.min_edge)//UNIT` (buy cheap);
  `SELL_N → assert q.price ≥ intrinsic_n·(UNIT+q.min_edge)//UNIT` (sell dear).
  *(The old "merge-floor invariant `price(P)+price(N) ≥ 1 ETH`" is **deleted** — it is
  provably subsumed by this directional floor for a one-leg-per-fill desk; see F11.)*
- **G6 — Size + inventory + outflow caps.** `0 < q.amount ≤ MAX_FILL`. Project
  `proj_net = net_n ± amount`; if `proj_net > 0`,
  `assert convert(proj_net,uint256)·intrinsic_n//UNIT ≤ MAX_NAV_AT_RISK` (NAV-at-risk =
  ETH lost if `x → STRIKE`, N → 0 — **not** raw units). At/over the cap only inventory-
  *reducing* fills pass ⇒ the desk quotes **one side only**. Plus a fixed/tumbling **per-window
  ETH-outflow cap** that counts split-funded ETH (`need` in buy-N) and direct payouts
  (`proceeds` in sell-N), and a **MIN_ETH_FLOAT** floor (F2/F3). *(Tumbling, not sliding:
  worst case is up to 2× the cap straddling a window boundary — size `outflow_cap` for 2×.)*

`MIN_EDGE` is the immutable hard floor; `q.min_edge` may be tighter-for-the-desk but
never looser. A stolen key's worst case is bounded to `min_edge × MAX_FILL` per nonce,
the per-window outflow budget across the book, and `MAX_NAV_AT_RISK` on inventory — and
`set_paused()`/`set_quoter()` are the instant kill switches. **It is the operator's own
expendable capital, knowingly at risk — never retail's.**

### Fill entrypoints (CEI strict; `@nonreentrant` + transient `_locked`)

```vyper
@external @payable @nonreentrant
def fill_buy_n(q, v, r, s) -> uint256:        # TAKER buys N == DESK SELLS N -> q.side == SELL_N
    # verify+guard; assert msg.value == q.amount*q.price//UNIT (exact, no change)
    # source N: if held < amount: need = amount-held; assert self.balance >= need ("underfunded for split")
    #           and assert self.balance + msg.value - need >= MIN_ETH_FLOAT; split(value=need) (keeps P)
    # transfer N out; net_n -= amount

@external @nonreentrant
def fill_sell_n(q, v, r, s) -> uint256:       # TAKER sells N == DESK BUYS N  -> q.side == BUY_N
    # verify+guard; proceeds = amount*price//UNIT; assert proceeds <= self.balance
    # transferFrom taker's N (CEI: pull before pay); net_n += amount
    # RECYCLE: mergeable = min(p_held, amount); if >0: merge(mergeable); net_n -= mergeable
    # raw_call(msg.sender, b"", value=proceeds)  (interaction last)
```

Operator controls (all `assert msg.sender == owner`; 2-step ownership):
`fund() payable`, `fund_p(series, amount)`, `withdraw_eth(amount)` (`@nonreentrant`),
`withdraw_token(token, amount)`, `set_paused(bool)`, `set_quoter(addr)`,
`set_caps(max_fill, max_nav_at_risk)`, plus owner-only `operator_merge(series, amount)`
/ `operator_redeem_n(series, amount)` passthroughs so post-roll old-series inventory can
be wound down in-contract (F12). `__default__()` is undecorated payable for merge/redeem
ETH receipt.

## 5. Economics at ~5 ETH (ETH ≈ $1,760 ⇒ ~$8,800)

The desk splits the 5 ETH as **3 ETH directional risk budget** (NAV-at-risk, the loss
if ETH → strike) + **2 ETH operating/float reserve** (ETH float for sell-N fills, gas,
ops). Because quotes are off-chain signed and the desk rents no standing position,
**idle bleed ≈ $0** — no funding, no carry, no posting gas.

**O₁ burden and per-N NAV-at-risk** (from `clear-n-findings.md`; at a fresh series
`x₀ = STRIKE/r`, a unit of N is worth `(1−r)` ETH and falls to 0 at the strike):

| strike r | leverage 1/(1−r) | O₁ = (1−r)/r | N genesis value (ETH/unit) = max loss to strike | ETH-drop buffer before roll |
|---|---|---|---|---|
| 0.50 | 2.00× | 1.00 | 0.50 | 25% |
| 0.60 | 2.50× | 0.67 | 0.40 | 10% |
| 0.63 | 2.70× | 0.59 | 0.37 | 5% |
| 0.79 | 4.76× | 0.27 | 0.21 | 5% |

**Recommended r = 0.60** (lev 2.5×): O₁ is 33% off the worst case, the 10% buffer is
survivable for a beta, and `r·roll_trigger ≤ 0.95` (genesis-brick guard) holds.

**Sizing so worst case stays inside 5 ETH** (cap denominated in NAV-at-risk, not raw
units; at the cap the on-chain guard flips to sells-only):

| strike r | NAV-at-risk budget | warehouse cap before SELLS-ONLY | per-fill cap (25% of budget) | per-fill cap (tight, 10%) |
|---|---|---|---|---|
| 0.50 | 3 ETH | 6.0 N-units (3 ETH face) | 0.75 ETH risk/fill | 0.30 ETH risk/fill |
| 0.60 | 3 ETH | 7.5 N-units (3 ETH face) | 0.75 ETH risk/fill | 0.30 ETH risk/fill |
| 0.79 | 3 ETH | 14.3 N-units (3 ETH face) | 0.75 ETH risk/fill | 0.30 ETH risk/fill |

Worst case (ETH instantly to strike, inventory full) = 3 ETH lost, 2 ETH reserve intact,
operator withdraws.

**Revenue = spread × volume.** Realized edge = `min_edge` each side; a matched
round-trip (buy N + merge with inventory P, or buy then sell) captures the full
`s = 2·min_edge`; a one-sided fill held to `redeem_n` captures only `s/2`:

| spread s (min_edge each side) | cover $50/mo | cover $150/mo | cover $300/mo |
|---|---|---|---|
| 0.5% (0.25%) | $10k RT / $20k one-side | $30k / $60k | $60k / $120k |
| 1.0% (0.50%) | $5k RT / $10k one-side | $15k / $30k | $30k / $60k |
| 2.0% (1.00%) | $2.5k RT / $5k one-side | $7.5k / $15k | $15k / $30k |

**Launch at s = 2% (min_edge = 1%)**, tighten toward 1% as flow appears (`MAX_EDGE < UNIT/5`
= 20% on-chain cap respected).

**Costs:** theta carry is *largely neutralized* (buy-side floor pays below intrinsic, so
no time-value premium bleed on floor-priced inventory; residual is directional, captured
by the cap, not a continuous drip). Adverse selection is bounded per fill by `min_edge` +
the per-fill/per-window caps + tight TTL + the G4 staleness gate. Gas is ~0 idle (signed
quotes off-chain), paid out of spread on fills.

**Do NOT hedge at 5 ETH.** Max net-long face ~3 ETH ($5,280); a perp short to neutralize
delta costs ~0.9%/mo funding ≈ **$48/mo**, plus gas/basis risk, to remove an
*already-capped* ≤3 ETH directional bet. Stay unhedged; cap inventory instead. Hedging is
phase-2 interface-only (`IHedger`), revisited only at much larger scale.

**Honest verdict:** at flow ≈ 0 this is a **near-zero-cost peg-maintenance desk**, not a
bleed (off-chain quotes ⇒ ~$0 idle), *unless* ETH drops while inventory is loaded (capped
at 3 ETH, a knowing bet). It turns **modestly positive at ~$10–30k/mo one-sided at 1–2%**,
and a real money-maker only at sustained two-sided round-trip flow well above $30k/mo. Its
value is one that exists nowhere else: **a venue to sell N.**

## 6. Confirmed findings + fixes

Every confirmed finding, folded into the guardrails/risks above:

| # | Title | Sev | Fix (folded in) |
|---|---|---|---|
| F1 | Stale-but-valid oracle lets `split`-and-dump drain the buy-N side (~35% of true N value/unit) | **high** | **G4**: independent TIGHT `DESK_MAX_STALENESS` (~300–900 s) on the hot path, read `updated_at` directly / via a new hub age view — separate from the 7-day heartbeat; the load-bearing fix since both floor and merge-floor read the same `x`. Defense-in-depth: quoter signs `x_sign`, assert `|x_fill−x_sign| ≤ max_dev`. Keep caps small. |
| F2 | `fill_buy_n` mint-on-demand turns liquid ETH into illiquid P, drains the operating reserve uncapped | med | **G6**: `MIN_ETH_FLOAT` floor on the split branch — `assert self.balance + msg.value − need ≥ MIN_ETH_FLOAT`; complementary net-P / ETH-locked cap. Do **not** price sell-N up to recover full split cost (would kill legit leverage flow). |
| F3 | Hot-key blast radius is **not** "min_edge/unit" — it is `MAX_FILL × unconsumed nonces`; quoter mints nonces unboundedly | low | **G6**: per-window ETH-outflow cap that counts **split-funded** ETH (`need`), not just payouts; optional per-window JIT-split cap / inventory-only above a threshold. Document the residual as **griefing-of-liquidity** (self-funded by attacker, halted by `pause`/`set_quoter`), not theft. |
| F4 | Deadline/TTL bounds only the *signed* price; the floor re-derives from a live oracle that accepts up to a 7-day heartbeat | low | **G4** `DESK_MAX_STALENESS` + per-block outflow cap + point the desk only at a tight-heartbeat asset (the 7200 s USD feed). |
| F5 | Heartbeat-edge timing: taker fills in the block before the feed updates, picking the about-to-be-stale `x` | low | **G4** tight hot-path freshness (`MAX_QUOTE_STALENESS` ~60–180 s via a hub `price_with_age` view) + add `assert answered_in ≥ round_id` in `OracleHub._read` (currently read & discarded) + ~1-block TTL. |
| F6 | Two-feed staleness skew on non-USD RWA: `x=(ETH/USD)/(ASSET/USD)` wrong even when both feeds are individually "fresh" | med | **Gate v1 to `ASSET == empty(bytes32)` (USD-only) as a `__init__` assert.** For non-USD, require `MIN_EDGE ≥ (eth_drift + asset_drift)·leverage`; phase 2: hub view returning `min(eth_updated_at, asset_updated_at)` + a skew bound. Document that "freshness via heartbeat" only covers single-feed desks. |
| F7 | `x ≤ STRIKE` (intrinsic = 0) degenerate floor: taker pays ~0 for N with real option value, or dumps N for ~0 | med | **G5**: `assert intrinsic_n > 0` hard no-trade band (ideally `x > STRIKE·STRIKE_PROXIMITY//UNIT`, `STRIKE_PROXIMITY ≥ roll_trigger`) + `assert intrinsic_n·q.min_edge//UNIT > 0` (truncation corner). Time value can't be priced on-chain ⇒ no-trade band around strike, not "intrinsic=0 is fair." |
| F8 | Oracle-priced entry vs oracle-FREE merge exit: a stale-`x` fill the desk merges locks the oracle error in as a guaranteed loss | med | **G4** tight-heartbeat asset id; size `min_edge ≥ (max move over window)/(1−r)`; quoter short TTL + spot-deviation check + emit per-fill round-trip/merge PnL. The merge-floor cannot fix it (same stale `x`); constrain `x` or oversize `min_edge`. |
| F9 | `redeem_n` settlement uses a different oracle read than the fill-time floor; the buffer is off-chain only | low | **G3**: move the buffer on-chain — `assert block.timestamp + PRE_MATURITY_BUFFER < MATURITY` (e.g. 1–2 d, inside the 7-d roll window), at least on SELL_N. |
| F10 | (cluster 1) directional floor is correctly two-sided, **but** the touted merge-floor invariant is **dead code** | low | **DELETE** the merge-floor block from `_verify_and_guard` (`price(P)+price(N) ≥ 1` reduces to a strictly-weaker constraint than the edge floor); correct §3/§4 docs. The directional edge floor already guarantees `intrinsic_n − q.price ≥ intrinsic_n·min_edge > 0`. |
| F11 | (cluster 1, doc) merge-floor listed as a "KEPT & made concrete" protection — it is neither concrete nor protective | low | Same as F10: remove from KEY DECISIONS / review checklist; replace with the honest one-control note. The desk quotes **one leg per fill**, so the n-curve two-leg simultaneous-quote merge-arb does not apply. |
| F12 | (cluster 3) killer correctly moved onto operator capital, **but** `redeem_n` is unreachable before settlement ⇒ leftover unpaired N is stuck-illiquid up to a full term | low | Disclose in §9: N bought beyond matching P is ETH locked until maturity/settlement (`MAX_NAV_AT_RISK` bounds it, protects the reserve, but new-quote capacity can stall a term). Quoter: free-ETH-liquidity is a **separate** soft cap from NAV-at-risk; prefer immediately-mergeable fills. Tooling: `fund_p` + `TrackerDAO.redeem` refill mergeable P; add owner `operator_merge`/`operator_redeem_n` passthroughs. |
| F13 | Series rolls/expires while the desk holds N: the C4 fill-time guard reverts ALL fills on the old vintage, freezing inventory with no in-contract unwind | low | Add owner-only `operator_merge(series, amount)` / `operator_redeem_n(series, amount)` (assert `settled` for redeem) keeping `net_n` consistent, `@nonreentrant`. `settle` stays permissionless (`TrackerDAO.sync`/`OptionSeries.settle`). Absent them, `withdraw_token` + external merge/redeem is already a complete recovery path. |
| F14 | `fill_buy_n` requires exact `msg.value` but must fund `(need − cost)` from its own balance to `split()`; no precheck, §6 comment self-contradictory | low | **G6**: before `split(value=need)`, `assert self.balance >= need, "desk underfunded for split"` (self.balance already includes `cost`; `cost < need`). Reconcile the comment. Without it, only effect is an opaque revert (tx + nonce revert atomically) — no loss. |
| F15 | "oracle freshness for free" overstated: `MAX_HEARTBEAT = 7 days`, so a quote can fill against a price up to a week stale and still pass | low | Honesty correction in §9 (replace "C6 for free" with "bounded by the registered feed's heartbeat, not zero") + the **G4** `MAX_QUOTE_STALENESS` immutable (assert against a hub `updated_at` view; absent the view, accept the heartbeat and say so) + ~30–90 s TTL bounds *quote* age not *feed* age + tiny `MAX_FILL` at launch. |

## 7. How it plugs in

### Factory-or-standalone: STANDALONE per-operator, NOT a 4th `PeripheryFactory` blueprint

`PeripheryFactory`'s trust model rests on four invariants the desk violates:

| `PeripheryFactory` (router/zapper/flash) | `SignedQuoteFiller` |
|---|---|
| Holds **no funds**; worst-case bug loses only the in-flight tx | Holds the operator's **~5 ETH + inventory persistently** |
| **No admin, no privileges** | **Operator-admin'd** (fund/withdraw/pause/quoter) |
| **One canonical instance per (tracker, fee)**, frozen forever | **Inherently plural** — many rival operators per peg |
| Keyed by `(tracker, fee)` (Uniswap `getPool` deterministic) | No pool, no fee tier — keyed by `(tracker, operator)` |

Folding it in would either **silently break the `is_router`/`is_zapper` ⇒ "safe because
holds no funds"** guarantee UIs rely on, or bolt an admin/multi-instance exception onto a
contract whose siblings promise "no privileges, holds no funds." Instead ship a separate
thin **`OperatorDeskRegistry.vy`** (permissionless, enumerable, EIP-5202 blueprint, holds
no funds, gated on `TrackerFactory.is_tracker`):

```
deploy_desk(tracker) -> address    # blueprint-deploys a SignedQuoteFiller, msg.sender = OPERATOR, records by (tracker, operator)
is_desk(addr) -> bool              # bytecode-trust (like is_router) — NOT funds-safety
operator(desk) -> address
desk_count(tracker) -> uint256;  desk_at(tracker, i) -> address
```

*(Cheap v1 alternative: hand-deploy the single spUSD desk from the blueprint and list it
in `operatorDesks.json`; add the registry in phase 2 when a 2nd operator/peg appears. But
the registry is ~80 lines and makes desks first-class-discoverable.)*

### Trust layer: bytecode-trust on-chain, operator-vouch off-chain

Mirror the certified-pegs pattern one tier down — the two questions are different and the
contract layer must not conflate them:

- **On-chain (objective):** `OperatorDeskRegistry.is_desk(addr)` proves known-good
  bytecode (the fill/floor/pause logic is the audited code); `desk.operator()` reveals
  who controls the funds. Analog of `is_router`/`is_tracker`.
- **Off-chain (curated):** `operatorDesks.json` in `@gimbal/protocol`, mirroring
  `certifiedPegs.json`: `{ tracker, desk, operator, quoterPubkey, assetSymbol, label, sinceBlock }`.
  Only listed desks are surfaced by default. "Listed" ⇔ "operator we recognize," **not**
  "we run it."
- **Quoter set:** v1 = **one quoter key per desk** (immutable-at-deploy preferred for the
  smallest surface; `set_quoter` settable is the rotatable phase-2 option). The json
  records the expected `quoterPubkey` so the UI shows "quotes signed by 0x… ✓."
- **UI labeling (REQUIRED, honesty-critical):** every RFQ surface must say **"Operator-quoted
  desk — your counterparty is `0x…` (operator), not the Gimbal protocol. Quotes are signed
  off-chain and filled at a price floored on-chain."** An unlisted desk gets the
  unverified-peg warning-gate treatment (muted, show-more, modal ack naming the operator).
  The desk must **never** be styled like a trustless protocol primitive.

### Frontend: a real sell-N path, and the false copy to fix

- **Fix the false copy first.** The Leverage/Provide tabs currently imply N is sellable
  today (e.g. "keep it… or sell it to leverage buyers… selling the N routes through the
  same pool"). **It is not — there is no N pool and no N venue; `LeverageRouter` only goes
  ETH→N.** That copy is false. The RFQ desk is what makes it true; until a desk is listed
  for a peg, disable the sell-N affordance with honest copy ("no desk is quoting this leg
  yet").
- **Quote-request flow:** resolve the desk via `desk_at` filtered by `operatorDesks.json`;
  `POST /quote {side, tracker, series, n_amount, taker?}` to the operator's quoter; receive
  the EIP-712-signed `Quote` + signature; show price vs on-chain intrinsic and the edge the
  desk takes (full transparency, the brand); fill on-chain via `fill_buy_n{value}` /
  `fill_sell_n` (approve N first). Treat every revert (`expired`, `nonce used`, `below floor`,
  `wrong series`, `cap exceeded`, `insufficient inventory`) as **"get a fresh quote"** except
  `paused`/`stale oracle` (show desk-down) — since the desk custodies no user funds, a failed
  fill never risks them; the user just re-quotes.
- **Honest depth display:** RFQ fills have no pool slippage but have inventory/cap limits and
  a single counterparty — surface remaining buy-side capacity (desk ETH), sell-side capacity
  (desk N + JIT-mint headroom), and paused state; offer to split or route the spUSD leg to the
  pool if size exceeds caps.

### Coexistence with the AMM pool + seed/keeper plan

- **Different legs, different venues — complementary, not rivals.** The spUSD/WETH Uniswap
  pool is the **P/stable** venue (Hold buys/sells spUSD; `LeverageRouter`/`FlashLeverageRouter`
  sink **P** there to net out to pure N). The RFQ desk is the **N/leverage** venue.
- **Does RFQ remove the need to seed the spUSD pool? NO for spUSD, YES for N.** Keep seeding
  the spUSD/WETH pool near NAV and keep the arb/keeper holding it near peg (unchanged) — it is
  still the P-sink `LeverageRouter.open_leverage` swaps through and the Hold tab's instant
  buy/sell. The desk is **additive**: it gives the N leg the buyer the Provide tab's handed-out
  N never had. But RFQ **removes any temptation to ever seed an N-side pool** — which never
  existed and, per `clear-n-findings.md` (every standing oracle-priced N bid drains via the
  merge floor C2; an LP/vault warehouse is C1-disqualified), should never be built. RFQ is the
  structurally-correct N venue precisely because the desk merges P+N→ETH oracle-free instead of
  holding a standing pool bid that arbs against intrinsic.

## 8. Components to build — v1 checklist vs phase 2

**v1 (minimal launchable): N-only desk for spUSD (USD-feed), single quoter, tiny caps.**

1. `SignedQuoteFiller.vy` — `fill_buy_n` + `fill_sell_n`; EIP-712 verify (G1) + single
   quoter key; replay/deadline/taker (G2); roll-safe vintage + settled + `PRE_MATURITY_BUFFER`
   (G3); **tight `DESK_MAX_STALENESS`** (G4 — `x_sign` deviation deferred to phase 2: the
   directional floor re-clamps to the fresh fill-time intrinsic, so it is redundant for desk
   safety); directional `MIN_EDGE` floor
   + `intrinsic_n > 0` no-trade band + truncation-corner assert (G5, **merge-floor block
   deleted**); `MAX_FILL` + `MAX_NAV_AT_RISK` + per-window outflow cap (counting split-funded
   ETH) + `MIN_ETH_FLOAT` + underfunded-for-split precheck (G6); `merge(min(p_held,amount))`
   recycle on buy-N; `@nonreentrant` + transient `_locked` + undecorated payable `__default__`.
2. Operator-only `fund` / `fund_p` / `withdraw_eth` / `withdraw_token` / `set_paused` /
   `set_quoter` / `set_caps`, 2-step ownership, + `operator_merge` / `operator_redeem_n`
   passthroughs (F12/F13).
3. `__init__(tracker, hub, asset, weth, quoter, min_edge, max_fill, max_nav_at_risk)` (owner =
   msg.sender), zero-address asserts, `DOMAIN_SEPARATOR` once, **`assert asset == empty(bytes32)`**
   (USD-only v1, F6), EIP-5202 blueprint `code_offset=3`.
4. `OperatorDeskRegistry.vy` (or hand-deploy the first desk from the blueprint + list it).
5. Off-chain **quoter service** (§ below) — `POST /quote`, `GET /healthz`, hot key in Railway
   secrets, single instance, graceful "no quotes ⇒ trading pauses" downtime.
6. `operatorDesks.json` + UI "operator-quoted desk, counterparty 0x…" label + warning gate for
   unlisted desks.
7. Leverage-tab **sell-N path enabled** + the false "sell on the leverage page" copy fixed.
8. "Sepolia testnet, research code, unaudited" tag everywhere.
9. Adversarial review targeting: the EIP-712 verify, the floor math, the staleness gate (G4),
   the caps/outflow accounting, and the key-compromise bound. *(The deleted merge-floor is no
   longer a review target — F10/F11.)*

**Quoter service params (capped-beta defaults, operator-tunable):** `MIN_EDGE_BPS` 100 (1%) at
launch → floor 50 (0.5%) with flow; `BASE_SPREAD_BPS` 50–150 (invariant `base ≥ min_edge`);
`SKEW_K` 1–3; `CAP_ETH` ~3 of 5; `MAX_FILL` ~0.1 ETH at cold start → ≤0.75 ETH with flow;
per-fill NAV-at-risk 0.30 ETH cold; `TTL_SECONDS` ~45 (≈1 block); `PRE_MATURITY_BUFFER` ~1–2 d;
`DESK_MAX_STALENESS` 300–900 s. Quote **wide**, cap **small**, widen only on observed two-sided
flow.

```
util = clamp(net_n / cap, 0, 1);  skew_bps = skew_k * base_spread_bps * util
DESK_BUYS_N:  buy_discount_bps = base_spread_bps + skew_bps;  price = fair*(1 - buy_discount_bps*1e14)/1e18; REFUSE at util>=1
DESK_SELLS_N: sell_markup_bps  = max(min_edge_bps, base_spread_bps - skew_bps);  price = fair*(1 + sell_markup_bps*1e14)/1e18
```

Nonce = one-shot consumed (Permit2-style unordered), tracked in-memory; on restart let
in-flight quotes expire. The service **only quotes** — it never moves the operator's principal
(that stays an owner action, minimizing the hot key's authority).

**Phase 2 (widen with flow):** spUSD two-way quoting (desk as a Hold venue alongside the pool;
add the merge-floor invariant only there, where it actually binds for two-leg quotes);
multi-desk / multi-peg via the registry; operator-managed multi-key quoter set;
`set_quoter` rotation; optional delta hedge of the net-long-N book —
`IHedger.target_short_eth(int256)` / `rebalance(int256)` / `position()`, keyed off
`net_n_delta = net_n · 1e18 · x // (x − STRIKE)` for `x > STRIKE` (capped); non-USD RWA desks
with the two-feed skew bound (F6). Widen caps toward the full ~5 ETH as confidence builds.

## 9. Honest risks + bottom line

- **Operator is short theta on net-long N** — a crash erodes the desk's *own* ETH. Bounded by
  `MAX_NAV_AT_RISK` (≤3 ETH), hedgeable in phase 2, expendable capital. **Not a yield product.**
- **Term-illiquidity (F12):** N bought beyond matching P is ETH locked until series maturity
  (`redeem_n` requires `settled`) or until the operator acquires matching P. The cap bounds it
  and protects the reserve, but new-quote capacity can stall for up to one term.
- **Stolen quoter key:** capped by the directional floor + `MAX_FILL` + per-window outflow cap +
  `MIN_ETH_FLOAT` + balance, with `set_paused`/`set_quoter` as instant kill switches. The real
  residual is **griefing-of-liquidity** (forced self-funded splits convert reserve into illiquid
  P), not theft — bounded, survivable, on expendable capital.
- **Oracle on the hot path:** freshness is bounded by the *registered feed's heartbeat* (2 h
  USD, up to 7 d at `MAX_HEARTBEAT`), **not zero** — the desk inherits exactly the core
  protocol's oracle posture. The tight `DESK_MAX_STALENESS` gate (G4) shrinks the window to a
  few blocks; the loss is bounded by the per-fill/per-window caps, never a drain. Two-feed RWA
  desks carry a ratio-skew risk (F6) — v1 is USD-only by assert.
- **Roll/vintage (C4):** quotes bind an exact series; the fill reverts on a mid-quote `sync()`
  roll. Old-series N is wound down via the operator passthroughs / `redeem_n` after settlement.
- **Counterparty clarity:** the UI must never let a user think the desk is the protocol — label
  + warning gate are mandatory.
- **Cold-start adverse selection:** the only early counterparty is an arber — quote wide, cap
  small until two-sided flow exists.
- **Profitability needs flow:** zero volume ⇒ ~$0 (off-chain quotes), not a bleed — but no
  margin either. It is a bet on volume.

**Bottom line.** The solo RFQ desk is the **provably-clean residual of the killed crowd-vault**:
it keeps the one good mechanism (directional edge floor + signed quotes, surviving even a stolen
key) and strips the two structural problems (pooled capital, NAV arb) by making the capital and
the short-theta risk the **operator's own, capped, knowing, withdrawable** bet on ~5 ETH of
expendable bootstrap capital. It does not create leverage demand — it is a **matching +
warehousing venue** — but it is the **first and only place an N holder can actually sell**, it
recovers capital oracle-free via `merge`, and it costs ~$0 to idle. **Sepolia testnet, research
code, unaudited; the operator's expendable bootstrap capital, not a yield product.** Best
described as a near-zero-cost peg-maintenance desk that can turn modestly profitable with flow.
