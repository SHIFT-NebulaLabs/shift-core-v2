// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/Script.sol";
import {LZResolver} from "script/helpers/LZResolver.s.sol";

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
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of the home chain
///           PEER_EID          — endpoint ID of the remote chain
///
///         Endpoint and lib addresses are resolved from the lz-address-book via block.chainid.
///         Falls back to .env (LZ_ENDPOINT, SEND_LIB, RECEIVE_LIB) for unsupported chains.
///
/// @dev Run:
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Home chain: both libs for home-side (A -> B send, B -> A receive) ────────

contract WireOFT_SetLibs_Home is LZResolver {
    function run() external {
        _initResolver();

        address adapter        = vm.envAddress("ADAPTER");
        uint32  peerEid        = uint32(vm.envUint("PEER_EID"));
        address endpoint       = _endpoint();
        address sendLib        = _sendLib();
        address homeReceiveLib = _receiveLib();

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setSendLibrary(adapter, peerEid, sendLib);
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(adapter, peerEid, homeReceiveLib, GRACE_PERIOD);
        vm.stopBroadcast();

        console.log("=== LIBS SET (home chain) ===");
        console.log("Address book     :", _useAddressBook);
        console.log("Adapter          :", adapter);
        console.log("PeerEid          :", peerEid);
        console.log("SendLib (A->B)   :", sendLib);
        console.log("ReceiveLib (B->A):", homeReceiveLib);
    }
}

// ─── Remote chain: both libs for remote-side (A -> B receive, B -> A send) ───

contract WireOFT_SetLibs_Remote is LZResolver {
    function run() external {
        _initResolver();

        address peer          = vm.envAddress("PEER");
        uint32  adapterEid    = uint32(vm.envUint("ADAPTER_EID"));
        address endpoint      = _endpoint();
        address receiveLib    = _receiveLib();
        address remoteSendLib = _sendLib();

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setReceiveLibrary(peer, adapterEid, receiveLib, GRACE_PERIOD);
        ILayerZeroEndpointV2(endpoint).setSendLibrary(peer, adapterEid, remoteSendLib);
        vm.stopBroadcast();

        console.log("=== LIBS SET (remote chain) ===");
        console.log("Address book     :", _useAddressBook);
        console.log("Peer             :", peer);
        console.log("AdapterEid       :", adapterEid);
        console.log("ReceiveLib (A->B):", receiveLib);
        console.log("SendLib (B->A)   :", remoteSendLib);
    }
}
