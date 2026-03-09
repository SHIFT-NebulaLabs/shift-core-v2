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

// Share price fixed-point precision (1e18 = WAD).
uint256 constant SHARE_PRICE_PRECISION = 1e18;

/*//////////////////////////////////////////////////////////////
                          LAYERZERO
//////////////////////////////////////////////////////////////*/

// LayerZero V2 EndpointV2 address — all chains except zkSync Era.
address constant LZ_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c;

// LayerZero V2 EndpointV2 address — zkSync Era only.
address constant LZ_ENDPOINT_V2_ZKSYNC = 0xd07C30aF3Ff30D96BDc9c6044958230Eb797DDBF;

/*//////////////////////////////////////////////////////////////
                        EIP-165 INTERFACE IDS
//////////////////////////////////////////////////////////////*/

// EIP-165 interface ID for ERC-7540 async deposit.
bytes4 constant INTERFACE_ID_ERC7540_DEPOSIT = 0xe3bc4e65;

// EIP-165 interface ID for ERC-7540 async redeem.
bytes4 constant INTERFACE_ID_ERC7540_REDEEM = 0x2f0a18c5;

// EIP-165 interface ID for ERC-7540 operator management.
bytes4 constant INTERFACE_ID_ERC7540_OPERATOR = 0xce3bbe50;

// EIP-165 interface ID for ERC-7575 share discovery.
bytes4 constant INTERFACE_ID_ERC7575 = 0x620ee8e4;

/*//////////////////////////////////////////////////////////////
                            ROLES
//////////////////////////////////////////////////////////////*/

// ADMIN role — full configuration access. Must be a multisig.
bytes32 constant ADMIN_ROLE = keccak256("ADMIN");

// GUARDIAN role — immediate pause only. No config, no fund access.
bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN");

// KEEPER role — epochSettle() per vault.
bytes32 constant KEEPER_ROLE = keccak256("KEEPER");

// ALLOCATOR role — deployCapital() / returnCapital() / settleRedeemBatch() per vault.
bytes32 constant ALLOCATOR_ROLE = keccak256("ALLOCATOR");
