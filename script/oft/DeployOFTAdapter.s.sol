// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {ICreateX}     from "script/interfaces/ICreateX.sol";

// Salt suffix — change to redeploy at a new address if needed.
bytes32 constant ADAPTER_SALT_SUFFIX = keccak256("shift.SyOFTAdapter.v1");

// CreateX factory — same address on all EVM chains.
address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

/// @title  DeployOFTAdapter
/// @notice Deploys the SyOFTAdapter on the HOME chain using CreateX (CREATE3).
///         The adapter wraps the existing SyShare ERC-20 using the lock/unlock model.
///
///         CREATE3 ensures the adapter lands at the same address on every chain,
///         regardless of the lzEndpoint constructor arg which differs per chain.
///         Address depends only on (deployer, ADAPTER_SALT_SUFFIX).
///
///         ⚠️  Deploy EXACTLY ONE adapter per SyShare globally.
///             Multiple adapters = broken liquidity + permanent token loss.
///
///         Deployment order (do not skip steps):
///           1. Run this script — deploy adapter, note the address.
///           2. Deploy SySharePeer on each remote chain (DeployOFTPeer.s.sol).
///           3. Set enforced options on both ends (WireOFT_SetOptions.s.sol).
///           4. Set rate limits (WireOFT_SetRateLimit.s.sol).
///           5. Set peers LAST (WireOFT_SetPeers.s.sol) — this opens the channel.
///
///         Required .env:
///           DEPLOYER_ADDRESS  — EOA used to deploy (controls the CREATE3 salt namespace)
///           SYSHARE           — SyShare ERC-20 address on this chain
///           LZ_ENDPOINT       — LayerZero EndpointV2 address on this chain
///           OFT_OWNER         — multisig that controls peer config and rate limits
///
/// @dev Run:
///   forge script script/oft/DeployOFTAdapter.s.sol --rpc-url $HOME_RPC --broadcast --verify --interactives 1

contract DeployOFTAdapter is Script {
    function run() external {
        address deployer   = vm.envAddress("DEPLOYER_ADDRESS");
        address syShare    = vm.envAddress("SYSHARE");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address oftOwner   = vm.envAddress("OFT_OWNER");

        // First 20 bytes = deployer (CreateX front-run protection).
        // Last 12 bytes  = unique suffix (intentional truncation of bytes32 salt to bytes12).
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(ADAPTER_SALT_SUFFIX)));

        bytes memory initCode = abi.encodePacked(
            type(SyOFTAdapter).creationCode,
            abi.encode(syShare, lzEndpoint, oftOwner)
        );

        address predicted = ICreateX(CREATEX).computeCreate3Address(salt, deployer);

        console.log("=== OFT ADAPTER DEPLOY (home chain) ===");
        console.log("Predicted address :", predicted);
        console.log("Deployer          :", deployer);
        console.log("SyShare           :", syShare);
        console.log("LZ Endpoint       :", lzEndpoint);
        console.log("Owner             :", oftOwner);
        console.log("");

        vm.startBroadcast();
        address adapter = ICreateX(CREATEX).deployCreate3(salt, initCode);
        vm.stopBroadcast();

        require(adapter == predicted, "DeployOFTAdapter: address mismatch");

        console.log("=== DEPLOYED ===");
        console.log("SyOFTAdapter :", adapter);
        console.log("");
        console.log("Add to .env:");
        console.log("ADAPTER=", adapter);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Deploy SySharePeer on each remote (DeployOFTPeer.s.sol)");
        console.log("  2. Set enforced options (make wire-options-home / wire-options-remote)");
        console.log("  3. Set rate limits    (make wire-ratelimit)");
        console.log("  4. Set peers LAST     (make wire-peers-home / wire-peers-remote)");
    }
}
