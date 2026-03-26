// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {ILayerZeroEndpointV2}
    from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam}
    from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig}
    from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {ExecutorConfig}
    from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";

// ─── Shared constants ─────────────────────────────────────────────────────────

// Per LZ docs: 0 means "use default". type(uint8).max = NIL = explicitly none.
uint8  constant NIL_DVN_COUNT     = type(uint8).max;
uint8  constant NIL_DVN_THRESHOLD = 0;

uint32 constant CONFIG_TYPE_EXECUTOR = 1;
uint32 constant CONFIG_TYPE_ULN      = 2;

/// @title  WireOFT_SetDVN
/// @notice Configures DVN + Executor security for BOTH directions of the OFT channel.
///
///         Each contract handles ONE chain and sets config for BOTH directions:
///
///           WireOFT_SetDVN_Home (run on HOME chain):
///             setConfig sendLib    -> Executor + ULN send config   (A -> B)
///             setConfig receiveLib -> ULN receive config            (B -> A)
///
///           WireOFT_SetDVN_Remote (run on REMOTE chain):
///             setConfig receiveLib -> ULN receive config            (A -> B)
///             setConfig sendLib    -> Executor + ULN send config    (B -> A)
///
///         Both sides MUST use the same DVN set and block confirmations per direction
///         or messages will be permanently blocked.
///         DVN addresses must be sorted ascending (lower address first).
///
///         DVN_COUNT controls how many DVNs are configured:
///           DVN_COUNT=1  — testnet (set DVN_HOME + DVN_REMOTE only)
///           DVN_COUNT=2  — mainnet (set DVN_HOME + DVN_HOME_2, DVN_REMOTE + DVN_REMOTE_2, sorted ascending)
///
///         Required .env:
///           LZ_ENDPOINT       — LayerZero EndpointV2 address
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of home chain
///           PEER_EID          — endpoint ID of remote chain
///           SEND_LIB          — SendUln302 on HOME chain     (A -> B send)
///           HOME_RECEIVE_LIB  — ReceiveUln302 on HOME chain  (B -> A receive)
///           RECEIVE_LIB       — ReceiveUln302 on REMOTE chain (A -> B receive)
///           REMOTE_SEND_LIB   — SendUln302 on REMOTE chain   (B -> A send)
///           EXECUTOR          — LayerZero Executor on HOME chain   (A -> B)
///           REMOTE_EXECUTOR   — LayerZero Executor on REMOTE chain (B -> A)
///           DVN_HOME          — LZ DVN address on HOME chain
///           DVN_REMOTE        — LZ DVN address on REMOTE chain
///           DVN_HOME_2        — second DVN on home chain   (mainnet, DVN_COUNT=2 only)
///           DVN_REMOTE_2      — second DVN on remote chain (mainnet, DVN_COUNT=2 only)
///           DVN_COUNT         — number of required DVNs: 1 (testnet) or 2 (mainnet)
///           BLOCK_CONFIRMATIONS — min source block confirmations before DVNs verify
///
///         Find lib, executor, and DVN addresses at:
///           https://docs.layerzero.network/v2/deployments/chains
///
/// @dev Run order: options -> ratelimit -> libs -> dvn -> peers (peers LAST)
///   forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Shared helper ────────────────────────────────────────────────────────────

library DVNHelper {
    function buildRequiredDvns(uint256 count, address dvn1, address dvn2)
        internal
        pure
        returns (address[] memory dvns)
    {
        dvns = new address[](count);
        dvns[0] = dvn1;
        if (count == 2) {
            require(
                uint160(dvn1) < uint160(dvn2),
                "WireOFT_SetDVN: DVN addresses must be sorted ascending (lower address first)"
            );
            dvns[1] = dvn2;
        }
    }

    function buildUln(uint256 dvnCount, address dvn1, address dvn2, uint64 confs)
        internal
        pure
        returns (UlnConfig memory uln)
    {
        require(dvnCount <= type(uint8).max, "DVNHelper: dvnCount overflow");
        address[] memory requiredDVNs = buildRequiredDvns(dvnCount, dvn1, dvn2);
        address[] memory optionalDVNs = new address[](0);
        uln = UlnConfig({
            confirmations:        confs,
            // forge-lint: disable-next-line(unsafe-typecast)
            requiredDVNCount:     uint8(dvnCount),
            optionalDVNCount:     NIL_DVN_COUNT,
            optionalDVNThreshold: NIL_DVN_THRESHOLD,
            requiredDVNs:         requiredDVNs,
            optionalDVNs:         optionalDVNs
        });
    }
}

// ─── Home chain: send config (A -> B) + receive config (B -> A) ───────────────

contract WireOFT_SetDVN_Home is Script {
    function run() external {
        address endpoint       = vm.envAddress("LZ_ENDPOINT");
        address adapter        = vm.envAddress("ADAPTER");
        uint32  peerEid        = uint32(vm.envUint("PEER_EID"));
        address sendLib        = vm.envAddress("SEND_LIB");
        address homeReceiveLib = vm.envAddress("HOME_RECEIVE_LIB");
        address executor       = vm.envAddress("EXECUTOR");
        address dvn1           = vm.envAddress("DVN_HOME");
        uint256 dvnCount       = vm.envOr("DVN_COUNT", uint256(2));
        address dvn2           = dvnCount == 2 ? vm.envAddress("DVN_HOME_2") : address(0);
        uint64  confs          = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));

        UlnConfig memory uln = DVNHelper.buildUln(dvnCount, dvn1, dvn2, confs);

        // A -> B: send config (Executor + ULN) on home chain
        ExecutorConfig memory exec = ExecutorConfig({maxMessageSize: 10_000, executor: executor});
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam({eid: peerEid, configType: CONFIG_TYPE_EXECUTOR, config: abi.encode(exec)});
        sendParams[1] = SetConfigParam({eid: peerEid, configType: CONFIG_TYPE_ULN,      config: abi.encode(uln)});

        // B -> A: receive config (ULN only) on home chain
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam({eid: peerEid, configType: CONFIG_TYPE_ULN, config: abi.encode(uln)});

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setConfig(adapter, sendLib,        sendParams);
        ILayerZeroEndpointV2(endpoint).setConfig(adapter, homeReceiveLib, recvParams);
        vm.stopBroadcast();

        console.log("=== DVN CONFIG SET (home chain) ===");
        console.log("Adapter          :", adapter);
        console.log("DVN count        :", dvnCount);
        console.log("DVN_HOME         :", dvn1);
        if (dvnCount == 2) console.log("DVN_HOME_2       :", dvn2);
        console.log("Executor (A->B)  :", executor);
        console.log("Confs            :", confs);
        console.log("SendLib (A->B)   :", sendLib);
        console.log("ReceiveLib (B->A):", homeReceiveLib);
    }
}

// ─── Remote chain: receive config (A -> B) + send config (B -> A) ────────────

contract WireOFT_SetDVN_Remote is Script {
    function run() external {
        address endpoint      = vm.envAddress("LZ_ENDPOINT");
        address peer          = vm.envAddress("PEER");
        uint32  adapterEid    = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib    = vm.envAddress("RECEIVE_LIB");
        address remoteSendLib = vm.envAddress("REMOTE_SEND_LIB");
        address remoteExec    = vm.envAddress("REMOTE_EXECUTOR");
        address dvn1          = vm.envAddress("DVN_REMOTE");
        uint256 dvnCount      = vm.envOr("DVN_COUNT", uint256(2));
        address dvn2          = dvnCount == 2 ? vm.envAddress("DVN_REMOTE_2") : address(0);
        uint64  confs         = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));

        UlnConfig memory uln = DVNHelper.buildUln(dvnCount, dvn1, dvn2, confs);

        // A -> B: receive config (ULN only) on remote chain
        SetConfigParam[] memory recvParams = new SetConfigParam[](1);
        recvParams[0] = SetConfigParam({eid: adapterEid, configType: CONFIG_TYPE_ULN, config: abi.encode(uln)});

        // B -> A: send config (Executor + ULN) on remote chain
        ExecutorConfig memory exec = ExecutorConfig({maxMessageSize: 10_000, executor: remoteExec});
        SetConfigParam[] memory sendParams = new SetConfigParam[](2);
        sendParams[0] = SetConfigParam({eid: adapterEid, configType: CONFIG_TYPE_EXECUTOR, config: abi.encode(exec)});
        sendParams[1] = SetConfigParam({eid: adapterEid, configType: CONFIG_TYPE_ULN,      config: abi.encode(uln)});

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setConfig(peer, receiveLib,    recvParams);
        ILayerZeroEndpointV2(endpoint).setConfig(peer, remoteSendLib, sendParams);
        vm.stopBroadcast();

        console.log("=== DVN CONFIG SET (remote chain) ===");
        console.log("Peer             :", peer);
        console.log("DVN count        :", dvnCount);
        console.log("DVN_REMOTE       :", dvn1);
        if (dvnCount == 2) console.log("DVN_REMOTE_2     :", dvn2);
        console.log("Executor (B->A)  :", remoteExec);
        console.log("Confs            :", confs);
        console.log("ReceiveLib (A->B):", receiveLib);
        console.log("SendLib (B->A)   :", remoteSendLib);
    }
}
