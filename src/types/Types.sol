// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  Types
/// @author Shift Protocol
/// @notice Shared enums, structs, and custom types for the syVault system.

/*//////////////////////////////////////////////////////////////
                            ENUMS
//////////////////////////////////////////////////////////////*/

/// @notice Lifecycle state of a vault instance.
enum VaultState {
    Pending,    // Not yet active — no operations allowed.
    Active,     // Fully operational.
    Deprecated, // No new deposits; redeems and cancels still open.
    Closed      // Terminal — only cancels allowed.
}

/// @notice Type of a redeem cycle.
enum CycleType {
    Normal, // 7-day cycle.
    Fast    // 1-day cycle.
}

/// @notice Result of a requestDeposit eligibility check.
enum DepositRequestStatus {
    Ok,             // Request can proceed.
    Paused,         // Vault is fully paused or deposits are paused.
    NotWhitelisted, // Deposit whitelist is enabled and caller is not on it.
    TVLExceeded,    // Deposit would push TVL above maxTVL.
    StalePrice,     // Keeper is too far behind — share price is stale.
    BelowMinDeposit, // Deposit amount is below the minimum deposit threshold.
    NotStarted      // Vault has not received its first epochSettle — not yet operational.
}

/// @notice Result of a requestRedeem (normal) eligibility check.
enum RedeemRequestStatus {
    Ok,             // Request can proceed (may open a new cycle if past cutoff).
    Paused,         // Vault is fully paused or redeems are paused.
    AlreadyPending, // Owner already has an active redeem request.
    PastCutoff      // Current cycle is past cutoff — request will be placed in the next cycle.
}

/// @notice Result of a requestFastRedeem eligibility check.
enum FastRedeemRequestStatus {
    Ok,                        // Request can proceed.
    Paused,                    // Vault is fully paused or redeems are paused.
    Disabled,                  // Fast redeem has been turned off by admin.
    AlreadyPending,            // Owner already has an active redeem request.
    FastCycleSettlementPending, // Current fast cycle is past cutoff and not yet settled — wait for Allocator.
    CapExceeded                // Fast redeem cap per cycle would be exceeded by this request.
}

/// @notice Progression state of a redeem cycle from the perspective of incoming requests.
enum CycleState {
    Pending,   // Accepting new requests.
    Cutoff,    // Past cutoff — new requests go to next cycle.
    Locked,    // Past lock window — no new requests, no cancellations.
    Claimable  // Settled — assets claimable by controllers.
}

/*//////////////////////////////////////////////////////////////
                           STRUCTS
//////////////////////////////////////////////////////////////*/

/// @notice Per-cycle accounting state.
/// @dev    Stored keyed by cycleId. For normal redeems cycleId = currentNormalCycleId(),
///         for fast redeems cycleId = currentFastCycleId() at request time.
struct RedeemCycle {
    CycleType cycleType;      // Normal or fast.
    uint256   shares;         // Total shares locked into this cycle.
    uint256   cutoffEpoch;    // Epoch at which new requests go to the next cycle.
    uint256   lockEpoch;      // Epoch at which cancellations are disabled.
    bool      settled;        // True after settleRedeemBatch() completes.
    uint256   returnedAmount; // Assets returned by Allocator via returnCapital().
    uint256   cycleRate;      // returnedAmount / shares, scaled by SHARE_PRICE_PRECISION.
    uint256   feeBps;         // Fast redeem fee snapshotted at cycle creation. 0 for normal cycles.
}

/// @notice Snapshot of share price data stored per epoch in the ring buffer.
/// @dev    Used by getSharePriceHistory() and getHwmHistory(). Max 720 epochs (30d).
struct SharePriceSnapshot {
    uint256 sharePrice;  // Raw asset units per whole share (e.g. 1e6 for 1 USDC/share, 1e18 for 1 WETH/share).
    uint256 totalSupply; // syShare totalSupply at settlement.
    uint256 timestamp;   // block.timestamp at epochSettle().
}
