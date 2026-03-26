// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {VaultState} from "src/types/Types.sol";
import {
    SyVault__ZeroAmount,
    SyVault__DepositsPaused,
    SyVault__DepositNotAllowed,
    SyVault__BelowMinDeposit,
    SyVault__NoPendingRequest,
    SyVault__NoClaimableDeposit,
    SyVault__NotHub
} from "src/types/Errors.sol";
import {DepositRequestStatus} from "src/types/Types.sol";
import {Hub__VaultNotActive} from "src/types/Errors.sol";
import {SHARE_PRICE_PRECISION} from "src/types/Constants.sol";

contract SyVaultDepositTest is Base {

    /*//////////////////////////////////////////////////////////////
                      requestDeposit — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestDeposit_ZeroAmount() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SyVault__ZeroAmount.selector);
        hub.requestDeposit(VAULT_ID, 0, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_NotHub() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SyVault__NotHub.selector);
        vault.requestDeposit(1e18, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_VaultNotActive() external {
        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Hub__VaultNotActive.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_DepositsPaused() external {
        vm.prank(admin);
        vault.pauseDeposits();

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SyVault__DepositsPaused.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_FullPause() external {
        vm.prank(admin);
        vault.pause();

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SyVault__DepositsPaused.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_NotWhitelisted() external {
        vm.startPrank(admin);
        vault.setDepositWhitelistEnabled(true);
        vault.setDepositWhitelist(bob, true); // bob whitelisted, alice not
        vm.stopPrank();

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(SyVault__DepositNotAllowed.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_RevertWhen_RequestDeposit_MaxTVLExceeded(uint256 depositAmount) external {
        depositAmount = bound(depositAmount, 2, type(uint128).max); // min 2 so cap can be >= 1
        uint256 cap = depositAmount - 1; // cap strictly below deposit (cap >= 1, so setMaxTvl is enforced)

        vm.prank(admin);
        vault.setMaxTvl(cap);

        _giveAssets(alice, depositAmount);
        vm.prank(alice);
        vm.expectRevert(SyVault__DepositNotAllowed.selector);
        hub.requestDeposit(VAULT_ID, depositAmount, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                      requestDeposit — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_requestDeposit_storesStateAndTransfersAssets(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        uint256 epoch = vault.currentEpoch();
        uint256 poolBefore = asset.balanceOf(address(pool));

        vm.prank(alice);
        uint256 requestId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        assertEq(requestId, epoch);
        assertEq(vault.pendingDepositRequest(requestId, alice), amount);
        assertEq(vault.pendingDepositAssets(), amount);
        assertEq(asset.balanceOf(address(pool)), poolBefore + amount);
        assertEq(asset.balanceOf(alice), 0);
    }

    function test_requestDeposit_whitelistAllowed() external {
        vm.startPrank(admin);
        vault.setDepositWhitelistEnabled(true);
        vault.setDepositWhitelist(alice, true);
        vm.stopPrank();

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
        assertEq(vault.pendingDepositRequest(reqId, alice), 1e18);
    }

    function test_requestDeposit_accumulatesMultiple(uint256 a, uint256 b) external {
        a = bound(a, 1, type(uint64).max);
        b = bound(b, 1, type(uint64).max);

        _giveAssets(alice, a + b);
        uint256 epoch = vault.currentEpoch();

        vm.startPrank(alice);
        hub.requestDeposit(VAULT_ID, a, alice, alice);
        hub.requestDeposit(VAULT_ID, b, alice, alice);
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(epoch, alice), a + b);
        assertEq(vault.pendingDepositAssets(), a + b);
    }

    /*//////////////////////////////////////////////////////////////
                    cancelDepositRequest — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_cancelDeposit_returnsAssets(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        vm.prank(alice);
        hub.cancelDepositRequest(VAULT_ID, reqId, alice);

        assertEq(vault.pendingDepositRequest(reqId, alice), 0);
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(asset.balanceOf(alice), aliceAssetBefore + amount);
    }

    function test_cancelDeposit_alwaysAvailableWhenPaused(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        vm.prank(admin);
        vault.pause();

        // Cancel must not revert even when fully paused
        vm.prank(alice);
        hub.cancelDepositRequest(VAULT_ID, reqId, alice);
        assertEq(asset.balanceOf(alice), amount);
    }

    /*//////////////////////////////////////////////////////////////
                  cancelDepositRequest — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CancelDeposit_NoPendingRequest() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__NoPendingRequest.selector);
        hub.cancelDepositRequest(VAULT_ID, 99, alice);
    }

    function test_RevertWhen_CancelDeposit_AfterSettlement(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE); // settles epoch 0 → reqId is now settled

        vm.prank(alice);
        vm.expectRevert(SyVault__NoPendingRequest.selector);
        hub.cancelDepositRequest(VAULT_ID, reqId, alice);
    }

    /*//////////////////////////////////////////////////////////////
                        deposit (claim) — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_deposit_claimsShares_atInitialPrice(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint128).max); // avoid dust

        _giveAssets(alice, amount);
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE);

        // EIP-7540: pending and claimable are mutually exclusive.
        // After settlement, pendingDepositRequest returns 0; claimableDepositRequest is set.
        assertEq(vault.claimableDepositRequest(reqId, alice), amount);
        assertEq(vault.pendingDepositRequest(reqId, alice), 0);

        vm.prank(alice);
        uint256 shares = hub.deposit(VAULT_ID, 0, alice, alice); // 0 = claim all

        // At 1:1 price, shares == amount
        assertEq(shares, amount);
        assertEq(syShare.balanceOf(alice), amount);
        // After claiming, both views return 0
        assertEq(vault.claimableDepositRequest(reqId, alice), 0);
        assertEq(vault.pendingDepositRequest(reqId, alice), 0);
    }

    function test_deposit_claimsShares_atCustomPrice(uint256 amount, uint256 price) external {
        amount = bound(amount, 1e9, type(uint128).max);
        price  = bound(price, 1e15, 10e18); // 0.001 to 10 per share

        _giveAssets(alice, amount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(price);

        vm.prank(alice);
        uint256 shares = hub.deposit(VAULT_ID, 0, alice, alice);

        uint256 expectedShares = (amount * SHARE_PRICE_PRECISION) / price;
        assertEq(shares, expectedShares);
        assertEq(syShare.balanceOf(alice), expectedShares);
    }

    function test_deposit_partialClaim(uint256 amount) external {
        amount = bound(amount, 2e9, type(uint128).max);

        _giveAssets(alice, amount);
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE);

        uint256 halfAmount = amount / 2;
        vm.prank(alice);
        uint256 shares = hub.deposit(VAULT_ID, halfAmount, alice, alice);

        assertEq(shares, halfAmount); // 1:1
        assertEq(vault.claimableDepositRequest(reqId, alice), amount - halfAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        mint (claim by shares)
    //////////////////////////////////////////////////////////////*/

    function test_mint_claimsShares(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint128).max);

        _giveAssets(alice, amount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE);

        // At 1:1 price: mint amount shares → costs amount assets
        vm.prank(alice);
        uint256 assetsConsumed = hub.mint(VAULT_ID, amount, alice, alice);

        assertEq(assetsConsumed, amount);
        assertEq(syShare.balanceOf(alice), amount);
    }

    function test_RevertWhen_Deposit_NothingClaimable() external {
        vm.prank(alice);
        vm.expectRevert(SyVault__NoClaimableDeposit.selector);
        hub.deposit(VAULT_ID, 0, alice, alice);
    }

    function test_RevertWhen_Deposit_PendingNotYetSettled(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        _giveAssets(alice, amount);

        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        // Do NOT settle — try to claim immediately
        vm.prank(alice);
        vm.expectRevert(SyVault__NoClaimableDeposit.selector);
        hub.deposit(VAULT_ID, 0, alice, alice);
    }

    /*//////////////////////////////////////////////////////////////
                         maxDeposit view
    //////////////////////////////////////////////////////////////*/

    function test_maxDeposit_returnsMaxUint_whenUnlimited() external view {
        uint256 maxDep = vault.maxDeposit(alice);
        assertEq(maxDep, type(uint256).max);
    }

    function test_maxDeposit_returnsZero_whenDepositsPaused() external {
        vm.prank(admin);
        vault.pauseDeposits();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_returnsZero_whenNotWhitelisted() external {
        vm.startPrank(admin);
        vault.setDepositWhitelistEnabled(true);
        vm.stopPrank();
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_maxDeposit_cappedByTVL(uint256 cap) external {
        cap = bound(cap, 1, type(uint128).max);
        vm.prank(admin);
        vault.setMaxTvl(cap);

        uint256 maxDep = vault.maxDeposit(alice);
        assertEq(maxDep, cap); // TVL = 0 (no supply), so remaining = cap
    }

    /*//////////////////////////////////////////////////////////////
                        requestDepositStatus view
    //////////////////////////////////////////////////////////////*/

    function test_requestDepositStatus_Ok() external view {
        assertEq(uint8(vault.requestDepositStatus(alice)), 0); // Ok = 0
    }

    function test_requestDepositStatus_Paused() external {
        vm.prank(admin);
        vault.pauseDeposits();
        assertEq(uint8(vault.requestDepositStatus(alice)), 1); // Paused = 1
    }

    function test_requestDepositStatus_NotWhitelisted() external {
        vm.startPrank(admin);
        vault.setDepositWhitelistEnabled(true);
        vm.stopPrank();
        assertEq(uint8(vault.requestDepositStatus(alice)), 2); // NotWhitelisted = 2
    }

    /*//////////////////////////////////////////////////////////////
                        minDeposit enforcement
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestDeposit_BelowMinDeposit(uint256 minDep, uint256 amount) external {
        minDep = bound(minDep, 2, type(uint128).max);
        amount = bound(amount, 1, minDep - 1);

        vm.prank(admin);
        vault.setMinDeposit(minDep);

        _giveAssets(alice, amount);
        vm.prank(alice);
        vm.expectRevert(SyVault__BelowMinDeposit.selector);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);
    }

    function test_requestDeposit_atMinDeposit_succeeds(uint256 minDep) external {
        minDep = bound(minDep, 1, 1_000_000e18);

        vm.prank(admin);
        vault.setMinDeposit(minDep);

        _giveAssets(alice, minDep);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, minDep, alice, alice); // must not revert
        assertEq(vault.pendingDepositAssets(), minDep);
    }

    function test_requestDeposit_noMinDeposit_zeroAllowed() external {
        // minDeposit = 0 means no minimum — only ZeroAmount reverts.
        assertEq(vault.minDeposit(), 0);
        _giveAssets(alice, 1);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, 1, alice, alice);
        assertEq(vault.pendingDepositAssets(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                        checkDepositAmount view
    //////////////////////////////////////////////////////////////*/

    function test_checkDepositAmount_ok_whenNoMin() external view {
        assertEq(uint8(vault.checkDepositAmount(1)), uint8(DepositRequestStatus.Ok));
    }

    function test_checkDepositAmount_ok_atOrAboveMin(uint256 minDep, uint256 amount) external {
        minDep = bound(minDep, 1, type(uint128).max);
        amount = bound(amount, minDep, type(uint128).max);

        vm.prank(admin);
        vault.setMinDeposit(minDep);

        assertEq(uint8(vault.checkDepositAmount(amount)), uint8(DepositRequestStatus.Ok));
    }

    function test_checkDepositAmount_belowMin(uint256 minDep, uint256 amount) external {
        minDep = bound(minDep, 2, type(uint128).max);
        amount = bound(amount, 1, minDep - 1);

        vm.prank(admin);
        vault.setMinDeposit(minDep);

        assertEq(uint8(vault.checkDepositAmount(amount)), uint8(DepositRequestStatus.BelowMinDeposit));
    }
}
