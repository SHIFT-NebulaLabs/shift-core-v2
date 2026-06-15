// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {CycleType, RedeemCycle, FastRedeemRequestStatus} from "src/types/Types.sol";
import {
    SyVault__ZeroAmount,
    SyVault__RedeemRequestAlreadyPending,
    SyVault__FastCycleNotSettled,
    SyVault__FastRedeemDisabled
} from "src/types/Errors.sol";
import {FAST_REDEEM_CUTOFF, FAST_REDEEM_LOCK_WINDOW, BASIS_POINTS, EPOCH_DURATION} from "src/types/Constants.sol";

contract SyVaultFastRedeemTest is Base {

    /*//////////////////////////////////////////////////////////////
                     requestFastRedeem — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_FastRedeem_ZeroShares() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__ZeroAmount.selector);
        hub.requestFastRedeem(VAULT_ID, 0, alice, alice);
    }

    function test_RevertWhen_FastRedeem_AlreadyHasNormalRedeem() external {
        uint256 shares = _giveShares(alice, 100e18);

        // Submit normal redeem first
        _requestRedeem(alice, shares / 2);

        // Fast redeem must revert
        _giveShares(alice, shares / 2);
        vm.startPrank(alice);
        syShare.approve(address(vault), shares / 2);
        vm.expectRevert(SyVault__RedeemRequestAlreadyPending.selector);
        hub.requestFastRedeem(VAULT_ID, shares / 2, alice, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_FastRedeem_AlreadyHasFastRedeem() external {
        uint256 shares = _giveShares(alice, 200e18);

        _requestFastRedeem(alice, shares / 2);

        // Second fast redeem must revert
        vm.startPrank(alice);
        syShare.approve(address(vault), shares / 2);
        vm.expectRevert(SyVault__RedeemRequestAlreadyPending.selector);
        hub.requestFastRedeem(VAULT_ID, shares / 2, alice, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_FastRedeem_PastCutoff_CycleNotSettled() external {
        // Get both batches of shares BEFORE any time warp
        uint256 aliceShares = _giveShares(alice, 100e18);
        uint256 bobShares   = _giveShares(bob, 50e18);

        _requestFastRedeem(alice, aliceShares);

        // Advance past fast cycle cutoff (12 epochs) — cycle still has alice's shares (non-empty)
        _warpEpochs(FAST_REDEEM_CUTOFF + 1);

        // Cycle is past cutoff, not settled, and has shares — bob cannot open a new fast cycle
        vm.startPrank(bob);
        syShare.approve(address(vault), bobShares);
        vm.expectRevert(SyVault__FastCycleNotSettled.selector);
        hub.requestFastRedeem(VAULT_ID, bobShares, bob, bob);
        vm.stopPrank();
    }


    /*//////////////////////////////////////////////////////////////
                     requestFastRedeem — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_requestFastRedeem_locksShares(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);

        uint256 balanceBefore = syShare.balanceOf(alice);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        assertGt(cycleId, 0);
        assertEq(vault.pendingFastRedeemRequest(cycleId, alice), shares);
        assertEq(syShare.balanceOf(alice), balanceBefore - shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        assertEq(uint8(cycle.cycleType), uint8(CycleType.Fast));
    }

    function test_requestFastRedeem_activeRedeemTracked() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        (uint256 reqId, bool isFast) = vault.activeRedeemRequest(alice);
        assertEq(reqId, cycleId);
        assertTrue(isFast);
    }

    function test_requestFastRedeem_pastCutoff_afterSettlement() external {
        // Get both batches of shares BEFORE any time warp
        uint256 aliceShares = _giveShares(alice, 100e18);
        uint256 bobShares   = _giveShares(bob, 50e18);

        uint256 firstCycleId = _requestFastRedeem(alice, aliceShares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(firstCycleId);
        vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);

        _allocatorSettleCycle(firstCycleId, 100e18);

        // Past cutoff AND settled — bob can open a new fast cycle
        uint256 bobCycleId = _requestFastRedeem(bob, bobShares);

        assertGt(bobCycleId, firstCycleId);
    }


    /*//////////////////////////////////////////////////////////////
                   fast redeem claim — WITH FEE
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeem_fee_deductedAtClaim(uint256 amount, uint256 feeBps) external {
        amount = bound(amount, 1e9, type(uint64).max);
        feeBps = bound(feeBps, 1, 2000); // 0.01% to 20%

        vm.prank(admin);
        vault.setFastRedeemFeeBps(feeBps);

        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(cycleId, amount);

        uint256 aliceBefore = asset.balanceOf(alice);
        uint256 recipBefore = asset.balanceOf(feeRecip);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        uint256 expectedFee = (amount * feeBps) / BASIS_POINTS;
        uint256 expectedNet = amount - expectedFee;

        assertEq(received, expectedNet);
        assertEq(asset.balanceOf(alice), aliceBefore + expectedNet);
        assertEq(asset.balanceOf(feeRecip), recipBefore + expectedFee);
    }

    function test_fastRedeem_feeWhitelist_exempt(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);

        vm.startPrank(admin);
        vault.setFastRedeemFeeBps(500); // 5%
        vault.setFastRedeemFeeWhitelist(alice, true);
        vm.stopPrank();

        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(cycleId, amount);

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        // Whitelisted — no fee
        assertEq(received, amount);
        assertEq(asset.balanceOf(alice), aliceBefore + amount);
        assertEq(asset.balanceOf(feeRecip), 0);
    }

    function test_fastRedeem_noFee_whenFeeBpsZero(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        // fastRedeemFeeBps defaults to 0

        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(cycleId, amount);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        assertEq(received, amount); // no fee
    }

    /*//////////////////////////////////////////////////////////////
                  claimableFastRedeemRequest — fee preview
    //////////////////////////////////////////////////////////////*/

    function test_claimableFastRedeemRequest_showsNetAmount(uint256 amount, uint256 feeBps) external {
        amount = bound(amount, 1e9, type(uint64).max);
        feeBps = bound(feeBps, 1, 2000);

        vm.prank(admin);
        vault.setFastRedeemFeeBps(feeBps);

        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(cycleId, amount);

        uint256 claimable = vault.claimableFastRedeemRequest(cycleId, alice);
        uint256 expectedNet = (amount * (BASIS_POINTS - feeBps)) / BASIS_POINTS;

        assertEq(claimable, expectedNet);
    }

    /*//////////////////////////////////////////////////////////////
               fast + normal cycles can coexist for different users
    //////////////////////////////////////////////////////////////*/

    function test_normalAndFast_differentUsers_sameEpoch() external {
        uint256 aliceAmount = 100e18;
        uint256 bobAmount   = 50e18;

        uint256 aliceShares = _giveShares(alice, aliceAmount);
        uint256 bobShares   = _giveShares(bob, bobAmount);

        uint256 normalCycleId = _requestRedeem(alice, aliceShares);
        uint256 fastCycleId   = _requestFastRedeem(bob, bobShares);

        assertNotEq(normalCycleId, fastCycleId);

        // Fast cycle settles first (shorter window)
        RedeemCycle memory fastCycle = vault.redeemCycleSchedule(fastCycleId);
        vm.warp(fastCycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(fastCycleId, bobAmount);

        vm.prank(bob);
        uint256 bobReceived = hub.redeem(VAULT_ID, bobShares, bob, bob);
        assertEq(bobReceived, bobAmount);

        // Normal cycle settles later
        RedeemCycle memory normalCycle = vault.redeemCycleSchedule(normalCycleId);
        vm.warp(normalCycle.lockEpoch * EPOCH_DURATION + 1);
        _allocatorSettleCycle(normalCycleId, aliceAmount);

        vm.prank(alice);
        uint256 aliceReceived = hub.redeem(VAULT_ID, aliceShares, alice, alice);
        assertEq(aliceReceived, aliceAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    requestFastRedeemStatus view
    //////////////////////////////////////////////////////////////*/

    function test_requestFastRedeemStatus_Ok() external view {
        assertEq(uint8(vault.requestFastRedeemStatus(alice)), uint8(FastRedeemRequestStatus.Ok));
    }

    function test_requestFastRedeemStatus_Paused() external {
        vm.prank(admin);
        vault.pauseRedeems();
        assertEq(uint8(vault.requestFastRedeemStatus(alice)), uint8(FastRedeemRequestStatus.Paused));
    }

    function test_requestFastRedeemStatus_AlreadyPending() external {
        uint256 shares = _giveShares(alice, 100e18);
        _requestFastRedeem(alice, shares);
        assertEq(
            uint8(vault.requestFastRedeemStatus(alice)),
            uint8(FastRedeemRequestStatus.AlreadyPending)
        );
    }

    function test_requestFastRedeemStatus_AlreadyPending_normalRedeemAlsoCounts() external {
        uint256 shares = _giveShares(alice, 100e18);
        _requestRedeem(alice, shares);
        // Normal redeem pending also blocks fast redeem (shared activeRedeemCycleId).
        assertEq(
            uint8(vault.requestFastRedeemStatus(alice)),
            uint8(FastRedeemRequestStatus.AlreadyPending)
        );
    }

    function test_requestFastRedeemStatus_FastCycleSettlementPending() external {
        // Open a fast cycle and advance past its cutoff without settling.
        uint256 shares = _giveShares(alice, 100e18);
        _requestFastRedeem(alice, shares);

        _warpEpochs(FAST_REDEEM_CUTOFF + 1);

        // A new fast request from bob would be blocked — prev cycle not settled.
        assertEq(
            uint8(vault.requestFastRedeemStatus(bob)),
            uint8(FastRedeemRequestStatus.FastCycleSettlementPending)
        );
    }

    function test_requestFastRedeemStatus_Ok_afterCycleSettled() external {
        uint256 sharesAlice = _giveShares(alice, 100e18);
        uint256 cycleId     = _requestFastRedeem(alice, sharesAlice);

        _warpEpochs(FAST_REDEEM_LOCK_WINDOW);
        _allocatorSettleCycle(cycleId, 100e18);

        // Cycle settled — bob can now open a new fast cycle.
        assertEq(uint8(vault.requestFastRedeemStatus(bob)), uint8(FastRedeemRequestStatus.Ok));
    }

    /*//////////////////////////////////////////////////////////////
                   setFastRedeemEnabled — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_FastRedeem_Disabled() external {
        uint256 shares = _giveShares(alice, 100e18);

        vm.prank(admin);
        vault.setFastRedeemEnabled(false);

        vm.startPrank(alice);
        syShare.approve(address(vault), shares);
        vm.expectRevert(SyVault__FastRedeemDisabled.selector);
        hub.requestFastRedeem(VAULT_ID, shares, alice, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                   setFastRedeemEnabled — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_FastRedeem_DisableDoesNotAffectInFlight() external {
        uint256 shares  = _giveShares(alice, 100e18);
        uint256 cycleId = _requestFastRedeem(alice, shares);

        // Disable after request is already in — in-flight cycle must complete normally.
        vm.prank(admin);
        vault.setFastRedeemEnabled(false);

        _warpEpochs(FAST_REDEEM_LOCK_WINDOW);
        _allocatorSettleCycle(cycleId, 100e18);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);
        assertGt(received, 0);
    }

    function test_FastRedeem_ReenableAfterDisable() external {
        uint256 shares = _giveShares(alice, 100e18);

        vm.prank(admin);
        vault.setFastRedeemEnabled(false);

        vm.startPrank(alice);
        syShare.approve(address(vault), shares);
        vm.expectRevert(SyVault__FastRedeemDisabled.selector);
        hub.requestFastRedeem(VAULT_ID, shares, alice, alice);
        vm.stopPrank();

        vm.prank(admin);
        vault.setFastRedeemEnabled(true);

        uint256 cycleId = _requestFastRedeem(alice, shares);
        assertGt(cycleId, 0);
    }

    function test_FastRedeemStatus_Disabled() external {
        vm.prank(admin);
        vault.setFastRedeemEnabled(false);

        assertEq(
            uint8(vault.requestFastRedeemStatus(alice)),
            uint8(FastRedeemRequestStatus.Disabled)
        );
    }

    function test_FastRedeemEnabled_view() external {
        assertTrue(vault.fastRedeemEnabled());

        vm.prank(admin);
        vault.setFastRedeemEnabled(false);
        assertFalse(vault.fastRedeemEnabled());
    }
}
