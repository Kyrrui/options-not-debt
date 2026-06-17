#!/usr/bin/env bash
# Deploys the P1 debt-free SHORT stack on Sepolia: MockUSDC + a PutOptionSeries + the immutable
# ownerless GimbalShortVault that writes it.
#
#   KEY=0x<funded-deployer-key> ./script/deploy-short-stack.sh             # dry run
#   KEY=0x<funded-deployer-key> BROADCAST=1 ./script/deploy-short-stack.sh # send + verify
#
# All three are STANDALONE (not factory-deployed). The vault is IMMUTABLE: NO owner/admin/pause/
# upgrade/withdraw — every value is frozen at construction. Go-live = anyone mints MockUSDC, deposits
# to the vault, and buy_m's. v1: USD-only, single dated put series, one leverage tier.
#
# Sepolia testnet, research code, unaudited. See docs/handoffs/short-series-spec.md.
set -euo pipefail

RPC=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}
: "${KEY:?set KEY to a funded Sepolia private key}"
DEPLOYER=$(cast wallet address --private-key "$KEY")

HUB=${HUB:-0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62}
TOKEN_BLUEPRINT=${TOKEN_BLUEPRINT:-0x360b1f203f82f06709c5d7c9ec9d86993a3034c4}
# Set USDC to an existing stable (e.g. Circle's verified Sepolia USDC
# 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) to use it as collateral and SKIP the MockUSDC deploy.
USDC=${USDC:-}

# strike K = 1.25x live ETH/USD (a ~4x short tier; p < K so immediately writable), maturity 30d out
P=$(cast call "$HUB" 'latest_price(bytes32)(uint256)' 0x0000000000000000000000000000000000000000000000000000000000000000 --rpc-url "$RPC" | awk '{print $1}')
K=${STRIKE_K:-$(python -c "print(int($P)*5//4)")}
MATURITY=${MATURITY:-$(( $(date +%s) + 2592000 ))}

# immutable vault params (frozen). Face units are M/L (1e18); deposit cap is 18-dec (USDC*1e12).
BASE_EDGE=${BASE_EDGE:-20000000000000000}            # 2% (4x tier launch edge)
DESK_MAX_STALENESS=${DESK_MAX_STALENESS:-3600}
PRE_MATURITY_BUFFER=${PRE_MATURITY_BUFFER:-172800}   # 2 days
STRIKE_PROXIMITY=${STRIKE_PROXIMITY:-950000000000000000}   # 0.95e18 FLIPPED sub-UNIT band
MAX_FILL=${MAX_FILL:-500000000000000000000}          # 500 M face/fill
MAX_WRITTEN=${MAX_WRITTEN:-5000000000000000000000}   # 5000 M face total (capital-at-risk bound)
OUTFLOW_WINDOW=${OUTFLOW_WINDOW:-3600}
OUTFLOW_CAP=${OUTFLOW_CAP:-2000000000000000000000}   # 2000 M face/window
MAX_WRITE_PER_BLOCK=${MAX_WRITE_PER_BLOCK:-500000000000000000000}  # 500 M face/block
TOTAL_DEPOSIT_CAP=${TOTAL_DEPOSIT_CAP:-50000000000000000000000}    # 50,000 USDC (18-dec)

echo "== build"; forge build > /dev/null
echo "== params: ETH/USD p=$P  K(strike)=$K  maturity=$MATURITY  deployer=$DEPLOYER (no post-deploy privilege)"

if [ "${BROADCAST:-0}" != "1" ]; then
  echo "== DRY RUN (set BROADCAST=1 to send). simulating..."
  forge create src/mocks/MockUSDC.vy:MockUSDC --rpc-url "$RPC" --private-key "$KEY" | tail -1
  echo "  (PutOptionSeries + GimbalShortVault deploy after MockUSDC exists; run with BROADCAST=1)"
  exit 0
fi

USDC_DEPLOYED=0
if [ -z "$USDC" ]; then
  echo "== 1/3 deploy MockUSDC"
  USDC=$(forge create src/mocks/MockUSDC.vy:MockUSDC --rpc-url "$RPC" --private-key "$KEY" --broadcast \
    | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
  echo "  MockUSDC: $USDC"
  USDC_DEPLOYED=1
else
  echo "== 1/3 using existing stable: $USDC (skipping MockUSDC)"
fi

echo "== 2/3 deploy PutOptionSeries (hub, usdc, K, maturity, tokenBlueprint)"
SERIES=$(forge create src/PutOptionSeries.vy:PutOptionSeries --rpc-url "$RPC" --private-key "$KEY" --broadcast \
  --constructor-args "$HUB" "$USDC" "$K" "$MATURITY" "$TOKEN_BLUEPRINT" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
echo "  PutOptionSeries: $SERIES"

echo "== 3/3 deploy GimbalShortVault"
VARGS=("$SERIES" "$HUB" "$BASE_EDGE" "$DESK_MAX_STALENESS" "$PRE_MATURITY_BUFFER" "$STRIKE_PROXIMITY" "$MAX_FILL" "$MAX_WRITTEN" "$OUTFLOW_WINDOW" "$OUTFLOW_CAP" "$MAX_WRITE_PER_BLOCK" "$TOTAL_DEPOSIT_CAP")
VAULT=$(forge create src/periphery/GimbalShortVault.vy:GimbalShortVault --rpc-url "$RPC" --private-key "$KEY" --broadcast \
  --constructor-args "${VARGS[@]}" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
echo "  GimbalShortVault: $VAULT"

echo "== verify on Blockscout"
SERIES_ARGS=$(cast abi-encode "constructor(address,address,uint256,uint256,address)" "$HUB" "$USDC" "$K" "$MATURITY" "$TOKEN_BLUEPRINT" | sed 's/^0x//')
VAULT_ARGS=$(cast abi-encode "constructor(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" "${VARGS[@]}" | sed 's/^0x//')
MANIFEST=$(mktemp)
MOCK_ENTRY=""
if [ "$USDC_DEPLOYED" = "1" ]; then MOCK_ENTRY=$(printf '{"address":"%s","file":"src/mocks/MockUSDC.vy","args":""},' "$USDC"); fi
printf '[%s{"address":"%s","file":"src/PutOptionSeries.vy","args":"%s"},{"address":"%s","file":"src/periphery/GimbalShortVault.vy","args":"%s"}]' \
  "$MOCK_ENTRY" "$SERIES" "$SERIES_ARGS" "$VAULT" "$VAULT_ARGS" > "$MANIFEST"
python script/verify_blockscout.py "$MANIFEST" || echo "(verification submit/poll failed — re-run later with the manifest)"

cat <<EOF

== done. record in docs/deployments.md:
MockUSDC:          $USDC   (6-dec, open faucet mint())
PutOptionSeries:   $SERIES   (K=$K, maturity=$MATURITY)
GimbalShortVault:  $VAULT   (IMMUTABLE; go-live = mint USDC -> deposit() -> buy_m())
EOF
