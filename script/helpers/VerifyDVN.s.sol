// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/Script.sol";
import {LZResolver} from "script/helpers/LZResolver.s.sol";

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
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of the home chain
///           PEER_EID          — endpoint ID of the remote chain
///
///         Endpoint and lib addresses are resolved from the lz-address-book via block.chainid.
///         Falls back to .env (LZ_ENDPOINT, SEND_LIB, RECEIVE_LIB) for unsupported chains.
///
/// @dev Run:
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Home   --rpc-url $HOME_RPC
///   forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Remote --rpc-url $REMOTE_RPC

// ─── Home chain: read both directions ────────────────────────────────────────

contract VerifyDVN_Home is LZResolver {
    function run() external {
        _initResolver();

        address adapter        = vm.envAddress("ADAPTER");
        uint32  peerEid        = uint32(vm.envUint("PEER_EID"));
        address sendLib        = _sendLib();
        address homeReceiveLib = _receiveLib();

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(_endpoint());

        console.log("======================================");
        console.log("  DVN VERIFY - HOME CHAIN            ");
        console.log("  Address book:", _useAddressBook);
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

contract VerifyDVN_Remote is LZResolver {
    function run() external {
        _initResolver();

        address peer          = vm.envAddress("PEER");
        uint32  adapterEid    = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib    = _receiveLib();
        address remoteSendLib = _sendLib();

        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(_endpoint());

        console.log("======================================");
        console.log("  DVN VERIFY - REMOTE CHAIN          ");
        console.log("  Address book:", _useAddressBook);
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
