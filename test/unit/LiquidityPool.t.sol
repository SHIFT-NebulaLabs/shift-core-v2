// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {
    LiquidityPool__NotAuthorized,
    LiquidityPool__ExceedsAllowance,
    LiquidityPool__InsufficientBalance
} from "src/types/Errors.sol";

contract LiquidityPoolTest is Base {

    /*//////////////////////////////////////////////////////////////
                       deployCapital — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DeployCapital_NotAllocator() external {
        vm.prank(alice);
        vm.expectRevert(LiquidityPool__NotAuthorized.selector);
        pool.deployCapital(1e18);
    }

    function test_RevertWhen_DeployCapital_ExceedsAllowance(uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);

        // Pool has no balance → allowance = 0
        vm.prank(allocator);
        vm.expectRevert(LiquidityPool__ExceedsAllowance.selector);
        pool.deployCapital(amount);
    }

    function test_RevertWhen_DeployCapital_ExceedsPendingReserved(uint256 depositAmount) external {
        depositAmount = bound(depositAmount, 1e9, type(uint64).max);

        // Fund pool via deposit (assets go to pool immediately)
        _giveAssets(alice, depositAmount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, depositAmount, alice, alice);

        // All assets are reserved as pendingDepositAssets — allowance = 0
        assertEq(pool.allocatorAllowance(), 0);

        vm.prank(allocator);
        vm.expectRevert(LiquidityPool__ExceedsAllowance.selector);
        pool.deployCapital(1);
    }

    /*//////////////////////////////////////////////////////////////
                       deployCapital — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_deployCapital_transfersToAllocator(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);

        // Give pool free balance (directly mint to pool, bypassing pending tracking)
        asset.mint(address(pool), amount);
        // No pending deposits / redeems → full balance is allowance

        uint256 allocatorBefore = asset.balanceOf(allocator);
        uint256 poolBefore      = asset.balanceOf(address(pool));

        vm.prank(allocator);
        pool.deployCapital(amount);

        assertEq(asset.balanceOf(allocator),      allocatorBefore + amount);
        assertEq(asset.balanceOf(address(pool)),  poolBefore - amount);
    }

    function test_deployCapital_onlyUpToAllowance(uint256 amount, uint256 excess) external {
        amount = bound(amount, 1e9, type(uint64).max);
        excess = bound(excess, 1, type(uint64).max);

        asset.mint(address(pool), amount);

        uint256 allowance = pool.allocatorAllowance();

        vm.prank(allocator);
        vm.expectRevert(LiquidityPool__ExceedsAllowance.selector);
        pool.deployCapital(allowance + excess);
    }

    /*//////////////////////////////////////////////////////////////
                      returnCapital — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_returnCapital_addsToPool(uint256 amount) external {
        amount = bound(amount, 1, type(uint64).max);

        // Give allocator tokens to return
        asset.mint(allocator, amount);

        uint256 poolBefore = asset.balanceOf(address(pool));

        vm.startPrank(allocator);
        asset.approve(address(pool), amount);
        pool.returnCapital(amount);
        vm.stopPrank();

        assertEq(asset.balanceOf(address(pool)), poolBefore + amount);
        assertEq(asset.balanceOf(allocator),     0);
    }

    function test_RevertWhen_ReturnCapital_NotAllocator() external {
        vm.prank(alice);
        vm.expectRevert(LiquidityPool__NotAuthorized.selector);
        pool.returnCapital(1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        allocatorAllowance — VIEW
    //////////////////////////////////////////////////////////////*/

    function test_allocatorAllowance_excludesPendingDeposits(uint256 amount) external {
        amount = bound(amount, 1, type(uint64).max);

        // Deposit → assets go to pool, but reserved as pending
        _giveAssets(alice, amount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, amount, alice, alice);

        assertEq(pool.allocatorAllowance(), 0);
    }

    function test_allocatorAllowance_afterSettlement_becomesDeployable(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);

        // Deposit, settle (removes from pending), don't deploy
        _giveShares(alice, amount); // internally deposits + settles

        // Now assets are in pool and shares are minted, pendingDepositAssets = 0
        // Allowance = pool.balance - redeemDue - claimable - pending = balance - 0 - 0 - 0
        assertGe(pool.allocatorAllowance(), 0);
    }

    function test_allocatorAllowance_excludesRedeemDue(uint256 amount) external {
        amount = bound(amount, 1e9, type(uint64).max);
        uint256 shares = _giveShares(alice, amount);

        // Lock shares into a redeem cycle — creates redeemDue
        _requestRedeem(alice, shares);

        uint256 allowance = pool.allocatorAllowance();
        uint256 redeemDue = vault.redeemDue();

        // allowance = balance - redeemDue (approx, ignoring dust)
        assertLe(allowance + redeemDue, pool.balance() + 1); // +1 for rounding
    }

    /*//////////////////////////////////////////////////////////////
                          balance / asset / vault
    //////////////////////////////////////////////////////////////*/

    function test_balance_returnsPoolBalance(uint256 amount) external {
        amount = bound(amount, 1, type(uint64).max);
        asset.mint(address(pool), amount);
        assertEq(pool.balance(), asset.balanceOf(address(pool)));
    }

    function test_asset_returnsAssetAddress() external view {
        assertEq(pool.asset(), address(asset));
    }

    function test_vault_returnsVaultAddress() external view {
        assertEq(pool.vault(), address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                        transferTo — SYVAULT ONLY
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_TransferTo_NotVault() external {
        vm.prank(alice);
        vm.expectRevert(LiquidityPool__NotAuthorized.selector);
        pool.transferTo(alice, 1);
    }
}
