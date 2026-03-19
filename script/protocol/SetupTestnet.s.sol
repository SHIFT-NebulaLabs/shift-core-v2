// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// TESTNET ONLY - delete after use.

import {Script, console} from "forge-std/Script.sol";

import {AdminGateway}  from "src/AdminGateway.sol";
import {ADMIN_ROLE, GUARDIAN_ROLE} from "src/types/Constants.sol";

// Fixed salt — must match the value used in SetupTestnet_Schedule.
bytes32 constant REGISTER_SALT = keccak256("shift.registerVault.testnet.v1");

/// @dev Grants ADMIN_ROLE and GUARDIAN_ROLE. Run once after deploy-singletons.
contract SetupTestnet_Roles is Script {
    function run() external {
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        address multisig     = vm.envAddress("MULTISIG");
        address guardian     = vm.envAddress("GUARDIAN");

        vm.startBroadcast();
        AdminGateway(payable(adminGateway)).grantRole(ADMIN_ROLE,    multisig);
        AdminGateway(payable(adminGateway)).grantRole(GUARDIAN_ROLE, guardian);
        vm.stopBroadcast();

        console.log("ADMIN_ROLE    granted to:", multisig);
        console.log("GUARDIAN_ROLE granted to:", guardian);
    }
}

/// @dev Schedules registerVault via TimelockController. Run after deploy-vault.
contract SetupTestnet_Schedule is Script {
    function run() external {
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        address syVault      = vm.envAddress("SYVAULT");
        address pool         = vm.envAddress("LIQUIDITY_POOL");
        address syShare      = vm.envAddress("SYSHARE");
        address syOft        = vm.envOr("VAULT_OFT", address(0));
        uint256 delay        = AdminGateway(payable(adminGateway)).getMinDelay();

        bytes memory innerData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).registerVault,
            (syVault, pool, syShare, syOft)
        );

        bytes32 opHash = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, innerData, bytes32(0), REGISTER_SALT
        );

        console.log("=== REGISTER VAULT: SCHEDULE ===");
        console.log("Operation:", vm.toString(opHash));
        console.log("Delay (s):", delay);

        vm.startBroadcast();
        AdminGateway(payable(adminGateway)).schedule(
            adminGateway, 0, innerData, bytes32(0), REGISTER_SALT, delay
        );
        vm.stopBroadcast();

        console.log("Scheduled. Run SetupTestnet_Execute after", delay, "seconds.");
    }
}

/// @dev Executes registerVault after TIMELOCK_DELAY has elapsed.
contract SetupTestnet_Execute is Script {
    function run() external {
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        address syVault      = vm.envAddress("SYVAULT");
        address pool         = vm.envAddress("LIQUIDITY_POOL");
        address syShare      = vm.envAddress("SYSHARE");
        address syOft        = vm.envOr("VAULT_OFT", address(0));

        bytes memory innerData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).registerVault,
            (syVault, pool, syShare, syOft)
        );

        bytes32 opHash = AdminGateway(payable(adminGateway)).hashOperation(
            adminGateway, 0, innerData, bytes32(0), REGISTER_SALT
        );

        bool pending = AdminGateway(payable(adminGateway)).isOperationPending(opHash);
        bool ready   = AdminGateway(payable(adminGateway)).isOperationReady(opHash);

        console.log("=== REGISTER VAULT: EXECUTE ===");
        console.log("Operation:", vm.toString(opHash));
        console.log("Pending  :", pending);
        console.log("Ready    :", ready);

        require(ready, "SetupTestnet_Execute: operation not ready - delay not elapsed");

        vm.startBroadcast();
        AdminGateway(payable(adminGateway)).execute(
            adminGateway, 0, innerData, bytes32(0), REGISTER_SALT
        );
        vm.stopBroadcast();

        console.log("registerVault executed. Vault is now Pending.");
        console.log("Next: run ActivateVault_Schedule, then ActivateVault_Execute.");
    }
}
