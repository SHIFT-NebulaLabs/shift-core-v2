// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {AdminGateway} from "src/AdminGateway.sol";
import {VaultState}   from "src/types/Types.sol";

// Deterministic salt - same value in both contracts so the operation hash matches.
bytes32 constant ACTIVATE_SALT = keccak256("shift.activateVault.v1");

/// @title  ActivateVault_Schedule
/// @notice Step 1: Schedule the Pending -> Active transition via TimelockController.
///
///         Vault lifecycle:
///           registerVault sets state to Pending (no deposits allowed).
///           setVaultState(vaultId, Active) opens the vault for deposits and redeems.
///
///         Required .env:
///           ADMIN_GATEWAY  - AdminGateway address
///           VAULT_ID       - vault identifier returned by registerVault
///
/// @dev Run:
///   forge script script/protocol/ActivateVault.s.sol:ActivateVault_Schedule \
///     --rpc-url $RPC_URL --broadcast --interactives 1
contract ActivateVault_Schedule is Script {
    function run() external {
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        uint256 vaultId      = vm.envUint("VAULT_ID");
        uint256 delay        = AdminGateway(payable(adminGateway)).getMinDelay();

        bytes memory innerData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).setVaultState,
            (vaultId, VaultState.Active)
        );

        bytes32 opHash = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, innerData, bytes32(0), ACTIVATE_SALT
        );

        console.log("=== ACTIVATE VAULT: SCHEDULE ===");
        console.log("AdminGateway :", adminGateway);
        console.log("VaultId      :", vaultId);
        console.log("Delay (s)    :", delay);
        console.log("Operation    :", vm.toString(opHash));
        console.log("");

        vm.startBroadcast();
        AdminGateway(payable(adminGateway)).schedule(
            adminGateway, 0, innerData, bytes32(0), ACTIVATE_SALT, delay
        );
        vm.stopBroadcast();

        console.log("Scheduled. Run ActivateVault_Execute after", delay, "seconds.");
        console.log("");
        console.log("Verify pending:");
        console.log("  cast call <ADMIN_GATEWAY> \"isOperationPending(bytes32)\" ", vm.toString(opHash));
    }
}

/// @title  ActivateVault_Execute
/// @notice Step 2: Execute the scheduled Pending -> Active transition.
///         Run this after TIMELOCK_DELAY seconds have elapsed since scheduling.
///
///         Required .env:
///           ADMIN_GATEWAY  - AdminGateway address
///           VAULT_ID       - vault identifier returned by registerVault
///
/// @dev Run:
///   forge script script/protocol/ActivateVault.s.sol:ActivateVault_Execute \
///     --rpc-url $RPC_URL --broadcast --interactives 1
contract ActivateVault_Execute is Script {
    function run() external {
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        uint256 vaultId      = vm.envUint("VAULT_ID");

        bytes memory innerData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).setVaultState,
            (vaultId, VaultState.Active)
        );

        bytes32 opHash = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, innerData, bytes32(0), ACTIVATE_SALT
        );

        bool pending = AdminGateway(payable(adminGateway)).isOperationPending(opHash);
        bool ready   = AdminGateway(payable(adminGateway)).isOperationReady(opHash);

        console.log("=== ACTIVATE VAULT: EXECUTE ===");
        console.log("AdminGateway :", adminGateway);
        console.log("VaultId      :", vaultId);
        console.log("Operation    :", vm.toString(opHash));
        console.log("Pending      :", pending);
        console.log("Ready        :", ready);
        console.log("");

        require(ready, "ActivateVault_Execute: operation not ready - delay not elapsed");

        vm.startBroadcast();
        AdminGateway(payable(adminGateway)).execute(
            adminGateway, 0, innerData, bytes32(0), ACTIVATE_SALT
        );
        vm.stopBroadcast();

        console.log("Vault", vaultId, "is now Active.");
    }
}
