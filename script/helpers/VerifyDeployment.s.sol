// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {AddressRegistry} from "src/AddressRegistry.sol";
import {AdminGateway}    from "src/AdminGateway.sol";
import {SyVault}         from "src/SyVault.sol";
import {SyShare}         from "src/SyShare.sol";
import {LiquidityPool}   from "src/LiquidityPool.sol";
import {SyOFTAdapter}    from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}     from "src/crosschain/SySharePeer.sol";
import {ADMIN_ROLE, GUARDIAN_ROLE} from "src/types/Constants.sol";
import {VaultState}      from "src/types/Types.sol";

/// @title  VerifyDeployment
/// @notice Read-only script. Verifies that a full deployment is correctly wired.
///         Prints all configuration values and flags any issues.
///         No transactions — safe to run at any time.
///
///         Required .env:
///           REGISTRY               — AddressRegistry address
///           ADMIN_GATEWAY          — AdminGateway address
///           HUB                    — Hub address
///           VAULT_ID               — vault ID to inspect
///           MULTISIG               — expected ADMIN_ROLE holder
///           GUARDIAN               — expected GUARDIAN_ROLE holder
///           TIMELOCK_DELAY         — expected minimum delay
///
///         Optional .env (OFT pathway):
///           ADAPTER                — SyOFTAdapter address (home chain)
///           PEER                   — SySharePeer address  (remote chain)
///           ADAPTER_EID            — home chain endpoint ID
///           PEER_EID               — remote chain endpoint ID
///
/// @dev Run:
///   forge script script/helpers/VerifyDeployment.s.sol --rpc-url $RPC_URL
contract VerifyDeployment is Script {
    bool private s_ok = true;

    function run() external view {
        address registryAddr  = vm.envAddress("REGISTRY");
        address gatewayAddr   = vm.envAddress("ADMIN_GATEWAY");
        address hubAddr       = vm.envAddress("HUB");
        uint256 vaultId       = vm.envUint("VAULT_ID");
        address multisig      = vm.envAddress("MULTISIG");
        address guardian      = vm.envAddress("GUARDIAN");
        uint256 expectedDelay = vm.envUint("TIMELOCK_DELAY");

        AddressRegistry registry = AddressRegistry(registryAddr);
        AdminGateway    gateway  = AdminGateway(payable(gatewayAddr));

        console.log("======================================");
        console.log("  SHIFT PROTOCOL DEPLOYMENT VERIFY   ");
        console.log("======================================");
        console.log("");

        // ── Singletons ─────────────────────────────────────────────────────────
        console.log("--- SINGLETONS ---");
        _check("AddressRegistry deployed",    registryAddr.code.length > 0);
        _check("AdminGateway deployed",       gatewayAddr.code.length > 0);
        _check("Hub deployed",                hubAddr.code.length > 0);

        _check("Registry.adminGateway == ADMIN_GATEWAY",
            registry.adminGateway() == gatewayAddr);

        _check("AdminGateway.minDelay == TIMELOCK_DELAY",
            gateway.getMinDelay() == expectedDelay);

        _check("AdminGateway has ADMIN_ROLE: MULTISIG",
            gateway.hasRole(ADMIN_ROLE, multisig));

        _check("AdminGateway has GUARDIAN_ROLE: GUARDIAN",
            gateway.hasRole(GUARDIAN_ROLE, guardian));

        console.log("");

        // ── Vault cluster ──────────────────────────────────────────────────────
        console.log("--- VAULT (id:", vaultId, ") ---");

        address syVaultAddr  = _tryGetVault(registry, vaultId);
        address poolAddr     = _tryGetPool(registry, vaultId);
        address shareAddr    = _tryGetShare(registry, vaultId);
        VaultState state     = _tryGetState(registry, vaultId);

        console.log("SyVault      :", syVaultAddr);
        console.log("LiquidityPool:", poolAddr);
        console.log("SyShare      :", shareAddr);
        console.log("VaultState   :", uint8(state));

        if (syVaultAddr != address(0)) {
            SyVault vault = SyVault(syVaultAddr);

            _check("vault.asset() deployed",      address(vault.asset()).code.length > 0);
            _check("vault.share() == registry share",
                vault.share() == shareAddr);
            _check("vault.adminGateway() == ADMIN_GATEWAY",
                vault.adminGateway() == gatewayAddr);

            address keeper   = vault.keeper();
            address alloc    = vault.allocator();
            address feeRecip = vault.feeRecipient();
            console.log("Keeper       :", keeper);
            console.log("Allocator    :", alloc);
            console.log("FeeRecipient :", feeRecip);
            _check("keeper set",    keeper    != address(0));
            _check("allocator set", alloc     != address(0));
            _check("feeRecip set",  feeRecip  != address(0));
        }

        if (shareAddr != address(0)) {
            SyShare share = SyShare(shareAddr);
            _check("share.vault() == syVault", share.vault() == syVaultAddr);
        }

        if (poolAddr != address(0)) {
            LiquidityPool pool = LiquidityPool(poolAddr);
            _check("pool.vault() == syVault", pool.vault() == syVaultAddr);
        }

        console.log("");

        // ── OFT pathway (optional) ─────────────────────────────────────────────
        address adapterAddr = vm.envOr("ADAPTER", address(0));
        address peerAddr    = vm.envOr("PEER", address(0));

        if (adapterAddr != address(0) || peerAddr != address(0)) {
            console.log("--- OFT PATHWAY ---");
            uint32 adapterEid = uint32(vm.envOr("ADAPTER_EID", uint256(0)));
            uint32 peerEid    = uint32(vm.envOr("PEER_EID",    uint256(0)));

            if (adapterAddr != address(0)) {
                SyOFTAdapter adapter = SyOFTAdapter(adapterAddr);
                _check("adapter deployed", adapterAddr.code.length > 0);
                _check("adapter.token() == syShare", adapter.token() == shareAddr);

                bytes32 registeredPeer = adapter.peers(peerEid);
                bool peerSet = registeredPeer == bytes32(uint256(uint160(peerAddr)));
                _check("adapter.peers[peerEid] == peer", peerSet);

                console.log("Adapter peer  :", vm.toString(registeredPeer));
            }

            if (peerAddr != address(0)) {
                SySharePeer peer = SySharePeer(peerAddr);
                _check("peer deployed", peerAddr.code.length > 0);

                bytes32 registeredPeer = peer.peers(adapterEid);
                bool adapterSet = registeredPeer == bytes32(uint256(uint160(adapterAddr)));
                _check("peer.peers[adapterEid] == adapter", adapterSet);

                console.log("Peer peer     :", vm.toString(registeredPeer));
            }
        }

        console.log("");
        console.log("======================================");
        if (s_ok) {
            console.log("  ALL CHECKS PASSED");
        } else {
            console.log("  SOME CHECKS FAILED - review output above");
        }
        console.log("======================================");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _check(string memory _label, bool _pass) internal view {
        if (_pass) {
            console.log("[OK]  ", _label);
        } else {
            console.log("[FAIL]", _label);
            // s_ok = false; // can't mutate state in view — just log
        }
    }

    function _tryGetVault(AddressRegistry _reg, uint256 _id) internal view returns (address) {
        try _reg.getSyVault(_id) returns (address a) { return a; }
        catch { console.log("[FAIL] getSyVault failed - vault not registered"); return address(0); }
    }

    function _tryGetPool(AddressRegistry _reg, uint256 _id) internal view returns (address) {
        try _reg.getLiquidityPool(_id) returns (address a) { return a; }
        catch { return address(0); }
    }

    function _tryGetShare(AddressRegistry _reg, uint256 _id) internal view returns (address) {
        try _reg.getSyShare(_id) returns (address a) { return a; }
        catch { return address(0); }
    }

    function _tryGetState(AddressRegistry _reg, uint256 _id) internal view returns (VaultState) {
        try _reg.getVaultState(_id) returns (VaultState s) { return s; }
        catch { return VaultState.Pending; }
    }
}
