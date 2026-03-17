// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {ILayerZeroEndpointV2}
    from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {UlnConfig}
    from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {ExecutorConfig}
    from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";

uint32 constant EXECUTOR_CONFIG_TYPE = 1;
uint32 constant ULN_CONFIG_TYPE      = 2;

// ─── Shared helper ────────────────────────────────────────────────────────────

function printUln(ILayerZeroEndpointV2 ep, address oapp, address lib, uint32 eid) view {
    bytes memory ulnBytes = ep.getConfig(oapp, lib, eid, ULN_CONFIG_TYPE);
    UlnConfig memory uln = abi.decode(ulnBytes, (UlnConfig));
    console.log("  confirmations   :", uln.confirmations);
    console.log("  requiredDVNCount:", uln.requiredDVNCount);
    for (uint256 i = 0; i < uln.requiredDVNs.length; i++) {
        console.log("  requiredDVN     :", uln.requiredDVNs[i]);
    }
    console.log("  optionalDVNCount:", uln.optionalDVNCount);
}

/// @title  VerifyDVN
/// @notice Read-only scripts. Reads and prints the active DVN + Executor config for
///         BOTH directions of the OFT channel.
///
///         Run both scripts and compare:
///           - confirmations must match per direction
///           - requiredDVNCount and DVN addresses must match per direction
///           - A->B send (home) must match A->B receive (remote)
///           - B->A send (remote) must match B->A receive (home)
///
///         Required .env:
///           LZ_ENDPOINT       — LayerZero EndpointV2 address
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of the home chain
///           PEER_EID          — endpoint ID of the remote chain
///           SEND_LIB          — SendUln302 on HOME chain
///           HOME_RECEIVE_LIB  — ReceiveUln302 on HOME chain
///           RECEIVE_LIB       — ReceiveUln302 on REMOTE chain
///           REMOTE_SEND_LIB   — SendUln302 on REMOTE chain
///
/// @dev Run:
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Home   --rpc-url $HOME_RPC
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Remote --rpc-url $REMOTE_RPC

// ─── Home chain: read both directions ────────────────────────────────────────

contract VerifyDVN_Home is Script {
    function run() external view {
        address endpoint       = vm.envAddress("LZ_ENDPOINT");
        address adapter        = vm.envAddress("ADAPTER");
        uint32  peerEid        = uint32(vm.envUint("PEER_EID"));
        address sendLib        = vm.envAddress("SEND_LIB");
        address homeReceiveLib = vm.envAddress("HOME_RECEIVE_LIB");

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);

        console.log("======================================");
        console.log("  DVN VERIFY - HOME CHAIN            ");
        console.log("  Adapter:", adapter);
        console.log("======================================");

        // A -> B send config
        console.log("--- A->B send config (SendLib) -------");
        bytes memory execBytes = ep.getConfig(adapter, sendLib, peerEid, EXECUTOR_CONFIG_TYPE);
        ExecutorConfig memory exec = abi.decode(execBytes, (ExecutorConfig));
        console.log("  executor        :", exec.executor);
        console.log("  maxMessageSize  :", exec.maxMessageSize);
        printUln(ep, adapter, sendLib, peerEid);

        // B -> A receive config
        console.log("--- B->A receive config (ReceiveLib) -");
        printUln(ep, adapter, homeReceiveLib, peerEid);

        console.log("======================================");
    }
}

// ─── Remote chain: read both directions ──────────────────────────────────────

contract VerifyDVN_Remote is Script {
    function run() external view {
        address endpoint      = vm.envAddress("LZ_ENDPOINT");
        address peer          = vm.envAddress("PEER");
        uint32  adapterEid    = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib    = vm.envAddress("RECEIVE_LIB");
        address remoteSendLib = vm.envAddress("REMOTE_SEND_LIB");

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);

        console.log("======================================");
        console.log("  DVN VERIFY - REMOTE CHAIN          ");
        console.log("  Peer:", peer);
        console.log("======================================");

        // A -> B receive config
        console.log("--- A->B receive config (ReceiveLib) -");
        printUln(ep, peer, receiveLib, adapterEid);

        // B -> A send config
        console.log("--- B->A send config (SendLib) -------");
        bytes memory execBytes = ep.getConfig(peer, remoteSendLib, adapterEid, EXECUTOR_CONFIG_TYPE);
        ExecutorConfig memory exec = abi.decode(execBytes, (ExecutorConfig));
        console.log("  executor        :", exec.executor);
        console.log("  maxMessageSize  :", exec.maxMessageSize);
        printUln(ep, peer, remoteSendLib, adapterEid);

        console.log("======================================");
    }
}
