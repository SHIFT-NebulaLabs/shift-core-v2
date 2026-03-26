// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {Hub} from "src/Hub.sol";
import {VaultState, RedeemCycle} from "src/types/Types.sol";
import {Hub__VaultNotActive, Hub__NotAuthorized, Hub__ZeroAddress} from "src/types/Errors.sol";

contract HubTest is Base {

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ZeroAddressRegistry() external {
        vm.expectRevert(Hub__ZeroAddress.selector);
        new Hub(address(0));
    }

    function test_addressRegistry_returnsRegistry() external view {
        assertEq(hub.addressRegistry(), address(registry));
    }

    /*//////////////////////////////////////////////////////////////
                     VAULT STATE GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_requestDeposit_requiresActive() external {
        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        _giveAssets(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(Hub__VaultNotActive.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_deposit_allowsDeprecated() external {
        uint256 amount = 100e18;
        _giveAssets(alice, amount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE);

        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        vm.prank(alice);
        uint256 shares = hub.deposit(VAULT_ID, 0, alice, alice);
        assertGt(shares, 0);
    }

    function test_requestRedeem_allowsDeprecated() external {
        uint256 shares = _giveShares(alice, 100e18);

        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        uint256 cycleId = _requestRedeem(alice, shares);
        assertGt(cycleId, 0);
    }

    function test_requestFastRedeem_allowsDeprecated() external {
        uint256 shares = _giveShares(alice, 100e18);

        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        vm.startPrank(alice);
        syShare.approve(address(vault), shares);
        uint256 cycleId = hub.requestFastRedeem(VAULT_ID, shares, alice, alice);
        vm.stopPrank();
        assertGt(cycleId, 0);
    }

    function test_cancelDepositRequest_anyState() external {
        _giveAssets(alice, 1e18);
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);

        vm.prank(alice);
        hub.cancelDepositRequest(VAULT_ID, reqId, alice);
        assertEq(asset.balanceOf(alice), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                    OPERATOR AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    function test_setOperator_approves() external {
        address operator = makeAddr("operator");

        vm.prank(alice);
        bool result = hub.setOperator(VAULT_ID, operator, true);

        assertTrue(result);
        assertTrue(vault.isOperator(alice, operator));
    }

    function test_setOperator_revokes() external {
        address operator = makeAddr("operator");

        vm.prank(alice);
        hub.setOperator(VAULT_ID, operator, true);

        vm.prank(alice);
        hub.setOperator(VAULT_ID, operator, false);

        assertFalse(vault.isOperator(alice, operator));
    }

    function test_operator_canRequestDepositOnBehalf() external {
        address operator = makeAddr("operator");

        vm.prank(alice);
        hub.setOperator(VAULT_ID, operator, true);

        _giveAssets(alice, 1e18);

        vm.prank(operator);
        uint256 reqId = hub.requestDeposit(VAULT_ID, 1e18, alice, alice);

        assertEq(vault.pendingDepositRequest(reqId, alice), 1e18);
    }

    function test_RevertWhen_Operator_NotApproved() external {
        address attacker = makeAddr("attacker");
        _giveAssets(alice, 1e18);

        vm.prank(attacker);
        vm.expectRevert(Hub__NotAuthorized.selector);
        hub.requestDeposit(VAULT_ID, 1e18, alice, alice);
    }

    function test_operator_canRequestRedeemOnBehalf() external {
        uint256 shares = _giveShares(alice, 100e18);
        address operator = makeAddr("operator");

        vm.prank(alice);
        hub.setOperator(VAULT_ID, operator, true);

        vm.prank(alice);
        syShare.approve(address(vault), shares);

        vm.prank(operator);
        uint256 cycleId = hub.requestRedeem(VAULT_ID, shares, alice, alice);
        assertGt(cycleId, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     END-TO-END — DEPOSIT + REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_hub_endToEnd_depositAndRedeem(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);

        _giveAssets(alice, amount);
        vm.prank(alice);
        uint256 reqId = hub.requestDeposit(VAULT_ID, amount, alice, alice);

        _settleEpoch(INITIAL_PRICE);

        vm.prank(alice);
        uint256 shares = hub.deposit(VAULT_ID, 0, alice, alice);
        assertEq(shares, amount); // 1:1

        uint256 cycleId = _requestRedeem(alice, shares);
        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        vm.warp(cycle.lockEpoch * 1 hours + 1);
        _allocatorSettleCycle(cycleId, amount);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, shares, alice, alice);
        assertEq(received, amount);
    }
}
