// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";

import {AddressRegistry} from "src/AddressRegistry.sol";
import {AdminGateway}    from "src/AdminGateway.sol";
import {Hub}             from "src/Hub.sol";
import {SyShare}         from "src/SyShare.sol";
import {LiquidityPool}   from "src/LiquidityPool.sol";
import {SyVault}         from "src/SyVault.sol";
import {MockERC20}       from "test/mocks/MockERC20.sol";

/// @notice Estimates raw CREATE gas for a full protocol + vault deployment.
///         Measures gasleft() around each `new`, i.e. the EVM CREATE cost (init-code
///         execution + storage writes). NOT included: the per-tx 21k base fee and the
///         calldata cost of submitting the init code. Add ~21k + ~16 gas/init-code-byte
///         per separate deploy tx for an on-chain total.
contract DeployGasTest is Test {
    // Deployed handles (storage to avoid "stack too deep").
    MockERC20       asset;
    AddressRegistry registry;
    AdminGateway    gateway;
    Hub             hub;
    SyShare         share;
    LiquidityPool   pool;
    SyVault         vault;

    // Per-contract CREATE gas.
    uint256 gasRegistry;
    uint256 gasGateway;
    uint256 gasHub;
    uint256 gasShare;
    uint256 gasPool;
    uint256 gasVault;

    function test_estimateDeploymentGas() public {
        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        _deploySingletons();
        _deployVault();
        _report();
    }

    function _deploySingletons() internal {
        address multisig = makeAddr("multisig");

        // Predict AdminGateway address to satisfy the registry<->gateway circular dep.
        // current nonce -> AddressRegistry; nonce+1 -> AdminGateway.
        address predictedGateway = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        uint256 g = gasleft();
        registry = new AddressRegistry(predictedGateway);
        gasRegistry = g - gasleft();

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        g = gasleft();
        gateway = new AdminGateway(2 days, proposers, executors, multisig, address(registry));
        gasGateway = g - gasleft();
        require(address(gateway) == predictedGateway, "gateway prediction off");

        g = gasleft();
        hub = new Hub(address(registry));
        gasHub = g - gasleft();
    }

    function _deployVault() internal {
        // SyShare needs the vault addr; SyVault needs SyShare -> predict vault addr.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);

        uint256 g = gasleft();
        share = new SyShare("Shift Yield USDC", "syUSDC", predictedVault);
        gasShare = g - gasleft();

        g = gasleft();
        pool = new LiquidityPool(address(asset), predictedVault);
        gasPool = g - gasleft();

        g = gasleft();
        vault = new SyVault(
            address(asset), address(share), address(pool), address(hub), address(gateway),
            makeAddr("keeper"), makeAddr("allocator"), makeAddr("feeRecip"),
            1_000_000, // initial price (1.0 @ 6 decimals)
            true       // fastRedeemEnabled
        );
        gasVault = g - gasleft();
        require(address(vault) == predictedVault, "vault prediction off");
    }

    function _report() internal view {
        uint256 protocolTotal = gasRegistry + gasGateway + gasHub;
        uint256 vaultTotal    = gasShare + gasPool + gasVault;

        console2.log("=================================================");
        console2.log("PROTOCOL SINGLETONS (once per chain) - CREATE gas");
        console2.log("  AddressRegistry :", gasRegistry);
        console2.log("  AdminGateway    :", gasGateway);
        console2.log("  Hub             :", gasHub);
        console2.log("  -- subtotal     :", protocolTotal);
        console2.log("-------------------------------------------------");
        console2.log("VAULT CLUSTER (per vault) - CREATE gas");
        console2.log("  SyShare         :", gasShare);
        console2.log("  LiquidityPool   :", gasPool);
        console2.log("  SyVault         :", gasVault);
        console2.log("  -- subtotal     :", vaultTotal);
        console2.log("-------------------------------------------------");
        console2.log("FIRST DEPLOY (protocol + 1 vault):", protocolTotal + vaultTotal);
        console2.log("Each ADDITIONAL vault            :", vaultTotal);
        console2.log("=================================================");
    }
}
