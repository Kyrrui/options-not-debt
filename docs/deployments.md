# Deployments

## Sepolia (chain id 11155111) — deployed 2026-06-11

All contracts source-verified on Blockscout. Live Chainlink feeds; no mocks.

| Contract | Address |
|---|---|
| OracleHub | [`0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62`](https://eth-sepolia.blockscout.com/address/0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62) |
| SeriesFactory | [`0x4Be934A244c25034546CF4a265db51b8943D248D`](https://eth-sepolia.blockscout.com/address/0x4Be934A244c25034546CF4a265db51b8943D248D) |
| spUSD TrackerDAO | [`0xf35cFEf2Db231c84EEd74fd988918DE1f9062201`](https://eth-sepolia.blockscout.com/address/0xf35cFEf2Db231c84EEd74fd988918DE1f9062201) |
| spXAU TrackerDAO | [`0xBc9E4b726dE6DDCAFaE3f41FBA6411E6679F4916`](https://eth-sepolia.blockscout.com/address/0xBc9E4b726dE6DDCAFaE3f41FBA6411E6679F4916) |
| OptionToken blueprint (EIP-5202) | `0x62ab76a68f5c95997aacc8e95b83d568e6a35a49` |
| OptionSeries blueprint (EIP-5202) | `0xee09c1d00777089d897058f06c6d471d792cfe35` |
| spXAU genesis series | [`0xf9b96E06cC5C2ED2A0ae6A782aB769bA78e15483`](https://eth-sepolia.blockscout.com/address/0xf9b96E06cC5C2ED2A0ae6A782aB769bA78e15483) |
| └ P leg (OPT-P) | [`0x7B922CeeD469713207eff6b870DDDA0E0ba1C9C6`](https://eth-sepolia.blockscout.com/address/0x7B922CeeD469713207eff6b870DDDA0E0ba1C9C6) |
| └ N leg (OPT-N) | [`0x344ad9E2dF0669a1650CAd58F3D272fA9eec74b8`](https://eth-sepolia.blockscout.com/address/0x344ad9E2dF0669a1650CAd58F3D272fA9eec74b8) |

**Oracle configuration**

| Asset | Feed | Heartbeat | Asset id |
|---|---|---|---|
| USD (sentinel) | ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306` | 7200s | `0x0` |
| XAU | XAU/USD `0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea` | 259200s (weekend-safe) | `0x760a8d196beecadca683d6491e5ff4f706cf736083a97a44374cabb6481525ff` |

**Genesis state** (at deploy, ETH $1,676.19 / XAU $4,227.43 → x = 0.3966 oz/ETH):
spXAU genesis series strike `0.198251867104758153` oz/ETH (= x/2), maturity
2026-07-09; 0.01 ETH smoke deposit minted shares at `share_price == 1e18`
exactly — one share = one ounce, priced off live feeds.

DAO parameters (both wrappers): term 28d, roll window 7d, roll trigger 1.5×,
strike ratio 0.5×, auction duration 1d, max edge 2%.

Deployer (testnet throwaway): `0xBd4bFfe718f607ad52C30A5ECA3526306cB38e33`.
