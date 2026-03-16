// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAddressRegistry}   from "src/interfaces/IAddressRegistry.sol";
import {VaultState}         from "src/types/Types.sol";
import {ADMIN_ROLE, GUARDIAN_ROLE} from "src/types/Constants.sol";
import {ISyVault}           from "src/interfaces/ISyVault.sol";
import {AdminGateway__ZeroAddress, AdminGateway__InvalidTransition, AdminGateway__NotAuthorized} from "src/types/Errors.sol";

/// @title  AdminGateway
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Singleton governance contract. Wraps OZ TimelockController.
/// @dev    The ONLY contract authorised to write to AddressRegistry.
///         High-risk actions (role assignment, vault lifecycle, fee recipient) go through timelock.
///         Low-risk parameter changes (maxTVL, fees, whitelists) are immediate but ADMIN-gated.
///         GUARDIAN can immediately pause — no timelock. ADMIN unpauses.
///
///         Vault lifecycle valid transitions:
///           Pending  → Active      (ADMIN + timelock)
///           Active   → Deprecated  (ADMIN + timelock)
///           Deprecated → Closed    (ADMIN + timelock)
contract AdminGateway is TimelockController {
    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Singleton AddressRegistry — the only registry this gateway writes to.
    IAddressRegistry private immutable i_addressRegistry;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _minDelay         Minimum timelock delay for high-risk actions.
    /// @param _proposers        Addresses that can propose timelock operations (ADMIN multisig).
    /// @param _executors        Addresses that can execute passed proposals.
    /// @param _admin            Initial admin — should be address(0) after setup to prevent bypass.
    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev High-risk actions MUST be called via TimelockController self-execution.
    ///      When the timelock executes a scheduled operation on itself, msg.sender == address(this).
    modifier onlyTimelock() { _onlyTimelock(); _; }

    function _onlyTimelock() internal view {
        if (msg.sender != address(this)) revert AdminGateway__NotAuthorized();
    }

    /// @dev Low-risk parameter changes — ADMIN role, no timelock.
    modifier onlyAdmin() { _onlyAdmin(); _; }

    function _onlyAdmin() internal view {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert AdminGateway__NotAuthorized();
    }

    /// @dev Emergency pause — GUARDIAN role, no timelock. Immediate.
    modifier onlyGuardian() { _onlyGuardian(); _; }

    function _onlyGuardian() internal view {
        if (!hasRole(GUARDIAN_ROLE, msg.sender)) revert AdminGateway__NotAuthorized();
    }

    /// @param _addressRegistry  Address of the singleton AddressRegistry.
    constructor(
        uint256 _minDelay,
        address[] memory _proposers,
        address[] memory _executors,
        address _admin,
        address _addressRegistry
    ) TimelockController(_minDelay, _proposers, _executors, _admin) {
        if (_addressRegistry == address(0)) revert AdminGateway__ZeroAddress();
        i_addressRegistry = IAddressRegistry(_addressRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                   VAULT REGISTRATION — TIMELOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new vault cluster in the AddressRegistry.
    /// @dev    High-risk — must go through timelock. Only ADMIN can propose.
    ///         vaultId is auto-assigned by the registry and emitted in VaultRegistered.
    ///         _syVault is validated against required EIP-7540 interfaces via EIP-165.
    /// @param  _syVault        Address of the deployed syVault contract.
    /// @param  _liquidityPool  Address of the deployed LiquidityPool contract.
    /// @param  _syShare        Address of the deployed syShare token.
    /// @param  _syOFT          Address of the syOFTAdapter (address(0) for single-chain vaults).
    /// @return vaultId         Auto-assigned vault identifier.
    function registerVault(
        address _syVault,
        address _liquidityPool,
        address _syShare,
        address _syOFT
    ) external onlyTimelock returns (uint256 vaultId) {
        return i_addressRegistry.registerVault(_syVault, _liquidityPool, _syShare, _syOFT);
    }

    /// @notice Set or update the OFT adapter for an existing vault. High-risk — must go through timelock.
    /// @param  _vaultId  Vault identifier.
    /// @param  _syOFT    New OFT adapter address (address(0) to clear).
    function setVaultOft(uint256 _vaultId, address _syOFT) external onlyTimelock {
        i_addressRegistry.setVaultOft(_vaultId, _syOFT);
    }

    /*//////////////////////////////////////////////////////////////
                  VAULT LIFECYCLE — TIMELOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Transition a vault to a new lifecycle state.
    /// @dev    High-risk — must go through timelock.
    ///         Valid: Pending→Active, Active→Deprecated, Deprecated→Closed.
    /// @param  _vaultId   Vault identifier.
    /// @param  _newState  Target VaultState.
    function setVaultState(uint256 _vaultId, VaultState _newState)
        external
        onlyTimelock
    {
        VaultState _current = i_addressRegistry.getVaultState(_vaultId);
        _validateTransition(_current, _newState);
        i_addressRegistry.setVaultState(_vaultId, _newState);
    }

    /*//////////////////////////////////////////////////////////////
                    PAUSE — GUARDIAN (immediate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause deposits on a vault. Callable by any GUARDIAN — no timelock.
    function pauseVaultDeposits(uint256 _vaultId) external onlyGuardian {
        ISyVault(_getSyVault(_vaultId)).pauseDeposits();
    }

    /// @notice Pause redeems on a vault. Callable by any GUARDIAN — no timelock.
    function pauseVaultRedeems(uint256 _vaultId) external onlyGuardian {
        ISyVault(_getSyVault(_vaultId)).pauseRedeems();
    }

    /// @notice Full pause on a vault. Callable by any GUARDIAN — no timelock.
    function pauseVault(uint256 _vaultId) external onlyGuardian {
        ISyVault(_getSyVault(_vaultId)).pause();
    }

    /*//////////////////////////////////////////////////////////////
             EMERGENCY EPOCH SETTLE — GUARDIAN or ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle the current epoch using the previous share price. Emergency fallback.
    /// @dev    Callable by GUARDIAN or ADMIN — no timelock. Passes sharePrice = 0 to SyVault,
    ///         which uses the previous price. Use when the Keeper is down and deposits must be settled.
    function emergencyEpochSettle(uint256 _vaultId) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert AdminGateway__NotAuthorized();
        }
        ISyVault(_getSyVault(_vaultId)).epochSettle(0);
    }

    /*//////////////////////////////////////////////////////////////
                    UNPAUSE — ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Lift deposit pause. onlyAdmin.
    function unpauseVaultDeposits(uint256 _vaultId) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).unpauseDeposits();
    }

    /// @notice Lift redeem pause. onlyAdmin.
    function unpauseVaultRedeems(uint256 _vaultId) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).unpauseRedeems();
    }

    /// @notice Lift full pause. onlyAdmin.
    function unpauseVault(uint256 _vaultId) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).unpause();
    }

    /*//////////////////////////////////////////////////////////////
              ROLE SETTERS — ADMIN (immediate, operational)
    //////////////////////////////////////////////////////////////*/

    /// @notice Rotate the Keeper address for a vault. onlyAdmin.
    function setKeeper(uint256 _vaultId, address _keeper) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setKeeper(_keeper);
    }

    /// @notice Rotate the Allocator address for a vault. onlyAdmin.
    function setAllocator(uint256 _vaultId, address _allocator) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setAllocator(_allocator);
    }

    /// @notice Change the fee recipient. High-risk — must go through timelock.
    function setFeeRecipient(uint256 _vaultId, address _feeRecipient) external onlyTimelock {
        ISyVault(_getSyVault(_vaultId)).setFeeRecipient(_feeRecipient);
    }

    /*//////////////////////////////////////////////////////////////
              PARAMETER SETTERS — ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set maxTVL cap for a vault. onlyAdmin.
    function setMaxTvl(uint256 _vaultId, uint256 _maxTVL) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setMaxTvl(_maxTVL);
    }

    /// @notice Set minimum deposit amount for a vault (raw asset units). 0 = no minimum. onlyAdmin.
    function setMinDeposit(uint256 _vaultId, uint256 _minDeposit) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setMinDeposit(_minDeposit);
    }

    /// @notice Set max share price move per epoch (basis points). onlyAdmin.
    function setMaxSharePriceDelta(uint256 _vaultId, uint256 _delta) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setMaxSharePriceDelta(_delta);
    }

    /// @notice Set max stale price epochs before deposits are blocked. onlyAdmin.
    function setMaxStalePriceEpochs(uint256 _vaultId, uint256 _epochs) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setMaxStalePriceEpochs(_epochs);
    }

    /// @notice Set maintenance fee collection interval (epochs). onlyAdmin.
    function setMaintenanceFeeInterval(uint256 _vaultId, uint256 _interval) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setMaintenanceFeeInterval(_interval);
    }

    /*//////////////////////////////////////////////////////////////
          FEE SETTERS — TIMELOCK (high-risk, financial)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set performance fee in basis points. High-risk — must go through timelock.
    function setPerformanceFeeBps(uint256 _vaultId, uint256 _bps) external onlyTimelock {
        ISyVault(_getSyVault(_vaultId)).setPerformanceFeeBps(_bps);
    }

    /// @notice Set annualised maintenance fee in basis points. High-risk — must go through timelock.
    function setMaintenanceFeeBps(uint256 _vaultId, uint256 _bps) external onlyTimelock {
        ISyVault(_getSyVault(_vaultId)).setMaintenanceFeeBps(_bps);
    }

    /// @notice Set fast redeem fee in basis points. High-risk — must go through timelock.
    function setFastRedeemFeeBps(uint256 _vaultId, uint256 _bps) external onlyTimelock {
        ISyVault(_getSyVault(_vaultId)).setFastRedeemFeeBps(_bps);
    }

    /*//////////////////////////////////////////////////////////////
                    WHITELISTS — ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable or disable the deposit whitelist. onlyAdmin.
    function setDepositWhitelistEnabled(uint256 _vaultId, bool _enabled) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setDepositWhitelistEnabled(_enabled);
    }

    /// @notice Update a deposit whitelist entry. onlyAdmin.
    function setDepositWhitelist(uint256 _vaultId, address _account, bool _approved) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setDepositWhitelist(_account, _approved);
    }

    /// @notice Update a fast redeem fee exempt whitelist entry. onlyAdmin.
    function setFastRedeemFeeWhitelist(uint256 _vaultId, address _account, bool _approved) external onlyAdmin {
        ISyVault(_getSyVault(_vaultId)).setFastRedeemFeeWhitelist(_account, _approved);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolve syVault address for a given vaultId.
    function _getSyVault(uint256 _vaultId) internal view returns (address) {
        return i_addressRegistry.getSyVault(_vaultId);
    }

    /// @dev Revert if the lifecycle transition is not valid.
    function _validateTransition(VaultState _from, VaultState _to) internal pure {
        bool _valid = (
            (_from == VaultState.Pending    && _to == VaultState.Active)     ||
            (_from == VaultState.Active     && _to == VaultState.Deprecated) ||
            (_from == VaultState.Deprecated && _to == VaultState.Closed)
        );
        if (!_valid) revert AdminGateway__InvalidTransition();
    }
}
