// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {ILayerZeroEndpointV2}
    from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

// gracePeriod = 0: library switch is immediate.
uint256 constant GRACE_PERIOD = 0;

/// @title  WireOFT_SetLibs
/// @notice Explicitly pins SendUln302 / ReceiveUln302 to each OFT contract for BOTH
///         directions of the channel. Run on mainnet to lock in your library choice
///         so a future default-library upgrade cannot silently change security assumptions.
///
///         Each contract handles ONE chain and sets libs for BOTH directions:
///
///           WireOFT_SetLibs_Home (run on HOME chain):
///             setSendLibrary   adapter → peerEid    (A -> B send)
///             setReceiveLibrary adapter ← peerEid   (B -> A receive)
///
///           WireOFT_SetLibs_Remote (run on REMOTE chain):
///             setReceiveLibrary peer ← adapterEid   (A -> B receive)
///             setSendLibrary   peer → adapterEid    (B -> A send)
///
///         Required .env:
///           LZ_ENDPOINT       — LayerZero EndpointV2 address (same on all EVM chains)
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of the home chain
///           PEER_EID          — endpoint ID of the remote chain
///           SEND_LIB          — SendUln302 on HOME chain   (A -> B send)
///           HOME_RECEIVE_LIB  — ReceiveUln302 on HOME chain (B -> A receive)
///           RECEIVE_LIB       — ReceiveUln302 on REMOTE chain (A -> B receive)
///           REMOTE_SEND_LIB   — SendUln302 on REMOTE chain  (B -> A send)
///
/// @dev Run:
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Home chain: both libs for home-side (A -> B send, B -> A receive) ────────

contract WireOFT_SetLibs_Home is Script {
    function run() external {
        address endpoint       = vm.envAddress("LZ_ENDPOINT");
        address adapter        = vm.envAddress("ADAPTER");
        uint32  peerEid        = uint32(vm.envUint("PEER_EID"));
        address sendLib        = vm.envAddress("SEND_LIB");
        address homeReceiveLib = vm.envAddress("HOME_RECEIVE_LIB");

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setSendLibrary(adapter, peerEid, sendLib);
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(adapter, peerEid, homeReceiveLib, GRACE_PERIOD);
        vm.stopBroadcast();

        console.log("=== LIBS SET (home chain) ===");
        console.log("Adapter          :", adapter);
        console.log("PeerEid          :", peerEid);
        console.log("SendLib (A->B)   :", sendLib);
        console.log("ReceiveLib (B->A):", homeReceiveLib);
    }
}

// ─── Remote chain: both libs for remote-side (A -> B receive, B -> A send) ───

contract WireOFT_SetLibs_Remote is Script {
    function run() external {
        address endpoint      = vm.envAddress("LZ_ENDPOINT");
        address peer          = vm.envAddress("PEER");
        uint32  adapterEid    = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib    = vm.envAddress("RECEIVE_LIB");
        address remoteSendLib = vm.envAddress("REMOTE_SEND_LIB");

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(peer, adapterEid, receiveLib, GRACE_PERIOD);
        ILayerZeroEndpointV2(endpoint).setSendLibrary(peer, adapterEid, remoteSendLib);
        vm.stopBroadcast();

        console.log("=== LIBS SET (remote chain) ===");
        console.log("Peer             :", peer);
        console.log("AdapterEid       :", adapterEid);
        console.log("ReceiveLib (A->B):", receiveLib);
        console.log("SendLib (B->A)   :", remoteSendLib);
    }
}
