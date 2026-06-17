# GimbalSimpleVault — frontend integration handoff (for the dapp builder)

> Self-contained handoff to wire the **immutable, ownerless crowd-house** (`GimbalSimpleVault`) into
> the Gimbal frontend. This is the **Earn** product (LPs fund the house and earn its trading P&L) **and**
> a new on-chain venue to **buy N (leverage)**. The big simplification vs the old RFQ desks: **there is
> NO quoter service, NO off-chain signing, NO RFQ API, NO operator.** Everything is plain `view` + `payable`
> contract calls. Prices are computed on-chain.
>
> Contract: [`src/periphery/GimbalSimpleVault.vy`](../../src/periphery/GimbalSimpleVault.vy).
> Canonical call shapes (every function, exercised): [`test/GimbalSimpleVault.fork.t.sol`](../../test/GimbalSimpleVault.fork.t.sol).
> Design + the MAINNET CHECKLIST: [`simple-vault-sepolia-spec.md`](simple-vault-sepolia-spec.md).
> Master FE handoff: `docs/handoffs/gimbal-frontend-handoff.md`.

## Status & addresses (Sepolia, chain id 11155111)

**LIVE + Blockscout-verified, currently UNFUNDED** (`totalSupply`=0, `nav`=0). Go-live needs no admin
step — the first `deposit()` funds it. Build against the ABI now.

| What | Address |
|---|---|
| **GimbalSimpleVault** (the house) | `0x25cDc829B67A4746Cf05517d53739017bd6BEe34` |
| spUSD TrackerDAO (current-series source) | `0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE` |
| OracleHub | `0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62` |

It is **immutable**: no owner, no admin, no pause, no upgrade, no `withdraw`. Every cap/param is a public
immutable getter — **read them on-chain, don't hardcode** (`BASE_EDGE`, `MAX_FILL`, `MAX_WRITTEN`,
`TOTAL_DEPOSIT_CAP`, `STRIKE_PROXIMITY`, `PRE_MATURITY_BUFFER`, `DESK_MAX_STALENESS`, …).

## Nav placement — this is the LONG side of Leverage (a short is also leverage)

Three-role nav `Hold · Leverage · Earn`. **Leverage is a Long ⇄ Short toggle, one tab — there is no
separate "Short" nav item** (a short is just leveraged in the down direction). This vault is the **Long**
side; the **Short** side (buy M) is `GimbalShortVault` — see `short-vault-frontend-handoff.md`. Likewise
**Earn** has a **Long house (ETH, this vault) ⇄ Short house (USDC, the short vault)** choice, not two nav
items.

## Three surfaces

1. **Earn tab · Long house (be the house):** `deposit()` / `redeem()` + NAV/share views. The core new product.
2. **Leverage tab · Long side (buy N):** `quote_buy_n` → `buy_n` against the vault, an alternative to the
   existing `LeverageRouter` pool path.
3. **A "Refresh / harvest" affordance:** anyone may call `poke()` (permissionless keeper).

---

## Earn tab — deposit / redeem (LP side)

**`deposit() payable returns (uint256 shares)`** — `msg.value` = ETH to deposit; mints house shares at
live NAV. Shares are **soulbound** (non-transferable in v1 — no `transfer`/`approve`; don't render a send
control). The very first deposit also mints a tiny `DEAD_SHARES` bootstrap (donation guard) — expected.

**`redeem(uint256 shares)`** — burns shares and pays a strict **pro-rata, in-kind** slice of the house:
buffered ETH **plus** the vault's P tokens of each open series, transferred to the LP. **No oracle on this
path — it can never be trapped or mispriced.** The LP receives P tokens they can later settle/merge
themselves (see "what P is" below). There is **one** redeem; it is also the emergency exit.

**Views for the Earn UI** (all on the vault):
- `nav() -> uint256` — total house value in **ETH wei** (`eth_buffer + Σ held-P marked at oracle`).
- `share_price() -> uint256` — ETH-wei NAV per share, 1e18-scaled (≈ `1e18` at genesis).
- `balanceOf(addr) -> uint256` — the LP's shares. `totalSupply() -> uint256`.
- `eth_buffer() -> uint256` — free (unwritten) ETH. `total_p_held() -> uint256` — written face (risk meter).
- `total_deposited()` / `TOTAL_DEPOSIT_CAP()` — show "X / cap ETH deposited" (deposits revert once the
  **lifetime-gross** total hits the cap — it does **not** decrease on redeem; surface this).

**Mandatory "Be the house" ack** before the first deposit (typed confirm), honest copy:
> You're funding an **immutable, ownerless** vault that writes leveraged-ETH options. You **earn its trading
> P&L** and **can lose principal** when traders win — but your loss is **capped at your deposit** and there
> are **no liquidations**. It's **short volatility**, not a yield/savings product. No operator, no admin, no
> pause — a bug's only recourse is migrating to a v2. Redemptions are pro-rata **in-kind** (ETH + option
> tokens). **Sepolia testnet, unaudited.**

**What "P" is (for the redeem UX):** each P token is the deep-ITM tracking leg of a specific option series;
once that series settles it redeems 1:1-ish for ETH via the series' `redeem_p`. Show the LP their received
P tokens and a "these settle to ETH at the series' maturity; or merge P+N to exit early" note. (`poke()`
auto-harvests settled P back into the buffer, so most of the time redeem is mostly ETH.)

---

## Leverage tab — buy N (buyer side)

**Resolve the writable series first** (the vault only writes the tracker's roll-safe current vintage):
```
target = ITracker(SPUSD).pending_series()
if target == 0x0: target = ITracker(SPUSD).active_series()
```
Use `target` as the `series` arg everywhere below. The N token to track = `ISeries(target).N()`; display
strike/maturity via `ISeries(target).STRIKE()` / `.MATURITY()`.

**`quote_buy_n(address series, uint256 amount) -> uint256`** (view) — ETH cost preview to buy `amount` N.
**`intrinsic_n(address series) -> uint256`** (view) — live N fair value (ETH wei per 1e18 N); show the
quote's implied edge vs this (the house's spread, ≈ `BASE_EDGE`).

**`buy_n(address series, uint256 amount, uint256 max_cost) payable returns (uint256 cost)`** — buy N.
- `msg.value` **MUST equal the live on-chain cost exactly** (no change returned). Compute it by calling
  `quote_buy_n` **immediately before** sending, then send `buy_n{value: quote}(target, amount, quote)`.
- `max_cost` is a slippage ceiling (`assert cost <= max_cost`). Set it `>= quote`.
- Because the price is live (not a fixed quote), if the oracle ticks between quote and mining, the
  on-chain cost changes and the tx reverts `"bad value"`. **On `"bad value"`, re-quote and retry.** This is
  rare on Sepolia (the feed updates slowly), but handle it. (v2/mainnet should accept `msg.value >= cost`
  and refund the remainder — noted in the spec's mainnet checklist.)

**Leverage display:** `leverage ≈ 1 / (1 − STRIKE·1e18 / x)`, `x = HUB.latest_price(0x0)`. This series is
the ~2× soft-peg vintage; Split-style higher tiers are the future P2 dated-series menu, not this venue.

**This vault is WRITE-ONLY — there is no sell-N back to it.** An N holder exits by: holding to the series'
maturity then calling `ISeries(target).redeem_n(amount)` (permissionless, oracle-free); or `merge(amount)`
if they hold both P and N; or a secondary market. **Do not show a "sell to the house" affordance** — make
the exit path explicit in the buy confirmation.

**Refresh / harvest:** a `poke()` button ("Refresh the house — anyone can call"). It best-effort settles
matured series and harvests their P → ETH buffer. No funds move to the caller. Surface it near a roll.

---

## Trust labeling — REQUIRED

Every vault surface shows, prominently:
> **The Gimbal House** — an **immutable, ownerless** on-chain vault funded by crowd LPs. No operator, no
> admin, no pause. Prices are computed on-chain from the oracle plus a fixed spread. **Sepolia testnet,
> research code, unaudited.**

This is the opposite of the old RFQ desk's "operator counterparty" label — there is no operator here.

## Revert handling

Failed calls never risk funds. Map the revert string to UX:
- **Re-quote / transient (buy_n):** `"bad value"` (price moved — re-quote), `"slippage"` (raise `max_cost`),
  `"size"` (amount > `MAX_FILL`), `"written cap"` / `"outflow cap"` / `"block cap"` (house at a cap — try
  smaller or later), `"underfunded"` (house buffer too low for the split — needs more deposits).
- **Rolling / unavailable (buy_n):** `"stale series"` (you didn't pass the current target — re-resolve),
  `"near maturity"` / `"near strike"` / `"settled"` (the vintage is rolling — show "leverage paused,
  rolling" and offer `poke()` / wait), `"dust"` (amount too small to price).
- **Oracle down (deposit & buy_n):** `"desk-stale"` / `"bad answer"` / `"incomplete round"` /
  `"future update"` — the feed is stale; show "oracle stale, try shortly." (Note: **redeem never hits the
  oracle**, so the exit always works even when these fire.)
- **Deposit:** `"deposit cap"` (lifetime cap reached), `"initial deposit too small"` (first deposit must
  exceed `DEAD_SHARES` = 1000 wei).

## Coexistence with the pool

The existing `LeverageRouter` (ETH→N via the spUSD/WETH P-sink) still works and is a separate buy-N venue.
Best-execution for **buy-N**: compare the vault's `quote_buy_n` against the router's pool path and route to
the cheaper. (There is no N pool to fall back to for selling — sell-N doesn't exist anywhere; N exits via
the series as above.) Do **not** build an N-side pool.

## Pointers
- Contract source: `src/periphery/GimbalSimpleVault.vy`
- Canonical call shapes (deposit/redeem/buy_n/poke, all guardrails): `test/GimbalSimpleVault.fork.t.sol`
- Design + immutable params + MAINNET CHECKLIST: `docs/handoffs/simple-vault-sepolia-spec.md`
- Deployed record: `docs/deployments.md` → "Immutable Autonomous Vault — GimbalSimpleVault"

**Everything here is Sepolia testnet, research code, unaudited — keep that framing in the UI.**
