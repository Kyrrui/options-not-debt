#!/usr/bin/env python3
"""Print initcode that deploys an EIP-5202 blueprint of a forge artifact.

Vyper's `create_from_blueprint` (default code_offset=3) consumes blueprints
whose runtime is 0xFE7100 || initcode. This wraps a compiled artifact's
creation bytecode in the standard 10-byte deploy stub.

Usage: python script/blueprint_initcode.py out/OptionToken.vy/OptionToken.json
"""
import json
import sys

artifact = json.load(open(sys.argv[1]))
initcode = artifact["bytecode"]["object"].removeprefix("0x")
runtime = "fe7100" + initcode
length = len(runtime) // 2
deployer = "0x61" + format(length, "04x") + "3d81600a3d39f3" + runtime
print(deployer)
