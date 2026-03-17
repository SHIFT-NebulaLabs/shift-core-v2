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

/// @title  VerifyDVN
/// @notice Read-only scripts. Reads and prints the active DVN + Executor config for
///         a deployed OFT pathway so you can confirm send/receive configs match.
///
///         A mismatch (different confirmations or DVN sets) will permanently block messages.
///
///         Two contracts — run each on the correct chain:
///           VerifyDVN_Home   — prints send config on HOME chain   (A -> B)
///           VerifyDVN_Remote — prints receive config on REMOTE chain (B <- A)
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
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Home   --rpc-url $HOME_RPC
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Remote --rpc-url $REMOTE_RPC

// ─── Home chain: read send config (A -> B) ───────────────────────────────────

contract VerifyDVN_Home is Script {
    function run() external view {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address adapter  = vm.envAddress("ADAPTER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        address sendLib  = vm.envAddress("SEND_LIB");

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);

        console.log("======================================");
        console.log("  DVN VERIFY - HOME (send config)    ");
        console.log("======================================");
        console.log("Adapter :", adapter);
        console.log("PeerEid :", peerEid);
        console.log("SendLib :", sendLib);
        console.log("--------------------------------------");

        bytes memory execBytes = ep.getConfig(adapter, sendLib, peerEid, EXECUTOR_CONFIG_TYPE);
        ExecutorConfig memory exec = abi.decode(execBytes, (ExecutorConfig));
        console.log("Executor        :", exec.executor);
        console.log("maxMessageSize  :", exec.maxMessageSize);
        console.log("--------------------------------------");

        bytes memory ulnBytes = ep.getConfig(adapter, sendLib, peerEid, ULN_CONFIG_TYPE);
        UlnConfig memory uln = abi.decode(ulnBytes, (UlnConfig));
        console.log("confirmations   :", uln.confirmations);
        console.log("requiredDVNCount:", uln.requiredDVNCount);
        for (uint256 i = 0; i < uln.requiredDVNs.length; i++) {
            console.log("  requiredDVN   :", uln.requiredDVNs[i]);
        }
        console.log("optionalDVNCount:", uln.optionalDVNCount);
        console.log("======================================");
    }
}

// ─── Remote chain: read receive config (B <- A) ──────────────────────────────

contract VerifyDVN_Remote is Script {
    function run() external view {
        address endpoint   = vm.envAddress("LZ_ENDPOINT");
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib = vm.envAddress("RECEIVE_LIB");

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(endpoint);

        console.log("======================================");
        console.log("  DVN VERIFY - REMOTE (receive cfg)  ");
        console.log("======================================");
        console.log("Peer       :", peer);
        console.log("AdapterEid :", adapterEid);
        console.log("ReceiveLib :", receiveLib);
        console.log("--------------------------------------");

        bytes memory ulnBytes = ep.getConfig(peer, receiveLib, adapterEid, ULN_CONFIG_TYPE);
        UlnConfig memory uln = abi.decode(ulnBytes, (UlnConfig));
        console.log("confirmations   :", uln.confirmations);
        console.log("requiredDVNCount:", uln.requiredDVNCount);
        for (uint256 i = 0; i < uln.requiredDVNs.length; i++) {
            console.log("  requiredDVN   :", uln.requiredDVNs[i]);
        }
        console.log("optionalDVNCount:", uln.optionalDVNCount);
        console.log("======================================");
    }
}
