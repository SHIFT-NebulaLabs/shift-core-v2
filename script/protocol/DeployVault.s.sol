// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyShare}       from "src/SyShare.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {SyVault}       from "src/SyVault.sol";
import {AdminGateway}  from "src/AdminGateway.sol";

/// @title  DeployVault
/// @notice Deploys one vault cluster: SyShare + LiquidityPool + SyVault.
///
///         SyShare needs the vault address at construction; SyVault needs SyShare.
///         The circular dependency is broken with vm.computeCreateAddress — all three
///         deploys happen in sequence within the same broadcast, so the nonce is predictable.
///
///         Each vault cluster has unique addresses per chain (regular CREATE, not CREATE2).
///         This is intentional — DeBanks and block explorers must not conflate syUSDC on Base
///         with syUSDT on Arbitrum.
///
///         After deployment, register the vault via the Safe Transaction Builder:
///           1. Call AdminGateway.schedule() to queue registerVault (see console output for calldata).
///           2. Wait for TIMELOCK_DELAY seconds.
///           3. Call AdminGateway.execute() with the same parameters.
///
///         Required .env:
///           DEPLOYER_ADDRESS       — EOA address used to deploy (must match the --interactives 1 key)
///           VAULT_ASSET            — underlying ERC-20 asset address
///           VAULT_SHARE_NAME       — e.g. "Shift Yield Share USDC"
///           VAULT_SHARE_SYMBOL     — e.g. "syUSDC"
///           HUB                    — Hub address
///           ADMIN_GATEWAY          — AdminGateway address
///           VAULT_KEEPER           — Keeper bot address
///           VAULT_ALLOCATOR        — Allocator bot address
///           VAULT_FEE_RECIPIENT    — fee recipient address
///           VAULT_INITIAL_PRICE    — initial share price in raw asset units
///                                    (e.g. 1000000 for 1.0 with USDC 6 decimals)
///           VAULT_FAST_REDEEM_ENABLED — true to enable fast redeem at launch, false to disable
///           VAULT_OFT              — SyOFTAdapter address, or leave unset for single-chain
///
/// @dev Run:
///   forge script script/protocol/DeployVault.s.sol --rpc-url $RPC_URL --broadcast --verify --interactives 1
contract DeployVault is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // ── Pre-compute vault address ─────────────────────────────────────────
        // Deploy order: SyShare (nonce) → LiquidityPool (nonce+1) → SyVault (nonce+2).
        uint64 nonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 2);

        console.log("Deployer       :", deployer);
        console.log("Nonce at start :", nonce);
        console.log("Predicted Vault:", predictedVault);

        vm.startBroadcast();

        // 1. SyShare — vault address must be predictedVault.
        SyShare share = new SyShare(
            vm.envString("VAULT_SHARE_NAME"),
            vm.envString("VAULT_SHARE_SYMBOL"),
            predictedVault
        );

        // 2. LiquidityPool.
        LiquidityPool pool = new LiquidityPool(vm.envAddress("VAULT_ASSET"), predictedVault);

        // 3. SyVault — must land at predictedVault.
        SyVault vault = new SyVault(
            vm.envAddress("VAULT_ASSET"),
            address(share),
            address(pool),
            vm.envAddress("HUB"),
            vm.envAddress("ADMIN_GATEWAY"),
            vm.envAddress("VAULT_KEEPER"),
            vm.envAddress("VAULT_ALLOCATOR"),
            vm.envAddress("VAULT_FEE_RECIPIENT"),
            vm.envUint("VAULT_INITIAL_PRICE"),
            vm.envBool("VAULT_FAST_REDEEM_ENABLED")
        );

        vm.stopBroadcast();

        require(address(vault) == predictedVault, "DeployVault: vault address mismatch");

        // ── Log deployed addresses ────────────────────────────────────────────
        console.log("=== VAULT DEPLOYED ===");
        console.log("SyShare        :", address(share));
        console.log("LiquidityPool  :", address(pool));
        console.log("SyVault        :", address(vault));
        console.log("");
        console.log("Add to .env:");
        console.log("SYSHARE=", address(share));
        console.log("LIQUIDITY_POOL=", address(pool));
        console.log("SYVAULT=", address(vault));
        console.log("");

        // ── Print Safe Transaction Builder calldata for registerVault ─────────
        // Registration requires two Safe transactions via TimelockController:
        //   TX 1: schedule() — queues the operation (wait TIMELOCK_DELAY seconds after this).
        //   TX 2: execute()  — executes the operation after the delay.
        //
        // Both transactions target AdminGateway (it calls itself).
        // Use the same target/data/predecessor/salt in both calls.
        address adminGateway = vm.envAddress("ADMIN_GATEWAY");
        address syOft        = vm.envOr("VAULT_OFT", address(0));
        uint256 delay        = AdminGateway(payable(adminGateway)).getMinDelay();
        bytes32 salt         = keccak256(abi.encode("registerVault", address(vault), block.timestamp));

        bytes memory innerData = abi.encodeCall(
            AdminGateway.registerVault,
            (address(vault), address(pool), address(share), syOft)
        );
        bytes memory scheduleData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).schedule,
            (adminGateway, 0, innerData, bytes32(0), salt, delay)
        );
        bytes memory executeData = abi.encodeCall(
            AdminGateway(payable(adminGateway)).execute,
            (adminGateway, 0, innerData, bytes32(0), salt)
        );

        console.log("=== POST-DEPLOY: REGISTER VAULT VIA SAFE ===");
        console.log("TX 1 (now) - schedule registerVault:");
        console.log("  To  :", adminGateway);
        console.log("  Data:", vm.toString(scheduleData));
        console.log("");
        console.log("TX 2 (after", delay, "seconds) - execute registerVault:");
        console.log("  To  :", adminGateway);
        console.log("  Data:", vm.toString(executeData));
        console.log("  Salt:", vm.toString(salt));
    }
}
