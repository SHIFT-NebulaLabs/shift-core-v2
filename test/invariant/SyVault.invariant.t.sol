// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Base} from "test/Base.t.sol";
import {SyVault} from "src/SyVault.sol";
import {SyShare} from "src/SyShare.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {Hub} from "src/Hub.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {RedeemCycle} from "src/types/Types.sol";
import {EPOCH_DURATION} from "src/types/Constants.sol";

/// @dev Handler that is called randomly by the Foundry invariant fuzzer.
///      Receives all contract references from SyVaultInvariantTest.
contract Handler is Test {

    SyVault         internal vault;
    SyShare         internal syShare;
    LiquidityPool   internal pool;
    Hub             internal hub;
    MockERC20       internal asset;
    uint256         internal VAULT_ID;
    uint256         internal INITIAL_PRICE;

    address internal keeper;
    address internal allocator;
    address internal feeRecip;

    address[] internal actors;
    uint256   internal _seed;

    // Ghost variables for invariant checking
    uint256 public ghost_totalSharesBurned;
    uint256 public ghost_depositSharesToVault;  // minted to the vault at epochSettle (B1)
    uint256 public ghost_depositSharesClaimed;  // transferred out of the vault at deposit() claims

    constructor(
        SyVault         _vault,
        SyShare         _syShare,
        LiquidityPool   _pool,
        Hub             _hub,
        MockERC20       _asset,
        uint256         _vaultId,
        uint256         _initialPrice,
        address         _keeper,
        address         _allocator,
        address         _feeRecip
    ) {
        vault        = _vault;
        syShare      = _syShare;
        pool         = _pool;
        hub          = _hub;
        asset        = _asset;
        VAULT_ID     = _vaultId;
        INITIAL_PRICE = _initialPrice;
        keeper       = _keeper;
        allocator    = _allocator;
        feeRecip     = _feeRecip;

        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));

        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 100 ether);
            asset.mint(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            asset.approve(address(vault), type(uint256).max);
            vm.prank(actors[i]);
            syShare.approve(address(vault), type(uint256).max);
        }
    }

    function _actor() internal returns (address) {
        return actors[_seed++ % actors.length];
    }

    // ── Deposit ───────────────────────────────────────────────────

    function requestDeposit(uint256 amount) external {
        amount = bound(amount, 1e9, 100_000e18);
        address actor = _actor();

        if (asset.balanceOf(actor) < amount) asset.mint(actor, amount);

        vm.prank(actor);
        hub.requestDeposit(VAULT_ID, amount, actor, actor);
    }

    function claimDeposit() external {
        address actor = _actor();

        vm.prank(actor);
        try hub.deposit(VAULT_ID, 0, actor, actor) returns (uint256 shares) {
            ghost_depositSharesClaimed += shares;
        } catch {}
    }

    // ── Epoch ─────────────────────────────────────────────────────

    function settleEpoch() external {
        if (vault.stalePriceEpochs() == 0) {
            vm.warp(block.timestamp + EPOCH_DURATION);
        }
        // Vault balance delta isolates the deposit shares minted to the vault at settle —
        // performance fee shares go to feeRecipient and never touch the vault balance.
        uint256 balBefore = syShare.balanceOf(address(vault));
        vm.prank(keeper);
        try vault.epochSettle(INITIAL_PRICE) {
            ghost_depositSharesToVault += syShare.balanceOf(address(vault)) - balBefore;
        } catch {}
    }

    // ── Normal redeem ─────────────────────────────────────────────

    function requestNormalRedeem(uint256 fraction) external {
        address actor = _actor();
        uint256 bal = syShare.balanceOf(actor);
        if (bal == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 shares = (bal * fraction) / 100;
        if (shares == 0) return;

        (uint256 activeId,) = vault.activeRedeemRequest(actor);
        if (activeId != 0) return;

        vm.prank(actor);
        try hub.requestRedeem(VAULT_ID, shares, actor, actor) {} catch {}
    }

    function settleNormalCycle() external {
        uint256 cycleId = vault.currentNormalCycleId();
        if (cycleId == 0) return;

        RedeemCycle memory cycle = vault.redeemCycleSchedule(cycleId);
        if (cycle.settled || cycle.shares == 0) return;

        if (vault.currentEpoch() < cycle.lockEpoch) {
            vm.warp(cycle.lockEpoch * EPOCH_DURATION + 1);
        }

        uint256 amount = cycle.shares; // return at 1:1 for simplicity
        asset.mint(allocator, amount);
        vm.startPrank(allocator);
        asset.approve(address(pool), amount);
        pool.returnCapital(amount);
        try vault.settleRedeemBatch(cycleId, amount) {
            ghost_totalSharesBurned += cycle.shares;
        } catch {}
        vm.stopPrank();
    }

    function claimNormalRedeem() external {
        address actor = _actor();
        uint256 maxRdm = vault.maxRedeem(actor);
        if (maxRdm == 0) return;

        vm.prank(actor);
        try hub.redeem(VAULT_ID, maxRdm, actor, actor) {} catch {}
    }
}

/// @dev Invariant test suite. Foundry calls Handler functions randomly.
contract SyVaultInvariantTest is Base {

    Handler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new Handler(
            vault, syShare, pool, hub, asset,
            VAULT_ID, INITIAL_PRICE,
            keeper, allocator, feeRecip
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                           CORE INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev totalSupply == effectiveSupply + pendingRedeemShares (locked shares are still in supply).
    function invariant_totalSupply_accounting() external view {
        uint256 total     = syShare.totalSupply();
        uint256 effective = vault.effectiveSupply();
        uint256 locked    = vault.pendingRedeemShares();

        assertEq(total, effective + locked);
    }

    /// @dev Pool balance must be >= reserved amounts at all times.
    function invariant_pool_covers_reserves() external view {
        uint256 poolBal   = pool.balance();
        uint256 redeemDue = vault.redeemDue();
        uint256 claimable = vault.claimableRedeemAssets();
        uint256 pending   = vault.pendingDepositAssets();

        assertGe(poolBal, redeemDue + claimable + pending);
    }

    /// @dev Shares held by vault contract == locked redeem shares + unclaimed deposit shares.
    ///      Deposit shares are minted to the vault at epochSettle (B1) and leave only via claims;
    ///      floor-rounding dust stays inside the minted−claimed remainder, so equality is exact.
    function invariant_vaultShareBalance_accounting() external view {
        assertEq(
            syShare.balanceOf(address(vault)),
            vault.pendingRedeemShares()
                + handler.ghost_depositSharesToVault()
                - handler.ghost_depositSharesClaimed()
        );
    }

    /// @dev effectiveSupply can never exceed totalSupply.
    function invariant_effectiveSupply_le_totalSupply() external view {
        assertLe(vault.effectiveSupply(), syShare.totalSupply());
    }

    /// @dev allocatorAllowance is always a subset of pool balance.
    function invariant_allocatorAllowance_le_poolBalance() external view {
        assertLe(pool.allocatorAllowance(), pool.balance());
    }

    /// @dev claimableRedeemAssets can never exceed pool balance.
    function invariant_claimable_le_poolBalance() external view {
        assertLe(vault.claimableRedeemAssets(), pool.balance());
    }

    /// @dev Share price is always > 0 once supply is non-zero.
    function invariant_sharePrice_positive() external view {
        if (syShare.totalSupply() > 0) {
            assertGt(vault.latestSharePrice(), 0);
        }
    }
}
