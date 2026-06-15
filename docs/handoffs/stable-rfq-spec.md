# Gimbal Stable RFQ Desk (spUSD) — operator-run market making for the P/dollar leg (spec)

> Build spec, not a sketch. A **single-operator**, self-funded RFQ desk that is the counterparty for Gimbal's **spUSD (P/dollar / stable) leg** — buy *and* sell — sibling to the deployed N-leg `SignedQuoteFiller` (Sepolia `0x48c93eD52507DEe37d79eA37Df9ed7fAF739C8F1`). The operator funds it with their *own* ETH + spUSD inventory, signs EIP-712 quotes off-chain, and only those quotes fill on-chain — bounded by a directional, **NAV-anchored** edge floor that survives a stolen quoter key. It reuses the N desk's entire safety skeleton (EIP-712 domain, G1–G6, fork-safe digest, tight `DESK_MAX_STALENESS`, 2-step ownership, `@nonreentrant`, undecorated payable `__default__`) and keeps that contract **UNTOUCHED**.
>
> **Sepolia testnet, research code, unaudited. This is the operator's own capped capital, not a yield product, not a pooled fund — no third-party deposits, no shares, no NAV-per-share token.**

## ⚠ Why this is the POSITIVE-CARRY desk — sound and solo-safe where the crowd-vault was killed

The N desk is honest that it is on the **wrong side of carry**: it warehouses N, the **decaying / short-theta** leg, and *knowingly bleeds* (`solo-rfq-spec.md §5`: "near-zero-cost to idle but bleeds if ETH drops while inventory is loaded"). The spUSD desk is its mirror image on **the side that collects the premium N pays**:

1. **POSITIVE carry, not bleed.** N pays the carry; the DAO harvests that premium into `eth_buffer` via the `sell_p`/`fill_roll` `MAX_EDGE` auctions, so `share_price()` (NAV/share) **accretes over time** (`TrackerDAO.vy:290`, harvest path `:457`). A desk that warehouses spUSD is on the **positive-carry** side: idle inventory gains value instead of losing it. The N desk's carry is `≤ 0`; this desk's is `≥ 0`.
2. **Mild, bounded, un-leveraged directional risk.** Net-long spUSD ≈ **1× short-ETH** (spUSD tracks USD; long-USD-vs-ETH = short-ETH at 1×). **No leverage, no liquidation** (the whole P/N system is liquidation-free by construction), no theta drip, no decay-to-zero. This is ordinary stablecoin-MM inventory risk, capped by `MAX_NET_SPUSD`.
3. **Solo-safe by the same deletions the N desk relies on.** No NAV-per-share token, no pooled deposits, no third-party shares — the killed crowd-vault's two structural problems (pooled capital, NAV/share arb) are *deleted*, not mitigated. The capital and the risk are the **operator's own, capped, withdrawable** bet. It is the surviving clean half of `mm-vault-spec.md`, applied to the profitable leg.
4. **The ONE trap it must dodge: never mint-to-sell.** To sell spUSD the desk needs spUSD. If it mints via `deposit()`, the DAO hands it the **N leg** (`TrackerDAO.vy:343` — the orphan-N handout), recreating the exact short-theta bleed this desk exists to avoid. So the desk is strictly **inventory-based** (§2). This is the headline constraint and the single most important guard.

So the spUSD desk is the structurally-correct positive-carry sibling the carry reframe points at: same machinery, opposite carry sign. Honest about magnitude — at Sepolia/bootstrap flow the carry is real but small in absolute dollars (§5).

---

## 1. What it is

`StableQuoteFiller.vy` — `# pragma version ==0.4.3`, one periphery-style contract per operator-per-peg, EIP-5202-blueprint-able, same conventions as `src/periphery/` (`raw_call` ETH-out, undecorated payable `__default__` for `redeem`/`merge` ETH callbacks, `@nonreentrant` transient guard). A **separate sibling** to the deployed N desk — not an extension; the N desk stays untouched (it is immutable, live-config'd, and has different fair-value math, risk axis, and inventory primitive — see §7).

- **Solo.** ONE operator funds it with their OWN ETH + spUSD inventory. ONLY quotes signed by the operator's approved quoter key can fill.
- **No public deposits, no vault shares, no NAV-per-share token** on any hot or cold path. That deletion is the point.
- **`TrackerDAO` IS the spUSD ERC20** (`implements: IERC20`) — so the `TRACKER` immutable and the spUSD token are the **same address**; there is no separate spUSD token to wire.
- **Single token, no vintage.** spUSD has no series / strike / maturity / roll. The N desk's per-series `Quote.series` field, its G3 roll-safe vintage block, and its `pre_maturity_buffer` / `strike_proximity` ctor params are all **deleted**. The only position accounting is a single **unsigned** `uint256 net_spusd` (the desk is never short — it sells only inventory), not the N desk's `HashMap[address,int256]`.
- **Operator controls everything:** `fund()`, `fund_spusd()`, `withdraw_eth()`, `withdraw_token()`, `set_paused()`, `set_quoter()`, `set_caps()`, `operator_redeem()` — all owner-only, 2-step ownership, any time. No third party can move desk funds.

## 2. How it trades spUSD

Confirmed against the real contracts (`TrackerDAO.vy`, `OptionSeries.vy`, `OracleHub.vy`):

- `TrackerDAO.deposit() payable -> uint256` (`:322`): splits ETH at the target series, keeps P, mints shares to the caller, **and `transfer`s the freshly-minted N back to the caller** (`:343`). **The desk NEVER calls this** (the trap).
- `TrackerDAO.redeem(shares)` (`:362`, **void**): burns shares, sends caller pro-rata `eth_buffer` ETH **and** pro-rata P of each live series (active + pending), **oracle-free**. Used only off the hot path (`operator_redeem`).
- `TrackerDAO.share_price() -> uint256` (`:290`): NAV per share in **asset units** (USD for the USD asset), 1e18, soft-peg target `1e18`; accrues as the DAO harvests.
- `OptionSeries.merge(amount)` (`:167`): burns P+N → ETH, **oracle-free, any time** — irrelevant to spUSD's hot path (the desk holds no N), noted for the P-disposition discussion (§6, F-row).
- `OracleHub.latest_price(ASSET) -> x` (`:102`): x = ETH priced in asset units (USD ⇒ ETH/USD), 1e18; `ETH_USD_FEED` public immutable.

The desk does **three** things:

1. **Sell spUSD** (taker buys spUSD): taker sends ETH; the desk delivers spUSD **from inventory ONLY**. There is no JIT-mint branch. When inventory would fall below `MIN_SPUSD_FLOAT` the fill **reverts** and the desk goes **one-sided (buy-only)** — exactly how the N desk refuses at its NAV-at-risk cap, but on the *depletion* axis. `fill_buy_spusd(q,v,r,s) payable`.
2. **Buy spUSD** (taker sells spUSD): taker delivers spUSD; the desk pays ETH and **warehouses** the spUSD as positive-carry inventory (`net_spusd += amount`). Gated by the net-long cap (`inventory-full`), `MIN_ETH_FLOAT`, and the per-window outflow cap. `fill_sell_spusd(q,v,r,s)` (taker `approve(desk, amount)` first).
3. **Recycle / wind-down (owner-only, OFF the hot path):** `operator_redeem(shares)` → `TrackerDAO.redeem(shares)`, oracle-free, returns pro-rata `eth_buffer` ETH (redeployable float) **plus** pro-rata P of each live series. **The ETH share is pure oracle-free recovered capital; the P share must be disposed of** (sell into the spUSD/WETH pool near NAV, or hold) — see the honest cost note in §5/§6. Unlike the N desk, there is **no `merge` recycling on the fill path**: `redeem()` is multi-asset and pays out ETH + up to two P tokens, not a clean per-fill round-trip.

**`fund_spusd(amount)` is ALLOWED** (the deliberate inverse of the N desk, where funding N directly was *forbidden*). Here funding spUSD raises `net_spusd` on the **safe** side the buy-floor already guards, so it is the desk's **primary inventory source** — cold-start inventory comes from the operator transferring spUSD they already hold (sourced via their own EOA `deposit()`/pool-buy done *outside* the desk). **No `operator_mint_inventory` / `operator_deposit` escape hatch ships** (it would call `deposit()` and re-import orphan N — see F-ORPHAN below).

## 3. Pricing: signed EIP-712 RFQ + the on-chain NAV floor

Two layers, same shape as the N desk; only the **priced object** changes.

**Fair value — NAV in ETH (the whole pricing delta).** spUSD NAV is in USD; convert to ETH via the oracle:

```
x      = OracleHub.latest_price(ASSET)   # USD per 1 ETH, 1e18   (USD asset -> single ETH/USD feed)
sp     = TrackerDAO.share_price()         # USD per 1e18 spUSD, 1e18 (NAV/share; accrues over time)
fair   = sp * UNIT // x                    # ETH wei per 1e18 spUSD
```
Dimensional check: (USD/spUSD) ÷ (USD/ETH) = ETH/spUSD, in wei — exactly the N desk's `price` units. Soft-peg makes `sp ≈ 1e18`, so `fair ≈ 1e18/x` ("≈ 1 USD of ETH"), drifting **up** as NAV accrues.

**Off-chain quoter** (the MM brain, §8): reads `x`, `share_price()`, and the desk's on-chain spUSD balance + ETH float; computes `fair`, adds a base spread and an **inventory-DEPLETION** skew (widens the SELL side as spUSD runs out, tightens the desk's BID as it empties to refill — opposite axis to the N desk's risk-shedding skew); clamps so the quote is **always ≥ min_edge favorable to the desk**; then EIP-712-signs an absolute `(amount, price)` pair. Invariant `base_spread_bps ≥ min_edge_bps`.

**On-chain floor** (the only thing the chain trusts): the filler **independently recomputes** `fair` from its own fresh oracle read and rejects any quote more favorable to the taker than `fair·(1±min_edge)`:
- **Desk SELLS spUSD** (`fill_buy_spusd`): `q.price ≥ fair·(UNIT + q.min_edge)//UNIT` — sell dear.
- **Desk BUYS spUSD** (`fill_sell_spusd`): `q.price ≤ fair·(UNIT − q.min_edge)//UNIT` — buy cheap.

The oracle is on the floor path ⇒ the **same tight `DESK_MAX_STALENESS` gate** the N desk runs (read off `ETH_USD_FEED.latestRoundData()`, independent of the hub's up-to-7-day heartbeat). There is **no near-strike no-trade band** (spUSD has no strike; `fair` degenerates only if `sp` or `x` is 0, caught by the "fair degenerate" + truncation-corner asserts).

**EIP-712 domain + Quote** (`DOMAIN_SEPARATOR` cached in `__init__`, fork-safe recompute on `chain.id` change, binds `chain.id` + `self`):

```
struct Quote:
    side:     uint8      # 0=BUY_SPUSD (desk buys), 1=SELL_SPUSD (desk sells)
    taker:    address    # empty(address)=open; else only this taker
    amount:   uint256    # spUSD units, 1e18
    price:    uint256    # ETH wei per 1e18 spUSD
    min_edge: uint256    # 1e18-scaled desk-favorable floor the quoter commits to (>= MIN_EDGE)
    nonce:    uint256     # single-use
    deadline: uint256     # unix; fill must land at/before

QUOTE_TYPEHASH = keccak256(
  "Quote(uint8 side,address taker,uint256 amount,uint256 price,uint256 min_edge,uint256 nonce,uint256 deadline)")
NAME_HASH = keccak256("Gimbal Solo RFQ Stable Desk")   # DISTINCT from the N desk's "Gimbal Solo RFQ Desk"
digest = keccak256(concat(0x1901, DOMAIN_SEPARATOR,
           keccak256(abi_encode(QUOTE_TYPEHASH, q.side, q.taker, q.amount,
                                q.price, q.min_edge, q.nonce, q.deadline))))
signer = ecrecover(digest, v, r, s)   # assert signer != empty(address) and signer == self.quoter
```

The Quote **drops the N desk's `series` field** (7 members, not 8 — spUSD is one token, no vintage). `NAME_HASH` is deliberately distinct (F-DOMAIN): cross-desk replay is already blocked by `self` in `DOMAIN_SEPARATOR` and by the different `QUOTE_TYPEHASH`, but the distinct name is belt-and-suspenders. **Do NOT copy a precomputed constant `DOMAIN_SEPARATOR` from the N desk; recompute it (must include `self`).**

## 4. The on-chain guardrails (survive a stolen quoter key)

A single internal `_verify_and_guard(q, v, r, s) -> fair` runs at the top of every `fill_*`, returning the freshly-recomputed `fair`. Reused **verbatim** from the N desk except where noted:

- **G1 — Signature == approved quoter.** `ecrecover` must return the live `self.quoter` (non-zero). The only authority to fill.
- **G2 — Replay / freshness / binding.** `not used_nonce[q.nonce]`; `block.timestamp ≤ q.deadline`; `q.taker == empty(address) or q.taker == msg.sender`. Mark `used_nonce[q.nonce] = True` as an **effect before any external call** (CEI).
- **G3 — (DELETED).** No vintage / settled / maturity / asset-match checks. spUSD is a single token; the whole roll-safety surface is gone ("simpler in one way").
- **G4 — Oracle freshness, TIGHT.** Inside `_fair()`: read `x`, then `_assert_fresh()` — copied verbatim from the N desk (`answer > 0`, `answered_in ≥ round_id`, `updated_at ≤ now`, `now − updated_at ≤ DESK_MAX_STALENESS` ≈ 300–900 s on mainnet, off `ETH_USD_FEED`). The load-bearing control. **v1 is USD-only by `__init__` assert** (single-feed freshness — F6 below).
- **G5 — Directional NAV floor (both sides).** `assert MIN_EDGE ≤ q.min_edge ≤ MAX_MIN_EDGE` (`MAX_MIN_EDGE = UNIT//5` = 20%, matching the DAO's `MAX_EDGE` posture); `assert fair·q.min_edge//UNIT > 0` (truncation corner). Then `SELL_SPUSD → price ≥ fair·(UNIT+q.min_edge)//UNIT`; `BUY_SPUSD → price ≤ fair·(UNIT−q.min_edge)//UNIT`. No near-strike band (spUSD has no strike).
- **G6 — Size + inventory + NAV-at-risk + outflow + float.** `0 < q.amount ≤ MAX_FILL`. **Sell side** (`fill_buy_spusd`): `net_spusd − q.amount ≥ MIN_SPUSD_FLOAT` (the **inventory rule** — revert / one-sided when dry, **never mint**). **Buy side** (`fill_sell_spusd`): project `proj = net_spusd + q.amount`; `assert proj·fair//UNIT ≤ MAX_NET_SPUSD` (NAV-at-risk = ETH-equivalent of net inventory = the 1×-short-ETH axis; at the cap → buy-only refused, sells-only to shed); `assert self.balance − proceeds ≥ MIN_ETH_FLOAT`; per-window tumbling `_charge_outflow(proceeds)` on ETH paid out (the buy side is the only ETH-out path), sized for 2× across a boundary.

`MIN_EDGE` is the immutable hard floor; `q.min_edge` may be tighter-for-the-desk but never looser. A stolen key's worst case is bounded to `min_edge × MAX_FILL` per nonce, the per-window outflow budget, and `MAX_NET_SPUSD` on inventory — and `set_paused()`/`set_quoter()` are instant kill switches. **The operator's own capped capital, knowingly at risk — never retail's.**

### Fill entrypoints (CEI strict; `@nonreentrant`)

```vyper
@external @payable @nonreentrant
def fill_buy_spusd(q, v, r, s) -> uint256:    # TAKER buys spUSD == DESK SELLS from INVENTORY ONLY
    assert q.side == SIDE_SELL_SPUSD, "side"
    fair: uint256 = self._verify_and_guard(q, v, r, s)
    cost: uint256 = q.amount * q.price // UNIT
    assert msg.value == cost, "bad value"
    assert self.net_spusd - q.amount >= self.min_spusd_float, "insufficient inventory"  # *** NO mint-to-sell ***
    self.net_spusd -= q.amount                                                          # effect (CEI)
    assert extcall IERC20(TRACKER).transfer(msg.sender, q.amount), "spusd transfer"
    return q.amount

@external @nonreentrant
def fill_sell_spusd(q, v, r, s) -> uint256:   # TAKER sells spUSD == DESK BUYS, warehouses, pays ETH
    assert q.side == SIDE_BUY_SPUSD, "side"
    fair: uint256 = self._verify_and_guard(q, v, r, s)
    proceeds: uint256 = q.amount * q.price // UNIT
    assert proceeds <= self.balance, "insufficient eth"
    assert (self.net_spusd + q.amount) * fair // UNIT <= self.max_net_spusd, "nav cap"
    assert self.balance - proceeds >= self.min_eth_float, "float floor"
    self._charge_outflow(proceeds)
    self.net_spusd += q.amount                                                          # effects first (CEI)
    assert extcall IERC20(TRACKER).transferFrom(msg.sender, self, q.amount), "spusd pull"
    raw_call(msg.sender, b"", value=proceeds)                                           # interaction last
    return proceeds
```

Operator controls (all `assert msg.sender == owner`; 2-step ownership):
`fund() payable`, `fund_spusd(amount)` (seed inventory; `net_spusd += amount`), `withdraw_eth(amount)` (`@nonreentrant`), `withdraw_token(token, amount)` (if `token == TRACKER`, `net_spusd -= amount` to keep the book honest), `set_paused(bool)`, `set_quoter(addr)`, `set_caps(max_fill, max_net_spusd, min_eth_float, min_spusd_float, outflow_cap)`, `operator_redeem(shares)` (`@nonreentrant`, oracle-free wind-down; `net_spusd -= shares`), and the convenience `operator_redeem_p(series, amount)` (`assert ISeries(series).settled()` → `redeem_p`, mirroring the N desk's `operator_redeem_n`, for old-vintage P after a roll — F-ROLL). `__default__()` is undecorated payable for the `redeem`/`merge` ETH callbacks. Views: `fair_price() -> uint256`, `net_spusd() -> uint256`, `redeem_floor_eth(amount) -> uint256` (the **eth_buffer pro-rata slice only** — honest hint, see F-FLOOR), `quoter()`, `paused()`, `quote_digest(q)`.

`__init__(owner, tracker, hub, asset, quoter, min_edge, desk_max_staleness, outflow_window, max_fill, max_net_spusd, min_eth_float, min_spusd_float, outflow_cap)`: zero-address asserts; **`assert asset == empty(bytes32)`** (USD-only v1, F6); `0 < min_edge ≤ MAX_MIN_EDGE`; `MIN_STALENESS ≤ desk_max_staleness ≤ MAX_STALENESS`; **`assert ITracker(TRACKER).HUB() == HUB and ITracker(TRACKER).ASSET() == ASSET`** (enforce the same-single-feed invariant on-chain — F6); `DOMAIN_SEPARATOR` cached once + `CACHED_CHAIN_ID`. **No** `pre_maturity_buffer` / `strike_proximity` / `roll_trigger` reads.

## 5. Economics at ~5 ETH (ETH ≈ $1,760 ⇒ ~$8,800)

Split the 5 ETH as **3 ETH inventory / directional budget** (`MAX_NET_SPUSD`, the 1×-short-ETH NAV-at-risk) + **2 ETH float/ops reserve** (`MIN_ETH_FLOAT`, buy-side payouts, gas). Off-chain signed quotes ⇒ **idle bleed ≈ $0** (no funding, no posting gas) — and unlike the N desk, idle inventory **earns positive carry** rather than bleeding.

**Carry — the line item the N desk does not have.** Every warehoused spUSD unit accrues the DAO's harvested premium into `eth_buffer`/NAV (`share_price` drifts up). Carry on `I` ETH of inventory at NAV-accretion APR `a` is `I · ETH_USD · a / 12`:

| spUSD inventory `I` | inventory $ | a = 2% APR | a = 5% APR | a = 10% APR |
|---|---|---|---|---|
| 1 ETH | $1,760 | $2.9/mo | $7.3/mo | $14.7/mo |
| 3 ETH (cap) | $5,280 | $8.8/mo | $22/mo | $44/mo |
| 5 ETH | $8,800 | $14.7/mo | $36.7/mo | $73/mo |

**Honest:** at Sepolia/bootstrap the harvest is thin, so `a` is realistically 2–5%. Carry is a *real, positive, structural* tailwind, but **small in absolute dollars** at 3–5 ETH. Its importance is **directional**: it makes breakeven volume strictly *lower* than the N desk's, because idle inventory earns instead of bleeds.

**Spread — identical shape, launches tighter.** Realized edge = `min_edge` each side; a matched round-trip captures `s = 2·min_edge`, a one-sided fill held captures `s/2`:

| spread s (min_edge each side) | cover $50/mo | cover $150/mo | cover $300/mo |
|---|---|---|---|
| 0.5% (0.25%) | $10k RT / $20k one-side | $30k / $60k | $60k / $120k |
| 1.0% (0.50%) | $5k RT / $10k one-side | $15k / $30k | $30k / $60k |
| 2.0% (1.00%) | $2.5k RT / $5k one-side | $7.5k / $15k | $15k / $30k |

spUSD's per-unit volatility is 1× vs N's ~2.5×, so adverse selection per fill is milder — but **do NOT launch below the within-window oracle-drift budget** (F-DRIFT): **launch at `s = 2%` (min_edge = 1%)** paired with a tight `DESK_MAX_STALENESS` and small `MAX_FILL`; tighten toward 1% only as two-sided flow appears. The "1× vol lets us quote tighter" argument is about counterparty adverse-selection, **not** oracle drift, and must not drive `min_edge` below it.

**Headline comparison at the 3-ETH cap (monthly):**

| Scenario | N desk (3 ETH N, ~2.5×) | spUSD desk (3 ETH spUSD, 1×) |
|---|---|---|
| Carry on full inventory | **≤ $0** (theta, ~$0 after floor) | **+$9 to +$22** (NAV accretion, a=2–5%) |
| Idle (zero flow) | ~$0 idle; bleeds if ETH drops (capped 3 ETH) | ~$0 idle **+ positive carry**; mild 1× ETH risk (capped) |
| $30k/mo round-trip @ launch spread | +$300 (s=2%) | +$150 (s=2%) **+ $9–22 carry** |
| Adverse ETH crash, inventory full | **−3 ETH** (lev decay to strike) | **−~1× move** (−20% ETH ≈ −0.6 ETH), no decay, no theta |

**Realization caveat (honest).** "Carry ≥ 0 / mildly positive at zero flow" is a **mark**, not guaranteed cash. Positive carry is *realized* only via (a) two-sided RFQ taker flow, (b) the `eth_buffer` slice of `redeem()` (oracle-free, but a small fraction of NAV — see F-FLOOR), or (c) selling P/spUSD into the pool near NAV. Winding down inventory when no takers buy and the pool is off-NAV forces crossing the spread / eating slippage that can exceed months of carry (F-EXIT). So keep `MAX_NET_SPUSD` **below 3 ETH** until two-sided flow is observed; the realizable floor is ~the `eth_buffer` pro-rata slice.

**Do NOT hedge at 5 ETH** — the ≤3 ETH 1×-short-ETH bet is already capped; a perp short's funding/gas/basis exceeds the benefit. Cap inventory instead.

**Honest verdict.** This is the structurally-profitable, peg-holding sibling that **offsets** the N desk's bleed — the offset is *structural* (right side of carry), not large in absolute dollars at 3–5 ETH. Net-positive at lower volume than the N desk (carry ≥ 0, idle ≈ $0), mildly positive even at zero flow, modestly positive at ~$5–15k/mo one-sided, a real earner only above ~$30k/mo round-trip. Milder tail (1× short-ETH, no leverage, no liquidation, no theta). **Sepolia testnet, research code, unaudited; the operator's own capped capital, not a yield product.**

## 6. Confirmed findings + fixes

Every confirmed finding, folded into the guardrails/risks above:

| # | Title | Sev | Fix (folded in) |
|---|---|---|---|
| F-DRIFT | F8 ported: a stale-but-fresh-passing `x` overpay on the BUY side is locked in; the oracle-free redeem floor does NOT recover it (e.g. x=1760 vs true 1850 ⇒ ~$46 loss on a $1000 fill, ~8× the 0.5% cushion) | **med** | **G4/G5 + calibration:** size `MIN_EDGE ≥` max plausible ETH drift over `DESK_MAX_STALENESS`. **Launch at ≥ 1% min_edge (not the 0.5% the economics tuning suggests)**, tight `DESK_MAX_STALENESS` (300–600 s mainnet), small `MAX_FILL`. Keep `_assert_fresh` verbatim (load-bearing). Treat the redeem floor strictly as exit-side defense-in-depth (it does NOT bound entry overpay). Phase-2 shared hardening: quoter signs `x_sign`, assert `|x_fill − x_sign| ≤ max_dev`; emit per-fill mark-to-true-x PnL. No redesign — calibration. |
| F-FLOOR-OVR | The "partial oracle-free buy-side floor" is overstated; "better-protected than the N desk" is **backwards** — `sell_p` rotates `eth_buffer` back into P, so the oracle-free slice is ~2–10% of NAV, while the N desk's `merge(P+N)→ETH` recovers ~100% of matched inventory oracle-free | **med** | Re-state honestly across docs/KEY DECISIONS: redeem recovers only the `eth_buffer` pro-rata slice (a steady-state minority, spiking only just after a harvest) with no oracle; the P slice still needs `x`. **Delete** "strictly better oracle protection than the N desk" / "structural buy-side safety." Note that for *matched* inventory the N desk is better oracle-protected on that axis. Load-bearing controls remain the directional NAV floor + tight `DESK_MAX_STALENESS`. |
| F-DOMAIN | EIP-712 `NAME_HASH` self-contradictory across the spec; an identical-to-N name is a latent cross-desk replay foot-gun if `self` is ever dropped from the domain | low | Resolve to **`NAME_HASH = keccak256("Gimbal Solo RFQ Stable Desk")`** (distinct name + distinct `verifyingContract` + distinct 7-field `QUOTE_TYPEHASH`). Recompute `DOMAIN_SEPARATOR` (must include `self`); never hardcode/copy the N desk's. Deploy/test harness asserts: (1) `DOMAIN_SEPARATOR != ` N-desk's; (2) an N-desk quote+sig reverts "bad sig" here; (3) off-chain digest of the 7-field Quote reproduces `quote_digest(q)` byte-for-byte before serving. |
| F-FLOOR | The oracle-free redeem floor is materially weaker than claimed: only the `eth_buffer` slice is oracle-free and it is frequently ~0 (the DAO's `sell_p` re-entry auction *drains* `eth_buffer` back into P ASAP) | low | Demote from "hardening control" to "opportunistic, usually ~0." **Do NOT wire `redeem_floor_eth` as a hard buy-price clamp** — it evaluates to ~0 in steady state and would brick all buys. Load-bearing buy controls stay the tight `DESK_MAX_STALENESS` gate + directional NAV floor. Keep `redeem_floor_eth(amount)` only as an honestly-labeled view ("oracle-free recoverable = `eth_buffer` pro-rata slice only — typically low-single-digit % of NAV, often ~0; the rest is P that still needs the oracle"). |
| F-ORPHAN | The proposed owner-only `deposit()`/`operator_mint_inventory` seed hatch silently re-imports the exact orphan-N short-theta bleed the desk exists to kill (`deposit()` hands back N at `TrackerDAO.vy:343`, untracked, uncapped) | low | **Omit any `deposit()`/`split()` path entirely** (owner-only or not). Delete `operator_mint_inventory`/`operator_deposit` from the design so all docs agree the desk is strictly inventory-based. Cold-start inventory comes ONLY from `fund_spusd()` (operator transfers pre-held spUSD). *If* ever deemed required: must (a) loudly document it as knowingly short-theta, (b) atomically transfer the handed-back N out in the same tx, (c) add an explicit `net_n` counter + separate N cap. Default: omit. |
| F6 | `share_price()`'s INTERNAL oracle read is gated by the hub's heartbeat, not the tight `DESK_MAX_STALENESS`; non-USD pegs use two feeds inside `_x()`, each gated only by its own (long) heartbeat — desk reports "fresh" on a 3-day-stale XAU print | low | **`__init__ assert asset == empty(bytes32)`** (USD-only v1). Add `__init__` assert `ITracker(TRACKER).HUB() == HUB and ITracker(TRACKER).ASSET() == ASSET` ("tracker oracle mismatch") — turns the silent "same single feed" assumption into a checked invariant at zero hot-path cost. Document that `_assert_fresh` only *transitively* covers `share_price()` because of single-feed USD. Phase-2: any two-feed desk must tightly gate BOTH feeds (the F6 fix owed on the N desk too). |
| F-PBAG | The P tokens `redeem()` hands back are an untracked, unmarked, potentially-stranding new inventory class — no cap, no floor, a settle/roll time bomb; "sell P into the spUSD/WETH pool" is wrong (that pool is spUSD/WETH, P has no pool) | low | Document honestly: `operator_redeem` returns mostly-illiquid P (whose only sinks are `merge`/`sell_p`/`redeem_p`/settlement), so the "recycle to keep buying" loop returns mostly P, not redeployable ETH. The realizable recovery is the `eth_buffer` slice + selling P/spUSD into the pool near NAV (with slippage) + `operator_redeem_p` after settlement. Keep `MAX_NET_SPUSD` small so the un-realizable bag stays small. Quoter gates P-into-pool disposal on `POOL_NAV_TOLERANCE_BPS`; default HOLD P when the pool is off-NAV. |
| F-EXIT | Winding down inventory after `share_price` has moved forces the desk to cross its own spread / eat pool slippage, so realized carry can be **negative** even though NAV "accrued" (3 ETH into a 5%-off pool ≈ −$260, wiping ~17 months of carry) | low | Replace unqualified "carry ≥ 0 / positive at zero flow" with the realization-caveat framing (§5): warehoused carry is a MARK; the realizable floor ≈ the oracle-free `eth_buffer` slice; the P slice's realization eats slippage. Keep `redeem_floor_eth` (eth_buffer slice only) as the conservative reference. **Set `MAX_NET_SPUSD` below 3 ETH until two-sided flow exists.** Quoter recycle signal gates P disposal on `POOL_NAV_TOLERANCE_BPS`; default HOLD off-NAV. |
| F-ROLL | Holding spUSD across a TrackerDAO ROLL means `redeem()` spans two vintages; the desk has zero roll awareness, so old-vintage P can strand | low | Document the roll/redeem interaction in NatSpec + runbook: `operator_redeem` during a roll (`pending_series() != 0`) returns P of BOTH vintages; the old one is wound down via `operator_redeem_p(series, amount)` (`assert settled()` → `redeem_p`, mirroring the N desk's `operator_redeem_n`) after it matures. In `operator_redeem`, read `pending_series()` and revert/flag with "roll open: recycle after RollFinalized" so the operator doesn't unknowingly accumulate a second vintage. Trading path stays vintage-free. |
| F-SHARED | Shared operator capital double-counts risk: the same 5 ETH backing BOTH desks is netted only off-chain, so each desk's caps are blind to the other; combined drawdown can exceed the reserve (per-desk "5 ETH = 3+2" tables imply 10 ETH if applied to both) | low | Add a cross-desk allocation note to §7/runbook: when one operator runs both legs on shared capital, Σ(funded ETH + spUSD-ETH-value) must equal the total reserve; **allocate** the per-desk tables (e.g. 3 ETH to one leg + 2 to the other, or halved profiles), don't apply full size to both. Set each desk's `max_net_spusd`/`min_eth_float`/`outflow_cap` to fractions of its OWN funded balance. Document honestly: the two legs are a **partial, non-delta-matched offset** (N ~2.5× long-ETH + theta; spUSD ~1× short-ETH, no decay), **not a hedge** — on an ETH rise the spUSD desk takes a real uncovered loss. Keep blast-radius isolation (separate funds/caps/pause/quoter). |

## 7. How it plugs in

### Sibling contract, NOT a `PeripheryFactory` blueprint, NOT an extension of the N desk

`StableQuoteFiller.vy` is a **separate sibling**; the deployed N desk stays untouched (immutable, live-config'd, different fair-value math / risk axis / inventory primitive — folding both into one contract doubles the state machine and attack surface for zero benefit). It reuses the N desk's safety skeleton verbatim with the distinct `NAME_HASH` (F-DOMAIN).

It is **standalone-deployed** (`script/deploy-rfq-desk-stable.sh` — `forge create` + Blockscout verify), **not** a `PeripheryFactory` helper: the factory only deploys stateless, fund-less, admin-less helpers keyed by `(tracker, fee)`; this desk **custodies the operator's ETH + spUSD inventory and has an owner**, so it cannot be a factory helper (same reasoning `deployments.md` records for the N desk). One desk per operator-per-peg. Drops the N-only ctor params (`pre_maturity_buffer`, `strike_proximity`).

### Best-ex router: the spUSD leg gains a THIRD venue

Today spUSD trades via the spUSD/WETH Uniswap pool + `deposit`/`redeem`. This desk slots into `solo-rfq-routing-spec.md` as the **phase-2 spUSD RFQ source** — the router builds one canonical `quote(side, size) → {effectiveOut, venue}` per venue and picks the best:

| Trade | RFQ desk | Pool | Mint/Redeem | Router behavior |
|---|---|---|---|---|
| **Buy spUSD** | desk SELLS (`fill_buy_spusd`) | WETH→spUSD swap (0.3%) | `deposit()` — **also yields unwanted N** | best effective spUSD/ETH; RFQ capped/down → pool. Surface `deposit` only on explicit "also receive N (leverage)" opt-in, else compare RFQ vs pool only |
| **Sell spUSD** | desk BUYS (`fill_sell_spusd`) | spUSD→WETH swap | `redeem()` oracle-free pro-rata (P + `eth_buffer` ETH) | best effective ETH/spUSD; **`redeem` = hard always-available floor** (no oracle, no counterparty, no pause) |

**Key asymmetry vs the N leg:** sell-spUSD ALWAYS has a protocol fallback (`redeem`), so the router never shows "sell unavailable" — unlike sell-N. Present `redeem` honestly as "instant oracle-free, pro-rata P + ETH" (not pure ETH; user must then dispose of the P). On `inventory-empty`/`inventory-full` the router falls back to pool/mint/redeem. Phase-2: an on-chain best-ex router taking a signed quote + pool route + redeem atomically with one `minOut`.

### Hold-tab frontend (same operator-quoted trust pattern)

Reuses `solo-rfq-frontend-handoff.md` machinery verbatim (frontend does NOT sign; the quoter signs; submit `v,r,s` on-chain). New fills `fill_buy_spusd{value}` (`msg.value == floor(amount*price/1e18)`) and `fill_sell_spusd` (`approve(desk, amount)` first). Views: `fair_price()`, `net_spusd()`, `quoter()`, `paused()`, `quote_digest(q)`, `redeem_floor_eth(amount)` (honestly labeled, F-FLOOR). **Trust labeling (REQUIRED, identical wording):** "Operator-quoted desk. Your counterparty is `0x…` (the operator), not the Gimbal protocol. Quotes are signed off-chain and filled at a price floored on-chain." Cross-check `quoter()` vs `operatorDesks.json`; unlisted desk → unverified-peg gate. When RFQ/pool are poor, show "Instant oracle-free redeem (pro-rata P + ETH)" as the guaranteed exit. Never style it as a trustless primitive.

### `operatorDesks.json` — a `leg` discriminator, 2 entries per peg

```json
[
  { "tracker":"0x80A2…4FAE", "leg":"N",     "desk":"0x48c9…",        "operator":"0x…",
    "quoterPubkey":"0x…", "quoterUrl":"https://…/n",      "assetSymbol":"spUSD", "label":"spUSD leverage desk", "sinceBlock":1234 },
  { "tracker":"0x80A2…4FAE", "leg":"spUSD", "desk":"0x<StableDesk>", "operator":"0x…",
    "quoterPubkey":"0x…", "quoterUrl":"https://…/stable", "assetSymbol":"spUSD", "label":"spUSD stable desk",   "sinceBlock":5678 }
]
```
`leg` (new, required) ∈ `{"N","spUSD"}`; old single-leg entries default `"N"`. Frontend keys desks by `(tracker, leg)` — Leverage tab reads `leg:"N"`, Hold tab reads `leg:"spUSD"`, each listable independently. **Separate quoter keys per leg recommended** (blast-radius isolation).

### Coexistence with the N desk — separate capital, shared operator

Separate contracts, separate funds, separate caps/pause/quoter; neither references the other (no on-chain coupling). The same operator may fund both from one wallet, but the ETH/inventory inside each is segregated — a drain or pause of one does not touch the other. Economic complementarity: the N desk is negative-carry (warehouses the decaying N), this desk is positive-carry (warehouses the premium-collecting spUSD). The operator nets them **off-chain** via capital allocation (F-SHARED): the per-desk sizing tables must be ALLOCATED across the shared reserve, not applied at full size to both, and the legs are a partial offset, **not a hedge**.

## 8. Components to build — v1 checklist vs phase 2

**v1 (minimal launchable): inventory-based spUSD desk (USD-feed), single quoter, tiny caps.**

1. `StableQuoteFiller.vy` — `fill_buy_spusd` + `fill_sell_spusd`; EIP-712 verify (G1) + single quoter; replay/deadline/taker (G2); **tight `DESK_MAX_STALENESS`** (G4); directional NAV floor + truncation-corner assert (G5, **no G3 vintage block, no near-strike band**); `MAX_FILL` + `MAX_NET_SPUSD` (NAV-at-risk, buy-side) + `MIN_SPUSD_FLOAT` (sell-side inventory rule = **no mint-to-sell**) + `MIN_ETH_FLOAT` + per-window outflow cap (G6); `net_spusd` single unsigned counter; `@nonreentrant` + undecorated payable `__default__`. **No `deposit()`/`split()` path anywhere** (F-ORPHAN).
2. Owner-only `fund` / `fund_spusd` / `withdraw_eth` / `withdraw_token` / `set_paused` / `set_quoter` / `set_caps`, 2-step ownership, + `operator_redeem(shares)` (oracle-free wind-down, roll-aware per F-ROLL) and `operator_redeem_p(series, amount)` passthroughs.
3. `__init__(owner, tracker, hub, asset, quoter, min_edge, desk_max_staleness, outflow_window, max_fill, max_net_spusd, min_eth_float, min_spusd_float, outflow_cap)`: zero-address asserts, `DOMAIN_SEPARATOR` once (distinct `NAME_HASH`, F-DOMAIN), **`assert asset == empty(bytes32)`** + **tracker oracle-wiring asserts** (F6), EIP-5202 blueprint.
4. `script/deploy-rfq-desk-stable.sh` (standalone) + `operatorDesks.json` `leg` field; the deploy/test harness EIP-712 separation assertions (F-DOMAIN).
5. Off-chain **quoter service** — `POST /quote`, `GET /healthz`; fair = `share_price() ÷ x`; depletion-axis skew; `inventory-empty` (sell side at/below `SELL_RESERVE`), `inventory-full` (buy side at cap); recycle signal via `/healthz`. Single instance, hot key in secrets, graceful "no quotes ⇒ pause."
6. Hold-tab RFQ flow + "operator-quoted desk, counterparty 0x…" label + warning gate for unlisted desks; honest `redeem` fallback display.
7. "Sepolia testnet, research code, unaudited" tag everywhere.
8. Adversarial review targeting: the EIP-712 verify + **domain separation from the N desk** (F-DOMAIN), the NAV floor math, the staleness gate (G4) + the `share_price` single-feed transitivity (F6), the **inventory rule / no-mint-to-sell** (F-ORPHAN), the caps/outflow accounting, the within-window oracle-drift overpay (F-DRIFT), and the key-compromise bound.

**Quoter service params (capped-beta defaults, operator-tunable):** `MIN_EDGE_BPS` **100 (1%) at launch** (≥ the within-window drift budget — F-DRIFT) → floor 50 with flow; `BASE_SPREAD_BPS` 50–100 (invariant `base ≥ min_edge`); `SKEW_K` 1–3; `MAX_FILL_SPUSD` small (~50e18) cold; `MAX_INVENTORY_SPUSD` denominated in ETH-NAV-at-risk (< 3 ETH cold, F-EXIT); `TARGET_INVENTORY_SPUSD`, `SELL_RESERVE_SPUSD`, `RECYCLE_HIGH_WATER`, `POOL_NAV_TOLERANCE_BPS` (gate P-into-pool disposal); `TTL_SECONDS` ~45 (~1 block); `DESK_MAX_STALENESS` 300–600 s (mainnet). `FILLER_ADDRESS` = the StableQuoteFiller sibling (NOT `0x48c9…`); `TRACKER_ADDRESS` unchanged. Drop `PRE_MATURITY_BUFFER_SECONDS`. Quote **wide**, cap **small**, widen only on observed two-sided flow.

```
fair = share_price() * 1e18 / x
inv = spUSD.balanceOf(desk); sellable = max(0, inv - SELL_RESERVE); depl = 1e18 - clamp(sellable*1e18/TARGET, 0, 1e18)
DESK_SELLS (side=1): if inv <= SELL_RESERVE -> 409 inventory-empty (NO mint-to-sell)
                     markupBps = clamp(BASE + SKEW_K*BASE*depl/1e18, 0, 5000); price = fair*(1e18 + markupBps*1e14)/1e18
DESK_BUYS  (side=0): if inv >= MAX_INVENTORY -> 409 inventory-full
                     discountBps = clamp(BASE + SKEW_K*BASE*(1e18-depl)/1e18, 0, 5000); price = fair*(1e18 - discountBps*1e14)/1e18
```
The service **only quotes** — it never moves the operator's principal (an owner action); recycling (`operator_redeem`) is owner-executed, the quoter only flags it.

**Phase 2 (widen with flow):** `x_sign` deviation check + per-fill mark-to-true-x PnL (F-DRIFT, shared with the N desk); on-chain best-ex router (signed quote + pool + redeem, atomic, one `minOut`); order splitting (fill desk to cap, remainder to pool/redeem); rotatable multi-key quoter set; non-USD / two-feed spUSD-family desks **only after** both feeds are tightly gated (F6); on-chain `OperatorDeskRegistry` enumerating both legs. Widen caps toward ~5 ETH as confidence builds.

## 9. Honest risks + bottom line

- **Mild 1× short-ETH directional risk** on net-long spUSD — an ETH *rise* erodes the desk's own ETH-denominated value. Bounded by `MAX_NET_SPUSD` (< 3 ETH until flow), **no leverage, no liquidation, no theta, no decay-to-zero** — strictly milder than the N desk's tail. **Not a yield product.**
- **Carry is a MARK, not guaranteed cash** (F-EXIT/F-FLOOR): positive carry realizes only via two-sided flow, the small oracle-free `eth_buffer` redeem slice, or selling near NAV. Winding down off-NAV eats slippage that can exceed months of carry. Size small.
- **The redeem floor is opportunistic, often ~0** (F-FLOOR/F-FLOOR-OVR): `sell_p` rotates `eth_buffer` back into P, so the oracle-free recoverable fraction is typically low-single-digit %; the P slice still needs the oracle. It is exit-side defense-in-depth, **not** an entry-side clamp, and **not** "better than the N desk" — for matched inventory the N desk's `merge` is better protected.
- **Within-window oracle drift locks in BUY-side overpay** (F-DRIFT): the load-bearing controls are the tight `DESK_MAX_STALENESS` gate + a `min_edge ≥` the drift budget (launch ≥ 1%, not 0.5%); the redeem floor does not recover it.
- **Stale `share_price` path** (F6): `share_price()` reads the oracle internally under the hub heartbeat; v1's USD-only assert + the tracker oracle-wiring asserts make `_assert_fresh` transitively cover it. Any non-USD desk reintroduces two-feed skew and is blocked until both feeds are tightly gated.
- **Stranded P from recycling** (F-PBAG/F-ROLL): `redeem()` returns mostly-illiquid P (up to two vintages during a roll); recovery is the `eth_buffer` slice + pool sells near NAV + `operator_redeem_p` after settlement. Keep inventory small.
- **Stolen quoter key:** capped by the directional NAV floor + `MAX_FILL` + per-window outflow cap + `MIN_ETH_FLOAT`/`MIN_SPUSD_FLOAT` + balance, with `set_paused`/`set_quoter` as instant kill switches. Residual is bounded griefing-of-liquidity, on expendable capital, never theft of retail funds.
- **Shared-capital correlation** (F-SHARED): if one operator runs both legs, allocate the shared reserve across desks (don't apply full per-desk sizing to both); the two legs are a partial offset, **not a hedge**.
- **Counterparty clarity:** the UI must never let a user think the desk is the protocol — the operator-not-protocol label + warning gate are mandatory.
- **Profitability needs flow:** zero volume ⇒ ~$0 idle + a small positive carry mark, not a bleed — but no spread margin either. It is a bet on volume, with carry as a structural tailwind.

**Bottom line.** The Stable RFQ Desk is the **positive-carry sibling** the N desk's bleed asked for: it warehouses the premium-collecting spUSD leg (idle inventory *accrues* NAV instead of decaying), runs ~1× short-ETH with no leverage / no liquidation / no theta, reuses the N desk's entire signed-quote + on-chain-floor safety skeleton, and dodges the one trap (mint-to-sell, which would re-import orphan N) by being strictly **inventory-based** — selling only spUSD it previously bought and going one-sided when dry. The offset to the N desk is **structural** (right side of carry), modest in absolute dollars at 3–5 ETH, net-positive at lower volume than the N desk, and a real earner only with sustained two-sided flow. It slots in as a third RFQ source for the spUSD leg, where — unlike sell-N — `redeem` guarantees a fallback. **Sepolia testnet, research code, unaudited; the operator's own capped capital, not a yield product.**
