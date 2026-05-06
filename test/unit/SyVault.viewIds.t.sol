// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";

/// @notice View-only tests for the deposit-requestId enumeration getters added so
///         the FE can list a controller's request IDs without scraping events.
contract SyVaultViewIdsTest is Base {

    /*//////////////////////////////////////////////////////////////
                          getDepositRequestIds
    //////////////////////////////////////////////////////////////*/

    function test_emptyController_returnsEmptySliceAndZeroTotal() external view {
        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 0, 100);
        assertEq(ids.length, 0);
        assertEq(total, 0);
        assertEq(vault.depositRequestIdsLength(alice), 0);
        assertEq(vault.depositRequestIdsCursor(alice), 0);
    }

    function test_singleDeposit_lengthOneAndCursorZero(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        uint256 epoch = vault.currentEpoch();
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);
        assertEq(reqId, epoch);

        assertEq(vault.depositRequestIdsLength(alice), 1);
        assertEq(vault.depositRequestIdsCursor(alice), 0);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 0, 100);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], epoch);
    }

    function test_twoDepositsSameEpoch_noDuplicate(uint256 a, uint256 b) external {
        a = bound(a, 1, type(uint64).max);
        b = bound(b, 1, type(uint64).max);
        _giveAssets(alice, a + b);

        uint256 epoch = vault.currentEpoch();
        vm.startPrank(alice);
        hub.requestDeposit(VAULT_ID, a, alice, alice);
        hub.requestDeposit(VAULT_ID, b, alice, alice);
        vm.stopPrank();

        // s_epochPushed guards against duplicates in the same epoch.
        assertEq(vault.depositRequestIdsLength(alice), 1);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 0, 100);
        assertEq(total, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], epoch);
    }

    function test_twoDepositsDifferentEpochs_inSubmissionOrder() external {
        _giveAssets(alice, 3e18);

        uint256 e1 = vault.currentEpoch();
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        // Settle once to advance the epoch counter; the new deposit lands in a different epoch.
        _settleEpoch(INITIAL_PRICE);

        uint256 e2 = vault.currentEpoch();
        assertGt(e2, e1);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 2e18, alice, alice);

        assertEq(vault.depositRequestIdsLength(alice), 2);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 0, 100);
        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], e1);
        assertEq(ids[1], e2);
    }

    function test_offsetGteTotal_returnsEmptySliceWithCorrectTotal() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 1, 50);
        assertEq(ids.length, 0);
        assertEq(total, 1);

        (ids, total) = vault.getDepositRequestIds(alice, 99, 50);
        assertEq(ids.length, 0);
        assertEq(total, 1);
    }

    function test_offsetPlusLimitOverflowsTotal_clampsToTotal() external {
        _giveAssets(alice, 3e18);

        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
        _settleEpoch(INITIAL_PRICE);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
        _settleEpoch(INITIAL_PRICE);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        // total = 3, request from offset=1 with huge limit → expect 2 ids (indices 1,2).
        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 1, type(uint256).max);
        assertEq(total, 3);
        assertEq(ids.length, 2);
    }

    function test_zeroLimit_returnsEmptySliceWithCorrectTotal() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, 0, 0);
        assertEq(ids.length, 0);
        assertEq(total, 1);
    }

    /*//////////////////////////////////////////////////////////////
                       depositRequestIdsCursor
    //////////////////////////////////////////////////////////////*/

    function test_cursorAdvances_afterClaimDrainsHeadEpoch() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        // Before settlement / claim — cursor still at head.
        assertEq(vault.depositRequestIdsCursor(alice), 0);

        _settleEpoch(INITIAL_PRICE);

        // Still 0 — claim() is what advances the cursor.
        assertEq(vault.depositRequestIdsCursor(alice), 0);

        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice); // claim all

        // Head epoch fully drained → cursor moves past index 0.
        assertEq(vault.depositRequestIdsCursor(alice), 1);
        assertEq(vault.depositRequestIdsLength(alice), 1);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev With three known deposits in the array, any (offset, limit) pair must:
    ///      - never revert
    ///      - always return total == 3
    ///      - return min(limit, 3 - min(offset,3)) ids when offset < 3, else empty
    function testFuzz_pagination_respectsBounds(uint256 offset, uint256 limit) external {
        _giveAssets(alice, 3e18);

        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
        _settleEpoch(INITIAL_PRICE);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
        _settleEpoch(INITIAL_PRICE);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        (uint256[] memory ids, uint256 total) = vault.getDepositRequestIds(alice, offset, limit);

        assertEq(total, 3);
        if (offset >= 3 || limit == 0) {
            assertEq(ids.length, 0);
        } else {
            uint256 available = 3 - offset;
            uint256 expected  = limit < available ? limit : available;
            assertEq(ids.length, expected);
        }
    }
}
