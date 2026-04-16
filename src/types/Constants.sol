// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// title:  Constants
// author: Shift Protocol
// notice: Global protocol constants. All values are immutable by design.

/*//////////////////////////////////////////////////////////////
                        EPOCH & TIMING
//////////////////////////////////////////////////////////////*/

// Duration of one epoch in seconds (1 hour). Base unit for all time calculations.
uint256 constant EPOCH_DURATION = 1 hours;

// Duration of a normal redeem cycle in epochs (7 days). Immutable — commitment to users.
uint256 constant NORMAL_REDEEM_CYCLE_DURATION = 168;

// Epoch within a normal cycle after which new requestRedeem() calls revert (5 days).
uint256 constant NORMAL_REDEEM_CUTOFF = 120;

// Epoch within a normal cycle at which cancellations are disabled (6 days).
uint256 constant NORMAL_REDEEM_LOCK_WINDOW = 144;

// Duration of a fast redeem cycle in epochs (1 day). Immutable.
uint256 constant FAST_REDEEM_CYCLE_DURATION = 24;

// Epoch within a fast cycle after which new requestFastRedeem() calls revert (12 hours).
uint256 constant FAST_REDEEM_CUTOFF = 12;

// Epoch within a fast cycle at which cancellations are disabled (20 hours).
uint256 constant FAST_REDEEM_LOCK_WINDOW = 20;

// Consecutive epochs with allocatorActive = true before the Keeper ignores the flag.
uint256 constant ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS = 2;

// Maximum epoch range for ring-buffer history queries (30 days).
uint256 constant MAX_HISTORY_RANGE = 720;

/*//////////////////////////////////////////////////////////////
                             MATH
//////////////////////////////////////////////////////////////*/

// Basis points denominator (10 000 = 100%).
uint256 constant BASIS_POINTS = 10_000;

// Maximum fast redeem fee (30%). Values above this have no legitimate use case
// and risk division-by-zero in withdraw() or total-loss in redeem().
uint256 constant MAX_FAST_REDEEM_FEE_BPS = 3_000;

// Epochs per year — used for annualised maintenance fee proration (1 epoch = 1 hour).
uint256 constant EPOCHS_PER_YEAR = 8_760;

// Share price fixed-point precision (1e18 = WAD).
uint256 constant SHARE_PRICE_PRECISION = 1e18;

/*//////////////////////////////////////////////////////////////
                            ROLES
//////////////////////////////////////////////////////////////*/

// ADMIN role — full configuration access. Must be a multisig.
bytes32 constant ADMIN_ROLE = keccak256("ADMIN");

// GUARDIAN role — immediate pause only. No config, no fund access.
bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN");
