// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {AddressRegistry} from "src/AddressRegistry.sol";
import {AdminGateway}    from "src/AdminGateway.sol";
import {Hub}             from "src/Hub.sol";
import {ADMIN_ROLE, GUARDIAN_ROLE} from "src/types/Constants.sol";

/// @title  DeploySingletons
/// @notice Deploys the three protocol singletons:
///           AddressRegistry → AdminGateway → Hub
///
///         SAME ADDRESS ACROSS CHAINS
///         AddressRegistry and Hub use CREATE2 (fixed salt) — deterministic address
///         regardless of deployer nonce. AdminGateway cannot use CREATE2 because its
///         init code includes AddressRegistry's address (breaking the hash), so it is
///         deployed with vm.computeCreateAddress to resolve the circular dependency.
///         To get the same AdminGateway address on every chain, use the same deployer
///         EOA at the same nonce.
///
///         POST-DEPLOY: GRANT ROLES VIA SAFE
///         After running this script, use the Safe Transaction Builder to submit
///         two transactions to AdminGateway (printed in console output):
///           1. grantRole(ADMIN_ROLE, multisig)   — unlocks onlyAdmin functions
///           2. grantRole(GUARDIAN_ROLE, guardian) — unlocks emergency pause
///
///         Required .env:
///           DEPLOYER_PRIVATE_KEY   — private key of the deploying EOA (no admin role needed)
///           MULTISIG               — Safe address that receives ADMIN_ROLE + DEFAULT_ADMIN_ROLE
///           GUARDIAN               — address that receives GUARDIAN_ROLE (can be same as MULTISIG)
///           TIMELOCK_DELAY         — minimum delay in seconds (e.g. 172800 = 2 days)
///
/// @dev Run:
///   forge script script/protocol/DeploySingletons.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeploySingletons is Script {
    // Fixed CREATE2 salts — same value on every chain = same address.
    bytes32 constant REGISTRY_SALT = keccak256("shift.protocol.AddressRegistry.v1");
    bytes32 constant HUB_SALT      = keccak256("shift.protocol.Hub.v1");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        address multisig      = vm.envAddress("MULTISIG");
        address guardian      = vm.envAddress("GUARDIAN");
        uint256 timelockDelay = vm.envUint("TIMELOCK_DELAY");

        // ── Pre-compute AdminGateway address ──────────────────────────────────
        // AdminGateway is the first regular (CREATE) deploy in the broadcast.
        // Compute nonce BEFORE vm.startBroadcast so it reflects the current on-chain nonce.
        uint64 deployerNonce = vm.getNonce(deployer);

        // CREATE2 deploys don't advance the deployer nonce.
        // AdminGateway will be the FIRST regular (CREATE) deploy → nonce = deployerNonce.
        address predictedGateway = vm.computeCreateAddress(deployer, deployerNonce);

        console.log("Deployer        :", deployer);
        console.log("Nonce at start  :", deployerNonce);
        console.log("Predicted AdminGateway:", predictedGateway);

        vm.startBroadcast(deployerKey);

        // 1. AddressRegistry — CREATE2, references predicted AdminGateway.
        AddressRegistry registry = new AddressRegistry{salt: REGISTRY_SALT}(predictedGateway);

        // 2. AdminGateway — regular CREATE (nonce = deployerNonce).
        //    TimelockController: proposers = multisig, executors = multisig, admin = multisig.
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = multisig;
        executors[0] = multisig;

        AdminGateway gateway = new AdminGateway(
            timelockDelay,
            proposers,
            executors,
            multisig,          // initial admin — revoke after setup if desired
            address(registry)
        );

        require(address(gateway) == predictedGateway, "DeploySingletons: gateway address mismatch");

        // 3. Hub — CREATE2.
        Hub hub = new Hub{salt: HUB_SALT}(address(registry));

        vm.stopBroadcast();

        // ── Log deployed addresses ────────────────────────────────────────────
        console.log("=== SINGLETONS DEPLOYED ===");
        console.log("AddressRegistry :", address(registry));
        console.log("AdminGateway    :", address(gateway));
        console.log("Hub             :", address(hub));
        console.log("");
        console.log("Add to .env:");
        console.log("REGISTRY=", address(registry));
        console.log("ADMIN_GATEWAY=", address(gateway));
        console.log("HUB=", address(hub));
        console.log("");

        // ── Print Safe Transaction Builder calldata ───────────────────────────
        // MULTISIG holds DEFAULT_ADMIN_ROLE (set in AdminGateway constructor).
        // Submit the following two transactions via the Safe Transaction Builder.
        bytes memory adminRoleData    = abi.encodeCall(gateway.grantRole, (ADMIN_ROLE,    multisig));
        bytes memory guardianRoleData = abi.encodeCall(gateway.grantRole, (GUARDIAN_ROLE, guardian));

        console.log("=== POST-DEPLOY: GRANT ROLES VIA SAFE ===");
        console.log("Submit to Safe Transaction Builder (batch or sequential):");
        console.log("");
        console.log("TX 1 - grantRole(ADMIN_ROLE, multisig) - enables onlyAdmin functions");
        console.log("  To  :", address(gateway));
        console.log("  Data:", vm.toString(adminRoleData));
        console.log("");
        console.log("TX 2 - grantRole(GUARDIAN_ROLE, guardian) - enables emergency pause");
        console.log("  To  :", address(gateway));
        console.log("  Data:", vm.toString(guardianRoleData));
    }
}
