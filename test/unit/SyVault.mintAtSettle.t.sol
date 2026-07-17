// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {SHARE_PRICE_PRECISION} from "src/types/Constants.sol";
import {DepositRequestStatus}  from "src/types/Types.sol";

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
///
///      Abstract: run by both the 18-decimal and 6-decimal concretes at the bottom of this
///      file. Amounts are scaled by ONE_ASSET and prices are quoted in raw asset units per
///      1e18 shares (so the 1:1 price is ONE_ASSET), which is what the deploy script feeds
///      VAULT_INITIAL_PRICE. SHARE_PRICE_PRECISION is a fixed 1e18 and never scales.
abstract contract SyVaultB1MintAtSettleBase is Base {

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Share price exactly as the off-chain Keeper computes it, with `equity` standing in
    ///      for the strategy mark the keeper supplies off-chain:
    ///          PPS = (Equity + poolContrib − stratReserved) × 1e18 / effectiveSupply
    function _keeperPriceWithEquity(uint256 equity) internal view returns (uint256) {
        (uint256 poolContrib, uint256 stratReserved) = vault.tvlComponents();
        uint256 tvl = equity + poolContrib - stratReserved;
        uint256 supply = vault.effectiveSupply();
        if (supply == 0) return INITIAL_PRICE;
        return (tvl * SHARE_PRICE_PRECISION) / supply;
    }

    /// @dev Keeper price with nothing deployed: Equity = 0, so TVL is just the pool contribution.
    function _keeperPrice() internal view returns (uint256) {
        return _keeperPriceWithEquity(0);
    }

    /// @dev Request a deposit for `who` and settle the epoch at `price`.
    function _depositAndSettle(address who, uint256 amount, uint256 price) internal {
        _requestDeposit(who, amount);
        _settleEpoch(price);
    }

    function _requestDeposit(address who, uint256 amount) internal {
        _giveAssets(who, amount);
        vm.prank(who);
        hub.requestDeposit(VAULT_ID, amount, who, who);
    }

    /// @dev Shares owed for `assets` settled at `price` — the floor the vault mints at settle.
    function _owed(uint256 assets, uint256 price) internal pure returns (uint256) {
        return (assets * SHARE_PRICE_PRECISION) / price;
    }

    /*//////////////////////////////////////////////////////////////
                 CORE REGRESSION — INCIDENT SCENARIO
    //////////////////////////////////////////////////////////////*/

    /// @dev THE incident test. A large deposit settles and stays unclaimed while a small
    ///      base of claimed holders exists (incident amplification ≈ 1 + unclaimed/NAV).
    ///      Pre-fix, the keeper-formula price deviated while the deposit sat unclaimed and
    ///      snapped back at claim. Post-fix it must be identical before and after the claim.
    function testFuzz_KeeperPriceUnchangedByClaim(uint256 baseAmount, uint256 bigAmount) external {
        baseAmount = bound(baseAmount, ONE_ASSET, 1_000_000 * ONE_ASSET);
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
        amount      = bound(amount, ONE_ASSET, 1_000_000 * ONE_ASSET);
        settlePrice = bound(settlePrice, ONE_ASSET / 2, 2 * ONE_ASSET);

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
        amount      = bound(amount, 1, 1_000_000 * ONE_ASSET);
        settlePrice = bound(settlePrice, ONE_ASSET / 2, 2 * ONE_ASSET);

        uint256 supplyBefore = syShare.totalSupply();
        _depositAndSettle(bob, amount, settlePrice);

        uint256 owedShares = _owed(amount, settlePrice);
        assertEq(syShare.totalSupply(), supplyBefore + owedShares, "supply truthful at settle");
        assertEq(syShare.balanceOf(address(vault)), owedShares, "vault holds the owed shares");
    }

    /// @dev Claiming transfers from the vault's balance — totalSupply must not change.
    function testFuzz_ClaimTransfersInsteadOfMints(uint256 amount) external {
        amount = bound(amount, ONE_ASSET, 1_000_000 * ONE_ASSET);
        _depositAndSettle(bob, amount, INITIAL_PRICE);

        uint256 supplyAtSettle = syShare.totalSupply();
        uint256 vaultBalBefore = syShare.balanceOf(address(vault));

        vm.prank(bob);
        uint256 shares = hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(syShare.totalSupply(), supplyAtSettle, "claim must not mint");
        assertEq(syShare.balanceOf(bob), shares, "receiver got the shares");
        assertEq(syShare.balanceOf(address(vault)), vaultBalBefore - shares, "vault balance debited");
    }

    /// @dev mint() (exact-shares claim path) must also transfer, never mint. Fuzzed over the
    ///      settlement price: _consumeDepositEpochsByShares rounds assets up and then re-floors
    ///      the shares, so it is the path most sensitive to price precision.
    function testFuzz_MintPathTransfersInsteadOfMints(uint256 amount, uint256 settlePrice) external {
        amount      = bound(amount, ONE_ASSET, 1_000_000 * ONE_ASSET);
        settlePrice = bound(settlePrice, ONE_ASSET / 2, 2 * ONE_ASSET);

        _depositAndSettle(bob, amount, settlePrice);

        uint256 supplyAtSettle = syShare.totalSupply();
        uint256 owedShares     = _owed(amount, settlePrice);

        vm.prank(bob);
        hub.mint(VAULT_ID, owedShares, bob, bob);

        assertEq(syShare.totalSupply(), supplyAtSettle, "mint() claim must not mint supply");
        assertEq(syShare.balanceOf(bob), owedShares, "receiver got exact shares");
        assertEq(syShare.balanceOf(address(vault)), 0, "vault fully drained by exact claim");
    }

    /// @dev Mixed partial claim: mint() an arbitrary slice of the owed shares, then deposit()
    ///      the remainder. mint() rounds the consumed assets UP, so the two paths must not
    ///      together hand out more shares than the single floor minted at settle — this is the
    ///      exact "cap after round-trip" underflow guarded in _consumeDepositEpochsByShares.
    function testFuzz_PartialMintThenDepositClaim(uint256 amount, uint256 settlePrice, uint256 slice) external {
        amount      = bound(amount, ONE_ASSET, 1_000_000 * ONE_ASSET);
        settlePrice = bound(settlePrice, ONE_ASSET / 2, 2 * ONE_ASSET);

        _depositAndSettle(bob, amount, settlePrice);

        uint256 owedShares     = _owed(amount, settlePrice);
        uint256 supplyAtSettle = syShare.totalSupply();
        slice = bound(slice, 1, owedShares);

        vm.prank(bob);
        hub.mint(VAULT_ID, slice, bob, bob);

        // Remainder may floor to zero shares, which the claim path rejects — that is the
        // documented dust outcome, not a failure.
        vm.prank(bob);
        try hub.deposit(VAULT_ID, 0, bob, bob) {} catch {}

        assertEq(syShare.totalSupply(), supplyAtSettle, "no path may mint at claim");
        assertLe(syShare.balanceOf(bob), owedShares, "claims never exceed shares minted at settle");
        assertEq(
            syShare.balanceOf(bob) + syShare.balanceOf(address(vault)),
            owedShares,
            "every owed share is either claimed or still held by the vault"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     ROUNDING & CAPACITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Multiple depositors in one epoch: sum of per-controller floors never exceeds the
    ///      single floor minted at settle, and the residual dust left in the vault is bounded
    ///      by 1 wei per claimer.
    function testFuzz_DustBoundedAfterAllClaims(uint256 a, uint256 b, uint256 settlePrice) external {
        a           = bound(a, ONE_ASSET / 1000, 1_000_000 * ONE_ASSET);
        b           = bound(b, ONE_ASSET / 1000, 1_000_000 * ONE_ASSET);
        settlePrice = bound(settlePrice, (ONE_ASSET * 9) / 10, (ONE_ASSET * 11) / 10);

        _requestDeposit(alice, a);
        _requestDeposit(bob, b);
        _settleEpoch(settlePrice);

        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice);
        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertLe(syShare.balanceOf(address(vault)), 2, "dust bounded by 1 wei per claimer");
    }

    /// @dev Dust is bounded per claimer PER EPOCH, and each epoch's shares are frozen at that
    ///      epoch's own settlement price. Two claimers accumulating across three differently
    ///      priced epochs must leave at most 1 wei each per epoch, and claiming everything at
    ///      once must not underflow the vault's shared share balance.
    function testFuzz_DustBoundedAcrossEpochs(uint256 a, uint256 b, uint256 p0, uint256 p1, uint256 p2) external {
        a  = bound(a, ONE_ASSET / 1000, 100_000 * ONE_ASSET);
        b  = bound(b, ONE_ASSET / 1000, 100_000 * ONE_ASSET);
        p0 = bound(p0, (ONE_ASSET * 9) / 10, (ONE_ASSET * 11) / 10);
        p1 = bound(p1, (ONE_ASSET * 9) / 10, (ONE_ASSET * 11) / 10);
        p2 = bound(p2, (ONE_ASSET * 9) / 10, (ONE_ASSET * 11) / 10);

        uint256[3] memory prices = [p0, p1, p2];
        uint256 expectedOwed;
        for (uint256 i; i < 3; ++i) {
            _requestDeposit(alice, a);
            _requestDeposit(bob, b);
            _settleEpoch(prices[i]);
            expectedOwed += _owed(a + b, prices[i]);
        }

        assertEq(syShare.totalSupply(), expectedOwed, "supply is the sum of per-epoch floors");
        assertEq(syShare.balanceOf(address(vault)), expectedOwed, "vault holds every epoch's shares");

        // Each claimant drains all three epochs in one call — exercises the epoch loop.
        vm.prank(alice);
        hub.deposit(VAULT_ID, 0, alice, alice);
        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(syShare.totalSupply(), expectedOwed, "claims across epochs never mint");
        assertLe(syShare.balanceOf(address(vault)), 2 * 3, "dust bounded by 1 wei per claimer per epoch");
    }

    /// @dev maxDeposit capacity must not double-count settled-but-unclaimed deposits, which
    ///      are now inside tvl (sharePrice × totalSupply) via the vault-held shares.
    function testFuzz_MaxDepositDoesNotDoubleCountClaimable(uint256 cap, uint256 amount) external {
        cap    = bound(cap, 2 * ONE_ASSET, 1_000_000 * ONE_ASSET);
        amount = bound(amount, ONE_ASSET, cap / 2);

        vm.prank(admin);
        vault.setMaxTvl(cap);

        _depositAndSettle(bob, amount, INITIAL_PRICE); // settled, unclaimed

        // used = tvl (includes bob's deposit via vault-held shares) + pending (0)
        uint256 roomBefore = vault.maxDeposit(bob);
        assertEq(roomBefore, cap - amount, "unclaimed deposit counted exactly once");

        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(vault.maxDeposit(bob), roomBefore, "capacity unchanged by claim");
    }

    /// @dev requestDepositStatus mirrors maxDeposit's capacity math — it must not double-count
    ///      claimable deposits either. Pre-B1 the unclaimed deposit was added twice, so the
    ///      status flipped to TVLExceeded early and back to Ok once the user claimed.
    function testFuzz_RequestDepositStatusDoesNotDoubleCountClaimable(uint256 cap, uint256 amount) external {
        cap    = bound(cap, 2 * ONE_ASSET, 1_000_000 * ONE_ASSET);
        amount = bound(amount, ONE_ASSET, cap / 2); // never more than half the cap → always Ok

        vm.prank(admin);
        vault.setMaxTvl(cap);

        _depositAndSettle(bob, amount, INITIAL_PRICE);

        assertEq(
            uint8(vault.requestDepositStatus(alice)),
            uint8(DepositRequestStatus.Ok),
            "half-full vault must stay open with the deposit unclaimed"
        );

        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(
            uint8(vault.requestDepositStatus(alice)),
            uint8(DepositRequestStatus.Ok),
            "status unchanged by claim"
        );
    }

    /// @dev The TVLExceeded branch itself: once vault-held claimable shares fill the cap,
    ///      the status reports the vault as full even though nobody has claimed yet.
    function test_RequestDepositStatus_TVLExceededByUnclaimedDeposit() external {
        uint256 cap = 1_000 * ONE_ASSET;
        vm.prank(admin);
        vault.setMaxTvl(cap);

        _depositAndSettle(bob, cap, INITIAL_PRICE);

        assertEq(
            uint8(vault.requestDepositStatus(alice)),
            uint8(DepositRequestStatus.TVLExceeded),
            "cap filled by unclaimed deposit must report TVLExceeded"
        );
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit agrees with requestDepositStatus");

        vm.prank(bob);
        hub.deposit(VAULT_ID, 0, bob, bob);

        assertEq(
            uint8(vault.requestDepositStatus(alice)),
            uint8(DepositRequestStatus.TVLExceeded),
            "still full after the claim - no capacity conjured by claiming"
        );
    }

    /*//////////////////////////////////////////////////////////////
                     REDEEM-VIEW ALIGNMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev The redeem-side mirror of the deposit incident. A locked redeemer is still a
    ///      shareholder — the payout floats with the price until settleRedeemBatch burns the
    ///      shares. The old views subtracted a FIXED redeemDue (priced at the previous epoch)
    ///      from the numerator while dropping the floating shares from the denominator, so an
    ///      epoch P&L move of d was reported as d × S/(S−L): the lockers' share of the P&L
    ///      landed on unlocked holders only, with a growing feedback loop once L > S/2.
    ///      Post-alignment the keeper price must equal equity/totalSupply exactly — no
    ///      dependence on how much of the supply is locked.
    function testFuzz_LockedRedeemPnlSharedProRata(
        uint256 amount,
        uint256 lockBps,
        uint256 driftBps,
        bool gain
    ) external {
        amount   = bound(amount, ONE_ASSET, 100_000 * ONE_ASSET);
        lockBps  = bound(lockBps, 100, 9_000);  // 1%–90% of supply locked (§6.3 sweep 10/50/90)
        driftBps = bound(driftBps, 1, 2_000);   // epoch P&L up to ±20%

        uint256 aliceShares = _giveShares(alice, amount);

        // Deploy the whole book so TVL is pure keeper-marked equity.
        uint256 deployed = pool.balance();
        vm.prank(allocator);
        pool.deployCapital(deployed);

        _requestRedeem(alice, (aliceShares * lockBps) / 10_000);

        uint256 equity = gain
            ? amount + (amount * driftBps) / 10_000
            : amount - (amount * driftBps) / 10_000;

        // Pro-rata fair value over the FULL supply — locked shares included.
        uint256 fair = (equity * SHARE_PRICE_PRECISION) / syShare.totalSupply();

        assertEq(
            _keeperPriceWithEquity(equity),
            fair,
            "epoch P&L must be shared pro-rata; locked fraction must not amplify the move"
        );
    }

    /// @dev settleRedeemBatch is the atomic swap: shares burn out of the denominator in the
    ///      same transaction their assets leave the numerator (into claimableRedeemAssets).
    ///      When the allocator returns exactly shares x price, the keeper price is identical
    ///      before and after — a redeem settlement is price-neutral, like a deposit claim.
    function testFuzz_SettleRedeemBatchPriceNeutral(uint256 amount, uint256 redeemAssets) external {
        amount       = bound(amount, 2 * ONE_ASSET, 100_000 * ONE_ASSET);
        redeemAssets = bound(redeemAssets, 1, amount / 2);

        uint256 aliceShares = _giveShares(alice, amount);
        uint256 lockShares  = (redeemAssets * SHARE_PRICE_PRECISION) / INITIAL_PRICE; // exact
        vm.assume(lockShares > 0 && lockShares <= aliceShares);

        uint256 deployed = pool.balance();
        vm.prank(allocator);
        pool.deployCapital(deployed);

        uint256 openEpoch = vault.currentEpoch();
        uint256 cycleId   = _requestRedeem(alice, lockShares);
        _warpToNormalLock(openEpoch);

        // Strategy pays the cycle out: equity shrinks by exactly what returns to the pool.
        uint256 equityRemaining = amount - redeemAssets;
        asset.mint(allocator, redeemAssets);
        vm.startPrank(allocator);
        asset.approve(address(pool), redeemAssets);
        pool.returnCapital(redeemAssets);

        uint256 priceBefore = _keeperPriceWithEquity(equityRemaining);
        vault.settleRedeemBatch(cycleId, redeemAssets);
        uint256 priceAfter = _keeperPriceWithEquity(equityRemaining);
        vm.stopPrank();

        assertEq(priceBefore, priceAfter, "redeem settlement must not move the keeper price");
        assertEq(priceBefore, INITIAL_PRICE, "price held at fair value through the cycle");
    }

    /*//////////////////////////////////////////////////////////////
              COEXISTENCE WITH REDEEM-LOCKED SHARES
    //////////////////////////////////////////////////////////////*/

    /// @dev The vault balance now holds redeem-locked shares AND unclaimed deposit shares.
    ///      settleRedeemBatch burns exactly the locked amount and must not touch the
    ///      deposit-claim reserve.
    function test_RedeemBurnDoesNotEatDepositClaimShares() external {
        uint256 aliceShares = _giveShares(alice, 1_000 * ONE_ASSET);

        // Bob's deposit settles and stays unclaimed → vault holds his owed shares.
        _depositAndSettle(bob, 500 * ONE_ASSET, INITIAL_PRICE);
        uint256 bobOwed = _owed(500 * ONE_ASSET, INITIAL_PRICE);

        // Alice locks all her shares in a normal redeem cycle.
        uint256 openEpoch = vault.currentEpoch();
        uint256 cycleId   = _requestRedeem(alice, aliceShares);
        assertEq(syShare.balanceOf(address(vault)), bobOwed + aliceShares, "vault holds both");

        _warpToNormalLock(openEpoch);
        _allocatorSettleCycle(cycleId, 1_000 * ONE_ASSET);

        // Burn consumed exactly the locked shares — bob's claim reserve is intact.
        assertEq(syShare.balanceOf(address(vault)), bobOwed, "deposit reserve untouched by burn");

        vm.prank(bob);
        uint256 claimed = hub.deposit(VAULT_ID, 0, bob, bob);
        assertEq(claimed, bobOwed, "bob claims his full owed shares");
        assertEq(syShare.balanceOf(address(vault)), 0, "vault drained cleanly");
    }
}

/// @dev Default precision — 18-decimal asset, 1:1 price = 1e18.
contract SyVaultB1MintAtSettle_18DecimalsTest is SyVaultB1MintAtSettleBase {}

/// @dev Production precision for Vault #2 (shiftHY/USDC): 6-decimal asset, 1:1 price = 1e6.
///      Low-decimal assets are where the claim-path rounding is tightest — the round-trip cap
///      in _consumeDepositEpochsByShares exists specifically for this case.
contract SyVaultB1MintAtSettle_6DecimalsTest is SyVaultB1MintAtSettleBase {
    function _assetDecimals() internal pure override returns (uint8) {
        return 6;
    }
}
