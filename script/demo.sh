#!/usr/bin/env bash
# End-to-end lifecycle demo against a local anvil node.
# Prereqs: anvil running on 127.0.0.1:8545 and `script/Deploy.s.sol` broadcast.
# Usage: ./script/demo.sh <ETH_FEED> <SPUSD_DAO>
set -euo pipefail

RPC=${RPC:-http://127.0.0.1:8545}
# anvil default account 0
KEY=${KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ETH_FEED=$1
DAO=$2

say() { printf '\n== %s\n' "$1"; }
sp()  { cast call "$DAO" 'share_price()(uint256)' --rpc-url "$RPC"; }

say "1. deposit 10 ETH into spUSD (DAO keeps P, depositor gets N back)"
cast send "$DAO" 'deposit()' --value 10ether --private-key "$KEY" --rpc-url "$RPC" > /dev/null
ACTIVE=$(cast call "$DAO" 'active_series()(address)' --rpc-url "$RPC")
echo "active series: $ACTIVE"
echo "share price (1e18 = 1 USD): $(sp)"
echo "nav (USD, 1e18):            $(cast call "$DAO" 'nav()(uint256)' --rpc-url "$RPC")"

say "2. ETH doubles to \$5000 -> peg must hold"
cast send "$ETH_FEED" 'setAnswer(int256)' 500000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
echo "share price: $(sp)"

say "3. ETH crashes to \$1850 -> roll rule triggers"
cast send "$ETH_FEED" 'setAnswer(int256)' 185000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$DAO" 'sync()' --private-key "$KEY" --rpc-url "$RPC" > /dev/null
PENDING=$(cast call "$DAO" 'pending_series()(address)' --rpc-url "$RPC")
echo "pending (lower-strike) series: $PENDING"
echo "share price during roll: $(sp)"

say "4. arbitrageur fills the rotation auction"
NEWP=$(cast call "$PENDING" 'P()(address)' --rpc-url "$RPC")
QUOTE=$(cast call "$DAO" 'roll_quote(uint256)(uint256)' 10000000000000000000 --rpc-url "$RPC" | cut -d' ' -f1)
echo "new P required for 10e18 old P: $QUOTE"
cast send "$PENDING" 'split()' --value 16ether --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$NEWP" 'approve(address,uint256)' "$DAO" "$QUOTE" --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$DAO" 'fill_roll(uint256)' 10000000000000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
echo "active series now: $(cast call "$DAO" 'active_series()(address)' --rpc-url "$RPC")"
echo "share price after roll: $(sp)"

say "5. fast-forward past maturity; slow oracle settles lazily"
cast rpc evm_increaseTime 2500000 --rpc-url "$RPC" > /dev/null   # ~29 days
cast rpc evm_mine --rpc-url "$RPC" > /dev/null
# oracle keeps reporting (fresh update at the new chain time)
cast send "$ETH_FEED" 'setAnswer(int256)' 185000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$DAO" 'sync()' --private-key "$KEY" --rpc-url "$RPC" > /dev/null
echo "eth buffer after harvest: $(cast call "$DAO" 'eth_buffer()(uint256)' --rpc-url "$RPC")"
echo "share price after settle+harvest: $(sp)"

say "demo complete: split -> peg -> roll -> auction -> settle -> harvest, zero liquidations"
