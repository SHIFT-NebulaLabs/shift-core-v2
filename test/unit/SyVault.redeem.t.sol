// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {CycleState, CycleType, RedeemCycle} from "src/types/Types.sol";
import {
    SyVault__ZeroAmount,
    SyVault__RedeemRequestAlreadyPending,
    SyVault__NoPendingRequest,
    SyVault__CycleNotLocked,
    SyVault__CycleAlreadySettled,
    SyVault__NoClaimableRedeem,
    SyVault__RedeemsPaused,
    SyVault__NotHub
} from "src/types/Errors.sol";
import {
    NORMAL_REDEEM_CUTOFF,
    NORMAL_REDEEM_LOCK_WINDOW,
    SHARE_PRICE_PRECISION
} from "src/types/Constants.sol";

contract SyVaultRedeemTest is Base {

    /*//////////////////////////////////////////////////////////////
                       requestRedeem — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeem_ZeroShares() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__ZeroAmount.selector);
        hub.requestRedeem(VAULT_ID, 0, alice, alice);
    }

    function test_RevertWhen_RequestRedeem_RedeemsPaused() external {
        vm.prank(admin);
        vault.pauseRedeems();

        _giveShares(alice, 100e18);
        vm.prank(alice);
        syShare.approve(address(vault), 100e18);

        vm.prank(alice);
        vm.expectRevert(SyVault__RedeemsPaused.selector);
        hub.requestRedeem(VAULT_ID, 100e18, alice, alice);
    }

    function test_RevertWhen_RequestRedeem_AlreadyPending() external {
        uint256 shares = _giveShares(alice, 100e18);

        vm.startPrank(alice);
        syShare.approve(address(vault), shares);
        hub.requestRedeem(VAULT_ID, shares / 2, alice, alice);

        // Second request from same owner must revert
        vm.expectRevert(SyVault__RedeemRequestAlreadyPending.selector);
        hub.requestRedeem(VAULT_ID, shares / 2, alice, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_RequestRedeem_NotHub() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__NotHub.selector);
        vault.requestRedeem(100e18, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                      requestRedeem — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_requestRedeem_locksShares(uint256 shares) external {
        shares = bound(shares, 1, type(uint64).max);
        uint256 given = _giveShares(alice, shares);

        uint256 balanceBefore = syShare.balanceOf(alice);
        uint256 cycleId = _requestRedeem(alice, given);

        assertGt(cycleId, 0);
        assertEq(vault.pendingRedeemRequest(cycleId, alice), given);
        assertEq(syShare.balanceOf(alice), balanceBefore - given);
        assertEq(syShare.balanceOf(address(vault)), given);
    }

    function test_requestRedeem_multipleUsers_sameCycle(uint256 aShares, uint256 bShares) external {
        aShares = bound(aShares, 1e9, type(uint64).max);
        bShares = bound(bShares, 1e9, type(uint64).max);

        _giveShares(alice, aShares);
        _giveShares(bob, bShares);

        uint256 aCycleId = _requestRedeem(alice, aShares);
        uint256 bCycleId = _requestRedeem(bob, bShares);

        // Same cycle for both (both in Pending phase)
        assertEq(aCycleId, bCycleId);
        assertEq(vault.redeemCycleSchedule(aCycleId).shares, aShares + bShares);
    }

    function test_requestRedeem_activeRedeemTracked() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        (uint256 reqId, bool isFast) = vault.activeRedeemRequest(alice);
        assertEq(reqId, cycleId);
        assertFalse(isFast);
    }

    function test_requestRedeem_pastCutoff_opensNewCycle() external {
        // Get both share batches BEFORE any time warp so epoch settlement works
        uint256 firstShares = _giveShares(alice, 100e18);
        uint256 moreShares  = _giveShares(alice, 50e18);

        uint256 firstCycleId = _requestRedeem(alice, firstShares);

        // Advance past cutoff of the first cycle
        _warpEpochs(NORMAL_REDEEM_CUTOFF + 1);

        // Cancel alice's request so she can open a new cycle
        vm.prank(alice);
        hub.cancelRedeemRequest(VAULT_ID, firstCycleId, alice);

        uint256 secondCycleId = _requestRedeem(alice, moreShares);

        assertGt(secondCycleId, firstCycleId);
    }

    /*//////////////////////////////////////////////////////////////
                  cancelRedeemRequest — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_cancelRedeemRequest_returnsShares(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);

        uint256 cycleId = _requestRedeem(alice, shares);

        uint256 vaultBalBefore = syShare.balanceOf(address(vault));
        uint256 aliceBalBefore = syShare.balanceOf(alice);

        vm.prank(alice);
        hub.cancelRedeemRequest(VAULT_ID, cycleId, alice);

        assertEq(syShare.balanceOf(alice), aliceBalBefore + shares);
        assertEq(syShare.balanceOf(address(vault)), vaultBalBefore - shares);
        assertEq(vault.pendingRedeemRequest(cycleId, alice), 0);
        assertEq(vault.pendingRedeemShares(), 0);

        (uint256 reqId,) = vault.activeRedeemRequest(alice);
        assertEq(reqId, 0); // cleared
    }

    function test_cancelRedeemRequest_alwaysAvailableWhenPaused(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        vm.prank(admin);
        vault.pause();

        vm.prank(alice);
        hub.cancelRedeemRequest(VAULT_ID, cycleId, alice); // must not revert
        assertEq(syShare.balanceOf(alice), shares);
    }

    /*//////////////////////////////////////////////////////////////
                 cancelRedeemRequest — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CancelRedeem_NoPendingRequest() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__NoPendingRequest.selector);
        hub.cancelRedeemRequest(VAULT_ID, 1, alice);
    }

    function test_RevertWhen_CancelRedeem_AfterLock() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1); // past lock

        vm.prank(alice);
        vm.expectRevert(SyVault__CycleNotLocked.selector);
        hub.cancelRedeemRequest(VAULT_ID, cycleId, alice);
    }

    /*//////////////////////////////////////////////////////////////
                   settleRedeemBatch — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_settleRedeemBatch_updatesState(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        _allocatorSettleCycle(cycleId, amount);

        RedeemCycle memory settled = vault.redeemCycleSchedule(cycleId);
        assertTrue(settled.settled);
        assertEq(settled.returnedAmount, amount);
        assertEq(settled.cycleRate, (amount * SHARE_PRICE_PRECISION) / shares);
        assertEq(vault.claimableRedeemRequest(cycleId, alice), shares);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function test_settleRedeemBatch_burnedShares() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        uint256 supplyBefore = syShare.totalSupply();
        _allocatorSettleCycle(cycleId, 100e18);

        assertEq(syShare.totalSupply(), supplyBefore - shares);
    }

    function test_settleRedeemBatch_cycleState_isClaimable() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Locked));

        _allocatorSettleCycle(cycleId, 100e18);

        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Claimable));
    }

    /*//////////////////////////////////////////////////////////////
                  settleRedeemBatch — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SettleBeforeLock() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        // Do NOT advance to lock epoch
        asset.mint(allocator, 100e18);
        vm.startPrank(allocator);
        asset.approve(address(pool), 100e18);
        pool.returnCapital(100e18);
        vm.expectRevert(SyVault__CycleNotLocked.selector);
        vault.settleRedeemBatch(cycleId, 100e18);
        vm.stopPrank();
    }

    function test_RevertWhen_SettleAlreadySettled() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        _allocatorSettleCycle(cycleId, 100e18);

        // Try to settle again — must revert
        asset.mint(allocator, 100e18);
        vm.startPrank(allocator);
        asset.approve(address(pool), 100e18);
        pool.returnCapital(100e18);
        vm.expectRevert(SyVault__CycleAlreadySettled.selector);
        vault.settleRedeemBatch(cycleId, 100e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         redeem (claim) — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_redeem_transfersAssets(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);
        _allocatorSettleCycle(cycleId, amount);

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        assertEq(received, amount);
        assertEq(asset.balanceOf(alice), aliceBefore + amount);
        assertEq(vault.claimableRedeemRequest(cycleId, alice), 0);

        (uint256 reqId,) = vault.activeRedeemRequest(alice);
        assertEq(reqId, 0);
    }

    function test_redeem_profitCycleRate(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        uint256 returnAmount = amount * 2; // 2x profit
        _allocatorSettleCycle(cycleId, returnAmount);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        assertEq(received, returnAmount);
    }

    function test_redeem_lossCycleRate(uint256 amount) external {
        amount = bound(amount, 2e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);

        uint256 returnAmount = amount / 2; // 50% loss
        _allocatorSettleCycle(cycleId, returnAmount);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);

        // cycleRate = returnAmount * 1e18 / shares, then received = shares * cycleRate / 1e18
        // Two integer divisions can introduce up to shares/1e18 wei of error
        assertApproxEqAbs(received, returnAmount, shares / SHARE_PRICE_PRECISION + 1);
    }

    /*//////////////////////////////////////////////////////////////
                        withdraw (claim by assets)
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_transfersAssets(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);
        _allocatorSettleCycle(cycleId, amount);

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesBurned = hub.withdraw(VAULT_ID, amount, alice, alice);

        assertEq(asset.balanceOf(alice), aliceBefore + amount);
        assertEq(sharesBurned, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            redeem — REVERT
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Redeem_NothingClaimable() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__NoClaimableRedeem.selector);
        hub.redeem(VAULT_ID, 1e18, alice, alice);
    }

    function test_RevertWhen_Redeem_NotYetSettled() external {
        uint256 shares = _giveShares(alice, 100e18);
        _requestRedeem(alice, shares);

        vm.prank(alice);
        vm.expectRevert(SyVault__NoClaimableRedeem.selector);
        hub.redeem(VAULT_ID, shares, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                       maxRedeem / currentCycleState
    //////////////////////////////////////////////////////////////*/

    function test_maxRedeem_zeroBeforeSettlement() external {
        uint256 shares = _giveShares(alice, 100e18);
        _requestRedeem(alice, shares);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function test_maxRedeem_nonZeroAfterSettlement() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);
        _allocatorSettleCycle(cycleId, 100e18);

        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_currentCycleState_transitions() external {
        uint256 shares = _giveShares(alice, 100e18);
        uint256 cycleId = _requestRedeem(alice, shares);

        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Pending));

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);

        vm.warp(cycle.cutoffEpoch * 1 hours + 1);
        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Cutoff));

        vm.warp(cycle.lockEpoch * 1 hours + 1);
        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Locked));

        _allocatorSettleCycle(cycleId, 100e18);
        assertEq(uint8(vault.currentCycleState(cycleId)), uint8(CycleState.Claimable));
    }
}
