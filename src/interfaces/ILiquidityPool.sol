// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  ILiquidityPool
/// @author Shift Protocol
/// @notice Interface for LiquidityPool — per-vault asset custody contract.
/// @dev    Holds non-deployed assets. Releases funds only on syVault authorisation.
///         deployCapital() and returnCapital() are nonReentrant.

interface ILiquidityPool {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the Allocator deploys capital from the pool.
    /// @param  amount     Assets deployed.
    /// @param  timestamp  block.timestamp at deployment.
    event CapitalDeployed(uint256 amount, uint256 timestamp);

    /// @notice Emitted when the Allocator returns capital to the pool.
    /// @param  amount     Assets returned.
    /// @param  timestamp  block.timestamp at return.
    event CapitalReturned(uint256 amount, uint256 timestamp);

    /*//////////////////////////////////////////////////////////////
                        ALLOCATOR — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer assets from the pool to the Allocator for deployment.
    /// @dev    onlyAllocator. nonReentrant. amount must not exceed allocatorAllowance().
    ///         Sets allocatorActive = true on the paired syVault before transfer.
    /// @param  amount  Assets to deploy.
    function deployCapital(uint256 amount) external;

    /// @notice Receive assets from the Allocator back into the pool.
    /// @dev    onlyAllocator. nonReentrant.
    ///         There is no on-chain ordering enforcement with settleRedeemBatch() — the mandatory
    ///         order (returnCapital first) is a bot-level rule to ensure funds are in the pool
    ///         before shares are burned at the settled rate.
    ///         Pass amount = 0 when funds are already in the pool (capital was never deployed):
    ///         no transfer occurs but CapitalReturned is emitted for the audit trail.
    ///         Resets allocatorActive = false on the paired syVault after receipt.
    /// @param  amount  Assets being returned. 0 if no transfer is needed.
    function returnCapital(uint256 amount) external;

    /// @notice Transfer assets from the pool to a recipient. Only callable by the paired syVault.
    /// @dev    onlyVault. Used for deposit cancellations and redeem claims.
    ///         Must never revert if balance is sufficient.
    /// @param  recipient  Address to receive assets.
    /// @param  amount     Assets to transfer.
    function transferTo(address recipient, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum assets the Allocator can deploy right now.
    /// @dev    = balance() − redeemDue − claimableRedeemAssets − pendingDepositAssets.
    ///         pendingDepositAssets are reserved because users can still cancel pending requests.
    function allocatorAllowance() external view returns (uint256);

    /// @notice Current asset balance held in this pool.
    function balance() external view returns (uint256);

    /// @notice Address of the underlying asset token.
    function asset() external view returns (address);

    /// @notice Address of the paired syVault.
    function vault() external view returns (address);
}
