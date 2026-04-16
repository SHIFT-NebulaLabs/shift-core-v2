// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal interface for the CreateX factory.
/// @dev    Deployed at 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed on all supported chains.
///         Full docs: https://github.com/pcaversaccio/createx
interface ICreateX {
    /// @notice Deploy a contract via CREATE3 — address depends only on (msg.sender, salt).
    /// @dev    Salt encoding: bytes32(abi.encodePacked(deployer, bytes12(suffix))).
    ///         If the first 20 bytes of the salt equal msg.sender, only that address can use this salt.
    /// @param  salt      32-byte salt. First 20 bytes should be the deployer for front-run protection.
    /// @param  initCode  Creation bytecode + ABI-encoded constructor args.
    /// @return newContract  Address of the deployed contract.
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @notice Precompute the CREATE3 address for a given (deployer, salt) pair.
    function computeCreate3Address(bytes32 salt, address deployer) external view returns (address);
}
