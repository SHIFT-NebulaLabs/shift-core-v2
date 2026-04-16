// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAddressRegistry}              from "src/interfaces/IAddressRegistry.sol";
import {ISyVault}                      from "src/interfaces/ISyVault.sol";
import {IERC7540Deposit, IERC7540Redeem} from "src/interfaces/IERC7540.sol";
import {VaultState}                    from "src/types/Types.sol";
import {
    AddressRegistry__NotAuthorized,
    AddressRegistry__ZeroAddress,
    AddressRegistry__VaultNotFound,
    AddressRegistry__IncompatibleVault
} from "src/types/Errors.sol";

/// @title  AddressRegistry
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Singleton address and vault state store.
/// @dev    Written exclusively by AdminGateway. No logic beyond storage and access control.
///         Hub, bots, and tooling read from here. Never holds funds.
contract AddressRegistry is IAddressRegistry {
    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice AdminGateway — the only address permitted to write to this registry.
    address private immutable i_adminGateway;

    /// @notice Total number of registered vaults.
    uint256 private s_vaultCount;

    /// @notice Maps vaultId → syVault address.
    mapping(uint256 vaultId => address syVault) private s_syVaults;

    /// @notice Maps vaultId → LiquidityPool address.
    mapping(uint256 vaultId => address liquidityPool) private s_liquidityPools;

    /// @notice Maps vaultId → syShare address.
    mapping(uint256 vaultId => address syShare) private s_syShares;

    /// @notice Maps vaultId → syOFTAdapter address (address(0) = single-chain).
    mapping(uint256 vaultId => address syOFT) private s_syOFTs;

    /// @notice Maps vaultId → current VaultState.
    mapping(uint256 vaultId => VaultState state) private s_vaultStates;

    /// @notice Maps vaultId → registration flag.
    mapping(uint256 vaultId => bool registered) private s_registered;

    /// @notice Maps bytes32 key → singleton contract address.
    mapping(bytes32 key => address addr) private s_contracts;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function to AdminGateway.
    modifier onlyAdminGateway() { _onlyAdminGateway(); _; }

    function _onlyAdminGateway() internal view {
        if (msg.sender != i_adminGateway) revert AddressRegistry__NotAuthorized();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _adminGateway  Address of the AdminGateway — immutable after deployment.
    constructor(address _adminGateway) {
        if (_adminGateway == address(0)) revert AddressRegistry__ZeroAddress();
        i_adminGateway = _adminGateway;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAddressRegistry
    function registerVault(
        address _syVault,
        address _liquidityPool,
        address _syShare,
        address _syOFT
    ) external onlyAdminGateway returns (uint256 _vaultId) {
        if (_syVault == address(0) || _liquidityPool == address(0) || _syShare == address(0)) {
            revert AddressRegistry__ZeroAddress();
        }

        // Validate that _syVault implements all required EIP-7540 and EIP-7575 interfaces.
        if (
            !ISyVault(_syVault).supportsInterface(type(IERC7540Deposit).interfaceId) ||
            !ISyVault(_syVault).supportsInterface(type(IERC7540Redeem).interfaceId)
        ) {
            revert AddressRegistry__IncompatibleVault();
        }

        _vaultId = ++s_vaultCount;

        s_registered[_vaultId]      = true;
        s_syVaults[_vaultId]        = _syVault;
        s_liquidityPools[_vaultId]  = _liquidityPool;
        s_syShares[_vaultId]        = _syShare;
        s_syOFTs[_vaultId]          = _syOFT;
        s_vaultStates[_vaultId]     = VaultState.Pending;

        emit VaultRegistered(_vaultId, _syVault, _liquidityPool, _syShare, _syOFT);
    }

    /// @inheritdoc IAddressRegistry
    function setVaultOft(uint256 _vaultId, address _syOFT) external onlyAdminGateway {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        address _old = s_syOFTs[_vaultId];
        s_syOFTs[_vaultId] = _syOFT;
        emit VaultOFTUpdated(_vaultId, _old, _syOFT);
    }

    /// @inheritdoc IAddressRegistry
    function setVaultState(uint256 _vaultId, VaultState _newState) external onlyAdminGateway {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        VaultState _old = s_vaultStates[_vaultId];
        s_vaultStates[_vaultId] = _newState;
        emit VaultStateChanged(_vaultId, _old, _newState);
    }

    /// @inheritdoc IAddressRegistry
    function setContractAddress(bytes32 _key, address _addr)
        external
        onlyAdminGateway
    {
        if (_addr == address(0)) revert AddressRegistry__ZeroAddress();
        address _old = s_contracts[_key];
        s_contracts[_key] = _addr;
        emit ContractAddressUpdated(_key, _old, _addr);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAddressRegistry
    function getSyVault(uint256 _vaultId) external view returns (address) {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        return s_syVaults[_vaultId];
    }

    /// @inheritdoc IAddressRegistry
    function getLiquidityPool(uint256 _vaultId) external view returns (address) {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        return s_liquidityPools[_vaultId];
    }

    /// @inheritdoc IAddressRegistry
    function getSyShare(uint256 _vaultId) external view returns (address) {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        return s_syShares[_vaultId];
    }

    /// @inheritdoc IAddressRegistry
    function getSyOft(uint256 _vaultId) external view returns (address) {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        return s_syOFTs[_vaultId];
    }

    /// @inheritdoc IAddressRegistry
    function getVaultState(uint256 _vaultId) external view returns (VaultState) {
        if (!s_registered[_vaultId]) revert AddressRegistry__VaultNotFound();
        return s_vaultStates[_vaultId];
    }

    /// @inheritdoc IAddressRegistry
    function getContractAddress(bytes32 _key) external view returns (address) {
        return s_contracts[_key];
    }

    /// @inheritdoc IAddressRegistry
    function vaultCount() external view returns (uint256) {
        return s_vaultCount;
    }

    /// @inheritdoc IAddressRegistry
    function adminGateway() external view returns (address) {
        return i_adminGateway;
    }
}
