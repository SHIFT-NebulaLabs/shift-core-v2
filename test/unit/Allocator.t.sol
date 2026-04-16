// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {NORMAL_REDEEM_LOCK_WINDOW, FAST_REDEEM_LOCK_WINDOW} from "src/types/Constants.sol";

/// @notice Allocator end-to-end behaviour tests.
///         Covers: deploy flow, return + settle flow, both cycles in one job,
///         allocatorAllowance accounting, and setAllocatorActive interaction.
contract AllocatorTest is Base {

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Give alice shares and open a normal redeem request. Returns (cycleId, shares).
    function _openNormalCycle(uint256 assetAmount) internal returns (uint256 cycleId, uint256 shares) {
        shares  = _giveShares(alice, assetAmount);
        cycleId = _requestRedeem(alice, shares);
    }

    /// @dev Give bob shares and open a fast redeem request. Returns (cycleId, shares).
    function _openFastCycle(uint256 assetAmount) internal returns (uint256 cycleId, uint256 shares) {
        shares  = _giveShares(bob, assetAmount);
        cycleId = _requestFastRedeem(bob, shares);
    }

    /*//////////////////////////////////////////////////////////////
                    setAllocatorActive
    //////////////////////////////////////////////////////////////*/

    function test_setAllocatorActive_true() external {
        vm.prank(allocator);
        vault.setAllocatorActive(true);
        assertTrue(vault.allocatorActive());
    }

    function test_setAllocatorActive_false() external {
        vm.prank(allocator);
        vault.setAllocatorActive(true);
        vm.prank(allocator);
        vault.setAllocatorActive(false);
        assertFalse(vault.allocatorActive());
    }

    function test_setAllocatorActive_resetsSkipCount() external {
        // Trigger 1 skip by settling while active.
        vm.prank(allocator);
        vault.setAllocatorActive(true);
        _settleEpoch(INITIAL_PRICE * 2); // skipped — uses prev price

        // Reset active — should reset skip counter.
        vm.prank(allocator);
        vault.setAllocatorActive(false);

        // Setting active again should skip again (counter reset to 0).
        vm.prank(allocator);
        vault.setAllocatorActive(true);
        uint256 prevPrice = vault.latestSharePrice();
        _settleEpoch(INITIAL_PRICE * 3); // should skip again, not override
        assertEq(vault.latestSharePrice(), prevPrice);
    }

    function test_RevertWhen_setAllocatorActive_notAllocator() external {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAllocatorActive(true);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPLOY CAPITAL FLOW
    //////////////////////////////////////////////////////////////*/

    function test_deployCapital_fullFlow(uint256 depositAmount) external {
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        // Seed the pool with a deposit.
        _giveAssets(alice, depositAmount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, depositAmount, alice, alice);

        uint256 allowanceBefore = vault.investableLiquidity();
        assertEq(allowanceBefore, 0); // pending deposit not yet deployable

        _settleEpoch(INITIAL_PRICE);

        uint256 allowanceAfterSettle = vault.investableLiquidity();
        // After settlement pending deposits become deployable.
        assertEq(allowanceAfterSettle, depositAmount);

        // Claim shares — pool balance unchanged but allowance still correct.
        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice);

        // Allocator deploy flow.
        vm.prank(allocator);
        vault.setAllocatorActive(true);

        uint256 deployAmount = vault.investableLiquidity();
        vm.prank(allocator);
        pool.deployCapital(deployAmount);

        assertEq(asset.balanceOf(allocator), deployAmount);
        assertEq(vault.investableLiquidity(), 0);

        vm.prank(allocator);
        vault.setAllocatorActive(false);
        assertFalse(vault.allocatorActive());
    }

    /*//////////////////////////////////////////////////////////////
                    RETURN + SETTLE FLOW — NORMAL CYCLE
    //////////////////////////////////////////////////////////////*/

    function test_returnAndSettle_normalCycle(uint256 assetAmount) external {
        assetAmount = bound(assetAmount, 1e18, 1_000_000e18);
        (uint256 cycleId, uint256 shares) = _openNormalCycle(assetAmount);

        // Warp past lock.
        _settleEpochs(NORMAL_REDEEM_LOCK_WINDOW, INITIAL_PRICE);

        uint256 returnAmount = assetAmount; // 1:1

        vm.prank(allocator);
        vault.setAllocatorActive(true);

        asset.mint(allocator, returnAmount);
        vm.startPrank(allocator);
        asset.approve(address(pool), returnAmount);
        pool.returnCapital(returnAmount);
        vault.settleRedeemBatch(cycleId, returnAmount);
        vault.setAllocatorActive(false);
        vm.stopPrank();

        // Cycle is now settled — user can claim.
        assertEq(vault.claimableRedeemRequest(cycleId, alice), shares);
        assertFalse(vault.allocatorActive());
    }

    /*//////////////////////////////////////////////////////////////
                    RETURN + SETTLE FLOW — FAST CYCLE
    //////////////////////////////////////////////////////////////*/

    function test_returnAndSettle_fastCycle(uint256 assetAmount) external {
        assetAmount = bound(assetAmount, 1e18, 1_000_000e18);
        (uint256 cycleId, uint256 shares) = _openFastCycle(assetAmount);

        _settleEpochs(FAST_REDEEM_LOCK_WINDOW, INITIAL_PRICE);

        uint256 returnAmount = assetAmount;

        asset.mint(allocator, returnAmount);
        vm.startPrank(allocator);
        asset.approve(address(pool), returnAmount);
        pool.returnCapital(returnAmount);
        vault.settleRedeemBatch(cycleId, returnAmount);
        vm.stopPrank();

        assertEq(vault.claimableRedeemRequest(cycleId, bob), shares);
    }

    /*//////////////////////////////////////////////////////////////
                  SETTLE BOTH CYCLES IN THE SAME JOB
    //////////////////////////////////////////////////////////////*/

    function test_settleBothCycles_sameJob() external {
        uint256 normalAssets = 100e18;
        uint256 fastAssets   = 50e18;

        // Open normal cycle (alice).
        uint256 normalShares = _giveShares(alice, normalAssets);
        uint256 normalCycleId = _requestRedeem(alice, normalShares);

        // Open fast cycle (bob) — both cycles active simultaneously.
        uint256 fastShares = _giveShares(bob, fastAssets);
        uint256 fastCycleId = _requestFastRedeem(bob, fastShares);

        // Warp past the longer lock window (normal).
        _settleEpochs(NORMAL_REDEEM_LOCK_WINDOW, INITIAL_PRICE);

        // Verify both read correctly.
        assertEq(vault.currentNormalCycleId(), normalCycleId);
        assertEq(vault.currentFastCycleId(),   fastCycleId);
        assertEq(vault.redeemCycleSchedule(normalCycleId).shares, normalShares);
        assertEq(vault.redeemCycleSchedule(fastCycleId).shares,   fastShares);

        // Combined return then separate settles.
        uint256 totalReturn = normalAssets + fastAssets;

        asset.mint(allocator, totalReturn);
        vm.startPrank(allocator);
        asset.approve(address(pool), totalReturn);
        pool.returnCapital(totalReturn);

        // One settleRedeemBatch per cycle — order does not matter.
        vault.settleRedeemBatch(normalCycleId, normalAssets);
        vault.settleRedeemBatch(fastCycleId,   fastAssets);
        vm.stopPrank();

        // Both cycles settled.
        assertTrue(vault.redeemCycleSchedule(normalCycleId).settled);
        assertTrue(vault.redeemCycleSchedule(fastCycleId).settled);

        // Alice and bob can claim.
        assertEq(vault.claimableRedeemRequest(normalCycleId, alice), normalShares);
        assertEq(vault.claimableRedeemRequest(fastCycleId,   bob),   fastShares);
    }

    /*//////////////////////////////////////////////////////////////
                  allocatorAllowance ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_allocatorAllowance_zeroWhilePendingNotSettled(uint256 amount) external {
        amount = bound(amount, 1e18, 1_000_000e18);
        _giveAssets(alice, amount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        // Pending deposits are reserved — allowance is 0.
        assertEq(vault.investableLiquidity(), 0);
    }

    function test_allocatorAllowance_excludesRedeemDue() external {
        uint256 depositAmount = 100e18;
        uint256 redeemAmount  = 40e18;

        // Setup: give alice shares and open a redeem.
        uint256 shares = _giveShares(alice, depositAmount);
        uint256 redeemShares = shares * redeemAmount / depositAmount;
        _requestRedeem(alice, redeemShares);

        // redeemDue is reserved — only the remainder is deployable.
        uint256 allowance = vault.investableLiquidity();
        uint256 due       = vault.redeemDue();
        assertEq(allowance + due, pool.balance()); // they sum to total pool
    }

    function test_allocatorAllowance_claimableIsReserved() external {
        uint256 depositAmount = 100e18;

        // Give alice shares; deploy capital so pool is empty before return.
        uint256 shares = _giveShares(alice, depositAmount);
        vm.prank(allocator);
        pool.deployCapital(depositAmount); // pool → 0

        // Open and settle a redeem cycle.
        uint256 cycleId = _requestRedeem(alice, shares);
        _settleEpochs(NORMAL_REDEEM_LOCK_WINDOW, INITIAL_PRICE);

        // Return and settle — pool refilled to depositAmount.
        asset.mint(allocator, depositAmount);
        vm.startPrank(allocator);
        asset.approve(address(pool), depositAmount);
        pool.returnCapital(depositAmount);
        vault.settleRedeemBatch(cycleId, depositAmount);
        vm.stopPrank();

        // Before claim: pool = depositAmount, claimable = depositAmount → allowance = 0.
        assertEq(vault.claimableRedeemAssets(), depositAmount);
        assertEq(vault.investableLiquidity(), 0);

        // Alice claims — pool empties, claimable clears.
        vm.prank(alice);
        hub.redeem(VAULT_ID, shares, alice, alice);

        assertEq(vault.claimableRedeemAssets(), 0);
        assertEq(pool.balance(), 0);
        assertEq(asset.balanceOf(alice), depositAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLE REVERTS (invariant guards)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_settleRedeemBatch_cycleNotLocked() external {
        (uint256 cycleId2, ) = _openNormalCycle(100e18);
        cycleId2;
        uint256 cycleId = vault.currentNormalCycleId();

        // Attempt settle before lock epoch.
        asset.mint(allocator, 100e18);
        vm.startPrank(allocator);
        asset.approve(address(pool), 100e18);
        pool.returnCapital(100e18);
        vm.expectRevert();
        vault.settleRedeemBatch(cycleId, 100e18);
        vm.stopPrank();
    }

    function test_RevertWhen_settleRedeemBatch_alreadySettled() external {
        (uint256 cycleId, ) = _openNormalCycle(100e18);
        _settleEpochs(NORMAL_REDEEM_LOCK_WINDOW, INITIAL_PRICE);
        _allocatorSettleCycle(cycleId, 100e18);

        // Second settle must revert.
        asset.mint(allocator, 100e18);
        vm.startPrank(allocator);
        asset.approve(address(pool), 100e18);
        pool.returnCapital(100e18);
        vm.expectRevert();
        vault.settleRedeemBatch(cycleId, 100e18);
        vm.stopPrank();
    }
}
