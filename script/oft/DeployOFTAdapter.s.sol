// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";

/// @title  DeployOFTAdapter
/// @notice Deploys the SyOFTAdapter on the HOME chain (Chain A).
///         The adapter wraps the existing SyShare ERC-20 using the lock/unlock model.
///
///         ⚠️  Deploy EXACTLY ONE adapter per SyShare globally.
///             Multiple adapters = broken liquidity + permanent token loss.
///
///         Deployment order (do not skip steps):
///           1. Run this script — deploy adapter, note the address.
///           2. Deploy SySharePeer on each remote chain (DeployOFTPeer.s.sol).
///           3. Set enforced options on both ends (WireOFT.s.sol step = options).
///           4. Set peers LAST (WireOFT.s.sol step = peers) — this opens the channel.
///
///         Required .env:
///           DEPLOYER_PRIVATE_KEY   — private key of the deploying EOA
///           SYSHARE                — SyShare ERC-20 address on this (home) chain
///           LZ_ENDPOINT            — LayerZero EndpointV2 address on this chain
///           OFT_OWNER              — multisig that controls peer config and rate limits
///
/// @dev Run:
///   forge script script/oft/DeployOFTAdapter.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployOFTAdapter is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address syShare    = vm.envAddress("SYSHARE");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address oftOwner   = vm.envAddress("OFT_OWNER");

        vm.startBroadcast(deployerKey);

        SyOFTAdapter adapter = new SyOFTAdapter(syShare, lzEndpoint, oftOwner);

        vm.stopBroadcast();

        console.log("=== OFT ADAPTER DEPLOYED (home chain) ===");
        console.log("SyOFTAdapter :", address(adapter));
        console.log("SyShare      :", syShare);
        console.log("LZ Endpoint  :", lzEndpoint);
        console.log("Owner        :", oftOwner);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Deploy SySharePeer on each remote (DeployOFTPeer.s.sol)");
        console.log("  2. Set enforced options on both sides (WireOFT.s.sol)");
        console.log("  3. Set peers LAST (WireOFT.s.sol)");
        console.log("");
        console.log("Add to .env:");
        console.log("ADAPTER=", address(adapter));
    }
}
