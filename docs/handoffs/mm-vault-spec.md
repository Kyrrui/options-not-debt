# Gimbal MM Vault — crowdsourced market-making for the legs (design sketch)

> Exploration/design doc, not a build order. Goal: a crowdsourced vault that is
> the RFQ counterparty for Gimbal's legs (N primarily, spUSD optionally).
> Depositors pool ETH; the vault quotes/fills user trades against its inventory;
> depositors share the desk's P&L. Resolves three threads at once:
>
> - **capital** — liquidity comes from the crowd, not the operator;
> - **Earn / yield** — depositors earn the desk's spread (a real, sourced upside);
> - **clear N** — the vault is the thing that buys *and* sells N.
>
> This is the Hyperliquid-HLP / GMX-GLP pattern, specialized to the P/N primitive.
> It is a **trading fund**: depositors share losses too. Honest framing is core.

## ⚠ VERDICT (post adversarial review): do NOT build this as a retail "Earn" product

Review: **29 findings, 23 confirmed.** They cluster into three problems:

1. **The price band is the wrong control (fixable).** A symmetric ±X% band (§4.1)
   caps the worst single fill but *licenses a continuous within-band drain* — the
   quoter rounds every fill toward the counterparty, and quoter+trader round-trips
   bleed depositors invisibly (every fill stays "compliant"). Fix: a **directional,
   vault-favorable edge FLOOR** — the vault buys N at ≤ intrinsic·(1−min_edge) and
   sells at ≥ intrinsic·(1+min_edge), i.e. it always *takes* spread, exactly like
   the DAO's `sell_p`/`fill_roll` MAX_EDGE auctions. Not a tolerance around fair.
2. **Deposit/withdraw oracle + JIT arb (fixable but hard).** NAV reads the live
   oracle, so deposit-before/withdraw-after an oracle tick or a known signed fill
   sandwiches the vault. Needs HLP-style protection: deposit/withdraw delays or
   epochs, TWAP/conservative marks, withdrawal friction > the largest single-block
   NAV step. Real engineering, known patterns.
3. **THE KILLER (structural, not fixable by plumbing):** the vault is net-long the
   **decaying** N leg → it is **short theta** → it *pays* carry. For a stable-skewed
   product it structurally accumulates N, so "Earn" would be **paying the crowd to
   hold a theta-bleeding leveraged-ETH bet.** And it's precisely the *"relocate the
   orphan into an unwilling warehouse"* pattern the clear-N research already
   disproved (`clear-n-findings.md`, C1: *never* the DAO/a vault) — now with retail
   as the bagholder. Crowdsourcing the *losing* side is worse than honest.

**The reframe the review points at:** you'd be pooling the **wrong side.** The N
side decays (pays theta); the **P / dollar side COLLECTS** that premium (it's the
option *seller*). So the only structurally-positive-carry thing to crowd-fund is
the **stable/premium-collecting side** — i.e. holding spUSD, or a staked-spUSD
wrapper that routes the premium (the "upside to holding stable," source B). The
DAO already holds the P. Don't build an N warehouse.

**So:** the MM vault confirms the clear-N conclusion rather than escaping it. The
real liquidity answer stays — **recruit a pro MM** (who takes the N risk knowingly,
hedged, for profit) and/or **bootstrap genuine leverage demand.** The sketch below
is retained for the record; do not ship it as a retail vault.

---

## 1. What it is

An ERC-4626-style vault:
- **Deposit ETH → vault shares** at NAV. **Withdraw shares → ETH** at NAV.
- Vault NAV = its holdings (ETH + spUSD + N + any P), marked to fair value.
- Depositor P&L = change in NAV/share = the desk's spread income minus carry and
  losses.
- This *is* the active "Earn" product (vs the passive AMM-LP "Earn" you already
  have — they can coexist as "Earn · LP" and "Earn · MM vault").

## 2. How it trades (the legs)

The vault is the counterparty for:
- **Buy N** (leverage buyer): pays ETH → vault delivers N (from inventory, or
  mints via `split` and keeps the P).
- **Sell N** (provider/holder shedding the leg — *the thing that's impossible
  today*): delivers N → vault pays ETH. **This is what makes "sell the leverage
  leg" real.**
- **(optional) Buy/sell spUSD** (be the Hold venue too): vs ETH at NAV ± spread.

Inventory recycling: when the vault holds matching P + N it `merge`s → ETH
(oracle-free), recovering capital. Leftover N it can hold to maturity (`redeem_n`)
or hedge (§6). Net inventory it carries = the **imbalance** between the two sides.

## 3. Pricing: signed RFQ, bounded on-chain

Two layers, both required:

- **Off-chain quoter** (the MM brain): reads NAV + oracle + inventory, computes a
  price = fair ± spread ± inventory-skew, signs it (EIP-712). Tight, smart pricing.
- **On-chain guardrails** (the depositor protection): the vault's `fill` verifies
  the quoter's signature **and** independently bounds the trade, so a bad/
  compromised/colluding quoter *cannot* loot the vault. The signature gets you a
  tight price; the guardrails cap the worst case.

(You can also run a no-signer fallback: the vault quotes purely on-chain off
oracle/NAV ± spread. Simpler trust, but oracle-on-hot-path + deterministic =
gameable. Keep it only as a backstop.)

## 4. The guardrails (the safety core — this is what makes it depositable)

Every fill must pass, regardless of what the quoter signed:
1. **NAV/intrinsic price band.** Fill price within ±X% of on-chain fair value
   (spUSD: `share_price`; N: `max(0, 1 − STRIKE/x)` from the oracle). The quoter
   can't fill outside the band → can't drain via a crazy price.
2. **Merge-floor invariant.** `price(P-side) + price(N-side) ≥ 1 ETH` per unit,
   always — or the vault is drainable via `split`/`merge` (the lesson from the
   bonding-curve review).
3. **Inventory cap, denominated in NAV-at-risk.** Cap the vault's net-N exposure
   by its loss under an adverse ETH move *to the strike* (not raw units — the
   other bonding-curve-review lesson). At the cap, the vault quotes sells only
   (stops accumulating directional risk).
4. **Oracle freshness + per-block outflow cap.** Fair-value reads must be fresh;
   bound ETH/inventory out per block → a single stale/manipulated print can't
   drain it.
5. **Deposit/withdraw fairness.** NAV must be marked honestly so nobody can
   deposit-before / withdraw-after a known profitable fill. Mark N
   **conservatively at intrinsic** (slightly under true value), add a small
   withdrawal delay or fee, and/or socialize fills over the block.

## 5. NAV marking (the subtle part)

NAV needs a value for the N (and P) inventory. Mark at **oracle intrinsic**
(`max(0,1−S/x)` ETH per N) — conservative (ignores time value, so the vault
slightly *under*-marks its N, which protects withdrawers from over-drawing).
Accept that this puts the oracle on the read-only NAV path (bounded, not a drain
vector). spUSD marked at `share_price`; ETH at face.

## 6. Hedging (phase 2)

The vault is structurally **net-long N = long leveraged ETH + short theta** (it
buys more N than it sells, given stable-skew). Two options:
- **v1: unhedged.** Simplest. But depositors are then *long leveraged ETH* on top
  of spread income — a crash hurts. Bound it with the NAV-at-risk cap (§4.3) and
  **disclose it loudly** ("this vault is net-long ETH via N; it can lose in a
  downturn").
- **v2: hedged.** The vault shorts ETH (on-chain perp) against its N delta →
  delta-neutral, earning spread + gamma, paying theta. Removes the directional
  bet but adds a perp integration (more surface/risk). The professional version.

## 7. How it plugs into what exists

- Uses the primitives directly: `TrackerDAO.deposit` (mint spUSD+N), `split`/
  `merge` (source/sink legs), `redeem_n` (expire N), the spUSD pool as a fallback
  sink.
- The **RFQ filler** is the `SignedQuoteRouter` we discussed; the vault is the
  inventory it fills against.
- Frontend: "Earn" → deposit into the vault; Leverage/Hold tabs → request quote →
  fill against the vault. Trust layer: approved-quoter set curated like the
  certified-pegs list (or open, since guardrails bound it).

## 8. Phasing

- **v1:** vault (deposit/withdraw at NAV) + bounded RFQ fill (signed quote + §4
  guardrails) + operator-run quoter + conservative caps/bands, **unhedged**,
  launched only once there's some real flow. Framed as a trading fund.
- **v2:** delta-neutral hedging, permissionless/competing quoters, tighter bands.

## 9. Honest risks (the things to attack)

- **Adverse selection at cold start.** With no organic flow, the only
  counterparties are arbers picking off the vault → depositors bleed. Don't launch
  the vault before there's two-sided flow; quote wide early.
- **Directional risk (v1 unhedged):** net-long-N = leveraged ETH → real loss in a
  crash. The cap bounds it; hedging (v2) removes it.
- **Quoter trust:** even band-bounded, the quoter sets price *within* the band →
  can skim or favor; collusion possible. Mitigate: tight bands, transparency,
  competing quoters, on-chain caps.
- **NAV-mark arb:** mis-marking N lets depositors arb the share price. Conservative
  marks + withdrawal friction.
- **Profitability needs flow.** Zero volume = zero yield (and carry/adverse-
  selection bleed). It's a bet on volume, not guaranteed yield.
- **Surface + optics:** vault + filler + guardrails (+ perp) = significant audited
  code; a public pooled trading fund has fund/securities optics.

## 10. Components to build

1. `MMVault.vy` — ERC-4626-ish: deposit/withdraw ETH↔shares at NAV; NAV from
   marked holdings; holds ETH/spUSD/N/P.
2. `SignedQuoteFiller` — verify EIP-712 quote + the §4 guardrails + execute against
   vault inventory (split/merge/transfer). Holds no funds of its own.
3. Off-chain **quoter** service (price + sign + inventory mgmt; merges P+N to
   recycle; optional hedge).
4. Guardrail params: NAV band %, NAV-at-risk cap, per-block cap, withdrawal
   friction.
5. Frontend: Earn→vault deposit; trade tabs→RFQ fill; quoter trust list.

## Bottom line

A crowdsourced MM vault makes the liquidity *not yours*, gives "Earn" a real
sourced yield (the spread), and is the venue that finally clears N — but it's a
**trading fund** that can lose, needs an operator/quoter + heavy guardrails +
audits, and only pays once there's flow. The guardrails (§4) are what make it
safe to deposit into; the honesty (§9) is what keeps it on-brand.
