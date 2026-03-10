// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IHub}             from "src/interfaces/IHub.sol";
import {ISyVault}         from "src/interfaces/ISyVault.sol";
import {IAddressRegistry} from "src/interfaces/IAddressRegistry.sol";
import {VaultState}       from "src/types/Types.sol";
import {Hub__VaultNotActive, Hub__ZeroAddress, Hub__NotAuthorized} from "src/types/Errors.sol";

/// @title  Hub
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Singleton user entry point. Validates vault state and forwards write calls to syVault.
/// @dev    Holds no funds. All user-facing write functions pass through here.
///         Bot functions (epochSettle, settleRedeemBatch) call syVault directly.
///         All view functions bypass Hub and go directly to syVault.
///         The stable integration address — contract addresses below Hub can be upgraded
///         via AdminGateway without breaking user integrations.
contract Hub is IHub {
    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Singleton AddressRegistry — source of vault addresses and states.
    IAddressRegistry private immutable i_addressRegistry;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _addressRegistry  Address of the singleton AddressRegistry.
    constructor(address _addressRegistry) {
        if (_addressRegistry == address(0)) revert Hub__ZeroAddress();
        i_addressRegistry = IAddressRegistry(_addressRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHub
    function requestDeposit(uint256 _vaultId, uint256 _assets, address _controller, address _owner) external returns (uint256 requestId) {
        _requireActive(_vaultId);
        _requireOwnerOrOperator(_vaultId, _controller, _owner);
        return ISyVault(_getSyVault(_vaultId)).requestDeposit(_assets, _controller, _owner);
    }

    /// @inheritdoc IHub
    function cancelDepositRequest(uint256 _vaultId, uint256 _requestId, address _controller) external {
        // Cancel always available — no vault state check.
        ISyVault(_getSyVault(_vaultId)).cancelDepositRequest(_requestId, _controller);
    }

    /// @inheritdoc IHub
    function deposit(uint256 _vaultId, uint256 _assets, address _receiver, address _controller) external returns (uint256 shares) {
        _requireActiveOrDeprecated(_vaultId);
        return ISyVault(_getSyVault(_vaultId)).deposit(_assets, _receiver, _controller);
    }

    /// @inheritdoc IHub
    function mint(uint256 _vaultId, uint256 _shares, address _receiver, address _controller) external returns (uint256 assets) {
        _requireActiveOrDeprecated(_vaultId);
        return ISyVault(_getSyVault(_vaultId)).mint(_shares, _receiver, _controller);
    }

    /*//////////////////////////////////////////////////////////////
                         REDEEM LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHub
    function requestRedeem(uint256 _vaultId, uint256 _shares, address _controller, address _owner) external returns (uint256 requestId) {
        _requireActiveOrDeprecated(_vaultId);
        _requireOwnerOrOperator(_vaultId, _controller, _owner);
        return ISyVault(_getSyVault(_vaultId)).requestRedeem(_shares, _controller, _owner);
    }

    /// @inheritdoc IHub
    function cancelRedeemRequest(uint256 _vaultId, uint256 _requestId, address _controller) external {
        ISyVault(_getSyVault(_vaultId)).cancelRedeemRequest(_requestId, _controller);
    }

    /// @inheritdoc IHub
    function redeem(uint256 _vaultId, uint256 _shares, address _receiver, address _controller) external returns (uint256 assets) {
        _requireActiveOrDeprecated(_vaultId);
        return ISyVault(_getSyVault(_vaultId)).redeem(_shares, _receiver, _controller);
    }

    /// @inheritdoc IHub
    function withdraw(uint256 _vaultId, uint256 _assets, address _receiver, address _controller) external returns (uint256 shares) {
        _requireActiveOrDeprecated(_vaultId);
        return ISyVault(_getSyVault(_vaultId)).withdraw(_assets, _receiver, _controller);
    }

    /*//////////////////////////////////////////////////////////////
                       FAST REDEEM LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHub
    function requestFastRedeem(
        uint256 _vaultId,
        uint256 _shares,
        address _controller,
        address _owner
    ) external returns (uint256 requestId) {
        _requireActive(_vaultId);
        _requireOwnerOrOperator(_vaultId, _controller, _owner);
        return ISyVault(_getSyVault(_vaultId)).requestFastRedeem(_shares, _controller, _owner);
    }

    /// @inheritdoc IHub
    function cancelFastRedeemRequest(uint256 _vaultId, uint256 _requestId, address _controller) external {
        ISyVault(_getSyVault(_vaultId)).cancelFastRedeemRequest(_requestId, _controller);
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHub
    function setOperator(uint256 _vaultId, address _operator, bool _approved) external returns (bool) {
        // Pass msg.sender as controller — Hub is always msg.sender on syVault.
        return ISyVault(_getSyVault(_vaultId)).setOperator(msg.sender, _operator, _approved);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHub
    function addressRegistry() external view returns (address) {
        return address(i_addressRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolve syVault address for a given vaultId.
    function _getSyVault(uint256 _vaultId) internal view returns (address) {
        return i_addressRegistry.getSyVault(_vaultId);
    }

    /// @dev Revert if vault is not in Active state.
    function _requireActive(uint256 _vaultId) internal view {
        if (i_addressRegistry.getVaultState(_vaultId) != VaultState.Active) {
            revert Hub__VaultNotActive();
        }
    }

    /// @dev Revert if msg.sender is not the owner and not an approved operator of the controller.
    ///      EIP-7540: owner is the asset/share source; operator approval is on the controller.
    function _requireOwnerOrOperator(uint256 _vaultId, address _controller, address _owner) internal view {
        if (msg.sender != _owner) {
            if (!ISyVault(_getSyVault(_vaultId)).isOperator(_controller, msg.sender)) {
                revert Hub__NotAuthorized();
            }
        }
    }

    /// @dev Revert if vault is not Active or Deprecated (allows claims during deprecation).
    function _requireActiveOrDeprecated(uint256 _vaultId) internal view {
        VaultState _state = i_addressRegistry.getVaultState(_vaultId);
        if (_state != VaultState.Active && _state != VaultState.Deprecated) {
            revert Hub__VaultNotActive();
        }
    }
}
