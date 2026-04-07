// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  IHub
/// @author Shift Protocol
/// @notice Interface for Hub — singleton user entry point.
/// @dev    Validates vault state and forwards all user write calls to syVault.
///         Holds no funds. Stable integration address for all user-facing interactions.
///         View functions bypass Hub and go directly to syVault.

interface IHub {
    /*//////////////////////////////////////////////////////////////
                        DEPOSIT LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a deposit request to a vault.
    /// @dev    Validates vault is Active. Forwards to syVault.requestDeposit().
    /// @param  vaultId     Identifier of the target vault.
    /// @param  assets      Amount of underlying asset to deposit.
    /// @param  controller  Address that will own the request and can claim shares.
    /// @param  owner       Address whose assets are used.
    /// @return requestId   Current epoch — use as key for pending/claimable queries.
    function requestDeposit(uint256 vaultId, uint256 assets, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Cancel a pending deposit request.
    /// @dev    Always available — bypasses vault pause. Forwards to syVault.cancelDepositRequest().
    /// @param  vaultId    Identifier of the target vault.
    /// @param  requestId  Epoch at which the request was submitted.
    /// @param  controller Controller that owns the request.
    function cancelDepositRequest(uint256 vaultId, uint256 requestId, address controller) external;

    /// @notice Claim a settled deposit — mints shares to receiver.
    /// @dev    Validates vault is Active or Deprecated. Forwards to syVault.deposit().
    /// @param  vaultId     Identifier of the target vault.
    /// @param  assets      Claimable asset amount (pass 0 to claim all).
    /// @param  receiver    Address that will receive minted shares.
    /// @param  controller  Controller that owns the deposit request.
    /// @return shares      Shares minted.
    function deposit(uint256 vaultId, uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Claim a settled deposit by specifying exact shares.
    /// @dev    EIP-7540 compliance. Forwards to syVault.mint().
    /// @param  vaultId     Identifier of the target vault.
    /// @param  shares      Exact shares to mint.
    /// @param  receiver    Address that will receive minted shares.
    /// @param  controller  Controller that owns the deposit request.
    /// @return assets      Assets debited from claimable balance.
    function mint(uint256 vaultId, uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /*//////////////////////////////////////////////////////////////
                         REDEEM LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a normal redeem request (7-day cycle).
    /// @dev    Forwards to syVault.requestRedeem(). Reverts if past cycle cutoff.
    /// @param  vaultId     Identifier of the target vault.
    /// @param  shares      Shares to redeem.
    /// @param  controller  Address that will own the request and can claim assets.
    /// @param  owner       Address whose shares are locked.
    /// @return requestId   Current normal cycle id.
    function requestRedeem(uint256 vaultId, uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Cancel a pending normal redeem request.
    /// @dev    Always available until cycle lock. Forwards to syVault.cancelRedeemRequest().
    /// @param  vaultId    Identifier of the target vault.
    /// @param  requestId  Normal cycle id at which the request was submitted.
    /// @param  controller Controller that owns the request.
    function cancelRedeemRequest(uint256 vaultId, uint256 requestId, address controller) external;

    /// @notice Claim a settled normal redeem — transfers assets to receiver.
    /// @dev    Forwards to syVault.redeem().
    /// @param  vaultId     Identifier of the target vault.
    /// @param  shares      Shares to redeem.
    /// @param  receiver    Address that will receive assets.
    /// @param  controller  Controller that owns the request.
    /// @return assets      Assets transferred.
    function redeem(uint256 vaultId, uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claim a settled redeem by specifying exact assets.
    /// @dev    EIP-7540 compliance. Forwards to syVault.withdraw().
    /// @param  vaultId     Identifier of the target vault.
    /// @param  assets      Exact assets to receive.
    /// @param  receiver    Address that will receive assets.
    /// @param  controller  Controller that owns the request.
    /// @return shares      Shares burned.
    function withdraw(uint256 vaultId, uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /*//////////////////////////////////////////////////////////////
                       FAST REDEEM LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a fast redeem request (1-day cycle).
    /// @dev    Forwards to syVault.requestFastRedeem(). Reverts if any active redeem exists.
    /// @param  vaultId     Identifier of the target vault.
    /// @param  shares      Shares to fast-redeem.
    /// @param  controller  Address that will own the request and can claim assets.
    /// @param  owner       Address whose shares are locked.
    /// @return requestId   Current fast cycle id.
    function requestFastRedeem(uint256 vaultId, uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);


    /*//////////////////////////////////////////////////////////////
                           OPERATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Approve or revoke an operator on a vault.
    /// @dev    Forwards to syVault.setOperator(). EIP-7540 compliance.
    /// @param  vaultId   Identifier of the target vault.
    /// @param  operator  Address to approve or revoke.
    /// @param  approved  True to approve, false to revoke.
    /// @return           Always true.
    function setOperator(uint256 vaultId, address operator, bool approved)
        external
        returns (bool);

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the AddressRegistry address.
    function addressRegistry() external view returns (address);
}
