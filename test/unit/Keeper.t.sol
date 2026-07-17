// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {SHARE_PRICE_PRECISION, EPOCH_DURATION} from "src/types/Constants.sol";

/// @notice Keeper end-to-end behaviour tests.
///         Covers: share price formula precision, investableLiquidity, effectiveSupply,
///         epochEnd view, and catch-up with mixed conditions.
contract KeeperTest is Base {

    /*//////////////////////////////////////////////////////////////
                    SHARE PRICE FORMULA PRECISION
    //////////////////////////////////////////////////////////////*/

    function test_sharePriceFormula_initialState() external view {
        // At initial state: totalSupply = 0, investableLiquidity = 0.
        // effectiveSupply = 0 → keeper cannot compute a valid price. First epoch is special.
        assertEq(syShare.totalSupply(),      0);
        assertEq(vault.investableLiquidity(), 0);
        assertEq(vault.effectiveSupply(),     0);
    }

    function test_sharePriceFormula_afterDeposit(uint256 depositAmount) external {
        depositAmount = bound(depositAmount, 1e18, 1_000_000e18);

        _giveAssets(alice, depositAmount);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, depositAmount, alice, alice);

        // Before settlement: pending deposit not deployable.
        // investableLiquidity = pool - pending - redeemDue - claimable = 0
        assertEq(vault.investableLiquidity(), 0);
        assertEq(vault.pendingDepositAssets(), depositAmount);

        _settleEpoch(INITIAL_PRICE);
        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice);

        // After claim: shares minted, pool holds depositAmount.
        // effectiveSupply = totalSupply (no redeem pending)
        // investableLiquidity = depositAmount (no pending, no redeemDue, no claimable)
        uint256 supply    = syShare.totalSupply();
        uint256 liquidity = vault.investableLiquidity();

        assertEq(supply,    (depositAmount * SHARE_PRICE_PRECISION) / INITIAL_PRICE);
        assertEq(liquidity, depositAmount);
        assertEq(vault.effectiveSupply(), supply);

        // Verify formula: sharePrice = (TVL * 1e18) / effectiveSupply
        // TVL = Equity + investableLiquidity — if Equity = 0 (nothing deployed):
        uint256 computedSharePrice = (liquidity * SHARE_PRICE_PRECISION) / vault.effectiveSupply();
        assertEq(computedSharePrice, INITIAL_PRICE);
    }

    function test_sharePriceFormula_effectiveSupply_includesLockedRedeemShares() external {
        uint256 depositAmount = 100e18;
        uint256 shares        = _giveShares(alice, depositAmount);

        uint256 redeemShares = shares / 2;
        _requestRedeem(alice, redeemShares);

        // Locked redeemers are still shareholders until settleRedeemBatch burns them:
        // effectiveSupply = totalSupply, locked shares tracked separately.
        assertEq(vault.effectiveSupply(), syShare.totalSupply());
        assertEq(vault.pendingRedeemShares(), redeemShares);
    }

    function test_sharePriceFormula_investableLiquidity_excludesRedeemDue() external {
        uint256 depositAmount = 100e18;
        uint256 shares        = _giveShares(alice, depositAmount);

        _requestRedeem(alice, shares);

        // redeemDue = shares * sharePrice / 1e18 = depositAmount
        uint256 due       = vault.redeemDue();
        uint256 liquidity = vault.investableLiquidity();

        assertEq(due, depositAmount);
        assertEq(liquidity, 0); // all pool reserved for redeem
    }

    function test_investableLiquidity_excludesClaimableRedeemAssets() external {
        uint256 depositAmount = 100e18;
        uint256 shares        = _giveShares(alice, depositAmount);

        // Deploy capital so pool is empty, then return via allocator.
        vm.prank(allocator);
        pool.deployCapital(depositAmount);

        uint256 cycleId = _requestRedeem(alice, shares);
        _settleEpochs(144, INITIAL_PRICE); // past normal lock

        // Allocator returns and settles — pool refilled to depositAmount.
        asset.mint(allocator, depositAmount);
        vm.startPrank(allocator);
        asset.approve(address(pool), depositAmount);
        pool.returnCapital(depositAmount);
        vault.settleRedeemBatch(cycleId, depositAmount);
        vm.stopPrank();

        // Pool = depositAmount, claimableRedeemAssets = depositAmount → investableLiquidity = 0.
        assertEq(vault.claimableRedeemAssets(), depositAmount);
        assertEq(vault.investableLiquidity(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        epochEnd VIEW
    //////////////////////////////////////////////////////////////*/

    function test_epochEnd_isNextHourBoundary() external view {
        uint256 end = vault.epochEnd();
        // epochEnd must be strictly in the future and exactly 1 epoch from deploy anchor.
        assertGt(end, block.timestamp);
        assertEq((end - block.timestamp) <= EPOCH_DURATION, true);
    }

    function test_epochEnd_advancesEachEpoch() external {
        uint256 end0 = vault.epochEnd();
        _settleEpoch(INITIAL_PRICE);
        uint256 end1 = vault.epochEnd();
        assertEq(end1, end0 + EPOCH_DURATION);
    }

    /*//////////////////////////////////////////////////////////////
                    stalePriceEpochs
    //////////////////////////////////////////////////////////////*/

    function test_stalePriceEpochs_zeroAfterSettle() external {
        _settleEpoch(INITIAL_PRICE);
        assertEq(vault.stalePriceEpochs(), 0);
    }

    function test_stalePriceEpochs_countsCorrectly(uint256 missed) external {
        missed = bound(missed, 1, 10);
        _warpEpochs(missed);
        assertEq(vault.stalePriceEpochs(), missed);
    }

    function test_stalePriceEpochs_catchUp_settlesAll(uint256 missed) external {
        missed = bound(missed, 1, 5);
        _warpEpochs(missed);

        // Keeper catches up — must call epochSettle once per missed epoch.
        for (uint256 i; i < missed; ++i) {
            vm.prank(keeper);
            vault.epochSettle(INITIAL_PRICE);
        }

        assertEq(vault.stalePriceEpochs(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    allocatorActive KEEPER INTERACTION
    //////////////////////////////////////////////////////////////*/

    function test_epochSettle_allocatorActive_keeperUsesZero() external {
        vm.prank(allocator);
        vault.setAllocatorActive(true);

        uint256 prevPrice = vault.latestSharePrice();

        // Keeper calls with 0 — contract uses previous price.
        _settleEpoch(0);
        assertEq(vault.latestSharePrice(), prevPrice);
    }

    function test_epochSettle_allocatorActive_keeperCanStillProposeAndWillBeIgnored() external {
        vm.prank(allocator);
        vault.setAllocatorActive(true);

        uint256 prevPrice    = vault.latestSharePrice();
        uint256 proposedHigh = INITIAL_PRICE * 2;

        // Keeper proposes a high price — while allocatorActive = true and within grace period,
        // contract ignores it and uses previous price.
        _settleEpoch(proposedHigh);
        assertEq(vault.latestSharePrice(), prevPrice);
    }
}
