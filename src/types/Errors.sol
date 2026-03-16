// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  Errors
/// @author Shift Protocol
/// @notice All custom errors for the syVault system, grouped by contract.

/*//////////////////////////////////////////////////////////////
                         SYVAULT
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when caller is not the Hub.
error SyVault__NotHub();

/// @notice Thrown when caller is not the assigned Keeper.
error SyVault__NotKeeper();

/// @notice Thrown when caller is not the assigned Allocator.
error SyVault__NotAllocator();

/// @notice Thrown when caller is not authorized for the requested action.
error SyVault__NotAuthorized();

/// @notice Thrown when the vault is fully paused.
error SyVault__Paused();

/// @notice Thrown when deposits are paused.
error SyVault__DepositsPaused();

/// @notice Thrown when redeems are paused.
error SyVault__RedeemsPaused();

/// @notice Thrown when a deposit would push TVL above maxTVL.
error SyVault__MaxTVLExceeded();

/// @notice Thrown when a deposit amount is below the minimum deposit threshold.
error SyVault__BelowMinDeposit();

/// @notice Thrown when caller is not on the deposit whitelist.
error SyVault__NotWhitelisted();

/// @notice Thrown when vault state does not permit the requested operation.
error SyVault__InvalidVaultState();

/// @notice Thrown when requestFastRedeem() is called after cutoff but the current fast cycle is not yet settled.
error SyVault__FastCycleNotSettled();

/// @notice Thrown when settleRedeemBatch() is called before the cycle lock epoch.
error SyVault__CycleNotLocked();

/// @notice Thrown when settleRedeemBatch() is called on an already-settled cycle.
error SyVault__CycleAlreadySettled();

/// @notice Thrown when requestFastRedeem() is called while a redeem request is already pending.
error SyVault__RedeemRequestAlreadyPending();

/// @notice Thrown when deposit() or mint() is called with no claimable deposit for the controller.
error SyVault__NoClaimableDeposit();

/// @notice Thrown when redeem() or withdraw() is called with no claimable redeem for the controller.
error SyVault__NoClaimableRedeem();

/// @notice Thrown when cancel is called on a request that is not in Pending state.
error SyVault__NoPendingRequest();

/// @notice Thrown when the proposed share price deviates more than maxSharePriceDelta from the previous.
error SyVault__SharePriceDeltaExceeded();

/// @notice Thrown when a zero share price is proposed outside of the emergency fallback path.
error SyVault__InvalidSharePrice();

/// @notice Thrown when the controller is not the owner and no operator approval exists.
error SyVault__NotOwnerOrOperator();

/// @notice Thrown when owner is not msg.sender and no operator is set.
error SyVault__InvalidOwner();

/// @notice Thrown when an epoch ring buffer range exceeds the 720-epoch maximum.
error SyVault__RangeTooLarge();

/// @notice Thrown when fromEpoch > toEpoch in a history range query.
error SyVault__InvalidRange();

/// @notice Thrown when epochSettle() is called but no full epoch has elapsed since last settlement.
error SyVault__EpochNotElapsed();

/// @notice Thrown when any preview function is called — async vault has no synchronous preview.
error SyVault__AsyncVault();

/// @notice Thrown when a zero amount is passed where a positive value is required.
error SyVault__ZeroAmount();

/// @notice Thrown when a fee parameter exceeds the allowed maximum (BASIS_POINTS).
error SyVault__InvalidParam();

/*//////////////////////////////////////////////////////////////
                        LIQUIDITYPOOL
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when caller is not the authorized vault or allocator.
error LiquidityPool__NotAuthorized();

/// @notice Thrown when deployCapital amount exceeds allocatorAllowance.
error LiquidityPool__ExceedsAllowance();

/// @notice Thrown when the pool has insufficient balance to fulfil the request.
error LiquidityPool__InsufficientBalance();

/*//////////////////////////////////////////////////////////////
                          SYSHARE
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when caller is not the paired syVault.
error SyShare__NotVault();

/*//////////////////////////////////////////////////////////////
                           HUB
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when the target vault is not in Active state.
error Hub__VaultNotActive();

/// @notice Thrown when caller is not authorized to act on behalf of the given controller.
error Hub__NotAuthorized();

/// @notice Thrown when a zero address is passed where a valid address is required.
error Hub__ZeroAddress();

/*//////////////////////////////////////////////////////////////
                       ADDRESSREGISTRY
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when caller is not the AdminGateway.
error AddressRegistry__NotAuthorized();

/// @notice Thrown when a zero address is passed for a required contract slot.
error AddressRegistry__ZeroAddress();

/// @notice Thrown when a vault with the given id is already registered.
error AddressRegistry__VaultAlreadyRegistered();

/// @notice Thrown when the requested vaultId does not exist.
error AddressRegistry__VaultNotFound();

/// @notice Thrown when a vault address does not implement the required EIP-7540 interfaces.
error AddressRegistry__IncompatibleVault();

/*//////////////////////////////////////////////////////////////
                        ADMINGATEWAY
//////////////////////////////////////////////////////////////*/

/// @notice Thrown when an operation is attempted on a zero address.
error AdminGateway__ZeroAddress();

/// @notice Thrown when an invalid vault state transition is requested.
error AdminGateway__InvalidTransition();

/// @notice Thrown when caller is not authorized (not timelock or admin).
error AdminGateway__NotAuthorized();
