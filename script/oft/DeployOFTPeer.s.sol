// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {console} from "forge-std/Script.sol";
import {LZResolver} from "script/helpers/LZResolver.s.sol";

import {SySharePeer} from "src/crosschain/SySharePeer.sol";
import {ICreateX}    from "script/interfaces/ICreateX.sol";

// Salt suffix — shared with DeployOFTAdapter so adapter + all peers of the same vault
// land at the same address. Must match the value in DeployOFTAdapter.s.sol.
bytes32 constant OFT_SALT_SUFFIX = keccak256("shift.SyOFT.v1");

// CreateX factory — same address on all EVM chains.
address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

/// @title  DeployOFTPeer
/// @notice Deploys a SySharePeer on a REMOTE chain using CreateX (CREATE3).
///         The peer mints tokens on arrival from Chain A and burns on return.
///         Deploy one instance per remote chain per vault.
///
///         CREATE3 ensures the peer lands at the same address on every remote chain,
///         regardless of the lzEndpoint constructor arg which differs per chain.
///         Address depends only on (deployer, SYSHARE, OFT_SALT_SUFFIX) — the same
///         formula used by DeployOFTAdapter, so adapter and all peers share one address.
///
///         Deployment order (do not skip steps):
///           1. Deploy SyOFTAdapter on home chain (DeployOFTAdapter.s.sol).
///           2. Run this script on each remote chain.
///           3. Set enforced options on both ends (WireOFT_SetOptions.s.sol).
///           4. Set rate limits (WireOFT_SetRateLimit.s.sol).
///           5. Set peers LAST (WireOFT_SetPeers.s.sol) — this opens the channel.
///
///         Required .env:
///           DEPLOYER_ADDRESS   — EOA used to deploy (must match the deployer used for the adapter)
///           SYSHARE            — SyShare ERC-20 address on the HOME chain (used only for salt derivation)
///           VAULT_SHARE_NAME   — token name, must match home chain (e.g. "Shift Yield Share USDC")
///           VAULT_SHARE_SYMBOL — token symbol, must match home chain (e.g. "syUSDC")
///           OFT_OWNER          — multisig that controls peer config
///
///         LZ_ENDPOINT is resolved from the lz-address-book via block.chainid.
///         Falls back to .env (LZ_ENDPOINT) for unsupported chains.
///
/// @dev Run (on each remote chain):
///   forge script script/oft/DeployOFTPeer.s.sol --rpc-url $REMOTE_RPC --broadcast --verify --interactives 1

contract DeployOFTPeer is LZResolver {
    function run() external {
        _initResolver();

        address deployer     = vm.envAddress("DEPLOYER_ADDRESS");
        address syShare      = vm.envAddress("SYSHARE");
        string memory name   = vm.envString("VAULT_SHARE_NAME");
        string memory symbol = vm.envString("VAULT_SHARE_SYMBOL");
        address lzEndpoint   = _endpoint();
        address oftOwner     = vm.envAddress("OFT_OWNER");

        // First 20 bytes = deployer (CreateX front-run protection).
        // Last 12 bytes  = vault-scoped suffix derived from the home-chain share token address.
        //   Identical formula to DeployOFTAdapter — so adapter and all peers of this vault
        //   land at the same address across chains.
        //   Different vaults have different syShare addresses → different salts → different OFT addresses.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 salt = bytes32(abi.encodePacked(deployer, bytes12(keccak256(abi.encodePacked(syShare, OFT_SALT_SUFFIX)))));

        bytes memory initCode = abi.encodePacked(
            type(SySharePeer).creationCode,
            abi.encode(name, symbol, lzEndpoint, oftOwner)
        );

        address predicted = ICreateX(CREATEX).computeCreate3Address(salt, deployer);

        console.log("=== OFT PEER DEPLOY (remote chain) ===");
        console.log("Predicted address :", predicted);
        console.log("Deployer          :", deployer);
        console.log("SyShare (salt)    :", syShare);
        console.log("Name              :", name);
        console.log("Symbol            :", symbol);
        console.log("LZ Endpoint       :", lzEndpoint);
        console.log("Owner             :", oftOwner);
        console.log("");

        vm.startBroadcast();
        address peer = ICreateX(CREATEX).deployCreate3(salt, initCode);
        vm.stopBroadcast();

        require(peer == predicted, "DeployOFTPeer: address mismatch");

        console.log("=== DEPLOYED ===");
        console.log("SySharePeer :", peer);
        console.log("");
        console.log("Add to .env:");
        console.log("PEER=", peer);
        console.log("");
        console.log("Next steps:");
        console.log("  1. Set enforced options (make wire-options-home / wire-options-remote)");
        console.log("  2. Set rate limits    (make wire-ratelimit)");
        console.log("  3. Set peers LAST     (make wire-peers-home / wire-peers-remote)");
    }
}
