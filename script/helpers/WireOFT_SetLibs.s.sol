// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {ILayerZeroEndpointV2}
    from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title  WireOFT_SetLibs
/// @notice Explicitly sets the send and receive MessageLib (SendUln302 / ReceiveUln302) for
///         a deployed OFT pathway on the LayerZero Endpoint.
///
///         This step is OPTIONAL when the default libraries already match SEND_LIB /
///         RECEIVE_LIB.  Run it on mainnet to lock in your library choice before setting
///         DVN config, so that a future default-library upgrade cannot silently change
///         your security assumptions.
///
///         Run order (before wire-dvn, before wire-peers):
///           1. wire-libs-home   — setSendLibrary    on home chain (A -> B)
///           2. wire-libs-remote — setReceiveLibrary on remote chain (B <- A)
///
///         Both contracts run on the chain where the OFT contract lives.
///
///         Required .env:
///           LZ_ENDPOINT  — LayerZero EndpointV2 address
///           ADAPTER      — SyOFTAdapter address (home chain)
///           PEER         — SySharePeer address  (remote chain)
///           PEER_EID     — endpoint ID of the remote chain
///           ADAPTER_EID  — endpoint ID of the home chain
///           SEND_LIB     — SendUln302 address on home chain
///           RECEIVE_LIB  — ReceiveUln302 address on remote chain
///
/// @dev Run:
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetSendLib    --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetReceiveLib --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Home chain: set send library (A -> B) ───────────────────────────────────

contract WireOFT_SetSendLib is Script {
    function run() external {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address adapter  = vm.envAddress("ADAPTER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        address sendLib  = vm.envAddress("SEND_LIB");

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setSendLibrary(adapter, peerEid, sendLib);
        vm.stopBroadcast();

        console.log("=== SEND LIBRARY SET (home chain) ===");
        console.log("Adapter  :", adapter);
        console.log("PeerEid  :", peerEid);
        console.log("SendLib  :", sendLib);
    }
}

// ─── Remote chain: set receive library (B <- A) ──────────────────────────────

contract WireOFT_SetReceiveLib is Script {
    // gracePeriod = 0 means the library switch is immediate (no timeout).
    uint256 internal constant GRACE_PERIOD = 0;

    function run() external {
        address endpoint   = vm.envAddress("LZ_ENDPOINT");
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib = vm.envAddress("RECEIVE_LIB");

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(peer, adapterEid, receiveLib, GRACE_PERIOD);
        vm.stopBroadcast();

        console.log("=== RECEIVE LIBRARY SET (remote chain) ===");
        console.log("Peer        :", peer);
        console.log("AdapterEid  :", adapterEid);
        console.log("ReceiveLib  :", receiveLib);
    }
}
