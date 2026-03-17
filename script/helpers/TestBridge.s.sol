// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console}  from "forge-std/Script.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder}   from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee}     from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {SendParam, OFTReceipt, MessagingReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {SyOFTAdapter}    from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}     from "src/crosschain/SySharePeer.sol";

/// @title  TestBridge
/// @notice Testnet-only scripts for verifying an OFT bridge pathway end-to-end.
///         Sends a small amount of syShare across chains and prints the LZ receipt.
///
///         Two scripts:
///           TestBridge_Send   — home chain (adapter) → remote chain (peer)
///           TestBridge_Return — remote chain (peer)  → home chain (adapter)
///
///         After sending, check delivery at https://layerzeroscan.com using the printed GUID.
///
///         Required .env (both scripts):
///           DEPLOYER_ADDRESS       — sender EOA (must hold syShare on source chain; must match --interactive key)
///           ADAPTER                — SyOFTAdapter address (home chain)
///           PEER                   — SySharePeer address  (remote chain)
///           ADAPTER_EID            — LayerZero endpoint ID of the home chain
///           PEER_EID               — LayerZero endpoint ID of the remote chain
///           SYSHARE                — syShare token address (home chain)
///           BRIDGE_AMOUNT          — amount to bridge in raw token units
///
///         Optional .env:
///           BRIDGE_RECIPIENT          — recipient EVM address on destination (defaults to sender)
///           BRIDGE_RECIPIENT_BYTES32  — recipient as raw bytes32 for Cairo/non-EVM destinations
///
/// @dev Run:
///   # Home -> Remote
///   forge script script/helpers/TestBridge.s.sol:TestBridge_Send --rpc-url $HOME_RPC --broadcast --interactive
///   # Remote -> Home
///   forge script script/helpers/TestBridge.s.sol:TestBridge_Return --rpc-url $REMOTE_RPC --broadcast --interactive

// ─── Home -> Remote (adapter locks, peer mints) ──────────────────────────────

contract TestBridge_Send is Script {
    using OptionsBuilder for bytes;

    function run() external {
        address sender      = vm.envAddress("DEPLOYER_ADDRESS");
        address adapterAddr = vm.envAddress("ADAPTER");
        uint32  peerEid     = uint32(vm.envUint("PEER_EID"));
        address syShare     = vm.envAddress("SYSHARE");
        uint256 amount      = vm.envUint("BRIDGE_AMOUNT");

        // Recipient on remote chain — defaults to sender's own address.
        bytes32 recipientBytes32 = vm.envOr("BRIDGE_RECIPIENT_BYTES32", bytes32(0)) != bytes32(0)
            ? vm.envBytes32("BRIDGE_RECIPIENT_BYTES32")
            : bytes32(uint256(uint160(vm.envOr("BRIDGE_RECIPIENT", sender))));

        SyOFTAdapter adapter = SyOFTAdapter(adapterAddr);

        console.log("======================================");
        console.log("    TEST BRIDGE: HOME -> REMOTE       ");
        console.log("======================================");
        console.log("Sender       :", sender);
        console.log("Adapter      :", adapterAddr);
        console.log("Destination  :", peerEid);
        console.log("Recipient    :", vm.toString(recipientBytes32));
        console.log("Amount       :", amount);
        console.log("syShare bal  :", IERC20(syShare).balanceOf(sender));
        console.log("");

        SendParam memory sendParam = SendParam({
            dstEid:       peerEid,
            to:           recipientBytes32,
            amountLD:     amount,
            minAmountLD:  amount,  // no slippage on testnet
            extraOptions: bytes(""),
            composeMsg:   bytes(""),
            oftCmd:       bytes("")
        });

        // Quote native fee.
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);
        console.log("LZ native fee (wei):", fee.nativeFee);
        console.log("Sender ETH bal     :", sender.balance);
        console.log("");

        require(sender.balance >= fee.nativeFee, "TestBridge: insufficient ETH for LZ fee");
        require(IERC20(syShare).balanceOf(sender) >= amount, "TestBridge: insufficient syShare balance");

        vm.startBroadcast();

        // Approve adapter to pull syShare.
        IERC20(syShare).approve(adapterAddr, amount);

        // Send.
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            adapter.send{value: fee.nativeFee}(sendParam, fee, sender);

        vm.stopBroadcast();

        console.log("=== SENT ===");
        console.log("GUID           :", vm.toString(msgReceipt.guid));
        console.log("Nonce          :", msgReceipt.nonce);
        console.log("Fee paid (wei) :", msgReceipt.fee.nativeFee);
        console.log("Amount sent    :", oftReceipt.amountSentLD);
        console.log("Amount received:", oftReceipt.amountReceivedLD);
        console.log("");
        console.log("Track delivery: https://layerzeroscan.com/tx/", vm.toString(msgReceipt.guid));
    }
}

// ─── Remote -> Home (peer burns, adapter unlocks) ─────────────────────────────

contract TestBridge_Return is Script {
    using OptionsBuilder for bytes;

    function run() external {
        address sender   = vm.envAddress("DEPLOYER_ADDRESS");
        address peerAddr = vm.envAddress("PEER");
        uint32  adapterEid  = uint32(vm.envUint("ADAPTER_EID"));
        uint256 amount      = vm.envUint("BRIDGE_AMOUNT");

        // Recipient on home chain — defaults to sender's own address.
        bytes32 recipientBytes32 = bytes32(uint256(uint160(
            vm.envOr("BRIDGE_RECIPIENT", sender)
        )));

        SySharePeer peer = SySharePeer(peerAddr);

        console.log("======================================");
        console.log("    TEST BRIDGE: REMOTE -> HOME       ");
        console.log("======================================");
        console.log("Sender       :", sender);
        console.log("Peer         :", peerAddr);
        console.log("Destination  :", adapterEid);
        console.log("Recipient    :", vm.toString(recipientBytes32));
        console.log("Amount       :", amount);
        console.log("Peer bal     :", IERC20(peerAddr).balanceOf(sender));
        console.log("");

        SendParam memory sendParam = SendParam({
            dstEid:       adapterEid,
            to:           recipientBytes32,
            amountLD:     amount,
            minAmountLD:  amount,
            extraOptions: bytes(""),
            composeMsg:   bytes(""),
            oftCmd:       bytes("")
        });

        // Quote native fee.
        MessagingFee memory fee = peer.quoteSend(sendParam, false);
        console.log("LZ native fee (wei):", fee.nativeFee);
        console.log("Sender ETH bal     :", sender.balance);
        console.log("");

        require(sender.balance >= fee.nativeFee, "TestBridge: insufficient ETH for LZ fee");
        require(IERC20(peerAddr).balanceOf(sender) >= amount, "TestBridge: insufficient peer token balance");

        vm.startBroadcast();

        // OFT peer burns directly — no approval needed.
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            peer.send{value: fee.nativeFee}(sendParam, fee, sender);

        vm.stopBroadcast();

        console.log("=== SENT ===");
        console.log("GUID           :", vm.toString(msgReceipt.guid));
        console.log("Nonce          :", msgReceipt.nonce);
        console.log("Fee paid (wei) :", msgReceipt.fee.nativeFee);
        console.log("Amount sent    :", oftReceipt.amountSentLD);
        console.log("Amount received:", oftReceipt.amountReceivedLD);
        console.log("");
        console.log("Track delivery: https://layerzeroscan.com/tx/", vm.toString(msgReceipt.guid));
    }
}
