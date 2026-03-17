// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {OptionsBuilder}      from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {RateLimiter}         from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

/// @title  WireOFT
/// @notice Wires a SyOFTAdapter <-> SySharePeer (or Cairo peer) pathway.
///
///         Step 1 — SetOptions : set enforced gas options.
///         Step 2 — SetPeers   : register peers (opens the channel — always LAST).
///         Step 3 — SetRateLimit (optional): set outbound rate limit on adapter.
///
///         !! Always SetOptions BEFORE SetPeers. SetPeers opens the live channel. !!
///
///         Each contract runs EXACTLY ONE side — home (adapter) or remote (peer).
///         This avoids false-positive code.length hits when the same address has
///         unrelated bytecode on the other chain.
///
///         Cairo / non-EVM peers:
///           - Set PEER_BYTES32 to the raw bytes32 peer address (e.g. a Starknet contract address).
///           - Only run the _Home variants — Cairo peer is wired via Cairo tooling.
///
///         Required .env (all steps):
///           (no key in env — pass private key interactively via --interactives 1 when running)
///           ADAPTER                — SyOFTAdapter address (home chain)
///           PEER                   — SySharePeer address  (remote chain, EVM)
///           PEER_BYTES32           — (optional) override: raw bytes32 peer address for non-EVM peers
///           ADAPTER_EID            — LayerZero endpoint ID of the home chain
///           PEER_EID               — LayerZero endpoint ID of the remote chain
///
///         Additional .env for SetRateLimit:
///           RATE_LIMIT_AMOUNT      — max outflow per window in token units (18 decimals)
///           RATE_LIMIT_WINDOW      — window duration in seconds (e.g. 3600 = 1 hour)
///
/// @dev Run order:
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetOptions_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetOptions_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetPeers_Home     --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetPeers_Remote   --rpc-url $REMOTE_RPC --broadcast --interactives 1
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetRateLimit      --rpc-url $HOME_RPC   --broadcast --interactives 1

// ─── SetOptions ───────────────────────────────────────────────────────────────

contract WireOFT_SetOptions_Home is Script {
    using OptionsBuilder for bytes;

    uint128 constant DEFAULT_GAS = 80_000;

    function run() external {
        address adapter = vm.envAddress("ADAPTER");
        uint32  peerEid = uint32(vm.envUint("PEER_EID"));
        uint128 gas     = uint128(vm.envOr("ENFORCED_GAS", uint256(DEFAULT_GAS)));

        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);

        EnforcedOptionParam[] memory adapterOpts = new EnforcedOptionParam[](1);
        adapterOpts[0] = EnforcedOptionParam({eid: peerEid, msgType: 1 /* SEND */, options: opts});

        vm.startBroadcast();
        SyOFTAdapter(adapter).setEnforcedOptions(adapterOpts);
        vm.stopBroadcast();

        console.log("EnforcedOptions set on adapter for peerEid:", peerEid);
    }
}

contract WireOFT_SetOptions_Remote is Script {
    using OptionsBuilder for bytes;

    uint128 constant DEFAULT_GAS = 80_000;

    function run() external {
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        uint128 gas        = uint128(vm.envOr("ENFORCED_GAS", uint256(DEFAULT_GAS)));

        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);

        EnforcedOptionParam[] memory peerOpts = new EnforcedOptionParam[](1);
        peerOpts[0] = EnforcedOptionParam({eid: adapterEid, msgType: 1 /* SEND */, options: opts});

        vm.startBroadcast();
        SySharePeer(peer).setEnforcedOptions(peerOpts);
        vm.stopBroadcast();

        console.log("EnforcedOptions set on peer for adapterEid:", adapterEid);
    }
}

// ─── SetPeers ─────────────────────────────────────────────────────────────────

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

// ─── SetRateLimit (adapter only) ──────────────────────────────────────────────

contract WireOFT_SetRateLimit is Script {
    function run() external {
        address adapter  = vm.envAddress("ADAPTER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        uint192 limitAmt = uint192(vm.envUint("RATE_LIMIT_AMOUNT"));
        uint64  window   = uint64(vm.envUint("RATE_LIMIT_WINDOW"));

        vm.startBroadcast();

        RateLimiter.RateLimitConfig[] memory cfg = new RateLimiter.RateLimitConfig[](1);
        cfg[0] = RateLimiter.RateLimitConfig({dstEid: peerEid, limit: limitAmt, window: window});

        SyOFTAdapter(adapter).setRateLimits(cfg);

        vm.stopBroadcast();

        console.log("=== RATE LIMIT SET ===");
        console.log("Adapter :", adapter);
        console.log("PeerEid :", peerEid);
        console.log("Limit   :", limitAmt);
        console.log("Window  :", window);
    }
}
