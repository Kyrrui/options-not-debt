#!/usr/bin/env bash
# Deploys the stack to Sepolia against REAL Chainlink feeds (no mocks),
# registers gold, and spins up spUSD + spXAU wrapper DAOs.
#
#   KEY=0x<funded-deployer-key> ./script/deploy-sepolia.sh
#
# Feeds (verified live on-chain, docs.chain.link):
#   ETH/USD 0x694AA1769357215DE4FAC081bf1f309aDC325306 (8 dec, ~1h heartbeat)
#   XAU/USD 0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea (8 dec, daily + weekend gaps)
set -euo pipefail

RPC=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}
: "${KEY:?set KEY to a funded Sepolia private key}"

ETH_FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306
XAU_FEED=0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea
ETH_HEARTBEAT=7200      # 1h feed + 1h margin (testnet feeds lapse)
XAU_HEARTBEAT=259200    # daily feed + weekend gap margin (72h)

CREATE_FLAGS=(--rpc-url "$RPC" --private-key "$KEY" --broadcast)

deployed() { grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3; }

forge build > /dev/null

echo "== EIP-5202 blueprints"
TOKEN_BP_INIT=$(python script/blueprint_initcode.py out/OptionToken.vy/OptionToken.json)
SERIES_BP_INIT=$(python script/blueprint_initcode.py out/OptionSeries.vy/OptionSeries.json)
TOKEN_BP=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$TOKEN_BP_INIT" | grep -oE '"contractAddress":"0x[0-9a-fA-F]{40}"' | cut -d'"' -f4)
SERIES_BP=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$SERIES_BP_INIT" | grep -oE '"contractAddress":"0x[0-9a-fA-F]{40}"' | cut -d'"' -f4)
echo "token blueprint:  $TOKEN_BP"
echo "series blueprint: $SERIES_BP"

echo "== core contracts"
HUB=$(forge create src/OracleHub.vy:OracleHub "${CREATE_FLAGS[@]}" --constructor-args "$ETH_FEED" "$ETH_HEARTBEAT" | deployed)
FACTORY=$(forge create src/SeriesFactory.vy:SeriesFactory "${CREATE_FLAGS[@]}" --constructor-args "$HUB" "$SERIES_BP" "$TOKEN_BP" | deployed)
echo "OracleHub:     $HUB"
echo "SeriesFactory: $FACTORY"

echo "== register gold (permissionless, content-addressed)"
cast send "$HUB" 'register(address,uint256,string)' "$XAU_FEED" "$XAU_HEARTBEAT" "XAU" --rpc-url "$RPC" --private-key "$KEY" > /dev/null
XAU_ID=$(cast call "$HUB" 'asset_id(address,uint256)(bytes32)' "$XAU_FEED" "$XAU_HEARTBEAT" --rpc-url "$RPC")
USD_ID=0x0000000000000000000000000000000000000000000000000000000000000000
echo "XAU asset id: $XAU_ID"

echo "== wrapper DAOs (term 28d, roll window 7d, trigger 1.5x, strike 0.5x, auction 1d, edge 2%)"
DAO_TAIL=(2419200 604800 1500000000000000000 500000000000000000 86400 20000000000000000)
SPUSD=$(forge create src/TrackerDAO.vy:TrackerDAO "${CREATE_FLAGS[@]}" --constructor-args "Soft Peg USD" "spUSD" "$HUB" "$FACTORY" "$USD_ID" "${DAO_TAIL[@]}" | deployed)
SPXAU=$(forge create src/TrackerDAO.vy:TrackerDAO "${CREATE_FLAGS[@]}" --constructor-args "Soft Peg Gold" "spXAU" "$HUB" "$FACTORY" "$XAU_ID" "${DAO_TAIL[@]}" | deployed)
echo "spUSD DAO: $SPUSD"
echo "spXAU DAO: $SPXAU"

echo "== smoke: 0.01 ETH deposit into spXAU"
cast send "$SPXAU" 'deposit()' --value 10000000000000000 --rpc-url "$RPC" --private-key "$KEY" > /dev/null
echo "share_price (1e18 = 1 oz): $(cast call "$SPXAU" 'share_price()(uint256)' --rpc-url "$RPC")"
echo "active series:             $(cast call "$SPXAU" 'active_series()(address)' --rpc-url "$RPC")"

cat <<EOF

== done. record these in docs/deployments.md:
network:        sepolia (11155111)
OracleHub:      $HUB
SeriesFactory:  $FACTORY
token bp:       $TOKEN_BP
series bp:      $SERIES_BP
XAU asset id:   $XAU_ID
spUSD DAO:      $SPUSD
spXAU DAO:      $SPXAU
EOF
