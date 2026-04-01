// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {LZAddressContext} from "lz-address-book/LZAddressBook.sol";

/// @title  LZResolver
/// @notice Shared base for scripts that need LayerZero infrastructure addresses.
///         Tries the lz-address-book first (auto-detected via block.chainid).
///         Falls back to .env variables when the chain or a DVN provider is not
///         in the address book — so non-EVM pathways (Starknet, etc.) still work
///         with manual config.
///
///         Env var fallback keys (only needed when address book cannot resolve):
///           LZ_ENDPOINT       — EndpointV2
///           SEND_LIB          — SendUln302
///           RECEIVE_LIB       — ReceiveUln302
///           EXECUTOR          — Executor
///           DVN_1 … DVN_N     — DVN addresses (raw, must be sorted ascending)
abstract contract LZResolver is Script {
    LZAddressContext internal _ctx;
    bool internal _useAddressBook;

    /// @dev Call once at the top of run(). Safe to call on any chain.
    function _initResolver() internal {
        _ctx = new LZAddressContext();
        _useAddressBook = _ctx.isChainIdSupported(block.chainid);
        if (_useAddressBook) _ctx.setChainByChainId(block.chainid);
    }

    // ── Core protocol ────────────────────────────────────────────────────────

    function _endpoint() internal view returns (address) {
        return _useAddressBook ? _ctx.getEndpointV2() : vm.envAddress("LZ_ENDPOINT");
    }

    function _sendLib() internal view returns (address) {
        return _useAddressBook ? _ctx.getSendUln302() : vm.envAddress("SEND_LIB");
    }

    function _receiveLib() internal view returns (address) {
        return _useAddressBook ? _ctx.getReceiveUln302() : vm.envAddress("RECEIVE_LIB");
    }

    function _executor() internal view returns (address) {
        return _useAddressBook ? _ctx.getExecutor() : vm.envAddress("EXECUTOR");
    }

    // ── DVNs ─────────────────────────────────────────────────────────────────

    /// @dev Resolves DVN addresses. When the address book is available AND all
    ///      requested DVN names exist, returns them sorted ascending.
    ///      Otherwise falls back to DVN_1, DVN_2, … env vars (caller must
    ///      ensure they are pre-sorted ascending).
    function _resolveDvns(uint256 dvnCount) internal returns (address[] memory sortedDvns) {
        if (_useAddressBook) {
            // Try name-based resolution
            string[] memory names = new string[](dvnCount);
            bool allFound = true;

            for (uint256 i = 0; i < dvnCount; i++) {
                // DVN_1_NAME, DVN_2_NAME, …
                string memory key = string.concat("DVN_", vm.toString(i + 1), "_NAME");
                string memory name = vm.envOr(key, string(""));
                if (bytes(name).length == 0) { allFound = false; break; }
                if (!_ctx.isDVNAvailable(name)) { allFound = false; break; }
                names[i] = name;
            }

            if (allFound) return _ctx.getSortedDVNs(names);
        }

        // Fallback: raw addresses from env (must be sorted ascending)
        sortedDvns = new address[](dvnCount);
        for (uint256 i = 0; i < dvnCount; i++) {
            // DVN_1, DVN_2, …
            string memory key = string.concat("DVN_", vm.toString(i + 1));
            sortedDvns[i] = vm.envAddress(key);
        }

        // Validate ascending sort for manual addresses
        for (uint256 i = 1; i < dvnCount; i++) {
            require(
                uint160(sortedDvns[i - 1]) < uint160(sortedDvns[i]),
                "LZResolver: DVN addresses must be sorted ascending"
            );
        }
    }
}
