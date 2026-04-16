// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";

/// @title  WireOFT_SetRateLimit
/// @notice Sets outbound rate limit on the adapter (home chain only).
///         A limit of 0 (default) blocks ALL sends — this must be called
///         before the adapter is used.
///
///         Required .env:
///           ADAPTER            — SyOFTAdapter address (home chain)
///           PEER_EID           — LayerZero endpoint ID of the remote chain
///           RATE_LIMIT_AMOUNT  — max outflow per window (token units, 18 decimals)
///           RATE_LIMIT_WINDOW  — window duration in seconds (e.g. 3600 = 1 hour)
///
/// @dev Run order: options -> ratelimit -> libs -> dvn -> peers (peers LAST)
///   forge script script/helpers/WireOFT_SetRateLimit.s.sol:WireOFT_SetRateLimit --rpc-url $HOME_RPC --broadcast --interactives 1

contract WireOFT_SetRateLimit is Script {
    function run() external {
        address adapter  = vm.envAddress("ADAPTER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        uint192 limitAmt = uint192(vm.envUint("RATE_LIMIT_AMOUNT"));
        uint64  window   = uint64(vm.envUint("RATE_LIMIT_WINDOW"));

        RateLimiter.RateLimitConfig[] memory cfg = new RateLimiter.RateLimitConfig[](1);
        cfg[0] = RateLimiter.RateLimitConfig({dstEid: peerEid, limit: limitAmt, window: window});

        vm.startBroadcast();
        SyOFTAdapter(adapter).setRateLimits(cfg);
        vm.stopBroadcast();

        console.log("=== RATE LIMIT SET ===");
        console.log("Adapter :", adapter);
        console.log("PeerEid :", peerEid);
        console.log("Limit   :", limitAmt);
        console.log("Window  :", window);
    }
}
