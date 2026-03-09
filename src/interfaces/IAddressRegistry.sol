// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {VaultState} from "src/types/Types.sol";

/// @title  IAddressRegistry
/// @author Shift Protocol
/// @notice Interface for AddressRegistry — singleton address and vault state store.
/// @dev    Written exclusively by AdminGateway. Read by Hub, bots, and tooling.
///         No logic — pure storage with access control.

interface IAddressRegistry {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new vault cluster is registered.
    /// @param  vaultId         Vault identifier.
    /// @param  syVault         Address of the syVault contract.
    /// @param  liquidityPool   Address of the LiquidityPool contract.
    /// @param  syShare         Address of the syShare token contract.
    event VaultRegistered(
        uint256 indexed vaultId,
        address syVault,
        address liquidityPool,
        address syShare
    );

    /// @notice Emitted when a vault's state transitions.
    /// @param  vaultId   Vault identifier.
    /// @param  oldState  Previous VaultState.
    /// @param  newState  New VaultState.
    event VaultStateChanged(uint256 indexed vaultId, VaultState oldState, VaultState newState);

    /// @notice Emitted when a singleton contract address is updated.
    /// @param  name     Human-readable contract name.
    /// @param  oldAddr  Previous address.
    /// @param  newAddr  New address.
    event ContractAddressUpdated(string name, address oldAddr, address newAddr);

    /*//////////////////////////////////////////////////////////////
                     ADMINGATEWAY — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new vault cluster. Only callable by AdminGateway.
    /// @param  vaultId        Vault identifier.
    /// @param  syVault        Address of the syVault contract.
    /// @param  liquidityPool  Address of the LiquidityPool contract.
    /// @param  syShare        Address of the syShare token contract.
    function registerVault(
        uint256 vaultId,
        address syVault,
        address liquidityPool,
        address syShare
    ) external;

    /// @notice Update the lifecycle state of a vault. Only callable by AdminGateway.
    /// @param  vaultId   Vault identifier.
    /// @param  newState  New VaultState.
    function setVaultState(uint256 vaultId, VaultState newState) external;

    /// @notice Update a singleton contract address. Only callable by AdminGateway.
    /// @param  name   Human-readable identifier (e.g. "Hub", "AdminGateway").
    /// @param  addr   New address.
    function setContractAddress(string calldata name, address addr) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice syVault address for a given vault id.
    function getSyVault(uint256 vaultId) external view returns (address);

    /// @notice LiquidityPool address for a given vault id.
    function getLiquidityPool(uint256 vaultId) external view returns (address);

    /// @notice syShare address for a given vault id.
    function getSyShare(uint256 vaultId) external view returns (address);

    /// @notice Current lifecycle state of a vault.
    function getVaultState(uint256 vaultId) external view returns (VaultState);

    /// @notice Resolve a singleton contract address by name.
    function getContractAddress(string calldata name) external view returns (address);

    /// @notice Total number of registered vaults.
    function vaultCount() external view returns (uint256);

    /// @notice Address of the AdminGateway — the only writer.
    function adminGateway() external view returns (address);
}
