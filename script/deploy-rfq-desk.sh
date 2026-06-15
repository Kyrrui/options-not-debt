#!/usr/bin/env bash
# Deploys a SignedQuoteFiller (Solo RFQ Desk) for one peg on Sepolia.
#
#   KEY=0x<funded-deployer-key> ./script/deploy-rfq-desk.sh            # dry run
#   KEY=0x<funded-deployer-key> BROADCAST=1 ./script/deploy-rfq-desk.sh # send + verify
#
# STANDALONE — NOT via PeripheryFactory: the desk holds the operator's funds, so it
# is not a stateless factory helper (one desk per operator-per-peg). v1: USD-only
# (spUSD), N-only.
#
# Two values default to the DEPLOYER and must be reconciled before go-live:
#   * QUOTER  — set to the deployer as a PLACEHOLDER. The operator MUST call
#               set_quoter(<the quoter-service key's address>) before serving quotes.
#   * OWNER   — the deployer controls the desk (fund/withdraw/pause/set_quoter/
#               set_caps); transfer_ownership(<operator wallet>) to hand it off.
# The desk also needs fund()/fund_p() before it can fill, and caps are tunable
# post-deploy via set_caps. Sepolia testnet, research code, unaudited.
set -euo pipefail

RPC=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}
: "${KEY:?set KEY to a funded Sepolia private key}"

DEPLOYER=$(cast wallet address --private-key "$KEY")

# --- peg + oracle (spUSD on Sepolia) ---
TRACKER=${TRACKER:-0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE}   # spUSD TrackerDAO
HUB=${HUB:-0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62}           # OracleHub
ASSET=${ASSET:-0x0000000000000000000000000000000000000000000000000000000000000000}  # USD sentinel

# --- desk control (placeholders; see header) ---
OWNER=${OWNER:-$DEPLOYER}
QUOTER=${QUOTER:-$DEPLOYER}

# --- immutable safety bounds ---
MIN_EDGE=${MIN_EDGE:-10000000000000000}             # 1% hard floor (spec launch min_edge)
DESK_MAX_STALENESS=${DESK_MAX_STALENESS:-3600}      # 1h: loosest the contract allows, suits Sepolia's slow feed. Use 300-600 on mainnet.
PRE_MATURITY_BUFFER=${PRE_MATURITY_BUFFER:-172800}  # 2 days (inside spUSD's 7d roll window)
OUTFLOW_WINDOW=${OUTFLOW_WINDOW:-3600}              # 1h tumbling window
# strike_proximity MUST be >= the tracker's ROLL_TRIGGER — read it on-chain
STRIKE_PROXIMITY=${STRIKE_PROXIMITY:-$(cast call "$TRACKER" 'ROLL_TRIGGER()(uint256)' --rpc-url "$RPC" | awk '{print $1}')}

# --- caps (mutable via set_caps; tune after funding) ---
MAX_FILL=${MAX_FILL:-100000000000000000}                 # 0.1 N per fill
MAX_NAV_AT_RISK=${MAX_NAV_AT_RISK:-3000000000000000000}  # 3 ETH net-long-N risk budget
MIN_ETH_FLOAT=${MIN_ETH_FLOAT:-1000000000000000000}      # keep >=1 ETH liquid for sell-N payouts
OUTFLOW_CAP=${OUTFLOW_CAP:-2000000000000000000}          # <=2 ETH committed per window

CTOR_SIG="constructor(address,address,address,bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
ARGS=("$OWNER" "$TRACKER" "$HUB" "$ASSET" "$QUOTER" "$MIN_EDGE" "$DESK_MAX_STALENESS" "$PRE_MATURITY_BUFFER" "$STRIKE_PROXIMITY" "$OUTFLOW_WINDOW" "$MAX_FILL" "$MAX_NAV_AT_RISK" "$MIN_ETH_FLOAT" "$OUTFLOW_CAP")

echo "== build"
forge build > /dev/null

echo "== params"
echo "  owner=$OWNER"
echo "  quoter=$QUOTER  $([ "$QUOTER" = "$DEPLOYER" ] && echo '(PLACEHOLDER — set_quoter before go-live)')"
echo "  tracker=$TRACKER hub=$HUB asset=USD strike_proximity=$STRIKE_PROXIMITY"
echo "  min_edge=$MIN_EDGE staleness=$DESK_MAX_STALENESS buffer=$PRE_MATURITY_BUFFER window=$OUTFLOW_WINDOW"
echo "  caps: max_fill=$MAX_FILL max_nav_at_risk=$MAX_NAV_AT_RISK min_eth_float=$MIN_ETH_FLOAT outflow_cap=$OUTFLOW_CAP"

# abi-encoded constructor args (for Blockscout verification), no 0x prefix
CTOR_ARGS_HEX=$(cast abi-encode "$CTOR_SIG" "${ARGS[@]}" | sed 's/^0x//')

if [ "${BROADCAST:-0}" != "1" ]; then
  echo "== DRY RUN (set BROADCAST=1 to send). simulating forge create..."
  forge create src/periphery/SignedQuoteFiller.vy:SignedQuoteFiller \
    --rpc-url "$RPC" --private-key "$KEY" --constructor-args "${ARGS[@]}"
  echo "== ctor args (hex) for verification:"
  echo "$CTOR_ARGS_HEX"
  exit 0
fi

echo "== DEPLOY (broadcast)"
ADDR=$(forge create src/periphery/SignedQuoteFiller.vy:SignedQuoteFiller \
  --rpc-url "$RPC" --private-key "$KEY" --broadcast --constructor-args "${ARGS[@]}" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
echo "SignedQuoteFiller: $ADDR"

echo "== verify on Blockscout"
MANIFEST=$(mktemp)
printf '[{"address":"%s","file":"src/periphery/SignedQuoteFiller.vy","args":"%s"}]' "$ADDR" "$CTOR_ARGS_HEX" > "$MANIFEST"
python script/verify_blockscout.py "$MANIFEST" || echo "(verification submit/poll failed — re-run later with the manifest)"

cat <<EOF

== done. record in docs/deployments.md:
SignedQuoteFiller (spUSD solo RFQ desk): $ADDR
  owner:  $OWNER
  quoter: $QUOTER  $([ "$QUOTER" = "$DEPLOYER" ] && echo '<-- PLACEHOLDER')

next (operator):
  1. generate the quoter-service key, then: cast send $ADDR 'set_quoter(address)' <quoterAddr> --private-key \$OWNER_KEY
  2. fund:  cast send $ADDR 'fund()' --value <wei>   (and fund_p for mergeable P inventory)
  3. tune:  cast send $ADDR 'set_caps(uint256,uint256,uint256,uint256)' <max_fill> <max_nav> <min_float> <outflow_cap>
  4. (optional) transfer_ownership to the operator wallet
  5. add the operatorDesks.json entry for the frontend
EOF
