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

/// @title  WireOFT_DVN
/// @notice Configures DVN + Executor security settings on a deployed OFT pathway.
///         Must be run AFTER WireOFT (peers + options already set).
///
///         Two contracts — run each on the correct chain:
///           WireOFT_SetDVN_Home   — send config on HOME chain   (A -> B)
///           WireOFT_SetDVN_Remote — receive config on REMOTE chain (B <- A)
///
///         Both sides MUST use the same DVN set, or messages will be blocked.
///         DVN addresses must be sorted ascending (lower address first).
///
///         DVN_COUNT controls how many DVNs are configured:
///           DVN_COUNT=1  — testnet (set DVN_HOME + DVN_REMOTE only)
///           DVN_COUNT=2  — mainnet (also set DVN_HOME_2 + DVN_REMOTE_2, sorted ascending)
///
///         Required .env:
///           LZ_ENDPOINT         — LayerZero EndpointV2 address
///           ADAPTER             — SyOFTAdapter address (home chain)
///           PEER                — SySharePeer address  (remote chain)
///           ADAPTER_EID         — endpoint ID of home chain
///           PEER_EID            — endpoint ID of remote chain
///           SEND_LIB            — SendUln302 address on home chain
///           RECEIVE_LIB         — ReceiveUln302 address on remote chain
///           EXECUTOR            — LayerZero Executor address on home chain
///           DVN_HOME            — LZ DVN address on HOME chain   (used by SetDVN_Home)
///           DVN_REMOTE          — LZ DVN address on REMOTE chain (used by SetDVN_Remote)
///           DVN_HOME_2          — second DVN on home chain   (mainnet, DVN_COUNT=2 only)
///           DVN_REMOTE_2        — second DVN on remote chain (mainnet, DVN_COUNT=2 only)
///           DVN_COUNT           — number of required DVNs: 1 (testnet) or 2 (mainnet)
///           BLOCK_CONFIRMATIONS — min source block confirmations before DVNs verify
///
///         Find SEND_LIB, RECEIVE_LIB, EXECUTOR, DVN addresses at:
///           https://docs.layerzero.network/v2/deployments/chains/arbitrum-sepolia
///           https://docs.layerzero.network/v2/deployments/chains/base-sepolia
///
/// @dev Run:
///   forge script script/helpers/WireOFT_DVN.s.sol:WireOFT_SetDVN_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_DVN.s.sol:WireOFT_SetDVN_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

// ─── Shared constants ─────────────────────────────────────────────────────────

// Per LZ docs: setting 0 for optional fields means "use default".
// Use type(uint8).max to explicitly mean "none" (NIL).
uint8  constant NIL_DVN_COUNT    = type(uint8).max;
uint8  constant NIL_DVN_THRESHOLD = 0; // threshold 0 is unambiguously "none"

// ─── Shared helper ────────────────────────────────────────────────────────────

library DVNHelper {
    function buildRequiredDVNs(uint256 count, address dvn1, address dvn2)
        internal
        pure
        returns (address[] memory dvns)
    {
        dvns = new address[](count);
        dvns[0] = dvn1;
        if (count == 2) {
            require(uint160(dvn1) < uint160(dvn2), "WireOFT_DVN: DVN must be sorted ascending (lower address first)");
            dvns[1] = dvn2;
        }
    }
}

// ─── Home chain: send config (A -> B) ────────────────────────────────────────

contract WireOFT_SetDVN_Home is Script {
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN      = 2;

    function run() external {
        address endpoint  = vm.envAddress("LZ_ENDPOINT");
        address adapter   = vm.envAddress("ADAPTER");
        uint32  peerEid   = uint32(vm.envUint("PEER_EID"));
        address sendLib   = vm.envAddress("SEND_LIB");
        address executor  = vm.envAddress("EXECUTOR");
        address dvn1      = vm.envAddress("DVN_HOME");
        uint256 dvnCount  = vm.envOr("DVN_COUNT", uint256(2));
        address dvn2      = dvnCount == 2 ? vm.envAddress("DVN_HOME_2") : address(0);
        uint64  confs     = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));

        address[] memory requiredDVNs = DVNHelper.buildRequiredDVNs(dvnCount, dvn1, dvn2);
        address[] memory optionalDVNs = new address[](0);

        UlnConfig memory uln = UlnConfig({
            confirmations:        confs,
            requiredDVNCount:     uint8(dvnCount),
            optionalDVNCount:     NIL_DVN_COUNT,    // type(uint8).max = explicitly no optional DVNs
            optionalDVNThreshold: NIL_DVN_THRESHOLD,
            requiredDVNs:         requiredDVNs,
            optionalDVNs:         optionalDVNs
        });

        ExecutorConfig memory exec = ExecutorConfig({
            maxMessageSize: 10_000,
            executor:       executor
        });

        SetConfigParam[] memory params = new SetConfigParam[](2);
        params[0] = SetConfigParam(peerEid, CONFIG_TYPE_EXECUTOR, abi.encode(exec));
        params[1] = SetConfigParam(peerEid, CONFIG_TYPE_ULN,      abi.encode(uln));

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setConfig(adapter, sendLib, params);
        vm.stopBroadcast();

        console.log("=== DVN SEND CONFIG SET (home -> remote) ===");
        console.log("Adapter   :", adapter);
        console.log("PeerEid   :", peerEid);
        console.log("DVN count :", dvnCount);
        console.log("DVN_HOME  :", dvn1);
        if (dvnCount == 2) console.log("DVN_HOME_2:", dvn2);
        console.log("Executor  :", executor);
        console.log("Confs     :", confs);
    }
}

// ─── Remote chain: receive config (B <- A) ───────────────────────────────────

contract WireOFT_SetDVN_Remote is Script {
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    function run() external {
        address endpoint   = vm.envAddress("LZ_ENDPOINT");
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        address receiveLib = vm.envAddress("RECEIVE_LIB");
        address dvn1       = vm.envAddress("DVN_REMOTE");
        uint256 dvnCount   = vm.envOr("DVN_COUNT", uint256(2));
        address dvn2       = dvnCount == 2 ? vm.envAddress("DVN_REMOTE_2") : address(0);
        uint64  confs      = uint64(vm.envUint("BLOCK_CONFIRMATIONS"));

        address[] memory requiredDVNs = DVNHelper.buildRequiredDVNs(dvnCount, dvn1, dvn2);
        address[] memory optionalDVNs = new address[](0);

        // Receive side: ULN config only — no Executor on destination.
        UlnConfig memory uln = UlnConfig({
            confirmations:        confs,
            requiredDVNCount:     uint8(dvnCount),
            optionalDVNCount:     NIL_DVN_COUNT,    // type(uint8).max = explicitly no optional DVNs
            optionalDVNThreshold: NIL_DVN_THRESHOLD,
            requiredDVNs:         requiredDVNs,
            optionalDVNs:         optionalDVNs
        });

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam(adapterEid, CONFIG_TYPE_ULN, abi.encode(uln));

        vm.startBroadcast();
        ILayerZeroEndpointV2(endpoint).setConfig(peer, receiveLib, params);
        vm.stopBroadcast();

        console.log("=== DVN RECEIVE CONFIG SET (remote <- home) ===");
        console.log("Peer         :", peer);
        console.log("AdapterEid   :", adapterEid);
        console.log("DVN count    :", dvnCount);
        console.log("DVN_REMOTE   :", dvn1);
        if (dvnCount == 2) console.log("DVN_REMOTE_2 :", dvn2);
        console.log("Confs        :", confs);
    }
}
