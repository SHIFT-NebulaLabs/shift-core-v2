// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {AdminGateway} from "src/AdminGateway.sol";
import {VaultState}   from "src/types/Types.sol";

/// @title  TimelockHelper
/// @notice Collection of scripts for scheduling and executing AdminGateway timelock operations.
///
///         The AdminGateway inherits OZ TimelockController.
///         High-risk operations (registerVault, setVaultState, fee changes, setFeeRecipient)
///         must be proposed → delayed → executed. Low-risk ops (setKeeper, maxTVL, etc.) are
///         immediate and do not require this helper.
///
///         Workflow:
///           1. Run a Schedule_* script to queue the operation.
///           2. Wait for TIMELOCK_DELAY seconds.
///           3. Run Execute_Operation to execute it.
///
///         The SALT printed by each Schedule script must be saved — it is needed for execution.
///
///         Required .env (all scripts):
///           ADMIN_PRIVATE_KEY      — must hold PROPOSER_ROLE on AdminGateway (multisig EOA)
///           ADMIN_GATEWAY          — AdminGateway address

// ─── Schedule: registerVault ────────────────────────────────────────────────

/// @dev Required additional .env:
///        SYVAULT, LIQUIDITY_POOL, SYSHARE, VAULT_OFT (or 0x000...)
contract TimelockHelper_ScheduleRegisterVault is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");

        address syVault      = vm.envAddress("SYVAULT");
        address liquidityPool = vm.envAddress("LIQUIDITY_POOL");
        address syShare      = vm.envAddress("SYSHARE");
        address syOft        = vm.envOr("VAULT_OFT", address(0));

        bytes memory data = abi.encodeCall(
            AdminGateway.registerVault,
            (syVault, liquidityPool, syShare, syOft)
        );

        bytes32 salt = keccak256(abi.encode("registerVault", syVault, block.timestamp));
        uint256 delay = AdminGateway(payable(adminGateway)).getMinDelay();

        vm.startBroadcast(deployerKey);
        AdminGateway(payable(adminGateway)).schedule(
            adminGateway, 0, data, bytes32(0), salt, delay
        );
        vm.stopBroadcast();

        bytes32 opId = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, data, bytes32(0), salt
        );

        console.log("=== registerVault SCHEDULED ===");
        console.log("Target   :", adminGateway);
        console.log("SyVault  :", syVault);
        console.log("Delay    :", delay);
        console.log("Salt     :", vm.toString(salt));
        console.log("OpId     :", vm.toString(opId));
        console.log("Ready at :", block.timestamp + delay);
        console.log("Save SALT and OpId - needed for execution.");
    }
}

// ─── Schedule: setVaultState ─────────────────────────────────────────────────

/// @dev Required additional .env:
///        VAULT_ID, NEW_VAULT_STATE (0=Pending, 1=Active, 2=Deprecated, 3=Closed)
contract TimelockHelper_ScheduleSetVaultState is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");

        uint256 vaultId   = vm.envUint("VAULT_ID");
        uint8   rawState  = uint8(vm.envUint("NEW_VAULT_STATE"));
        VaultState newState = VaultState(rawState);

        bytes memory data = abi.encodeCall(AdminGateway.setVaultState, (vaultId, newState));
        bytes32 salt = keccak256(abi.encode("setVaultState", vaultId, newState, block.timestamp));
        uint256 delay = AdminGateway(payable(adminGateway)).getMinDelay();

        vm.startBroadcast(deployerKey);
        AdminGateway(payable(adminGateway)).schedule(
            adminGateway, 0, data, bytes32(0), salt, delay
        );
        vm.stopBroadcast();

        bytes32 opId = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, data, bytes32(0), salt
        );

        console.log("=== setVaultState SCHEDULED ===");
        console.log("VaultId  :", vaultId);
        console.log("NewState :", rawState);
        console.log("Delay    :", delay);
        console.log("Salt     :", vm.toString(salt));
        console.log("OpId     :", vm.toString(opId));
        console.log("Ready at :", block.timestamp + delay);
    }
}

// ─── Schedule: setFeeRecipient ───────────────────────────────────────────────

/// @dev Required additional .env:
///        VAULT_ID, FEE_RECIPIENT
contract TimelockHelper_ScheduleSetFeeRecipient is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");

        uint256 vaultId      = vm.envUint("VAULT_ID");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        bytes memory data = abi.encodeCall(AdminGateway.setFeeRecipient, (vaultId, feeRecipient));
        bytes32 salt = keccak256(abi.encode("setFeeRecipient", vaultId, feeRecipient, block.timestamp));
        uint256 delay = AdminGateway(payable(adminGateway)).getMinDelay();

        vm.startBroadcast(deployerKey);
        AdminGateway(payable(adminGateway)).schedule(
            adminGateway, 0, data, bytes32(0), salt, delay
        );
        vm.stopBroadcast();

        bytes32 opId = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, data, bytes32(0), salt
        );

        console.log("=== setFeeRecipient SCHEDULED ===");
        console.log("VaultId      :", vaultId);
        console.log("FeeRecipient :", feeRecipient);
        console.log("OpId         :", vm.toString(opId));
        console.log("Ready at     :", block.timestamp + delay);
    }
}

// ─── Schedule: fee changes ───────────────────────────────────────────────────

/// @dev Required additional .env:
///        VAULT_ID
///        PERFORMANCE_FEE_BPS (optional)
///        MAINTENANCE_FEE_BPS (optional)
///        FAST_REDEEM_FEE_BPS (optional)
///      At least one fee env var must be set.
contract TimelockHelper_ScheduleSetFees is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        uint256 vaultId      = vm.envUint("VAULT_ID");
        uint256 delay        = AdminGateway(payable(adminGateway)).getMinDelay();

        vm.startBroadcast(deployerKey);

        if (vm.envOr("PERFORMANCE_FEE_BPS", uint256(type(uint256).max)) != type(uint256).max) {
            uint256 bps = vm.envUint("PERFORMANCE_FEE_BPS");
            bytes memory data = abi.encodeCall(AdminGateway.setPerformanceFeeBps, (vaultId, bps));
            bytes32 salt = keccak256(abi.encode("performanceFeeBps", vaultId, bps, block.timestamp));
            AdminGateway(payable(adminGateway)).schedule(adminGateway, 0, data, bytes32(0), salt, delay);
            console.log("setPerformanceFeeBps scheduled:", bps, "bps");
        }

        if (vm.envOr("MAINTENANCE_FEE_BPS", uint256(type(uint256).max)) != type(uint256).max) {
            uint256 bps = vm.envUint("MAINTENANCE_FEE_BPS");
            bytes memory data = abi.encodeCall(AdminGateway.setMaintenanceFeeBps, (vaultId, bps));
            bytes32 salt = keccak256(abi.encode("maintenanceFeeBps", vaultId, bps, block.timestamp));
            AdminGateway(payable(adminGateway)).schedule(adminGateway, 0, data, bytes32(0), salt, delay);
            console.log("setMaintenanceFeeBps scheduled:", bps, "bps");
        }

        if (vm.envOr("FAST_REDEEM_FEE_BPS", uint256(type(uint256).max)) != type(uint256).max) {
            uint256 bps = vm.envUint("FAST_REDEEM_FEE_BPS");
            bytes memory data = abi.encodeCall(AdminGateway.setFastRedeemFeeBps, (vaultId, bps));
            bytes32 salt = keccak256(abi.encode("fastRedeemFeeBps", vaultId, bps, block.timestamp));
            AdminGateway(payable(adminGateway)).schedule(adminGateway, 0, data, bytes32(0), salt, delay);
            console.log("setFastRedeemFeeBps scheduled:", bps, "bps");
        }

        vm.stopBroadcast();
    }
}

// ─── Execute: any scheduled operation ────────────────────────────────────────

/// @dev Required .env:
///        DEPLOYER_PRIVATE_KEY, ADMIN_GATEWAY
///        TL_TARGET, TL_VALUE, TL_DATA (hex), TL_PREDECESSOR, TL_SALT
contract TimelockHelper_Execute is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");

        address target      = vm.envAddress("TL_TARGET");
        uint256 value       = vm.envOr("TL_VALUE", uint256(0));
        bytes memory data   = vm.envBytes("TL_DATA");
        bytes32 predecessor = vm.envOr("TL_PREDECESSOR", bytes32(0));
        bytes32 salt        = vm.envBytes32("TL_SALT");

        bytes32 opId = AdminGateway(payable(adminGateway)).hashOperation(
            target, value, data, predecessor, salt
        );

        require(
            AdminGateway(payable(adminGateway)).isOperationReady(opId),
            "TimelockHelper: operation not ready (delay not elapsed or not scheduled)"
        );

        vm.startBroadcast(deployerKey);
        AdminGateway(payable(adminGateway)).execute(target, value, data, predecessor, salt);
        vm.stopBroadcast();

        console.log("=== TIMELOCK OPERATION EXECUTED ===");
        console.log("OpId   :", vm.toString(opId));
        console.log("Target :", target);
    }
}
