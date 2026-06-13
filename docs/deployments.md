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

### Periphery (deployed 2026-06-13)

Stateless, trustless helper contracts (no admin, hold no funds between
calls; the core grants them nothing).

| Contract | Address |
|---|---|
| **LeverageRouter** (spUSD) — one-tx ETH→pure-N via the spUSD/WETH pool P-sink | [`0xe942843535Cf19272a576023588FF01a7Fce9556`](https://eth-sepolia.blockscout.com/address/0xe942843535Cf19272a576023588FF01a7Fce9556) |

LeverageRouter wiring: TRACKER = spUSD, SWAP_ROUTER =
`0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` (Uniswap v3 SwapRouter02),
WETH = `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`, POOL_FEE = 3000.
P-sink pool = spUSD/WETH 0.3% `0x8362C2A9b13e0ba770D7bFE7C2d0ae0b33B603B9`.
**Pool must be priced near spUSD's NAV (~$1) for sane economics** — when
mispriced/thin the router still works but the swap over/under-pays.

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
