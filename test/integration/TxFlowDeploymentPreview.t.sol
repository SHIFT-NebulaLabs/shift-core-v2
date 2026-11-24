// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PreviewTxFlowDeployment} from "script/protocol/PreviewTxFlowDeployment.s.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AdminGateway} from "src/AdminGateway.sol";
import {AddressRegistry} from "src/AddressRegistry.sol";
import {Hub} from "src/Hub.sol";
import {SyVault} from "src/syVault.sol";
import {AdminGateway__NotAuthorized, Hub__VaultNotActive} from "src/types/Errors.sol";
import {VaultState} from "src/types/Types.sol";
import {ITxFlowNavKeeper} from "src/integrations/txflow/ITxFlowNavKeeper.sol";
import {TxFlowNavKeeper} from "src/integrations/txflow/TxFlowNavKeeper.sol";

contract TxFlowDeploymentPreviewTest is Test {
    address private constant NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 private constant DELAY = 1 hours;

    AddressRegistry private registry;
    AdminGateway private gateway;
    Hub private hub;
    PreviewTxFlowDeployment private preview;

    function setUp() external {
        vm.chainId(42_161);
        vm.warp(1_800_000_000);
        vm.etch(NATIVE_USDC, address(new MockERC20("USDC fixture", "USDC", 6)).code);

        address predictedGateway = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new AddressRegistry(predictedGateway);
        address[] memory timelockAccounts = new address[](1);
        timelockAccounts[0] = address(this);
        gateway = new AdminGateway(DELAY, timelockAccounts, timelockAccounts, address(this), address(registry));
        assertEq(address(gateway), predictedGateway);
        hub = new Hub(address(registry));
        preview = new PreviewTxFlowDeployment();
    }

    function testUnsignedPreviewDeploysAndActivatesUsingStandardTimelock() external {
        (address navSigner, uint256 navSignerKey) = makeAddrAndKey("independent-nav");
        address executor = makeAddr("txflow-owner-and-allocator");
        address operator = makeAddr("nebula-keeper-operator");
        address feeRecipient = makeAddr("fee-recipient");

        PreviewTxFlowDeployment.DeploymentPacket memory packet = preview.buildDeployment(
            PreviewTxFlowDeployment.Config({
                deployer: address(this),
                startNonce: vm.getNonce(address(this)),
                hub: address(hub),
                gateway: address(gateway),
                executor: executor,
                feeRecipient: feeRecipient,
                navSigner: navSigner,
                operator: operator,
                maximumNavAge: 180,
                maximumApprovalLifetime: 120,
                shareName: "Shift TxFlow fixture",
                shareSymbol: "sTXF",
                timelockDelay: DELAY
            })
        );

        assertEq(_create(packet.shareInitCode), packet.share);
        assertEq(_create(packet.poolInitCode), packet.pool);
        assertEq(_create(packet.vaultInitCode), packet.vault);
        assertEq(_create(packet.guardInitCode), packet.guard);
        SyVault vault = SyVault(packet.vault);
        TxFlowNavKeeper guard = TxFlowNavKeeper(packet.guard);
        assertEq(vault.asset(), NATIVE_USDC);
        assertEq(vault.keeper(), address(guard));
        assertEq(vault.allocator(), executor);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.latestSharePrice(), 1e6);
        assertTrue(vault.fastRedeemEnabled());
        assertEq(vault.fastRedeemCapBps(), 1_000);
        assertEq(guard.navSigner(), navSigner);
        assertEq(guard.operator(), operator);

        _executeAfterDelay(packet.register);
        uint256 vaultId = registry.vaultCount();
        assertEq(vaultId, 1);
        assertEq(registry.getSyVault(vaultId), packet.vault);
        assertEq(registry.getLiquidityPool(vaultId), packet.pool);
        assertEq(registry.getSyShare(vaultId), packet.share);
        assertEq(registry.getSyOft(vaultId), address(0));
        assertEq(uint8(registry.getVaultState(vaultId)), uint8(VaultState.Pending));
        assertEq(vault.performanceFeeBps(), 0);
        assertEq(vault.maintenanceFeeBps(), 0);

        vm.expectRevert(AdminGateway__NotAuthorized.selector);
        gateway.setPerformanceFeeBps(vaultId, 1500);
        _executeAfterDelay(preview.buildGovernance(address(gateway), vaultId, DELAY, false));
        assertEq(vault.performanceFeeBps(), 1500);

        PreviewTxFlowDeployment.TimelockPacket memory activation =
            preview.buildGovernance(address(gateway), vaultId, DELAY, true);
        _schedule(activation);
        vm.warp(block.timestamp + DELAY);
        _startEpoch(guard, navSignerKey, operator);
        assertLt(vault.epochEnd(), type(uint256).max);
        assertEq(uint8(registry.getVaultState(vaultId)), uint8(VaultState.Pending));
        vm.expectRevert(Hub__VaultNotActive.selector);
        hub.requestDeposit(vaultId, 1e6, address(this), address(this));

        _execute(activation);
        assertEq(uint8(registry.getVaultState(vaultId)), uint8(VaultState.Active));
    }

    function _startEpoch(TxFlowNavKeeper _guard, uint256 _navSignerKey, address _operator) private {
        uint64 observedAt = uint64(block.timestamp);
        ITxFlowNavKeeper.EpochApproval memory approval = ITxFlowNavKeeper.EpochApproval({
            epochEnd: type(uint256).max,
            price: 0,
            nonce: 0,
            observedAt: observedAt,
            validUntil: observedAt + 120,
            stateHash: _guard.stateHash(),
            evidenceHash: keccak256("independent empty-vault startup")
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_navSignerKey, _guard.approvalDigest(approval));
        vm.prank(_operator);
        _guard.settleEpoch(approval, abi.encodePacked(r, s, v));
    }

    function _create(bytes memory _initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(_initCode, 0x20), mload(_initCode))
        }
        assertNotEq(deployed, address(0), "creation failed");
    }

    function _executeAfterDelay(PreviewTxFlowDeployment.TimelockPacket memory _packet) private {
        _schedule(_packet);
        vm.warp(block.timestamp + DELAY);
        _execute(_packet);
    }

    function _schedule(PreviewTxFlowDeployment.TimelockPacket memory _packet) private {
        (bool scheduled,) = address(gateway).call(_packet.scheduleData);
        assertTrue(scheduled, "timelock schedule failed");
        assertTrue(gateway.isOperationPending(_packet.operationId));
        (bool premature,) = address(gateway).call(_packet.executeData);
        assertFalse(premature, "timelock executed before minimum delay");
    }

    function _execute(PreviewTxFlowDeployment.TimelockPacket memory _packet) private {
        assertTrue(gateway.isOperationReady(_packet.operationId));
        (bool executed,) = address(gateway).call(_packet.executeData);
        assertTrue(executed, "timelock execute failed");
        assertTrue(gateway.isOperationDone(_packet.operationId));
    }
}
