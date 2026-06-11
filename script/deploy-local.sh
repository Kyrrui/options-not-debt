#!/usr/bin/env bash
# Deploys the full stack to a local anvil node with mock Chainlink feeds,
# registers gold (XAU) as an RWA, and spins up spUSD + spXAU wrapper DAOs.
#
#   anvil                      # terminal 1
#   ./script/deploy-local.sh   # terminal 2
#
# For a public testnet, set RPC/KEY and replace the mock feeds with the
# canonical Chainlink aggregator addresses for the target network.
set -euo pipefail

RPC=${RPC:-http://127.0.0.1:8545}
KEY=${KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}

CREATE_FLAGS=(--rpc-url "$RPC" --private-key "$KEY" --broadcast)

deployed() { grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3; }

forge build > /dev/null

echo "== mock Chainlink feeds (ETH/USD \$2500, XAU/USD \$2500)"
ETH_FEED=$(forge create test/mocks/MockV3Aggregator.sol:MockV3Aggregator "${CREATE_FLAGS[@]}" --constructor-args 8 250000000000 | deployed)
XAU_FEED=$(forge create test/mocks/MockV3Aggregator.sol:MockV3Aggregator "${CREATE_FLAGS[@]}" --constructor-args 8 250000000000 | deployed)
echo "ETH/USD: $ETH_FEED"
echo "XAU/USD: $XAU_FEED"

echo "== EIP-5202 blueprints"
TOKEN_BP_INIT=$(python script/blueprint_initcode.py out/OptionToken.vy/OptionToken.json)
SERIES_BP_INIT=$(python script/blueprint_initcode.py out/OptionSeries.vy/OptionSeries.json)
TOKEN_BP=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$TOKEN_BP_INIT" | grep -oE '"contractAddress":"0x[0-9a-fA-F]{40}"' | cut -d'"' -f4)
SERIES_BP=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$SERIES_BP_INIT" | grep -oE '"contractAddress":"0x[0-9a-fA-F]{40}"' | cut -d'"' -f4)
echo "token blueprint:  $TOKEN_BP"
echo "series blueprint: $SERIES_BP"

echo "== core contracts"
HUB=$(forge create src/OracleHub.vy:OracleHub "${CREATE_FLAGS[@]}" --constructor-args "$ETH_FEED" 3600 | deployed)
FACTORY=$(forge create src/SeriesFactory.vy:SeriesFactory "${CREATE_FLAGS[@]}" --constructor-args "$HUB" "$SERIES_BP" "$TOKEN_BP" | deployed)
echo "OracleHub:     $HUB"
echo "SeriesFactory: $FACTORY"

echo "== register gold (permissionless, content-addressed by feed+heartbeat)"
cast send "$HUB" 'register(address,uint256,string)' "$XAU_FEED" 86400 "XAU" --rpc-url "$RPC" --private-key "$KEY" > /dev/null
XAU_ID=$(cast call "$HUB" 'asset_id(address,uint256)(bytes32)' "$XAU_FEED" 86400 --rpc-url "$RPC")
USD_ID=0x0000000000000000000000000000000000000000000000000000000000000000
echo "XAU asset id: $XAU_ID"

echo "== wrapper DAOs (term 28d, roll window 7d, trigger 1.5x, strike 0.5x, auction 1d, edge 2%)"
DAO_ARGS=("$HUB" "$FACTORY" 2419200 604800 1500000000000000000 500000000000000000 86400 20000000000000000)
SPUSD=$(forge create src/TrackerDAO.vy:TrackerDAO "${CREATE_FLAGS[@]}" --constructor-args "Soft Peg USD" "spUSD" "${DAO_ARGS[0]}" "${DAO_ARGS[1]}" "$USD_ID" "${DAO_ARGS[@]:2}" | deployed)
SPXAU=$(forge create src/TrackerDAO.vy:TrackerDAO "${CREATE_FLAGS[@]}" --constructor-args "Soft Peg Gold" "spXAU" "${DAO_ARGS[0]}" "${DAO_ARGS[1]}" "$XAU_ID" "${DAO_ARGS[@]:2}" | deployed)
echo "spUSD DAO: $SPUSD"
echo "spXAU DAO: $SPXAU"

cat <<EOF

deployment complete.
run the lifecycle demo with:
  ./script/demo.sh $ETH_FEED $SPUSD
EOF
