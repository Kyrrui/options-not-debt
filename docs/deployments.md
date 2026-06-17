# Deployments

## Sepolia (chain id 11155111)

All contracts source-verified on Blockscout. Live Chainlink feeds; no mocks.

### Core (deployed 2026-06-11; OracleHub is shared by all stack versions)

| Contract | Address |
|---|---|
| OracleHub | [`0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62`](https://eth-sepolia.blockscout.com/address/0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62) |

### Current stack (deployed 2026-06-12, v4 — standard ERC-20 metadata)

Trackers are created permissionlessly through the factory and enumerated
on-chain — **UIs should discover trackers from the factory, not from this
file** (`tracker_count`/`tracker_list(i)`/`is_tracker(addr)`). All tokens
expose standard lowercase `name()`/`symbol()`/`decimals()` (wallets, DEXes,
explorers) alongside the uppercase Vyper getters. P/N tokens self-describe:
`P-<ASSET>-<STRIKE>-<YYMMDD>` (e.g. `P-XAU-0.197-260711`).

| Contract | Address |
|---|---|
| **SeriesFactory** | [`0x63C29F7981b45cbbE9D6c5E20d892D70f6db19C2`](https://eth-sepolia.blockscout.com/address/0x63C29F7981b45cbbE9D6c5E20d892D70f6db19C2) |
| **TrackerFactory** | [`0x7C87799cad38576ddB03881570bd62e7ac1daf49`](https://eth-sepolia.blockscout.com/address/0x7C87799cad38576ddB03881570bd62e7ac1daf49) |
| OptionToken blueprint (EIP-5202) | `0x360b1f203f82f06709c5d7c9ec9d86993a3034c4` |
| OptionSeries blueprint (EIP-5202) | `0x0e5f7f8a8ee445acab0a1fdbfcefe02361fe1d6b` |
| TrackerDAO blueprint (EIP-5202) | `0x302E0aF6f6F4F42049dF5513d0109870c7D987F0` |
| spUSD — Soft Peg USD (tracker 0) | [`0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE`](https://eth-sepolia.blockscout.com/address/0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE) |
| spXAU — Soft Peg Gold (tracker 1) | [`0x51eBb768b45461B4024eE4a9631752d2fD8e38F2`](https://eth-sepolia.blockscout.com/address/0x51eBb768b45461B4024eE4a9631752d2fD8e38F2) |
| spBTC — Soft Peg Bitcoin (tracker 2) | [`0x46E85dAbbFB4951bEa691E3AbD8008d02c1C5109`](https://eth-sepolia.blockscout.com/address/0x46E85dAbbFB4951bEa691E3AbD8008d02c1C5109) |
| spXAU genesis series (`XAU-0.197-260711`) | [`0xE9BdF51C0064E5E49a3800E79364544164243924`](https://eth-sepolia.blockscout.com/address/0xE9BdF51C0064E5E49a3800E79364544164243924) |
| └ P / N legs | `0x755E166541537834E0C489FeFed9BE18f3ba2750` / `0x7e2E2Ec62C37fd6C0BF35B858e2948daC7659221` |

### Periphery — factory-deployed + registry-tracked (PeripheryFactory v2, 2026-06-14)

Stateless, trustless helpers (no admin, hold no funds between calls; the core
grants them nothing). Periphery is deployed and discovered through the
**PeripheryFactory** — UIs read a peg's router/zapper/flash from the registry by
`(tracker, fee)`, not from this file. v2 adds the FlashLeverageRouter as a third
auto-deployed helper.

| Contract | Address |
|---|---|
| **PeripheryFactory v2** — permissionless deploy + enumerable registry of a peg's router + zapper + flash | [`0xdfD387aFFF2aDD0726dDA0fbE6ac7ee77F562D6D`](https://eth-sepolia.blockscout.com/address/0xdfD387aFFF2aDD0726dDA0fbE6ac7ee77F562D6D) |
| LeverageRouter blueprint (EIP-5202) | `0xFA6a16cE35Cdaaa611a85E1670aecc226898AA60` |
| LPZapper blueprint (EIP-5202) | `0x528D055A0ecB7566d56c3EEb31dae6412cF491a7` |
| FlashLeverageRouter blueprint (EIP-5202) | `0xCeA3AE530cb7FB8b10bb44C2D175Af8631B107A7` |

PeripheryFactory wiring: TRACKER_FACTORY = `0x7C87799cad38576ddB03881570bd62e7ac1daf49`,
UNIV3_FACTORY = `0x0227628f3F023bb0B980b67D528571c95c6DaC1c`, NPM =
`0x1238536071E1c677A632429e3655c799b22cDA52`, SWAP_ROUTER =
`0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E`, WETH =
`0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`, VAULT =
`0xBA12222222228d8Ba445958a75a0704d566BF2C8` (Balancer v2, for the flash router).
`deploy_periphery(tracker, fee)` (permissionless) → `(router, zapper, flash)`:
asserts the tracker is TrackerFactory-created, resolves the spToken/WETH pool
(must exist), **reads tick_spacing from the pool**, blueprint-deploys all three
helpers, records them keyed by `(tracker, fee)`. Discover via `get_router` /
`get_zapper` / `get_flash` / `get_pool` / `is_deployed`(tracker,fee) +
`entry_count`/`entry_tracker(i)`/`entry_fee(i)`, reverse `is_router`/`is_zapper`/
`is_flash`. Reviews: full pre-deploy review (1 HIGH — caller-supplied tick_spacing
— **FIXED** by reading it from the pool) + focused review of the v2 flash addition
(0 confirmed, full parity with the router/zapper handling).

**Canonical periphery (v2 registry-tracked) — spUSD @ fee 3000:**

| Contract | Address |
|---|---|
| LeverageRouter (spUSD) — one-tx ETH→pure-N via the spUSD/WETH P-sink | [`0xdA387BdE50b4943162947ccDF4E9eca3dA70940E`](https://eth-sepolia.blockscout.com/address/0xdA387BdE50b4943162947ccDF4E9eca3dA70940E) |
| LPZapper (spUSD) — one-tx ETH→full-range spUSD/WETH v3 LP (+ N forwarded) | [`0x8828AF8682dC8B95DCC08a52F79E5d6Cb9c80aF1`](https://eth-sepolia.blockscout.com/address/0x8828AF8682dC8B95DCC08a52F79E5d6Cb9c80aF1) |
| FlashLeverageRouter (spUSD) — "send exactly your premium" via Balancer flash | [`0xF8a2DF8E9288a9b9dd56a0F6F749773dBb8A2957`](https://eth-sepolia.blockscout.com/address/0xF8a2DF8E9288a9b9dd56a0F6F749773dBb8A2957) |

P-sink / LP pool = spUSD/WETH 0.3% `0x8362C2A9b13e0ba770D7bFE7C2d0ae0b33B603B9`.
**Both need the pool priced near spUSD's NAV (~$1) for sane economics** — when
mispriced/thin they still work but the swap over/under-pays and the LP add uses
only part of one side, refunding the rest (fork run: ~49% of the WETH side used
against the current mispriced pool).

FlashLeverageRouter detail: caller sends `msg.value` = premium (max loss); the
P-side is flash-borrowed from Balancer (`0xBA12222222228d8Ba445958a75a0704d566BF2C8`,
0-fee; ~4 WETH on Sepolia, ~1390 on mainnet, same address on both) and repaid
from the P sale in-tx — no change-back, and a full premium deploys in one tx.
Same per-unit economics as LeverageRouter but a larger P sale → more slippage.
Review: 21 findings, 0 confirmed, 3 hardenings; proven against the live Balancer
vault. Auto-deployed per peg by PeripheryFactory v2.

Periphery API (registry- and hand-deployed instances share one source):
- LeverageRouter: `open_leverage(min_eth_out) -> (n_token, n_amount, eth_returned)`.
- LPZapper: `add_liquidity(eth_to_deposit, amount_sp_min, amount_weth_min, deadline) -> (token_id, liquidity, sp_used, weth_used)` — mints the NFT to the caller, forwards N, refunds leftovers; caller supplies split + slippage (mins ≠ 0), no on-chain price math.
- FlashLeverageRouter: `open_leverage(flash_amount, min_eth_out) payable -> (n_token, n_amount, eth_returned)` — msg.value = premium; flash-borrows the P-side; `min_eth_out >= flash_amount` required.

### Solo RFQ Desk — SignedQuoteFiller (standalone, NOT factory-deployed)

Operator-run quote desk for the N (leverage) leg — the first/only venue to **sell** N.
Holds the operator's funds, so it is intentionally standalone (not a stateless
PeripheryFactory helper). Built + reviewed (6 low findings fixed) + fork-tested 10/10.
Spec `docs/handoffs/solo-rfq-spec.md`; integration `docs/handoffs/solo-rfq-frontend-handoff.md` +
`docs/handoffs/solo-rfq-quoter-spec.md`. Deploy: `KEY=… BROADCAST=1 ./script/deploy-rfq-desk.sh`.

| Contract | Address |
|---|---|
| SignedQuoteFiller (spUSD desk) | [`0x48c93eD52507DEe37d79eA37Df9ed7fAF739C8F1`](https://eth-sepolia.blockscout.com/address/0x48c93eD52507DEe37d79eA37Df9ed7fAF739C8F1) |

**NOT YET LIVE — do not list in operatorDesks.json yet.** Deployed Blockscout-verified
with **placeholder `owner = quoter = deployer`** (`0xBd4bFfe718f607ad52C30A5ECA3526306cB38e33`)
and **unfunded**. Before go-live the operator must: `set_quoter(<real quoter-service key>)`,
`fund()`/`fund_p()`, tune `set_caps`, optionally `transfer_ownership`, then add the
`operatorDesks.json` entry. Deploy params: USD-only; min_edge 1%; desk_max_staleness 3600s
(loosest the contract allows — suits Sepolia's slow feed; use 300–600s on mainnet);
pre_maturity_buffer 2d; strike_proximity 1.5e18 (= spUSD `ROLL_TRIGGER`); caps 0.1 N /
3 ETH NAV-at-risk / 1 ETH float / 2 ETH per-window.

### Stable RFQ Desk — StableQuoteFiller (standalone, NOT factory-deployed)

Positive-carry **sibling** to the N desk for the spUSD (P/dollar) leg — buy + sell spUSD,
inventory-based (NO mint-to-sell), NAV-anchored floor, distinct EIP-712 domain. Reviewed
(4 confirmed, all fixed: NAV cap in spUSD UNITS not the falling ETH-mark, saturating
`net_spusd` + `resync_spusd`, `sp_sign` deferred) + 12/12 fork tests. Spec
`docs/handoffs/stable-rfq-spec.md`. Deploy: `KEY=… BROADCAST=1 ./script/deploy-rfq-desk-stable.sh`.

| Contract | Address |
|---|---|
| StableQuoteFiller (spUSD desk) | [`0x520089CCFCB62cd79971afeBB3A3EA2E973E29cc`](https://eth-sepolia.blockscout.com/address/0x520089CCFCB62cd79971afeBB3A3EA2E973E29cc) |

**NOT YET LIVE — do not list in operatorDesks.json yet.** Deployed Blockscout-verified
with **placeholder `owner = quoter = deployer`** (`0xBd4bFfe718f607ad52C30A5ECA3526306cB38e33`)
and **unfunded**. Go-live (operator): `set_quoter(<real key>)`, seed spUSD via `fund_spusd`
(acquire spUSD off-desk; the desk has NO mint path), `fund()` ETH for the buy side, tune
`set_caps`, optionally `transfer_ownership`, then add the `operatorDesks.json` entry with
`leg:"spUSD"`. Deploy params: USD-only; min_edge 1%; desk_max_staleness 3600s (mainnet
300–600s); caps 100 spUSD/fill · 3000 spUSD-UNITS net (oracle-invariant) · 0 floats ·
2 ETH/window outflow.

### Immutable Autonomous Vault — GimbalSimpleVault (standalone, NOT factory-deployed)

The minimal crowd-owned house: an **immutable, ownerless** ETH vault that writes + sells the N
(leverage) leg of spUSD's current ~2× series at an on-chain formulaic price (NO signer), keeping P.
Crowd LPs deposit ETH (Earn-only); the only outflow is an LP's own oracle-free in-kind `redeem()` or a
settled-series harvest via the permissionless `poke()`. NO owner/admin/pause/upgrade/withdraw — every
cap is a ctor immutable. Adversarial pre-deploy review: 14 agents, 1 confirmed-real finding (info-sev
dust write — fixed pre-freeze with `assert cost > 0`), **DEPLOY-AS-IS** verdict; 14/14 fork tests green
on live Sepolia. Spec + MAINNET CHECKLIST: `docs/handoffs/simple-vault-sepolia-spec.md`. Deploy:
`KEY=… BROADCAST=1 ./script/deploy-simple-vault.sh`.

| Contract | Address |
|---|---|
| GimbalSimpleVault (spUSD immutable house) | [`0x25cDc829B67A4746Cf05517d53739017bd6BEe34`](https://eth-sepolia.blockscout.com/address/0x25cDc829B67A4746Cf05517d53739017bd6BEe34) |

**LIVE + Blockscout-verified, currently UNFUNDED (`totalSupply`=0, `nav`=0).** Go-live needs NO admin
step — anyone calls `deposit()` to fund it + `buy_n()` to trade; `poke()` is the permissionless keeper.
Immutable params (frozen forever): USD-only; base_edge 2%; desk_max_staleness 3600s; pre_maturity_buffer
7d (= spUSD `ROLL_WINDOW`); strike_proximity 1.5e18 (= `ROLL_TRIGGER`); caps 0.5 N/fill · 3 ETH total
written · 1 ETH/window · 0.5 ETH/block · 10 ETH gross-deposit (lifetime, not current-TVL). **Immutable
BY CHOICE for the Sepolia research phase — do NOT deploy as-is to mainnet (see the spec's MAINNET
CHECKLIST: timelock guardian, hardened settle/dead-oracle, epochs, Halmos+audit, legal entity, …).**

### Debt-free SHORT stack (P1) — PutOptionSeries + GimbalShortVault (immutable, ownerless)

The leveraged ETH **short**: lock USDC → M (gains as ETH falls) + L (covered), M+L=1 stable, max loss =
premium, no liquidation. Built to the **ownerless** architecture (NOT the spec's operated `ShortQuoteFiller`
— that predates the no-operated-desks decision): the trading venue is the immutable `GimbalShortVault`, the
USDC/put mirror of `GimbalSimpleVault`. Adversarial pre-deploy review: 14 agents, 4 findings (all low/info),
**DEPLOY-AS-IS**; two one-line polish fixes applied pre-freeze (VYP-01 `merge` dust guard, VYP-02 vault
`split_cost6` dust assert). 13/13 fork tests green. Spec: `docs/handoffs/short-series-spec.md`; frontend:
`docs/handoffs/short-vault-frontend-handoff.md`. Deploy: `KEY=… BROADCAST=1 ./script/deploy-short-stack.sh`.

**Collateral = Circle's VERIFIED Sepolia USDC** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (6-dec; get
it from faucet.circle.com), NOT a mock — chosen for fidelity (real FiatToken, wallet-recognized, exercises
the F-FREEZE blocklist/pause risk).

| Contract | Address |
|---|---|
| **GimbalShortVault** (immutable USDC short house) | [`0xB835cB7616Ce72ee2F30486812105d30CA9533c7`](https://eth-sepolia.blockscout.com/address/0xB835cB7616Ce72ee2F30486812105d30CA9533c7) |
| **PutOptionSeries** (`M-USD-2177.825-…` / `L-…`) | [`0xaC10cb644715A19A736a787BDE3eC0E3fb880B61`](https://eth-sepolia.blockscout.com/address/0xaC10cb644715A19A736a787BDE3eC0E3fb880B61) |
| └ M / L legs | `0x28B45AF2688506E3Bd0766376239759e6976ED7a` / `0xA54f026cB9abf3444AfBBE610443aE4593b57087` |
| Circle USDC (collateral) | [`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`](https://eth-sepolia.blockscout.com/address/0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) |

*(Superseded MockUSDC-backed first cut — vault `0xf9b268eB464178349Bd81BbCAcc3EC771d0C6254`, series
`0xa9Eac5413C3058224DCbCa676FEB0C7b47a31FcC`, MockUSDC `0x31B7d96A5C8ab4d91077873e61aFaBCFE11E5002` —
left verified but do not list; redeployed against Circle USDC for fidelity. `src/mocks/MockUSDC.vy` stays
for local/fork testing only.)*

**LIVE + Blockscout-verified, UNFUNDED (`totalSupply`=0).** Go-live = LPs get Circle USDC →
`deposit()` → buyers `buy_m()`; `poke()` is the permissionless keeper. Immutable params (frozen): USD-only; strike
K≈$2,177.83 (~4× tier, set 1.25× spot at deploy); 30-day maturity; base_edge 2%; staleness 3600s;
pre_maturity_buffer 2d; strike_proximity 0.95e18 (FLIPPED sub-UNIT band); caps 500 M/fill · 5000 M written ·
2000 M/window · 500 M/block · 50,000 USDC gross-deposit. **Immutable BY CHOICE for Sepolia — do NOT deploy
as-is to mainnet** (real USDC + F-FREEZE; hardened `settle_fallback` for the dead-oracle trap; epochs;
Halmos+audit; spUSD soft-short + P2 tiers — see the spec's MAINNET CHECKLIST).

**Deprecated periphery (superseded by v2 — do not list in UIs):**

| Contract | Address |
|---|---|
| PeripheryFactory v1 | `0xDD1310E9ce98a6D34Ee4Db8164B98fEc1AD19bc9` |
| LeverageRouter (v1 registry, spUSD) | `0xf5DEb5F36Ff8D6ed6657bA159eF7A7dBc46EedB0` |
| LPZapper (v1 registry, spUSD) | `0x8F4C9824Ac836AB636BBA715Bc5dD99C65AA906c` |
| FlashLeverageRouter (standalone, spUSD) | `0x0a48A236b899ca5a14b6b7C348E37adB4Ae3e0df` |
| LeverageRouter (standalone, 06-13) | `0xe942843535Cf19272a576023588FF01a7Fce9556` |
| LPZapper (standalone, 06-14) | `0x96575DDc64eeB0BBe8616519C57835c4CB2A3897` |

### Deprecated earlier stacks (2026-06-12)

| Version | Defect | Addresses |
|---|---|---|
| v3 (symbology, uppercase-only metadata) | no lowercase `name()`/`symbol()`/`decimals()` — invisible to wallets/DEXes | SF `0x6b44...D390`, TF `0x8E50...7A19`, spUSD `0xa1B1...6208`, spXAU `0x734F...f12C`, spBTC `0x789D...799F` |
| v2 (generic OPT-P/OPT-N names) | leg symbols collide across rolls | SF `0x4Be9...248D`, TF `0xC78A...E713`, spUSD `0xD4CB...c03F`, spXAU `0xB150...3faC`, spBTC `0xf538...85dE` |

### Deprecated (pre-factory standalone deployments, 2026-06-11)

Superseded by the factory-created pegs above; not in the factory registry.
Hold only ~0.01 ETH smoke deposits. Do not list in UIs.

| Contract | Address |
|---|---|
| spUSD (standalone) | `0xf35cFEf2Db231c84EEd74fd988918DE1f9062201` |
| spXAU (standalone) | `0xBc9E4b726dE6DDCAFaE3f41FBA6411E6679F4916` |
| └ genesis series / P / N | `0xf9b96E06cC5C2ED2A0ae6A782aB769bA78e15483` / `0x7B922CeeD469713207eff6b870DDDA0E0ba1C9C6` / `0x344ad9E2dF0669a1650CAd58F3D272fA9eec74b8` |

**Oracle configuration**

| Asset | Feed | Heartbeat | Asset id |
|---|---|---|---|
| USD (sentinel) | ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306` | 7200s | `0x0` |
| XAU | XAU/USD `0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea` | 259200s (weekend-safe) | `0x760a8d196beecadca683d6491e5ff4f706cf736083a97a44374cabb6481525ff` |
| BTC | BTC/USD `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` | 86400s | `0x18fe0e0ad0677db1b70559bb43b867648caebb35a4a086ea23920c543cdc747a` |

**Genesis state** (at deploy, ETH $1,676.19 / XAU $4,227.43 → x = 0.3966 oz/ETH):
spXAU genesis series strike `0.198251867104758153` oz/ETH (= x/2), maturity
2026-07-09; 0.01 ETH smoke deposit minted shares at `share_price == 1e18`
exactly — one share = one ounce, priced off live feeds.

DAO parameters (both wrappers): term 28d, roll window 7d, roll trigger 1.5×,
strike ratio 0.5×, auction duration 1d, max edge 2%.

Deployer (testnet throwaway): `0xBd4bFfe718f607ad52C30A5ECA3526306cB38e33`.
