// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {OptionsBuilder}      from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

/// @title  WireOFT_SetOptions
/// @notice Sets enforced gas options on the adapter and peer.
///         Must be set on BOTH sides before any other wiring step.
///         Ensures senders always pay enough gas for lzReceive at the destination.
///
///         Required .env:
///           ADAPTER        — SyOFTAdapter address (home chain)
///           PEER           — SySharePeer address  (remote chain)
///           ADAPTER_EID    — LayerZero endpoint ID of the home chain
///           PEER_EID       — LayerZero endpoint ID of the remote chain
///
///         Optional .env:
///           ENFORCED_GAS   — gas for lzReceive (default: 80 000)
///
/// @dev Run order: options -> ratelimit -> libs -> dvn -> peers (peers LAST)
///   forge script script/helpers/WireOFT_SetOptions.s.sol:WireOFT_SetOptions_Home   --rpc-url $HOME_RPC   --broadcast --interactives 1
///   forge script script/helpers/WireOFT_SetOptions.s.sol:WireOFT_SetOptions_Remote --rpc-url $REMOTE_RPC --broadcast --interactives 1

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
        console.log("Gas:", gas);
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
        console.log("Gas:", gas);
    }
}
