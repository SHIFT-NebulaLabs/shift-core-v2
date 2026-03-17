// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

/// @title  VerifyOFT
/// @notice Read-only script. Verifies that an OFT pathway is correctly deployed and wired.
///         Run once on the home chain and once on the remote chain.
///         No transactions — safe to run at any time.
///
///         Required .env:
///           ADAPTER        — SyOFTAdapter address (home chain)
///           PEER           — SySharePeer address  (remote EVM chain); set to 0x0 for Cairo
///           ADAPTER_EID    — LayerZero endpoint ID of the home chain
///           PEER_EID       — LayerZero endpoint ID of the remote chain
///           SYSHARE        — expected syShare token (checked on adapter side only)
///           OFT_OWNER      — expected owner on both contracts
///
///         Optional .env:
///           PEER_BYTES32       — raw bytes32 peer address for Cairo/non-EVM peers
///           VAULT_SHARE_NAME   — expected peer token name  (checked on peer side)
///           VAULT_SHARE_SYMBOL — expected peer token symbol (checked on peer side)
///
/// @dev Run:
///   # Home chain (adapter side)
///   forge script script/helpers/VerifyOFT.s.sol --rpc-url $HOME_RPC
///   # Remote chain (peer side)
///   forge script script/helpers/VerifyOFT.s.sol --rpc-url $REMOTE_RPC
contract VerifyOFT is Script {
    function run() external view {
        address adapter    = vm.envAddress("ADAPTER");
        address peer       = vm.envOr("PEER", address(0));
        uint32  adapterEid = uint32(vm.envUint("ADAPTER_EID"));
        uint32  peerEid    = uint32(vm.envUint("PEER_EID"));
        address syShare    = vm.envAddress("SYSHARE");
        address oftOwner   = vm.envAddress("OFT_OWNER");

        // Resolve peer bytes32 — override for Cairo/non-EVM, otherwise derive from address.
        bytes32 peerBytes32 = vm.envOr("PEER_BYTES32", bytes32(0)) != bytes32(0)
            ? vm.envBytes32("PEER_BYTES32")
            : bytes32(uint256(uint160(peer)));

        bytes32 adapterBytes32 = bytes32(uint256(uint160(adapter)));
        bool    isCairo        = vm.envOr("PEER_BYTES32", bytes32(0)) != bytes32(0);

        console.log("======================================");
        console.log("    SHIFT PROTOCOL OFT VERIFY        ");
        console.log("======================================");
        console.log("");

        // ── Adapter (home chain) ───────────────────────────────────────────────
        if (adapter.code.length > 0) {
            console.log("--- ADAPTER (home chain) ---");

            SyOFTAdapter adapterContract = SyOFTAdapter(adapter);

            _check("adapter deployed",              true);
            _check("adapter.token() == SYSHARE",    adapterContract.token() == syShare);
            _check("adapter.owner() == OFT_OWNER",  adapterContract.owner() == oftOwner);

            bytes32 regPeer = adapterContract.peers(peerEid);
            _check("adapter.peers[PEER_EID] set",   regPeer == peerBytes32);
            console.log("  registered:", vm.toString(regPeer));
            console.log("  expected  :", vm.toString(peerBytes32));

            bytes memory opts = adapterContract.enforcedOptions(peerEid, 1 /* SEND */);
            _check("adapter enforced options set",  opts.length > 0);

            // rateLimits public mapping returns tuple: (amountInFlight, lastUpdated, limit, window)
            (,, uint192 rlLimit, uint64 rlWindow) = adapterContract.rateLimits(peerEid);
            _check("adapter rate limit configured", rlLimit > 0);
            console.log("  rate limit:", uint256(rlLimit));
            console.log("  window (s):", uint256(rlWindow));

            console.log("");
        }

        // ── Peer (remote EVM chain) ────────────────────────────────────────────
        if (!isCairo && peer != address(0) && peer.code.length > 0) {
            console.log("--- PEER (remote chain) ---");

            SySharePeer peerContract = SySharePeer(peer);

            _check("peer deployed",              true);
            _check("peer.owner() == OFT_OWNER",  peerContract.owner() == oftOwner);

            bytes32 regAdapter = peerContract.peers(adapterEid);
            _check("peer.peers[ADAPTER_EID] set", regAdapter == adapterBytes32);
            console.log("  registered:", vm.toString(regAdapter));
            console.log("  expected  :", vm.toString(adapterBytes32));

            bytes memory opts = peerContract.enforcedOptions(adapterEid, 1 /* SEND */);
            _check("peer enforced options set",  opts.length > 0);

            // Optional name / symbol check.
            string memory expName   = vm.envOr("VAULT_SHARE_NAME",   string(""));
            string memory expSymbol = vm.envOr("VAULT_SHARE_SYMBOL", string(""));

            console.log("  name  :", peerContract.name());
            console.log("  symbol:", peerContract.symbol());

            if (bytes(expName).length > 0) {
                _check("peer.name() == VAULT_SHARE_NAME",
                    keccak256(bytes(peerContract.name())) == keccak256(bytes(expName)));
            }
            if (bytes(expSymbol).length > 0) {
                _check("peer.symbol() == VAULT_SHARE_SYMBOL",
                    keccak256(bytes(peerContract.symbol())) == keccak256(bytes(expSymbol)));
            }

            console.log("");
        }

        // ── Cairo / non-EVM peer ───────────────────────────────────────────────
        if (isCairo) {
            console.log("--- CAIRO PEER (non-EVM) ---");
            console.log("  peer bytes32:", vm.toString(peerBytes32));
            console.log("  [INFO] Cairo peer cannot be verified from EVM.");
            console.log("         Verify on Starknet with starknet.js or Starkscan.");
            console.log("");
        }

        // ── Nothing found on this chain ────────────────────────────────────────
        if (adapter.code.length == 0 && (isCairo || peer == address(0) || peer.code.length == 0)) {
            console.log("[WARN] No adapter or peer found on this chain.");
            console.log("       Check ADAPTER/PEER env vars and --rpc-url.");
            console.log("");
        }

        console.log("======================================");
        console.log("  Run on each chain to verify both sides.");
        console.log("======================================");
    }

    function _check(string memory _label, bool _pass) internal pure {
        if (_pass) {
            console.log("[OK]  ", _label);
        } else {
            console.log("[FAIL]", _label);
        }
    }
}
