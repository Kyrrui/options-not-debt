# Solo RFQ Desk — frontend integration handoff (for the dapp builder)

> **⤳ Architecture note:** the end-state is the crowd-owned **immutable autonomous vault** (Earn-only funding, **no quoter service**, buy-from-vault on-chain) — see [`autonomous-vault-spec.md`](autonomous-vault-spec.md). Per its GO/NO-GO the operated desks below remain the **interim** venue (prove demand + harden settlement on pausable contracts first), so this handoff **stands for now**.

> Self-contained handoff to wire the **operator-quoted RFQ desk** (`SignedQuoteFiller`)
> into the Gimbal frontend. This is the first and only venue where a user can **sell
> the N (leverage) leg**, plus a quote-driven way to buy it. Full design:
> `docs/handoffs/solo-rfq-spec.md`. Contract: `src/periphery/SignedQuoteFiller.vy`. Integration
> shapes (canonical): `test/SignedQuoteFiller.fork.t.sol`.

## Status & what you can build now

The contract is **built, adversarially reviewed (6 low findings, all fixed), and
fork-tested 10/10 on live Sepolia** — but **not yet deployed**. Two builds are needed
for go-live, and **both are yours**:
1. **This frontend integration** — the quote-request flow + the two fill txns + trust labeling.
2. **The quoter service** — the backend this frontend POSTs to (prices off the oracle +
   inventory, signs EIP-712 quotes). Separate, self-contained spec:
   **`docs/handoffs/solo-rfq-quoter-spec.md`**. Build it alongside the UI; the API contract below
   is exactly what it exposes.

**Operator provides (config, not code):**
- the deployed `SignedQuoteFiller` address, per peg → frontend config `desk`;
- the quoter signing key (set on-chain as the desk's `quoter()`), which the quoter service holds;
- the `operatorDesks.json` entry (discovery, below).

Build the UI + service against the ABI/spec now; the operator wires the live address + key
and deploys. Until a desk is listed, gate the new surfaces behind "no desk is quoting this leg yet."

## What's new for the frontend

1. A **real sell-N path** (today selling N is impossible — see "false copy" below).
2. A **quote-request flow**: ask the operator's quoter for a signed price, then submit it on-chain. The frontend does **not** sign; the **quoter** signs.
3. **Trust labeling**: the desk is an **operator** counterparty, not the protocol.

## Contract interface

**Quote** (ABI tuple — field order is load-bearing):

```
(uint8 side, address taker, address series, uint256 amount,
 uint256 price, uint256 min_edge, uint256 nonce, uint256 deadline)
```

| field | meaning |
|---|---|
| `side` | `0` = BUY_N (desk buys N == **taker sells N** → call `fill_sell_n`); `1` = SELL_N (desk sells N == **taker buys N** → call `fill_buy_n`). Set by the quoter. |
| `taker` | `0x0` = anyone may fill; else only that address. Set by the quoter. |
| `series` | the exact `OptionSeries` vintage the quote is priced for. Set by the quoter (roll-safe). Pass through; do not derive. |
| `amount` | N units, 1e18-scaled. |
| `price` | ETH wei per 1e18 units of N. |
| `min_edge` | 1e18-scaled edge the desk takes; quoter sets it ≥ the desk's on-chain `MIN_EDGE`. |
| `nonce` | single-use; quoter sets. |
| `deadline` | unix seconds; fill must land at/before. |

**Functions you call:**
- `fill_buy_n(Quote q, uint8 v, bytes32 r, bytes32 s) payable returns (uint256 nOut)` — **taker buys N**. `msg.value` **MUST equal `floor(amount * price / 1e18)` exactly** (no change is returned). Use bigint math.
- `fill_sell_n(Quote q, uint8 v, bytes32 r, bytes32 s) returns (uint256 ethOut)` — **taker sells N**. The taker must first `approve(desk, amount)` on the **N token**.

**Views for the UI:**
- `intrinsic_n(address series) -> uint256` — live N fair value (ETH wei per 1e18 units), `0` at/below strike. Show the user the quote's price vs this (the desk's edge).
- `net_n(address series) -> int256` — desk's net N position (depth/inventory hint).
- `quoter() -> address` — approved signer; display "quotes signed by 0x… ✓".
- `paused() -> bool` — desk-down flag.
- `quote_digest(Quote q) -> bytes32` — the EIP-712 digest (optional: verify the quoter sig client-side before submitting).

**Per-series token addresses:** `ISeries(series).N()` (the token the taker approves for sell-N) and `.P()`.

## The quote-request flow (frontend ↔ quoter)

1. User picks **side + size**.
2. `POST {quoterUrl}/quote` — body:
   ```json
   { "side": 1, "tracker": "0x80A2…4FAE", "n_amount": "10000000000000000", "taker": "0xUser…" }
   ```
   (`taker` optional; uint as **decimal strings** to avoid JS precision loss. You may omit `series` and let the quoter set the roll-safe target.)
3. Quoter responds with the **signed quote**:
   ```json
   { "quote": { "side":1, "taker":"0x0…0", "series":"0x…", "amount":"…",
                "price":"…", "min_edge":"20000000000000000", "nonce":"…", "deadline":"…" },
     "v": 27, "r": "0x…", "s": "0x…" }
   ```
4. Show the user: price, implied edge vs `intrinsic_n(series)`, expiry (`deadline`), and for buy-N the exact ETH cost = `floor(amount*price/1e18)`.
5. On confirm:
   - **Buy N:** `fill_buy_n{value: floor(amount*price/1e18)}(quote, v, r, s)`.
   - **Sell N:** if needed, `nToken.approve(desk, amount)`, then `fill_sell_n(quote, v, r, s)`.

## Revert handling

A failed fill never risks user funds (the desk custodies none) — the user just re-quotes.
- **Re-quote (transient):** `expired`, `nonce used`, `below floor`/`above floor`, `stale series` (a roll happened), `size`, `insufficient eth`/inventory, `nav cap`, `outflow cap`. Auto-offer a fresh quote.
- **Desk down (don't auto-retry):** `paused`, `desk-stale` (oracle), `bad sig`. Show a "desk unavailable" state.

## Trust + labeling — REQUIRED (honesty-critical)

Every RFQ surface MUST display, prominently:

> **Operator-quoted desk.** Your counterparty is `0x…` (the operator), **not** the Gimbal
> protocol. Quotes are signed off-chain and filled at a price floored on-chain.

Show the quoter pubkey ("quotes signed by 0x… ✓", cross-checked against `operatorDesks.json` and the on-chain `quoter()`). An **unlisted** desk gets the unverified-peg treatment (muted, show-more, modal ack naming the operator). **Never** style the desk like a trustless protocol primitive.

## Fix the false copy + gate sell-N

The current Leverage/Provide copy implies N is sellable today (e.g. "keep it… or sell it to leverage buyers… routes through the same pool"). **That is false** — there is no N pool, and `LeverageRouter` only goes ETH→N. The RFQ desk is what makes sell-N real. Until a desk is **listed** for a peg, **disable** the sell-N affordance with honest copy ("no desk is quoting this leg yet").

## Discovery

v1: a curated `operatorDesks.json` in `@gimbal/protocol` (mirrors `certifiedPegs.json`). Each
entry carries a **`leg`** discriminator (`"N"` | `"spUSD"`) — there are now two desks per peg
(the N/leverage desk and the spUSD/stable desk, `StableQuoteFiller`):
```json
[ { "tracker":"0x…", "leg":"N",     "desk":"0x…", "operator":"0x…", "quoterPubkey":"0x…",
    "quoterUrl":"https://…/n",      "assetSymbol":"spUSD", "label":"spUSD leverage desk", "sinceBlock":1234 },
  { "tracker":"0x…", "leg":"spUSD", "desk":"0x…", "operator":"0x…", "quoterPubkey":"0x…",
    "quoterUrl":"https://…/stable", "assetSymbol":"spUSD", "label":"spUSD stable desk",   "sinceBlock":5678 } ]
```
Key desks by `(tracker, leg)`: the Leverage tab reads `leg:"N"`, the Hold tab reads `leg:"spUSD"`.
Surface only listed desks by default. (On-chain `OperatorDeskRegistry` enumeration is phase 2 — don't build against it yet.) **The spUSD/Hold desk's full integration is `docs/handoffs/stable-rfq-spec.md` §7** (same trust labeling + signed-quote flow; new fills `fill_buy_spusd`/`fill_sell_spusd`).

## Coexistence with the AMM pool

The spUSD/WETH Uniswap pool stays the **P/stable** venue (the Hold tab + the
`LeverageRouter`/`FlashLeverageRouter` P-sink). The RFQ desk is the **N/leverage** venue.
They complement each other — do **not** build an N-side pool.

**Best-execution routing** (make the desk site-wide, falling back to Uniswap on price/size):
see `docs/handoffs/solo-rfq-routing-spec.md`. Key asymmetry: routing/fallback applies to **buy-N**
only — **sell-N is RFQ-exclusive** (no N pool exists to fall back to).

## Pointers

- Design/rationale: `docs/handoffs/solo-rfq-spec.md`
- Contract source: `src/periphery/SignedQuoteFiller.vy`
- Canonical call shapes (Quote struct, EIP-712 digest, both flows, all guardrails): `test/SignedQuoteFiller.fork.t.sol`
- Master frontend handoff: `docs/handoffs/gimbal-frontend-handoff.md`

**Note:** everything here is Sepolia testnet, research code, unaudited — keep that framing in the UI.
