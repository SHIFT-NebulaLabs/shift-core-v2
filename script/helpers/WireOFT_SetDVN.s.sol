// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/Script.sol";
import {LZResolver} from "script/helpers/LZResolver.s.sol";

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
///           DVN_COUNT=1  — testnet (one DVN)
///           DVN_COUNT=2  — mainnet (two DVNs)
///
///         Required .env:
///           ADAPTER           — SyOFTAdapter address (home chain)
///           PEER              — SySharePeer address  (remote chain)
///           ADAPTER_EID       — endpoint ID of home chain
///           PEER_EID          — endpoint ID of remote chain
///           DVN_COUNT         — number of required DVNs: 1 (testnet) or 2 (mainnet)
///           BLOCK_CONFIRMATIONS — min source block confirmations before DVNs verify
///
///         Address book mode (default for supported EVM chains):
///           DVN_1_NAME        — first DVN provider name  (e.g. "LayerZero Labs")
///           DVN_2_NAME        — second DVN provider name (e.g. "Nethermind", DVN_COUNT=2 only)
///           Endpoint, libs, executor, and DVN addresses resolved via lz-address-book.
///
///         Manual fallback (unsupported chains or custom DVNs):
///           LZ_ENDPOINT / SEND_LIB / RECEIVE_LIB / EXECUTOR / DVN_1 / DVN_2
///           Raw addresses — DVNs must be pre-sorted ascending.
///
/// @dev Run order: options -> ratelimit -> libs -> dvn -> peers (peers LAST)
///   forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Shared helper ────────────────────────────────────────────────────────────

library DVNHelper {
    /// @dev Build a UlnConfig using DVN addresses (must be sorted ascending).
    function buildUln(address[] memory sortedDvns, uint64 confs)
        internal
        pure
        returns (UlnConfig memory uln)
    {
        address[] memory optionalDVNs = new address[](0);
        uln = UlnConfig({
            confirmations:        confs,
            // forge-lint: disable-next-line(unsafe-typecast)
            requiredDVNCount:     uint8(sortedDvns.length),
            optionalDVNCount:     NIL_DVN_COUNT,
            optionalDVNThreshold: NIL_DVN_THRESHOLD,
            requiredDVNs:         sortedDvns,
            optionalDVNs:         optionalDVNs
        });
    }
}

// ─── Home chain: send config (A -> B) + receive config (B -> A) ───────────────

contract WireOFT_SetDVN_Home is LZResolver {
    function run() external {
        _initResolver();

        address adapter  = vm.envAddress("ADAPTER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        uint64  confs    = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));
        uint256 dvnCount = vm.envOr("DVN_COUNT", uint256(2));

        address endpoint       = _endpoint();
        address sendLib        = _sendLib();
        address homeReceiveLib = _receiveLib();
        address executor       = _executor();
        address[] memory sortedDvns = _resolveDvns(dvnCount);

        UlnConfig memory uln = DVNHelper.buildUln(sortedDvns, confs);

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
        console.log("Address book     :", _useAddressBook);
        console.log("Adapter          :", adapter);
        console.log("DVN count        :", dvnCount);
        for (uint256 i = 0; i < sortedDvns.length; i++) {
            console.log("  DVN            :", sortedDvns[i]);
        }
        console.log("Executor (A->B)  :", executor);
        console.log("Confs            :", confs);
        console.log("SendLib (A->B)   :", sendLib);
        console.log("ReceiveLib (B->A):", homeReceiveLib);
    }
}

// ─── Remote chain: receive config (A -> B) + send config (B -> A) ────────────

contract WireOFT_SetDVN_Remote is LZResolver {
    function run() external {
        _initResolver();

        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        uint64  confs      = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));
        uint256 dvnCount   = vm.envOr("DVN_COUNT", uint256(2));

        address endpoint      = _endpoint();
        address receiveLib    = _receiveLib();
        address remoteSendLib = _sendLib();
        address remoteExec    = _executor();
        address[] memory sortedDvns = _resolveDvns(dvnCount);

        UlnConfig memory uln = DVNHelper.buildUln(sortedDvns, confs);

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
        console.log("Address book     :", _useAddressBook);
        console.log("Peer             :", peer);
        console.log("DVN count        :", dvnCount);
        for (uint256 i = 0; i < sortedDvns.length; i++) {
            console.log("  DVN            :", sortedDvns[i]);
        }
        console.log("Executor (B->A)  :", remoteExec);
        console.log("Confs            :", confs);
        console.log("ReceiveLib (A->B):", receiveLib);
        console.log("SendLib (B->A)   :", remoteSendLib);
    }
}
