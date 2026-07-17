// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {SHARE_PRICE_PRECISION} from "src/types/Constants.sol";

/// @dev B1 mint-at-settle — regression suite for the PPS deviation incident.
///
///      Root cause of the incident: settled-but-unclaimed deposits were excluded from the
///      supply denominator (shares minted lazily at claim) while their assets were reserved
///      at fixed principal in the TVL numerator. The keeper's computed share price deviated
///      by a factor of ~(1 + claimable/NAV) and snapped back the moment users claimed.
///
///      With B1, epochSettle() mints the epoch's owed shares to the vault itself and claims
///      transfer from that balance. totalSupply is truthful at every block, so the keeper
///      formula — sharePrice = (Equity + poolContrib − stratReserved) × 1e18 / effectiveSupply()
///      — is invariant across claims. These tests compute the price exactly as the keeper does.
contract SyVaultB1MintAtSettleTest is Base {

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Share price exactly as the off-chain Keeper computes it.
    ///      Equity = 0 in these tests — no capital is deployed to strategies,
    ///      so TVL is just the pool contribution.
    function _keeperPrice() internal view returns (uint256) {
        (uint256 poolContrib, uint256 stratReserved) = vault.tvlComponents();
        uint256 tvl = poolContrib - stratReserved;
        uint256 supply = vault.effectiveSupply();
        if (supply == 0) return INITIAL_PRICE;
        return (tvl * SHARE_PRICE_PRECISION) / supply;
    }

    /// @dev Request a deposit for `who` and settle the epoch at `price`.
    function _depositAndSettle(address who, uint256 amount, uint256 price) internal {
        _giveAssets(who, amount);
        vm.prank(who);
        hub.requestDeposit(VAULT_ID, amount, who, who);
        _settleEpoch(price);
    }

    /*//////////////////////////////////////////////////////////////
                 CORE REGRESSION — INCIDENT SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @dev THE incident test. A large deposit settles and stays unclaimed while a small
    ///      base of claimed holders exists (incident amplification ≈ 1 + unclaimed/NAV).
    ///      Pre-fix, the keeper-formula price deviated while the deposit sat unclaimed and
    ///      snapped back at claim. Post-fix it must be identical before and after the claim.
    function testFuzz_KeeperPriceUnchangedByClaim(uint256 baseAmount, uint256 bigAmount) external {
        baseAmount = bound(baseAmount, 1e18, 1_000_000e18);
        // Unclaimed deposit up to 100× the existing base — far beyond the incident's 4×.
        bigAmount  = bound(bigAmount, baseAmount, baseAmount * 100);

        _giveShares(alice, baseAmount);                    // claimed baseline holder
        _depositAndSettle(bob, bigAmount, INITIAL_PRICE);  // settled, NOT claimed

        uint256 priceBeforeClaim = _keeperPrice();

        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        uint256 priceAfterClaim = _keeperPrice();

        // No snap-back: claiming is economically neutral for the share price.
        assertEq(priceBeforeClaim, priceAfterClaim, "claim must not move the keeper price");
        // And while unclaimed, the keeper price already matched the settled on-chain price.
        assertEq(priceBeforeClaim, INITIAL_PRICE, "no deviation while deposit sits unclaimed");
    }

    /// @dev Same property when the settlement price has drifted away from 1:1 —
    ///      owed shares are frozen at each epoch's settlement price.
    function testFuzz_KeeperPriceUnchangedByClaim_WithDrift(uint256 amount, uint256 settlePrice) external {
        amount      = bound(amount, 1e18, 1_000_000e18);
        settlePrice = bound(settlePrice, 0.5e18, 2e18);

        _giveShares(alice, amount);
        // Simulate yield accrued in the pool so the drifted price is backed by real assets:
        // TVL must equal settlePrice × supply for the keeper formula to reproduce settlePrice.
        uint256 aliceShares = syShare.balanceOf(alice);
        uint256 targetTvl   = (aliceShares * settlePrice) / SHARE_PRICE_PRECISION;
        if (targetTvl > amount) {
            asset.mint(address(pool), targetTvl - amount);
        } else {
            vm.prank(address(pool));
            asset.transfer(address(0xdead), amount - targetTvl);
        }

        _depositAndSettle(bob, amount, settlePrice); // bob settles at the drifted price

        uint256 priceBeforeClaim = _keeperPrice();
        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);
        uint256 priceAfterClaim = _keeperPrice();

        assertEq(priceBeforeClaim, priceAfterClaim, "claim must not move the keeper price");
        // 1 wei tolerance: floor rounding of the vault-held share mint.
        assertApproxEqAbs(priceBeforeClaim, settlePrice, 1, "keeper price tracks settled price");
    }

    /*//////////////////////////////////////////////////////////////
                     SUPPLY TRUTHFULNESS
    //////////////////////////////////////////////////////////////*/

    /// @dev totalSupply must include settled-but-unclaimed deposit shares, held by the vault.
    function testFuzz_TotalSupplyIncludesUnclaimedShares(uint256 amount, uint256 settlePrice) external {
        amount      = bound(amount, 1, 1_000_000e18);
        settlePrice = bound(settlePrice, 0.5e18, 2e18);

        uint256 supplyBefore = syShare.totalSupply();
        _depositAndSettle(bob, amount, settlePrice);

        uint256 owedShares = (amount * SHARE_PRICE_PRECISION) / settlePrice;
        assertEq(syShare.totalSupply(), supplyBefore + owedShares, "supply truthful at settle");
        assertEq(syShare.balanceOf(address(vault)), owedShares, "vault holds the owed shares");
    }

    /// @dev Claiming transfers from the vault's balance — totalSupply must not change.
    function testFuzz_ClaimTransfersInsteadOfMints(uint256 amount) external {
        amount = bound(amount, 1e18, 1_000_000e18);
        _depositAndSettle(bob, amount, INITIAL_PRICE);

        uint256 supplyAtSettle = syShare.totalSupply();
        uint256 vaultBalBefore = syShare.balanceOf(address(vault));

        vm.prank(bob);
        uint256 shares = hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(syShare.totalSupply(), supplyAtSettle, "claim must not mint");
        assertEq(syShare.balanceOf(bob), shares, "receiver got the shares");
        assertEq(syShare.balanceOf(address(vault)), vaultBalBefore - shares, "vault balance debited");
    }

    /// @dev mint() (exact-shares claim path) must also transfer, never mint.
    function test_MintPathTransfersInsteadOfMints() external {
        uint256 amount = 1_000e18;
        _depositAndSettle(bob, amount, INITIAL_PRICE);

        uint256 supplyAtSettle = syShare.totalSupply();
        uint256 owedShares     = (amount * SHARE_PRICE_PRECISION) / INITIAL_PRICE;

        vm.prank(bob);
        hub.mint(VAULT_ID, owedShares, bob, bob);

        assertEq(syShare.totalSupply(), supplyAtSettle, "mint() claim must not mint supply");
        assertEq(syShare.balanceOf(bob), owedShares, "receiver got exact shares");
    }

    /*//////////////////////////////////////////////////////////////
                     ROUNDING & CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Multiple depositors in one epoch: sum of per-controller floors never exceeds the
    ///      single floor minted at settle, and the residual dust left in the vault is bounded
    ///      by 1 wei per claimer.
    function testFuzz_DustBoundedAfterAllClaims(uint256 a, uint256 b, uint256 settlePrice) external {
        a           = bound(a, 1e6, 1_000_000e18);
        b           = bound(b, 1e6, 1_000_000e18);
        settlePrice = bound(settlePrice, 0.9e18, 1.1e18); // within default delta guard = off (0)

        _giveAssets(alice, a);
        _giveAssets(bob, b);
        vm.prank(alice);
        hub.requestDeposit(VAULT_ID, a, alice, alice);
        vm.prank(bob);
        hub.requestDeposit(VAULT_ID, b, bob, bob);
        _settleEpoch(settlePrice);

        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice);
        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertLe(syShare.balanceOf(address(vault)), 2, "dust bounded by 1 wei per claimer");
    }

    /// @dev maxDeposit capacity must not double-count settled-but-unclaimed deposits, which
    ///      are now inside tvl (sharePrice × totalSupply) via the vault-held shares.
    function test_MaxDepositDoesNotDoubleCountClaimable() external {
        uint256 cap = 10_000e18;
        vm.prank(admin);
        vault.setMaxTvl(cap);

        _depositAndSettle(bob, 4_000e18, INITIAL_PRICE); // settled, unclaimed

        // used = tvl (includes bob's 4k via vault-held shares) + pending (0)
        assertEq(vault.maxDeposit(bob), cap - 4_000e18, "unclaimed deposit counted exactly once");

        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(vault.maxDeposit(bob), cap - 4_000e18, "capacity unchanged by claim");
    }

    /*//////////////////////////////////////////////////////////////
              COEXISTENCE WITH REDEEM-LOCKED SHARES
    //////////////////////////////////////////////////////////////*/

    /// @dev The vault balance now holds redeem-locked shares AND unclaimed deposit shares.
    ///      settleRedeemBatch burns exactly the locked amount and must not touch the
    ///      deposit-claim reserve.
    function test_RedeemBurnDoesNotEatDepositClaimShares() external {
        uint256 aliceShares = _giveShares(alice, 1_000e18);

        // Bob's deposit settles and stays unclaimed → vault holds his owed shares.
        _depositAndSettle(bob, 500e18, INITIAL_PRICE);
        uint256 bobOwed = (500e18 * SHARE_PRICE_PRECISION) / INITIAL_PRICE;

        // Alice locks all her shares in a normal redeem cycle.
        uint256 openEpoch = vault.currentEpoch();
        uint256 cycleId   = _requestRedeem(alice, aliceShares);
        assertEq(syShare.balanceOf(address(vault)), bobOwed + aliceShares, "vault holds both");

        _warpToNormalLock(openEpoch);
        _allocatorSettleCycle(cycleId, 1_000e18);

        // Burn consumed exactly the locked shares — bob's claim reserve is intact.
        assertEq(syShare.balanceOf(address(vault)), bobOwed, "deposit reserve untouched by burn");

        vm.prank(bob);
        uint256 claimed = hub.deposit(VAULT_ID, 0, bob, bob);
        assertEq(claimed, bobOwed, "bob claims his full owed shares");
        assertEq(syShare.balanceOf(address(vault)), 0, "vault drained cleanly");
    }
}
