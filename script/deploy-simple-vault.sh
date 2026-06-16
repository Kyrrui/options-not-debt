#!/usr/bin/env bash
# Deploys GimbalSimpleVault (the minimal immutable, ownerless, crowd-funded house) on Sepolia.
#
#   KEY=0x<funded-deployer-key> ./script/deploy-simple-vault.sh             # dry run
#   KEY=0x<funded-deployer-key> BROADCAST=1 ./script/deploy-simple-vault.sh # send + verify
#
# STANDALONE — NOT via PeripheryFactory (it custodies pooled LP funds). It is IMMUTABLE:
# there is NO owner, NO quoter, NO admin, NO pause, NO upgrade, NO withdraw. EVERY value
# below is frozen at construction forever — there is no set_* to fix a mistake; a bad
# param means redeploy. "Go-live" is simply: anyone calls deposit() to fund it and buy_n()
# to trade. v1: USD-only (spUSD), N-only, writes the tracker's current ~2x series.
#
# Sepolia testnet, research code, unaudited. See docs/handoffs/simple-vault-sepolia-spec.md
# (incl. the MAINNET CHECKLIST — do NOT deploy this as-is to mainnet).
set -euo pipefail

RPC=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}
: "${KEY:?set KEY to a funded Sepolia private key}"

DEPLOYER=$(cast wallet address --private-key "$KEY")

# --- peg + oracle (spUSD on Sepolia) ---
TRACKER=${TRACKER:-0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE}   # spUSD TrackerDAO (current-series source)
HUB=${HUB:-0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62}           # OracleHub
ASSET=${ASSET:-0x0000000000000000000000000000000000000000000000000000000000000000}  # USD sentinel

# --- immutable pricing / safety bounds (FROZEN — no setter) ---
BASE_EDGE=${BASE_EDGE:-20000000000000000}           # 2% house spread over intrinsic (wider than a signer: the ownerless cost)
DESK_MAX_STALENESS=${DESK_MAX_STALENESS:-3600}      # 1h tight ETH/USD freshness; suits Sepolia's slow feed. Use 300-600 on mainnet.
PRE_MATURITY_BUFFER=${PRE_MATURITY_BUFFER:-604800}  # 7 days == spUSD ROLL_WINDOW: stop writing exactly when the tracker starts rolling
OUTFLOW_WINDOW=${OUTFLOW_WINDOW:-3600}              # 1h tumbling written-face window
# strike_proximity MUST be >= the tracker's ROLL_TRIGGER — read it on-chain
STRIKE_PROXIMITY=${STRIKE_PROXIMITY:-$(cast call "$TRACKER" 'ROLL_TRIGGER()(uint256)' --rpc-url "$RPC" | awk '{print $1}')}

# --- immutable caps (FROZEN — tiny Sepolia blast-radius bounds) ---
MAX_FILL=${MAX_FILL:-500000000000000000}                  # 0.5 N face per fill
MAX_WRITTEN=${MAX_WRITTEN:-3000000000000000000}           # 3 ETH total written-face (capital-at-risk bound)
OUTFLOW_CAP=${OUTFLOW_CAP:-1000000000000000000}           # <=1 ETH face written per window
MAX_WRITE_PER_BLOCK=${MAX_WRITE_PER_BLOCK:-500000000000000000}  # 0.5 ETH face per block (atomic-extraction bound)
TOTAL_DEPOSIT_CAP=${TOTAL_DEPOSIT_CAP:-10000000000000000000}    # 10 ETH gross deposit cap

# ctor: (tracker, hub, asset, base_edge, desk_max_staleness, pre_maturity_buffer, strike_proximity,
#        max_fill, max_written, outflow_window, outflow_cap, max_write_per_block, total_deposit_cap)
CTOR_SIG="constructor(address,address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
ARGS=("$TRACKER" "$HUB" "$ASSET" "$BASE_EDGE" "$DESK_MAX_STALENESS" "$PRE_MATURITY_BUFFER" "$STRIKE_PROXIMITY" "$MAX_FILL" "$MAX_WRITTEN" "$OUTFLOW_WINDOW" "$OUTFLOW_CAP" "$MAX_WRITE_PER_BLOCK" "$TOTAL_DEPOSIT_CAP")

echo "== build"
forge build > /dev/null

echo "== params (ALL IMMUTABLE — frozen forever)"
echo "  deployer=$DEPLOYER (holds NO privilege post-deploy)"
echo "  tracker=$TRACKER hub=$HUB asset=USD strike_proximity=$STRIKE_PROXIMITY"
echo "  base_edge=$BASE_EDGE staleness=$DESK_MAX_STALENESS buffer=$PRE_MATURITY_BUFFER window=$OUTFLOW_WINDOW"
echo "  caps: max_fill=$MAX_FILL max_written=$MAX_WRITTEN outflow_cap=$OUTFLOW_CAP max_write_per_block=$MAX_WRITE_PER_BLOCK total_deposit_cap=$TOTAL_DEPOSIT_CAP"

CTOR_ARGS_HEX=$(cast abi-encode "$CTOR_SIG" "${ARGS[@]}" | sed 's/^0x//')

if [ "${BROADCAST:-0}" != "1" ]; then
  echo "== DRY RUN (set BROADCAST=1 to send). simulating forge create..."
  forge create src/periphery/GimbalSimpleVault.vy:GimbalSimpleVault \
    --rpc-url "$RPC" --private-key "$KEY" --constructor-args "${ARGS[@]}"
  echo "== ctor args (hex) for verification:"
  echo "$CTOR_ARGS_HEX"
  exit 0
fi

echo "== DEPLOY (broadcast)"
ADDR=$(forge create src/periphery/GimbalSimpleVault.vy:GimbalSimpleVault \
  --rpc-url "$RPC" --private-key "$KEY" --broadcast --constructor-args "${ARGS[@]}" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
echo "GimbalSimpleVault: $ADDR"

echo "== verify on Blockscout"
MANIFEST=$(mktemp)
printf '[{"address":"%s","file":"src/periphery/GimbalSimpleVault.vy","args":"%s"}]' "$ADDR" "$CTOR_ARGS_HEX" > "$MANIFEST"
python script/verify_blockscout.py "$MANIFEST" || echo "(verification submit/poll failed — re-run later with the manifest)"

cat <<EOF

== done. record in docs/deployments.md:
GimbalSimpleVault (spUSD immutable house): $ADDR
  IMMUTABLE — no owner, no admin. Go-live = anyone calls deposit() to fund + buy_n() to trade.
EOF
