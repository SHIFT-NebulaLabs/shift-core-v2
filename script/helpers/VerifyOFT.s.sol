// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

// EndpointV2.delegates() is not in ILayerZeroEndpointV2 — use a minimal interface.
interface IEndpointDelegate {
    function delegates(address oapp) external view returns (address);
}

/// @title  VerifyOFT
/// @notice Read-only scripts. Verify that an OFT pathway is correctly deployed and wired.
///         No transactions — safe to run at any time.
///
///         Two contracts — run each on the correct chain:
///           VerifyOFT_Home   — checks adapter on HOME chain
///           VerifyOFT_Remote — checks peer on REMOTE chain
///
///         Required .env:
///           LZ_ENDPOINT    — LayerZero EndpointV2 address (same on all EVM chains)
///           ADAPTER        — SyOFTAdapter address (home chain)
///           PEER           — SySharePeer address  (remote EVM chain)
///           ADAPTER_EID    — LayerZero endpoint ID of the home chain
///           PEER_EID       — LayerZero endpoint ID of the remote chain
///           SYSHARE        — expected syShare token (adapter side)
///           OFT_OWNER      — expected owner and delegate on both contracts
///
///         Optional .env:
///           PEER_BYTES32       — raw bytes32 peer address for non-EVM peers
///           VAULT_SHARE_NAME   — expected peer token name
///           VAULT_SHARE_SYMBOL — expected peer token symbol
///
/// @dev Run:
///   forge script script/helpers/VerifyOFT.s.sol:VerifyOFT_Home   --rpc-url $HOME_RPC
///   forge script script/helpers/VerifyOFT.s.sol:VerifyOFT_Remote --rpc-url $REMOTE_RPC

contract VerifyOFT_Home is Script {
    function run() external view {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address adapter  = vm.envAddress("ADAPTER");
        address peer     = vm.envAddress("PEER");
        uint32  peerEid  = uint32(vm.envUint("PEER_EID"));
        address syShare  = vm.envAddress("SYSHARE");
        address oftOwner = vm.envAddress("OFT_OWNER");

        bytes32 peerBytes32 = vm.envOr("PEER_BYTES32", bytes32(0)) != bytes32(0)
            ? vm.envBytes32("PEER_BYTES32")
            : bytes32(uint256(uint160(peer)));

        console.log("======================================");
        console.log("  OFT VERIFY - HOME (adapter)        ");
        console.log("======================================");

        SyOFTAdapter adapterContract = SyOFTAdapter(adapter);

        _check("adapter deployed",             adapter.code.length > 0);
        _check("adapter.token() == SYSHARE",   adapterContract.token() == syShare);
        _check("adapter.owner() == OFT_OWNER", adapterContract.owner() == oftOwner);

        bytes32 regPeer = adapterContract.peers(peerEid);
        _check("adapter.peers[PEER_EID] set",  regPeer == peerBytes32);
        console.log("  registered:", vm.toString(regPeer));
        console.log("  expected  :", vm.toString(peerBytes32));

        bytes memory opts = adapterContract.enforcedOptions(peerEid, 1 /* SEND */);
        _check("adapter enforced options set",  opts.length > 0);

        (,, uint192 rlLimit, uint64 rlWindow) = adapterContract.rateLimits(peerEid);
        _check("adapter rate limit configured", rlLimit > 0);
        console.log("  rate limit:", uint256(rlLimit));
        console.log("  window (s):", uint256(rlWindow));

        address delegate = IEndpointDelegate(endpoint).delegates(adapter);
        _check("adapter delegate == OFT_OWNER", delegate == oftOwner);
        console.log("  delegate  :", delegate);

        uint8 sd = adapterContract.sharedDecimals();
        console.log("  sharedDecimals:", sd);
        console.log("  (must match peer sharedDecimals - see verify-oft-remote)");

        console.log("======================================");
    }

    function _check(string memory _label, bool _pass) internal pure {
        console.log(_pass ? "[OK]  " : "[FAIL]", _label);
    }
}

contract VerifyOFT_Remote is Script {
    function run() external view {
        address endpoint   = vm.envAddress("LZ_ENDPOINT");
        address peer       = vm.envAddress("PEER");
        address adapter    = vm.envAddress("ADAPTER");
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        address oftOwner   = vm.envAddress("OFT_OWNER");

        bytes32 adapterBytes32 = bytes32(uint256(uint160(adapter)));

        console.log("======================================");
        console.log("  OFT VERIFY - REMOTE (peer)         ");
        console.log("======================================");

        SySharePeer peerContract = SySharePeer(peer);

        _check("peer deployed",              peer.code.length > 0);
        _check("peer.owner() == OFT_OWNER",  peerContract.owner() == oftOwner);

        bytes32 regAdapter = peerContract.peers(adapterEid);
        _check("peer.peers[ADAPTER_EID] set", regAdapter == adapterBytes32);
        console.log("  registered:", vm.toString(regAdapter));
        console.log("  expected  :", vm.toString(adapterBytes32));

        bytes memory opts = peerContract.enforcedOptions(adapterEid, 1 /* SEND */);
        _check("peer enforced options set",  opts.length > 0);

        string memory expName   = vm.envOr("VAULT_SHARE_NAME",   string(""));
        string memory expSymbol = vm.envOr("VAULT_SHARE_SYMBOL", string(""));

        console.log("  name  :", peerContract.name());
        console.log("  symbol:", peerContract.symbol());

        if (bytes(expName).length > 0) {
            _check("peer.name() matches",
                keccak256(bytes(peerContract.name())) == keccak256(bytes(expName)));
        }
        if (bytes(expSymbol).length > 0) {
            _check("peer.symbol() matches",
                keccak256(bytes(peerContract.symbol())) == keccak256(bytes(expSymbol)));
        }

        address delegate = IEndpointDelegate(endpoint).delegates(peer);
        _check("peer delegate == OFT_OWNER", delegate == oftOwner);
        console.log("  delegate  :", delegate);

        uint8 sd = peerContract.sharedDecimals();
        console.log("  sharedDecimals:", sd);
        console.log("  (must match adapter sharedDecimals - see verify-oft-home)");

        console.log("======================================");
    }

    function _check(string memory _label, bool _pass) internal pure {
        console.log(_pass ? "[OK]  " : "[FAIL]", _label);
    }
}
