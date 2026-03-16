// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SySharePeer} from "src/crosschain/SySharePeer.sol";

/// @title  DeployOFTPeer
/// @notice Deploys a SySharePeer on a REMOTE chain (Chain B, C, ...).
///         The peer mints tokens on arrival from Chain A and burns on return.
///         Deploy one instance per remote chain per vault.
///
///         Deployment order (do not skip steps):
///           1. Deploy SyOFTAdapter on home chain (DeployOFTAdapter.s.sol).
///           2. Run this script on the remote chain.
///           3. Set enforced options on both ends (WireOFT.s.sol step = options).
///           4. Set peers LAST (WireOFT.s.sol step = peers).
///
///         Required .env:
///           DEPLOYER_PRIVATE_KEY   — private key of the deploying EOA
///           SYSHARE_NAME           — token name, must match home chain (e.g. "Shift Yield Share USDC")
///           SYSHARE_SYMBOL         — token symbol, must match home chain (e.g. "syUSDC")
///           LZ_ENDPOINT            — LayerZero EndpointV2 address on THIS remote chain
///           OFT_OWNER              — multisig that controls peer config
///
/// @dev Run (on the remote chain):
///   forge script script/oft/DeployOFTPeer.s.sol --rpc-url $REMOTE_RPC_URL --broadcast --verify
contract DeployOFTPeer is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        string memory name   = vm.envString("SYSHARE_NAME");
        string memory symbol = vm.envString("SYSHARE_SYMBOL");
        address lzEndpoint   = vm.envAddress("LZ_ENDPOINT");
        address oftOwner     = vm.envAddress("OFT_OWNER");

        vm.startBroadcast(deployerKey);

        SySharePeer peer = new SySharePeer(name, symbol, lzEndpoint, oftOwner);

        vm.stopBroadcast();

        console.log("=== OFT PEER DEPLOYED (remote chain) ===");
        console.log("SySharePeer  :", address(peer));
        console.log("Name         :", name);
        console.log("Symbol       :", symbol);
        console.log("LZ Endpoint  :", lzEndpoint);
        console.log("Owner        :", oftOwner);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Set enforced options on both sides (WireOFT.s.sol)");
        console.log("  2. Set peers LAST (WireOFT.s.sol)");
        console.log("");
        console.log("Add to .env:");
        console.log("PEER=", address(peer));
    }
}
