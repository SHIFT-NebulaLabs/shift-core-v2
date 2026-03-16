// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyShare}       from "src/SyShare.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {SyVault}       from "src/SyVault.sol";

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
///         After deployment, register the vault by running:
///           forge script script/helpers/TimelockHelper.s.sol:TimelockHelper_ScheduleRegisterVault
///         (requires ADMIN_PRIVATE_KEY holding PROPOSER_ROLE on AdminGateway)
///
///         Required .env:
///           DEPLOYER_PRIVATE_KEY   — private key of the deploying EOA (no admin role needed)
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
///           VAULT_OFT              — SyOFTAdapter address, or leave unset for single-chain
///
/// @dev Run:
///   forge script script/protocol/DeployVault.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        // ── Pre-compute vault address ─────────────────────────────────────────
        // Deploy order: SyShare (nonce) → LiquidityPool (nonce+1) → SyVault (nonce+2).
        uint64 nonce = vm.getNonce(deployer);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 2);

        console.log("Deployer       :", deployer);
        console.log("Nonce at start :", nonce);
        console.log("Predicted Vault:", predictedVault);

        vm.startBroadcast(deployerKey);

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
            vm.envUint("VAULT_INITIAL_PRICE")
        );

        vm.stopBroadcast();

        require(address(vault) == predictedVault, "DeployVault: vault address mismatch");

        // ── Log deployed addresses ────────────────────────────────────────────
        console.log("=== VAULT DEPLOYED ===");
        console.log("SyShare        :", address(share));
        console.log("LiquidityPool  :", address(pool));
        console.log("SyVault        :", address(vault));
        console.log("");
        console.log("Next: register the vault via timelock.");
        console.log("Set in .env: SYVAULT / LIQUIDITY_POOL / SYSHARE / VAULT_OFT");
        console.log("Then run:");
        console.log("  forge script script/helpers/TimelockHelper.s.sol:TimelockHelper_ScheduleRegisterVault");
        console.log("");
        console.log("Add to .env:");
        console.log("SYSHARE=", address(share));
        console.log("LIQUIDITY_POOL=", address(pool));
        console.log("SYVAULT=", address(vault));
    }
}
