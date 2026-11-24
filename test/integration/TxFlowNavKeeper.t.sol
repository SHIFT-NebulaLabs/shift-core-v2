// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AddressRegistry} from "src/AddressRegistry.sol";
import {Hub} from "src/Hub.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {SyShare} from "src/syShare.sol";
import {SyVault} from "src/syVault.sol";
import {EPOCH_DURATION, NORMAL_REDEEM_LOCK_WINDOW} from "src/types/Constants.sol";
import {SyVault__NotKeeper, SyVault__EpochNotElapsed} from "src/types/Errors.sol";
import {VaultState} from "src/types/Types.sol";
import {ITxFlowNavKeeper} from "src/integrations/txflow/ITxFlowNavKeeper.sol";
import {TxFlowNavKeeper} from "src/integrations/txflow/TxFlowNavKeeper.sol";

contract TxFlowNavKeeperTest is Test {
    address private constant NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 private constant INTAKE = 10_000e6;
    uint256 private constant INITIAL_PRICE = 1e6;
    uint64 private constant MAX_AGE = 180;
    uint64 private constant MAX_LIFETIME = 120;

    MockERC20 private asset;
    SyVault private vault;
    SyShare private share;
    LiquidityPool private pool;
    Hub private hub;
    TxFlowNavKeeper private guard;
    uint256 private vaultId;
    uint256 private navSignerKey;
    address private executor;
    address private navSigner;
    address private operator;
    address private depositor;
    address private feeRecipient;

    function setUp() public {
        vm.chainId(42_161);
        vm.warp(1_800_000_000);
        executor = makeAddr("txflow-owner-and-allocator");
        (navSigner, navSignerKey) = makeAddrAndKey("independent-nav");
        operator = makeAddr("nebula-keeper-transaction-sender");
        depositor = makeAddr("depositor");
        feeRecipient = makeAddr("fee-recipient");

        MockERC20 implementation = new MockERC20("USDC fixture", "USDC", 6);
        vm.etch(NATIVE_USDC, address(implementation).code);
        asset = MockERC20(NATIVE_USDC);
        AddressRegistry registry = new AddressRegistry(address(this));
        hub = new Hub(address(registry));
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        share = new SyShare("Shift TxFlow", "stx", predictedVault);
        pool = new LiquidityPool(address(asset), predictedVault);
        vault = new SyVault(
            address(asset),
            address(share),
            address(pool),
            address(hub),
            address(this),
            operator,
            executor,
            feeRecipient,
            INITIAL_PRICE,
            false
        );
        assertEq(address(vault), predictedVault);
        vaultId = registry.registerVault(address(vault), address(pool), address(share), address(0));
        registry.setVaultState(vaultId, VaultState.Active);
        vault.setPerformanceFeeBps(1500);
        vault.setMaintenanceFeeBps(0);
        guard = new TxFlowNavKeeper(address(vault), address(pool), executor, navSigner, operator, MAX_AGE, MAX_LIFETIME);
        vault.setKeeper(address(guard));
    }

    function testGuardStartsVaultAndSettlesFirstDeposit() external {
        _startAndDeposit();
        assertEq(share.balanceOf(depositor), 10_000e18);
        assertEq(pool.balance(), INTAKE);
        assertEq(vault.latestSharePrice(), INITIAL_PRICE);
        assertEq(guard.nonce(), 2);
    }

    function testEOACustodyAndCorePerformanceFeeRemainInStandardLifecycle() external {
        _startAndDeposit();
        vm.startPrank(executor);
        vault.setAllocatorActive(true);
        pool.deployCapital(INTAKE);
        vault.setAllocatorActive(false);
        vm.stopPrank();
        assertEq(asset.balanceOf(executor), INTAKE);
        assertEq(asset.balanceOf(address(guard)), 0);

        uint256 grossPrice = 1_010_000;
        asset.mint(executor, 100e6);
        vm.warp(block.timestamp + EPOCH_DURATION);
        uint256 priorSupply = share.totalSupply();
        _settle(_approval(grossPrice));
        uint256 expectedFeeShares = (grossPrice - INITIAL_PRICE) * priorSupply * 1500 / (grossPrice * 10_000);
        assertEq(share.balanceOf(feeRecipient), expectedFeeShares);
        assertEq(vault.latestSharePrice(), grossPrice * priorSupply / (priorSupply + expectedFeeShares));
        assertEq(vault.latestHwm(), grossPrice);

        uint256 shares = share.balanceOf(depositor);
        vm.startPrank(depositor);
        share.approve(address(vault), shares);
        uint256 cycleId = hub.requestRedeem(vaultId, shares, depositor, depositor);
        vm.stopPrank();
        vm.warp(block.timestamp + NORMAL_REDEEM_LOCK_WINDOW * EPOCH_DURATION);
        uint256 payout = shares * vault.latestSharePrice() / 1e18;
        vm.startPrank(executor);
        vault.setAllocatorActive(true);
        asset.approve(address(pool), payout);
        pool.returnCapital(payout);
        vault.settleRedeemBatch(cycleId, payout);
        vault.setAllocatorActive(false);
        vm.stopPrank();
        vm.prank(depositor);
        assertEq(hub.redeem(vaultId, shares, depositor, depositor), payout);
        assertEq(asset.balanceOf(depositor), payout);
    }

    function testShortNormalRedemptionPaysTheConfirmedCycleRateWithoutASecondFee() external {
        _startAndDeposit();
        uint256 shares = 100e18;
        vm.startPrank(depositor);
        share.approve(address(vault), shares);
        uint256 cycleId = hub.requestRedeem(vaultId, shares, depositor, depositor);
        vm.stopPrank();
        vm.warp(block.timestamp + NORMAL_REDEEM_LOCK_WINDOW * EPOCH_DURATION);
        uint256 gross = shares * vault.latestSharePrice() / 1e18;
        uint256 payout = gross * 9970 / 10000;
        vm.startPrank(executor);
        vault.setAllocatorActive(true);
        vault.settleRedeemBatch(cycleId, payout);
        vault.setAllocatorActive(false);
        vm.stopPrank();
        assertEq(vault.claimableRedeemAssets(), payout);
        vm.prank(depositor);
        assertEq(hub.redeem(vaultId, shares, depositor, depositor), payout);
        assertEq(vault.claimableRedeemAssets(), 0);
        assertEq(share.balanceOf(feeRecipient), 0);
    }

    function testRejectsUnauthorizedCallerAndWrongSigner() external {
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(0);
        bytes memory signature = _sign(approval, navSignerKey);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__Unauthorized.selector);
        vm.prank(navSigner);
        guard.settleEpoch(approval, signature);

        signature = _sign(approval, 99);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        vm.expectRevert(SyVault__NotKeeper.selector);
        vm.prank(operator);
        vault.epochSettle(0);
        assertEq(guard.nonce(), 0);
    }

    function testRejectsReplayAndChangedArbitrumState() external {
        _startAndDeposit();
        vm.warp(block.timestamp + EPOCH_DURATION);
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(INITIAL_PRICE);
        bytes memory signature = _sign(approval, navSignerKey);
        asset.mint(executor, 1);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);

        approval = _approval(INITIAL_PRICE);
        signature = _sign(approval, navSignerKey);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        assertEq(guard.nonce(), 3);
    }

    function testRejectsExpiredAndWrongEpochApprovals() external {
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(0);
        approval.epochEnd = block.timestamp;
        bytes memory signature = _sign(approval, navSignerKey);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);

        approval = _approval(0);
        vm.warp(approval.validUntil);
        signature = _sign(approval, navSignerKey);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        assertEq(guard.nonce(), 0);
    }

    function testRejectsClaimAndStalePolicyChangesAfterObservation() external {
        _requestAndSettleDeposit();
        vm.warp(block.timestamp + EPOCH_DURATION);
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(INITIAL_PRICE);
        bytes memory signature = _sign(approval, navSignerKey);

        vm.prank(depositor);
        hub.deposit(vaultId, 0, depositor, depositor);
        assertEq(vault.totalClaimableDeposits(), 0);
        assertEq(vault.effectiveSupply(), 10_000e18);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);

        approval = _approval(INITIAL_PRICE);
        signature = _sign(approval, navSignerKey);
        vault.setMaxStalePriceEpochs(3);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidApproval.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        assertEq(guard.nonce(), 2);
    }

    function testCoreRevertDoesNotConsumeNonce() external {
        _settle(_approval(0));
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(0);
        bytes memory signature = _sign(approval, navSignerKey);
        vm.expectRevert(SyVault__EpochNotElapsed.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        assertEq(guard.nonce(), 1);
    }

    function testRejectsActiveAllocatorAndPolicyDrift() external {
        _startAndDeposit();
        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(executor);
        vault.setAllocatorActive(true);
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(INITIAL_PRICE);
        bytes memory signature = _sign(approval, navSignerKey);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidVaultState.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        vm.prank(executor);
        vault.setAllocatorActive(false);

        vault.setPerformanceFeeBps(1400);
        approval = _approval(INITIAL_PRICE);
        signature = _sign(approval, navSignerKey);
        vm.expectRevert(TxFlowNavKeeper.TxFlowNavKeeper__InvalidVaultState.selector);
        vm.prank(operator);
        guard.settleEpoch(approval, signature);
        assertEq(guard.nonce(), 2);
    }

    function testDigestMatchesTypedDataEncoding() external view {
        ITxFlowNavKeeper.EpochApproval memory approval = _approval(0);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Shift TxFlow NAV Keeper"),
                keccak256("1"),
                uint256(42_161),
                address(guard)
            )
        );
        bytes32 data = keccak256(
            abi.encode(
                keccak256(
                    "EpochApproval(uint256 epochEnd,uint256 price,uint256 nonce,uint64 observedAt,uint64 validUntil,bytes32 stateHash,bytes32 evidenceHash)"
                ),
                approval.epochEnd,
                approval.price,
                approval.nonce,
                approval.observedAt,
                approval.validUntil,
                approval.stateHash,
                approval.evidenceHash
            )
        );
        assertEq(guard.approvalDigest(approval), keccak256(abi.encodePacked(hex"1901", domain, data)));
    }

    function _startAndDeposit() private {
        _requestAndSettleDeposit();
        vm.prank(depositor);
        hub.deposit(vaultId, 0, depositor, depositor);
    }

    function _requestAndSettleDeposit() private {
        _settle(_approval(0));
        assertNotEq(vault.epochEnd(), type(uint256).max);
        asset.mint(depositor, INTAKE);
        vm.startPrank(depositor);
        asset.approve(address(vault), INTAKE);
        hub.requestDeposit(vaultId, INTAKE, depositor, depositor);
        vm.stopPrank();
        vm.warp(block.timestamp + EPOCH_DURATION);
        _settle(_approval(0));
    }

    function _approval(uint256 _price) private view returns (ITxFlowNavKeeper.EpochApproval memory approval) {
        return ITxFlowNavKeeper.EpochApproval({
            epochEnd: vault.epochEnd(),
            price: _price,
            nonce: guard.nonce(),
            observedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp) + MAX_LIFETIME,
            stateHash: guard.stateHash(),
            evidenceHash: keccak256("independent-nav-evidence-fixture")
        });
    }

    function _sign(ITxFlowNavKeeper.EpochApproval memory _approvalData, uint256 _key)
        private
        view
        returns (bytes memory signature)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, guard.approvalDigest(_approvalData));
        return abi.encodePacked(r, s, v);
    }

    function _settle(ITxFlowNavKeeper.EpochApproval memory _approvalData) private {
        bytes memory signature = _sign(_approvalData, navSignerKey);
        vm.prank(operator);
        guard.settleEpoch(_approvalData, signature);
    }
}
