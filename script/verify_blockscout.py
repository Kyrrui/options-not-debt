#!/usr/bin/env python3
"""Verify the deployed Vyper contracts on Blockscout (Sepolia).

forge verify-contract cannot drive Vyper verification on Windows (it wants a
forge-managed vyper binary, which has no Windows build), so this posts to
Blockscout's vyper-code verification endpoint directly.

Usage: python script/verify_blockscout.py
"""
import json
import sys
import time
import urllib.request

BASE = "https://eth-sepolia.blockscout.com/api/v2/smart-contracts"
COMPILER = "v0.4.3+commit.bff19ea2"
EVM_VERSION = "prague"  # forge config evm_version used at deploy
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"  # blockscout WAF blocks default UA

CONTRACTS = [
    {
        "address": "0x2993760Eda4B5249FB827A90724e9DBC5A94Ee62",
        "file": "src/OracleHub.vy",
        # constructor(address eth_usd_feed, uint256 eth_usd_heartbeat)
        "args": "000000000000000000000000694aa1769357215de4fac081bf1f309adc325306"
                "0000000000000000000000000000000000000000000000000000000000001c20",
    },
    {
        "address": "0x4Be934A244c25034546CF4a265db51b8943D248D",
        "file": "src/SeriesFactory.vy",
        # constructor(address hub, address series_blueprint, address token_blueprint)
        "args": "0000000000000000000000002993760eda4b5249fb827a90724e9dbc5a94ee62"
                "000000000000000000000000ee09c1d00777089d897058f06c6d471d792cfe35"
                "00000000000000000000000062ab76a68f5c95997aacc8e95b83d568e6a35a49",
    },
]


def verify(address: str, file: str, args: str) -> None:
    source = open(file, encoding="utf-8").read()
    body = json.dumps({
        "compiler_version": COMPILER,
        "source_code": source,
        "constructor_args": args,
        "evm_version": EVM_VERSION,
    }).encode()
    req = urllib.request.Request(
        f"{BASE}/{address}/verification/via/vyper-code",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": UA},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        print(file, "->", resp.status, resp.read().decode()[:200])


def status(address: str) -> str:
    req = urllib.request.Request(f"{BASE}/{address}", headers={"User-Agent": UA})
    with urllib.request.urlopen(req) as resp:
        d = json.loads(resp.read())
    return "verified" if d.get("is_verified") else "unverified"


if __name__ == "__main__":
    if len(sys.argv) > 1:  # optional: extra contracts from a JSON manifest
        CONTRACTS = json.load(open(sys.argv[1], encoding="utf-8"))
    for c in CONTRACTS:
        try:
            verify(c["address"], c["file"], c["args"])
        except Exception as e:  # noqa: BLE001
            print(c["file"], "-> submit failed:", e)
    print("waiting for verification workers...")
    time.sleep(30)
    ok = True
    for c in CONTRACTS:
        s = status(c["address"])
        print(c["address"], s)
        ok = ok and s == "verified"
    sys.exit(0 if ok else 1)
