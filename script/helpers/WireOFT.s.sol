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
///         Run each step ONCE per chain:
///           HOME chain   (adapter):  use ADAPTER_OWNER_KEY
///           REMOTE chain (peer):     use PEER_OWNER_KEY
///         The _isDeployed() guard ensures only the correct branch executes.
///
///         Cairo / non-EVM peers:
///           - Set PEER_BYTES32 to the raw bytes32 peer address (e.g. a Starknet contract address).
///           - Leave PEER at a placeholder (0x0) — _isDeployed(PEER) will be false on EVM, which
///             is correct: the adapter side wires, the peer side is handled by Cairo tooling.
///
///         Required .env (all steps):
///           (no key in env — pass private key interactively via --interactive when running)
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
/// @dev Examples:
///   # Home chain (adapter side) — enter adapter owner key when prompted
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetOptions  --rpc-url $HOME_RPC   --broadcast --interactive
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetPeers    --rpc-url $HOME_RPC   --broadcast --interactive
///   # Remote chain (peer side) — enter peer owner key when prompted
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetOptions  --rpc-url $REMOTE_RPC --broadcast --interactive
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetPeers    --rpc-url $REMOTE_RPC --broadcast --interactive
///   # Rate limit (home chain only)
///   forge script script/helpers/WireOFT.s.sol:WireOFT_SetRateLimit --rpc-url $HOME_RPC  --broadcast --interactive
contract WireOFT_SetOptions is Script {
    using OptionsBuilder for bytes;

    // Gas profiled for a plain OFT SEND on EVM destinations.
    // Adjust per destination chain if a different gas limit is needed.
    uint128 constant DEFAULT_GAS = 80_000;

    function run() external {
        address adapter    = vm.envAddress("ADAPTER");
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        uint32  peerEid    = uint32(vm.envUint("PEER_EID"));
        uint128 gas        = uint128(vm.envOr("ENFORCED_GAS", uint256(DEFAULT_GAS)));

        bytes memory opts = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);

        // ── Adapter side (home chain) ─────────────────────────────────────────
        if (adapter.code.length > 0) {
            vm.startBroadcast();
            EnforcedOptionParam[] memory adapterOpts = new EnforcedOptionParam[](1);
            adapterOpts[0] = EnforcedOptionParam({eid: peerEid, msgType: 1 /* SEND */, options: opts});
            SyOFTAdapter(adapter).setEnforcedOptions(adapterOpts);
            vm.stopBroadcast();
            console.log("EnforcedOptions set on adapter for peerEid:", peerEid);
        }

        // ── Peer side (remote EVM chain) ──────────────────────────────────────
        if (peer.code.length > 0) {
            vm.startBroadcast();
            EnforcedOptionParam[] memory peerOpts = new EnforcedOptionParam[](1);
            peerOpts[0] = EnforcedOptionParam({eid: adapterEid, msgType: 1 /* SEND */, options: opts});
            SySharePeer(peer).setEnforcedOptions(peerOpts);
            vm.stopBroadcast();
            console.log("EnforcedOptions set on peer for adapterEid:", adapterEid);
        }
    }

    function _isDeployed(address _a) internal view returns (bool) {
        return _a.code.length > 0;
    }
}

contract WireOFT_SetPeers is Script {
    function run() external {
        address adapter    = vm.envAddress("ADAPTER");
        address peer       = vm.envAddress("PEER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        uint32  peerEid    = uint32(vm.envUint("PEER_EID"));

        // PEER_BYTES32 overrides the peer address for non-EVM peers (e.g. Cairo/Starknet).
        // If not set, derive from the PEER address.
        bytes32 adapterBytes32 = bytes32(uint256(uint160(adapter)));
        bytes32 peerBytes32;
        if (vm.envOr("PEER_BYTES32", bytes32(0)) != bytes32(0)) {
            peerBytes32 = vm.envBytes32("PEER_BYTES32");
        } else {
            peerBytes32 = bytes32(uint256(uint160(peer)));
        }

        // ── Adapter side (home chain) ─────────────────────────────────────────
        if (adapter.code.length > 0) {
            vm.startBroadcast();
            SyOFTAdapter(adapter).setPeer(peerEid, peerBytes32);
            vm.stopBroadcast();
            console.log("Adapter peer set for peerEid:", peerEid);
        }

        // ── Peer side (remote EVM chain) ──────────────────────────────────────
        if (peer.code.length > 0) {
            vm.startBroadcast();
            SySharePeer(peer).setPeer(adapterEid, adapterBytes32);
            vm.stopBroadcast();
            console.log("Peer peer set for adapterEid:", adapterEid);
        }

        console.log("=== OFT WIRED ===");
        console.log("Adapter :", adapter, "EID:", adapterEid);
        console.log("Peer    :", peer,    "EID:", peerEid);
        console.log("Channel is now OPEN. Tokens can be bridged.");
    }
}

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
