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
///         POST-DEPLOY: CONFIGURE VIA SAFE
///         After running this script, use the Safe Transaction Builder to submit
///         four transactions to AdminGateway (printed in console output):
///           1. grantRole(ADMIN_ROLE, multisig)        — unlocks onlyAdmin functions
///           2. grantRole(GUARDIAN_ROLE, guardian)      — unlocks emergency pause
///           3. setContractAddress(Hub, hub)            — registers Hub in AddressRegistry
///           4. renounceRole(DEFAULT_ADMIN_ROLE, multisig) — locks role mgmt behind timelock
///
///         Required .env:
///           DEPLOYER_ADDRESS       — EOA address used to deploy (must match the --interactives 1 key)
///           MULTISIG               — Safe address that receives ADMIN_ROLE + DEFAULT_ADMIN_ROLE
///           GUARDIAN               — address that receives GUARDIAN_ROLE (can be same as MULTISIG)
///           TIMELOCK_DELAY         — minimum delay in seconds (e.g. 172800 = 2 days)
///
/// @dev Run:
///   forge script script/protocol/DeploySingletons.s.sol --rpc-url $RPC_URL --broadcast --verify --interactives 1
contract DeploySingletons is Script {
    // Fixed CREATE2 salts — same value on every chain = same address.
    bytes32 constant REGISTRY_SALT = keccak256("shift.protocol.AddressRegistry.v1");
    bytes32 constant HUB_SALT      = keccak256("shift.protocol.Hub.v1");

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        address multisig      = vm.envAddress("MULTISIG");
        address guardian      = vm.envAddress("GUARDIAN");
        uint256 timelockDelay = vm.envUint("TIMELOCK_DELAY");

        // ── Pre-compute AdminGateway address ──────────────────────────────────
        // AdminGateway is the first regular (CREATE) deploy in the broadcast.
        // Compute nonce BEFORE vm.startBroadcast so it reflects the current on-chain nonce.
        uint64 deployerNonce = vm.getNonce(deployer);

        // In Foundry broadcast, CREATE2 deploys are sent as transactions from the deployer
        // and DO advance the nonce. AddressRegistry (CREATE2) takes deployerNonce,
        // so AdminGateway (regular CREATE) lands at deployerNonce + 1.
        address predictedGateway = vm.computeCreateAddress(deployer, deployerNonce + 1);

        console.log("Deployer        :", deployer);
        console.log("Nonce at start  :", deployerNonce);
        console.log("Predicted AdminGateway:", predictedGateway);

        vm.startBroadcast();

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
        _logSafeTxs(gateway, hub, multisig, guardian);
    }

    /// @dev Extracted to avoid stack-too-deep in run().
    function _logSafeTxs(
        AdminGateway _gw,
        Hub _hub,
        address _multisig,
        address _guardian
    ) internal pure {
        console.log("=== POST-DEPLOY: CONFIGURE VIA SAFE ===");
        console.log("Submit to Safe Transaction Builder (batch or sequential):");

        bytes memory data;

        data = abi.encodeCall(_gw.grantRole, (ADMIN_ROLE, _multisig));
        console.log("");
        console.log("TX 1 - grantRole(ADMIN_ROLE, multisig) - enables onlyAdmin functions");
        console.log("  To  :", address(_gw));
        console.log("  Data:", vm.toString(data));

        data = abi.encodeCall(_gw.grantRole, (GUARDIAN_ROLE, _guardian));
        console.log("");
        console.log("TX 2 - grantRole(GUARDIAN_ROLE, guardian) - enables emergency pause");
        console.log("  To  :", address(_gw));
        console.log("  Data:", vm.toString(data));

        data = abi.encodeCall(_gw.setContractAddress, (keccak256("Hub"), address(_hub)));
        console.log("");
        console.log("TX 3 - setContractAddress(Hub) - registers Hub in AddressRegistry");
        console.log("  To  :", address(_gw));
        console.log("  Data:", vm.toString(data));

        data = abi.encodeCall(_gw.renounceRole, (bytes32(0), _multisig));
        console.log("");
        console.log("TX 4 - renounceRole(DEFAULT_ADMIN_ROLE, multisig) - locks role mgmt behind timelock");
        console.log("  To  :", address(_gw));
        console.log("  Data:", vm.toString(data));
    }
}
