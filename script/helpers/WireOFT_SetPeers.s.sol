// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

/// @title  WireOFT_SetPeers
/// @notice Registers the counterparty address on each side of the channel.
///         This is the step that opens the live message channel — always run LAST.
///         All options, rate limits, libs, and DVN config must be set before this.
///
///         Cairo / non-EVM peers:
///           Set PEER_BYTES32 to the raw bytes32 address (e.g. a Starknet contract address).
///           Only run the _Home variant — the remote side is wired via Cairo tooling.
///
///         Required .env:
///           ADAPTER        — SyOFTAdapter address (home chain)
///           PEER           — SySharePeer address  (remote EVM chain)
///           ADAPTER_EID    — LayerZero endpoint ID of the home chain
///           PEER_EID       — LayerZero endpoint ID of the remote chain
///
///         Optional .env:
///           PEER_BYTES32   — raw bytes32 override for non-EVM peers
///
/// @dev Run order: options -> ratelimit -> libs -> dvn -> peers (peers LAST)
///   forge script script/helpers/WireOFT_SetPeers.s.sol:WireOFT_SetPeers_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetPeers.s.sol:WireOFT_SetPeers_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

contract WireOFT_SetPeers_Home is Script {
    function run() external {
        address adapter = vm.envAddress("ADAPTER");
        uint32  peerEid = uint32(vm.envUint("PEER_EID"));

        // PEER_BYTES32 overrides for non-EVM peers (e.g. Cairo/Starknet).
        bytes32 peerBytes32 = vm.envOr("PEER_BYTES32", bytes32(0)) != bytes32(0)
            ? vm.envBytes32("PEER_BYTES32")
            : bytes32(uint256(uint160(vm.envAddress("PEER"))));

        vm.startBroadcast();
        SyOFTAdapter(adapter).setPeer(peerEid, peerBytes32);
        vm.stopBroadcast();

        console.log("Adapter peer set for peerEid :", peerEid);
        console.log("Peer bytes32                 :", vm.toString(peerBytes32));
        console.log("=== Channel OPEN on home side ===");
    }
}

contract WireOFT_SetPeers_Remote is Script {
    function run() external {
        address peer       = vm.envAddress("PEER");
        address adapter    = vm.envAddress("ADAPTER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));

        bytes32 adapterBytes32 = bytes32(uint256(uint160(adapter)));

        vm.startBroadcast();
        SySharePeer(peer).setPeer(adapterEid, adapterBytes32);
        vm.stopBroadcast();

        console.log("Peer peer set for adapterEid :", adapterEid);
        console.log("Adapter bytes32              :", vm.toString(adapterBytes32));
        console.log("=== Channel OPEN on remote side ===");
    }
}
