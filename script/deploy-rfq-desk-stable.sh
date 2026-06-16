#!/usr/bin/env bash
# Deploys a StableQuoteFiller (Solo spUSD RFQ Desk) for one peg on Sepolia.
#
#   KEY=0x<funded-deployer-key> ./script/deploy-rfq-desk-stable.sh            # dry run
#   KEY=0x<funded-deployer-key> BROADCAST=1 ./script/deploy-rfq-desk-stable.sh # send + verify
#
# STANDALONE (NOT a PeripheryFactory helper — it custodies the operator's ETH + spUSD
# inventory and has an owner). Sibling to the N-leg desk (SignedQuoteFiller); the spUSD
# (TrackerDAO) IS the spUSD ERC20, so TRACKER == the spUSD token. v1: USD-only,
# inventory-based (NO mint-to-sell). The constructor asserts the tracker's own oracle
# wiring (HUB/ASSET) matches what we pass (F6) — a mismatch reverts at deploy.
#
# Placeholders (reconcile before go-live): QUOTER + OWNER default to the deployer.
# Caps are tunable post-funding via set_caps; max_net_spusd is in spUSD UNITS (oracle-
# invariant), NOT an ETH mark. Inventory comes only from fund_spusd (operator transfers
# pre-held spUSD) — there is no mint path. Sepolia testnet, research code, unaudited.
set -euo pipefail

RPC=${RPC:-https://ethereum-sepolia-rpc.publicnode.com}
: "${KEY:?set KEY to a funded Sepolia private key}"

DEPLOYER=$(cast wallet address --private-key "$KEY")

# --- peg + oracle (spUSD on Sepolia) ---
TRACKER=${TRACKER:-0x80A229e1d85fd75511B889D0e7a2A8CA34f94FAE}   # spUSD TrackerDAO (= the spUSD ERC20)
HUB=${HUB:-0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62}           # OracleHub (must match TRACKER.HUB())
ASSET=${ASSET:-0x0000000000000000000000000000000000000000000000000000000000000000}  # USD sentinel (must match TRACKER.ASSET())

# --- desk control (placeholders; see header) ---
OWNER=${OWNER:-$DEPLOYER}
QUOTER=${QUOTER:-$DEPLOYER}

# --- immutable safety bounds ---
MIN_EDGE=${MIN_EDGE:-10000000000000000}             # 1% hard floor (>= within-window oracle drift, F-DRIFT)
DESK_MAX_STALENESS=${DESK_MAX_STALENESS:-3600}      # 1h: loosest the contract allows, suits Sepolia's slow feed. Use 300-600 on mainnet.
OUTFLOW_WINDOW=${OUTFLOW_WINDOW:-3600}              # 1h tumbling window

# --- caps (mutable via set_caps; tune after funding) ---
MAX_FILL=${MAX_FILL:-100000000000000000000}              # 100 spUSD (~$100) per fill
MAX_NET_SPUSD=${MAX_NET_SPUSD:-3000000000000000000000}   # 3000 spUSD UNITS (~$3k; below ~3 ETH until two-sided flow)
MIN_ETH_FLOAT=${MIN_ETH_FLOAT:-0}                        # ETH reserve floor on the buy side (operator tunes after funding)
MIN_SPUSD_FLOAT=${MIN_SPUSD_FLOAT:-0}                    # spUSD reserve floor on the sell side (operator tunes)
OUTFLOW_CAP=${OUTFLOW_CAP:-2000000000000000000}          # <=2 ETH paid out per window

CTOR_SIG="constructor(address,address,address,bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
ARGS=("$OWNER" "$TRACKER" "$HUB" "$ASSET" "$QUOTER" "$MIN_EDGE" "$DESK_MAX_STALENESS" "$OUTFLOW_WINDOW" "$MAX_FILL" "$MAX_NET_SPUSD" "$MIN_ETH_FLOAT" "$MIN_SPUSD_FLOAT" "$OUTFLOW_CAP")

echo "== build"
forge build > /dev/null

echo "== params"
echo "  owner=$OWNER"
echo "  quoter=$QUOTER  $([ "$QUOTER" = "$DEPLOYER" ] && echo '(PLACEHOLDER — set_quoter before go-live)')"
echo "  tracker=$TRACKER hub=$HUB asset=USD"
echo "  min_edge=$MIN_EDGE staleness=$DESK_MAX_STALENESS window=$OUTFLOW_WINDOW"
echo "  caps: max_fill=$MAX_FILL max_net_spusd(UNITS)=$MAX_NET_SPUSD min_eth_float=$MIN_ETH_FLOAT min_spusd_float=$MIN_SPUSD_FLOAT outflow_cap=$OUTFLOW_CAP"

CTOR_ARGS_HEX=$(cast abi-encode "$CTOR_SIG" "${ARGS[@]}" | sed 's/^0x//')

if [ "${BROADCAST:-0}" != "1" ]; then
  echo "== DRY RUN (set BROADCAST=1 to send). simulating forge create..."
  forge create src/periphery/StableQuoteFiller.vy:StableQuoteFiller \
    --rpc-url "$RPC" --private-key "$KEY" --constructor-args "${ARGS[@]}"
  echo "== ctor args (hex) for verification:"; echo "$CTOR_ARGS_HEX"
  exit 0
fi

echo "== DEPLOY (broadcast)"
ADDR=$(forge create src/periphery/StableQuoteFiller.vy:StableQuoteFiller \
  --rpc-url "$RPC" --private-key "$KEY" --broadcast --constructor-args "${ARGS[@]}" \
  | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | cut -d' ' -f3)
echo "StableQuoteFiller: $ADDR"

echo "== verify on Blockscout"
MANIFEST=$(mktemp)
printf '[{"address":"%s","file":"src/periphery/StableQuoteFiller.vy","args":"%s"}]' "$ADDR" "$CTOR_ARGS_HEX" > "$MANIFEST"
python script/verify_blockscout.py "$MANIFEST" || echo "(verification submit/poll failed — re-run later with the manifest)"

cat <<EOF

== done. record in docs/deployments.md:
StableQuoteFiller (spUSD stable desk): $ADDR
  owner:  $OWNER
  quoter: $QUOTER  $([ "$QUOTER" = "$DEPLOYER" ] && echo '<-- PLACEHOLDER')

next (operator):
  1. set_quoter(<real quoter-service key>)   (separate key from the N desk's, recommended)
  2. seed inventory: acquire spUSD via your EOA (deposit/pool), approve, then fund_spusd(<units>)
  3. fund ETH for the buy side: fund() --value <wei>
  4. tune: set_caps(max_fill, max_net_spusd(UNITS), min_eth_float, min_spusd_float, outflow_cap)
  5. (optional) transfer_ownership to the operator wallet
  6. add the operatorDesks.json entry with leg:"spUSD"
EOF
