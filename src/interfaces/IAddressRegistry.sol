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
    /// @param  syOFT           Address of the syOFTAdapter (address(0) if single-chain).
    event VaultRegistered(
        uint256 indexed vaultId,
        address syVault,
        address liquidityPool,
        address syShare,
        address syOFT
    );

    /// @notice Emitted when a vault's state transitions.
    /// @param  vaultId   Vault identifier.
    /// @param  oldState  Previous VaultState.
    /// @param  newState  New VaultState.
    event VaultStateChanged(uint256 indexed vaultId, VaultState oldState, VaultState newState);

    /// @notice Emitted when a vault's OFT adapter is set or updated.
    /// @param  vaultId  Vault identifier.
    /// @param  oldAddr  Previous OFT address (address(0) if unset).
    /// @param  newAddr  New OFT address (address(0) to clear).
    event VaultOFTUpdated(uint256 indexed vaultId, address oldAddr, address newAddr);

    /// @notice Emitted when a singleton contract address is updated.
    /// @param  key      bytes32 identifier (use CONTRACT_* constants).
    /// @param  oldAddr  Previous address.
    /// @param  newAddr  New address.
    event ContractAddressUpdated(bytes32 indexed key, address oldAddr, address newAddr);

    /*//////////////////////////////////////////////////////////////
                     ADMINGATEWAY — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new vault cluster. Only callable by AdminGateway.
    /// @dev    vaultId is auto-assigned as an incrementing counter starting at 1.
    ///         syVault is validated against required EIP-7540 interfaces via EIP-165.
    /// @param  syVault        Address of the syVault contract (must pass EIP-165 check).
    /// @param  liquidityPool  Address of the LiquidityPool contract.
    /// @param  syShare        Address of the syShare token contract.
    /// @param  syOFT          Address of the syOFTAdapter (pass address(0) for single-chain vaults).
    /// @return vaultId        Auto-assigned vault identifier.
    function registerVault(
        address syVault,
        address liquidityPool,
        address syShare,
        address syOFT
    ) external returns (uint256 vaultId);

    /// @notice Set or update the OFT adapter address for an existing vault. Only callable by AdminGateway.
    /// @dev    Pass address(0) to clear (downgrade to single-chain).
    /// @param  vaultId  Vault identifier.
    /// @param  syOFT    New OFT adapter address.
    function setVaultOft(uint256 vaultId, address syOFT) external;

    /// @notice Update the lifecycle state of a vault. Only callable by AdminGateway.
    /// @param  vaultId   Vault identifier.
    /// @param  newState  New VaultState.
    function setVaultState(uint256 vaultId, VaultState newState) external;

    /// @notice Update a singleton contract address. Only callable by AdminGateway.
    /// @param  key    bytes32 identifier — use CONTRACT_* constants from Constants.sol.
    /// @param  addr   New address.
    function setContractAddress(bytes32 key, address addr) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice syVault address for a given vault id.
    function getSyVault(uint256 vaultId) external view returns (address);

    /// @notice LiquidityPool address for a given vault id.
    function getLiquidityPool(uint256 vaultId) external view returns (address);

    /// @notice syShare address for a given vault id.
    function getSyShare(uint256 vaultId) external view returns (address);

    /// @notice syOFTAdapter address for a given vault id (address(0) if single-chain).
    function getSyOft(uint256 vaultId) external view returns (address);

    /// @notice Current lifecycle state of a vault.
    function getVaultState(uint256 vaultId) external view returns (VaultState);

    /// @notice Resolve a singleton contract address by key.
    /// @param  key  bytes32 identifier — use CONTRACT_* constants from Constants.sol.
    function getContractAddress(bytes32 key) external view returns (address);

    /// @notice Total number of registered vaults.
    function vaultCount() external view returns (uint256);

    /// @notice Address of the AdminGateway — the only writer.
    function adminGateway() external view returns (address);
}
