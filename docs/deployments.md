# Deployments

## Sepolia (chain id 11155111)

All contracts source-verified on Blockscout. Live Chainlink feeds; no mocks.

### Core (deployed 2026-06-11)

| Contract | Address |
|---|---|
| OracleHub | [`0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62`](https://eth-sepolia.blockscout.com/address/0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62) |
| SeriesFactory | [`0x4Be934A244c25034546CF4a265db51b8943D248D`](https://eth-sepolia.blockscout.com/address/0x4Be934A244c25034546CF4a265db51b8943D248D) |
| OptionToken blueprint (EIP-5202) | `0x62ab76a68f5c95997aacc8e95b83d568e6a35a49` |
| OptionSeries blueprint (EIP-5202) | `0xee09c1d00777089d897058f06c6d471d792cfe35` |

### TrackerFactory + canonical pegs (deployed 2026-06-12)

Trackers are created permissionlessly through the factory and enumerated
on-chain — **UIs should discover trackers from the factory, not from this
file** (`tracker_count`/`tracker_list(i)`/`is_tracker(addr)`).

| Contract | Address |
|---|---|
| **TrackerFactory** | [`0xC78A0A16755E45a70633631a40bBDEf349dCE713`](https://eth-sepolia.blockscout.com/address/0xC78A0A16755E45a70633631a40bBDEf349dCE713) |
| TrackerDAO blueprint (EIP-5202) | `0x643836b40C5D9D4864a2293584F8174BB0F1c175` |
| spUSD — Soft Peg USD (tracker 0) | [`0xD4CB61f4ad9bac2D52b2797cAEbF04e1270Ac03F`](https://eth-sepolia.blockscout.com/address/0xD4CB61f4ad9bac2D52b2797cAEbF04e1270Ac03F) |
| spXAU — Soft Peg Gold (tracker 1) | [`0xB150748D9F988df5f93c86F3b21c98ebC03D3faC`](https://eth-sepolia.blockscout.com/address/0xB150748D9F988df5f93c86F3b21c98ebC03D3faC) |
| spBTC — Soft Peg Bitcoin (tracker 2) | [`0xf5383E844C040312f2dCF6479C6cDf60FF7185dE`](https://eth-sepolia.blockscout.com/address/0xf5383E844C040312f2dCF6479C6cDf60FF7185dE) |

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
