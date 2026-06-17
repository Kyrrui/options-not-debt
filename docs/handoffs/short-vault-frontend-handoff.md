# GimbalShortVault — frontend integration handoff (for the dapp builder)

> Self-contained handoff to wire the **debt-free leveraged SHORT** into the Gimbal frontend. It is the
> USDC/put mirror of the long vault: an **immutable, ownerless** house where crowd LPs deposit USDC and a
> buyer can **buy M (a leveraged short on ETH)** — M **gains as ETH falls**, **max loss = the premium
> paid, no liquidation, fully collateralized**. Like the long vault: **NO quoter service, NO signing, NO
> RFQ, NO operator** — plain `view` + ERC20 contract calls, priced on-chain.
>
> Contracts: [`src/PutOptionSeries.vy`](../../src/PutOptionSeries.vy) (the put primitive),
> [`src/periphery/GimbalShortVault.vy`](../../src/periphery/GimbalShortVault.vy) (the venue).
> Canonical call shapes: [`test/PutShortStack.fork.t.sol`](../../test/PutShortStack.fork.t.sol).
> Design + findings: [`short-series-spec.md`](short-series-spec.md). Sibling long handoff:
> `docs/handoffs/simple-vault-frontend-handoff.md`.

## Status & addresses (Sepolia, chain id 11155111)

**LIVE + Blockscout-verified, UNFUNDED** (`totalSupply`=0). Go-live needs no admin step: anyone mints
MockUSDC, deposits to the vault, and buys M. Build against the ABI now.

| What | Address |
|---|---|
| **GimbalShortVault** (the short house) | `0xf9b268eB464178349Bd81BbCAcc3EC771d0C6254` |
| **PutOptionSeries** (the series it writes) | `0xa9Eac5413C3058224DCbCa676FEB0C7b47a31FcC` |
| **MockUSDC** (6-dec collateral, open faucet) | `0x31B7d96A5C8ab4d91077873e61aFaBCFE11E5002` |
| OracleHub | `0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62` |

Strike `K` ≈ **$2,177.83** (set 25% above spot at deploy → a ~**4× short tier**), 30-day maturity. The
vault is **immutable**: no owner/admin/pause/upgrade/withdraw; read every cap from its public getters.

**Test USDC:** `MockUSDC.mint(to, amount)` is an **open faucet** (anyone mints any amount, 6-dec). Give
users a "Get test USDC" button calling it. (Mainnet uses real USDC — see caveats.)

## Units (read carefully — this leg mixes 6-dec USDC and 18-dec legs)

- **USDC amounts are 6-dec** (`1 USDC = 1_000_000`): `deposit` input, `buy_m` cost, `redeem` USDC output.
- **M / L / share amounts are 18-dec.** `quote_buy_m(amount)` takes M units (1e18) and returns the cost in
  **USDC (6-dec)**. `nav()` is 18-dec "stable units" (`1e18 = 1 USDC`; divide by `SCALE()` = 1e12 for a
  USDC figure). `share_price()` is 1e18-scaled.

## Earn tab — be the short house (LP side, USDC)

The LP is the **counterparty to shorts**: they profit (premium) when ETH holds/rises and lose (capped,
pre-funded, never liquidated) when ETH falls hard. Mirror of the long house's "be the house."

- **`deposit(uint256 amount) → shares`** — `amount` = USDC (6-dec). **Approve USDC to the vault first.**
- **`redeem(uint256 shares)`** — burns shares for pro-rata **USDC + L tokens in-kind**. No oracle — never
  trapped. (L settles to USDC at the series' maturity; `poke()` auto-harvests settled L into the buffer.)
- Views: `nav()` (18-dec), `share_price()`, `balanceOf(addr)` (shares), `totalSupply()`, `buffer()`
  (free USDC, 18-dec), `l_held()` (written face / risk meter), `total_deposited()` vs `TOTAL_DEPOSIT_CAP()`.
- **"Be the short house" ack** (typed, before first deposit): *You fund an immutable, ownerless vault that
  writes leveraged ETH shorts. You collect premium and **can lose principal when ETH falls hard** — loss
  capped at your deposit, never liquidated. Short volatility, not a yield product. No operator/admin/pause.
  Redemptions are pro-rata in-kind (USDC + option tokens). Sepolia testnet, unaudited.*

## Short tab — buy M (open a leveraged short)

- **`quote_buy_m(uint256 amount) → uint256`** (view) — USDC (6-dec) cost to buy `amount` M (1e18).
- **`intrinsic_m() → uint256`** (view) — live M fair value (1e18-scaled USDC per 1e18 M); show edge vs it.
- **`buy_m(address series, uint256 amount, uint256 max_cost) → uint256 cost`** — pass `series` =
  the PutOptionSeries address above; `amount` = M units (1e18); `max_cost` = USDC slippage ceiling (6-dec).
  **Approve the vault to pull `max_cost` USDC first.** The vault pulls the *live* `cost` (≤ `max_cost`); no
  exact-amount dance — just approve a small buffer over the quote and set `max_cost` to it. Reverts
  `"slippage"` only if the live cost exceeds `max_cost` (re-quote). The M token = `ISeries(series).M()`.
- **Leverage / payoff:** `leverage ≈ 1 / (K/p − 1)`, `p = HUB.latest_price(0x0)`, `K = ISeries.STRIKE()`.
  Payoff **rises as ETH falls**, max loss = premium (literally true for M), **upper breakeven** at
  `p = K·(1 − premium)`. This series is a ~4× tier; Split-style tier menus are future P2.
- **Writes pause near/above strike (flipped band):** `buy_m` reverts `"near strike"` when ETH is within
  ~5% of K or above it (M ≈ worthless there). Show "shorts paused — ETH too close to strike." Note this is
  the *opposite* end from the long vault's band (`quote_buy_m` returns a price slightly into that band, so
  gate the UI on the band, not just the quote).

**Exit (WRITE-ONLY — no sell-back to the house):** an M holder closes by holding to the series' maturity
then calling `ISeries(series).redeem_m(amount)` (permissionless, oracle-free after `settle()`), or
`merge(amount)` if they hold matching M **and** L, or a secondary market. **Do not show "sell to the
house."** Make the exit explicit in the buy confirmation — the short leg has **no pool/merge/redeem
fallback for a lone M holder** before maturity.

**`poke()`** — permissionless "Refresh / settle + harvest" button; after maturity it settles the series and
harvests L → USDC. No funds move to the caller.

## Trust labeling — REQUIRED
> **The Gimbal Short House** — an immutable, ownerless on-chain vault funded by crowd LPs. No operator, no
> admin, no pause. Prices computed on-chain from the oracle plus a fixed spread. **Sepolia testnet,
> research code, unaudited.**

## Revert → UX map
- **buy_m:** `"slippage"` (raise `max_cost` / re-quote), `"size"` (> `MAX_FILL`), `"written cap"`/`"outflow
  cap"`/`"block cap"` (house at a cap), `"near strike"` (ETH too close to/above K — shorts paused),
  `"dust"` (amount too small), `"underfunded"` (house USDC too low — needs deposits), `"wrong series"`
  (pass the listed series). Oracle: `"desk-stale"`/`"bad answer"`/`"incomplete round"` (feed stale, retry).
- **deposit:** `"deposit cap"` (lifetime gross cap reached), `"initial deposit too small"`. Oracle-stale
  blocks deposit too — but **redeem never touches the oracle**, so the exit always works.

## Mainnet caveats (carry in the UI; full list in short-series-spec.md)
- **MockUSDC is a testnet faucet token**, not real USDC. Mainnet locks real USDC (issuer freeze/blocklist
  risk, F-FREEZE; no oracle-free ETH fallback).
- **Dead-oracle (F-DEAD-ORACLE):** if the feed dies before settlement, the series' locked USDC slice is
  stranded as un-settleable L until the feed revives (the vault itself never bricks — redeem stays open).
  Mainnet needs a hardened `settle_fallback`.
- spUSD-collateralized "soft short", the leverage-tier menu (P2), and a transferable share token are all
  future work — this is one USDC series, one tier, soulbound shares.

## Pointers
- Series + vault source: `src/PutOptionSeries.vy`, `src/periphery/GimbalShortVault.vy`
- Canonical call shapes (split/merge/settle/redeem, deposit/buy_m/redeem/poke): `test/PutShortStack.fork.t.sol`
- Design + 11 findings + the pre-deploy review (DEPLOY-AS-IS): `docs/handoffs/short-series-spec.md`
- Deployed record: `docs/deployments.md`

**Everything here is Sepolia testnet, research code, unaudited — keep that framing in the UI.**
