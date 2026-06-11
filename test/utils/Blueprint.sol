// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Deploys EIP-5202 blueprint contracts (the format Vyper's
///         `create_from_blueprint` consumes with the default code_offset=3).
library Blueprint {
    /// @param initcode the creation bytecode of the contract to blueprint
    function deployBlueprint(bytes memory initcode) internal returns (address addr) {
        // EIP-5202 preamble: 0xFE (invalid), 0x71 (blueprint magic), 0x00 (version)
        bytes memory runtime = abi.encodePacked(hex"fe7100", initcode);
        // standard "return this runtime" deploy stub (10 bytes):
        // PUSH2 len | RETURNDATASIZE | DUP2 | PUSH1 0x0a | RETURNDATASIZE | CODECOPY | RETURN
        bytes memory deployer = abi.encodePacked(
            hex"61",
            uint16(runtime.length),
            hex"3d81600a3d39f3",
            runtime
        );
        assembly {
            addr := create(0, add(deployer, 0x20), mload(deployer))
        }
        require(addr != address(0), "blueprint deploy failed");
    }
}
