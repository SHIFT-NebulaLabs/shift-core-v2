// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {MockERC20}       from "test/mocks/MockERC20.sol";
import {SyShare}         from "src/SyShare.sol";
import {SyVault}         from "src/SyVault.sol";
import {LiquidityPool}   from "src/LiquidityPool.sol";
import {AddressRegistry} from "src/AddressRegistry.sol";
import {Hub}             from "src/Hub.sol";
import {VaultState}      from "src/types/Types.sol";
import {
    EPOCH_DURATION,
    NORMAL_REDEEM_LOCK_WINDOW,
    FAST_REDEEM_LOCK_WINDOW
} from "src/types/Constants.sol";

/// @dev Shared deployment base for all unit and invariant tests.
///      `admin` acts as a simple EOA that plays the AdminGateway role —
///      this bypasses TimelockController complexity in unit tests.
///      AdminGateway.t.sol deploys the real contract separately.
abstract contract Base is Test {
    /*//////////////////////////////////////////////////////////////
                              CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockERC20       internal asset;
    SyShare         internal syShare;
    SyVault         internal vault;
    LiquidityPool   internal pool;
    AddressRegistry internal registry;
    Hub             internal hub;

    /*//////////////////////////////////////////////////////////////
                               ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal admin     = makeAddr("admin");      // plays AdminGateway role
    address internal keeper    = makeAddr("keeper");
    address internal allocator = makeAddr("allocator");
    address internal feeRecip  = makeAddr("feeRecipient");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Share price is denominated in raw asset units per 1e18 shares, so the 1:1 price
    ///      is one whole asset unit — 1e18 for an 18-decimal asset, 1e6 for USDC. Derived from
    ///      _assetDecimals() so suites can re-run against low-decimal assets unchanged.
    uint256 internal INITIAL_PRICE;

    /// @dev One whole unit of the asset (10 ** decimals).
    uint256 internal ONE_ASSET;

    uint256 internal VAULT_ID;

    /// @dev Override in a suite to re-run it against a different asset precision.
    function _assetDecimals() internal view virtual returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////
                               SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // 1. Asset token
        uint8 dec = _assetDecimals();
        ONE_ASSET     = 10 ** dec;
        INITIAL_PRICE = ONE_ASSET; // 1:1 — raw asset units per 1e18 shares
        asset = new MockERC20("Mock USDC", "mUSDC", dec);

        // 2. AddressRegistry — admin is the sole writer (plays AdminGateway)
        registry = new AddressRegistry(admin);

        // 3. Hub
        hub = new Hub(address(registry));

        // 4. Pre-compute SyVault address before deploying to break circular deps:
        //    nonce = current (after asset + registry + hub = 3 deploys)
        //    syShare = nonce+0, pool = nonce+1, vault = nonce+2
        uint256 nonce = vm.getNonce(address(this));
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 2);

        // 5. SyShare — vault address set to predictedVault
        syShare = new SyShare("Shift Mock USDC", "syMUSDC", predictedVault);

        // 6. LiquidityPool
        pool = new LiquidityPool(address(asset), predictedVault);

        // 7. SyVault — address must match predictedVault
        vault = new SyVault(
            address(asset),
            address(syShare),
            address(pool),
            address(hub),
            admin,        // adminGateway EOA — simplifies unit tests
            keeper,
            allocator,
            feeRecip,
            INITIAL_PRICE,
            true          // fastRedeemEnabled
        );

        assertEq(address(vault), predictedVault, "vault address prediction failed");

        // 8. Register and activate vault
        vm.startPrank(admin);
        VAULT_ID = registry.registerVault(address(vault), address(pool), address(syShare), address(0));
        registry.setVaultState(VAULT_ID, VaultState.Active);
        vm.stopPrank();

        // 9. Start the vault — first epochSettle anchors the epoch timeline.
        _startVault();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS — ASSETS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint `amount` asset to `who` and max-approve vault to pull.
    function _giveAssets(address who, uint256 amount) internal {
        asset.mint(who, amount);
        vm.prank(who);
        asset.approve(address(vault), type(uint256).max);
    }

    /// @dev Deposit + settle + claim: give `who` shares worth `assetAmount` asset.
    function _giveShares(address who, uint256 assetAmount) internal returns (uint256 shares) {
        _giveAssets(who, assetAmount);
        vm.prank(who);
        hub.requestDeposit(VAULT_ID, assetAmount, who, who);
        _settleEpoch(INITIAL_PRICE);
        vm.prank(who);
        shares = hub.deposit(VAULT_ID, 0, who, who);
    }

    /*//////////////////////////////////////////////////////////////
                           HELPERS — EPOCH
    //////////////////////////////////////////////////////////////*/

    /// @dev Trigger the first epochSettle to anchor epoch origin.
    ///      Uses the initial share price — epoch 0 is settled at genesis price.
    function _startVault() internal {
        vm.prank(keeper);
        vault.epochSettle(INITIAL_PRICE);
    }

    /// @dev Advance `n` full epochs (no settlement).
    function _warpEpochs(uint256 n) internal {
        vm.warp(block.timestamp + n * EPOCH_DURATION);
    }

    /// @dev Advance one epoch and settle with `sharePrice`.
    function _settleEpoch(uint256 sharePrice) internal {
        _warpEpochs(1);
        vm.prank(keeper);
        vault.epochSettle(sharePrice);
    }

    /// @dev Settle multiple epochs back-to-back, all at `sharePrice`.
    function _settleEpochs(uint256 count, uint256 sharePrice) internal {
        for (uint256 i; i < count; ++i) {
            _settleEpoch(sharePrice);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         HELPERS — REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @dev Approve vault to pull shares from `who`, then submit normal redeem request.
    function _requestRedeem(address who, uint256 shares) internal returns (uint256 cycleId) {
        vm.startPrank(who);
        syShare.approve(address(vault), shares);
        cycleId = hub.requestRedeem(VAULT_ID, shares, who, who);
        vm.stopPrank();
    }

    /// @dev Approve vault to pull shares from `who`, then submit fast redeem request.
    function _requestFastRedeem(address who, uint256 shares) internal returns (uint256 cycleId) {
        vm.startPrank(who);
        syShare.approve(address(vault), shares);
        cycleId = hub.requestFastRedeem(VAULT_ID, shares, who, who);
        vm.stopPrank();
    }

    /// @dev Simulate Allocator returning `amount` to pool and settling `cycleId`.
    function _allocatorSettleCycle(uint256 cycleId, uint256 amount) internal {
        // Mint return assets to allocator and approve pool
        asset.mint(allocator, amount);
        vm.startPrank(allocator);
        asset.approve(address(pool), amount);
        pool.returnCapital(amount);
        vault.settleRedeemBatch(cycleId, amount);
        vm.stopPrank();
    }

    /// @dev Advance past NORMAL_REDEEM_LOCK_WINDOW epochs (cycle must have been opened at currentEpoch).
    function _warpToNormalLock(uint256 cycleOpenEpoch) internal {
        uint256 lockEpoch = cycleOpenEpoch + NORMAL_REDEEM_LOCK_WINDOW;
        vm.warp(lockEpoch * EPOCH_DURATION + 1); // +1 ensures we're strictly past lock
    }

    /// @dev Advance past FAST_REDEEM_LOCK_WINDOW epochs.
    function _warpToFastLock(uint256 cycleOpenEpoch) internal {
        uint256 lockEpoch = cycleOpenEpoch + FAST_REDEEM_LOCK_WINDOW;
        vm.warp(lockEpoch * EPOCH_DURATION + 1);
    }

    /*//////////////////////////////////////////////////////////////
                         HELPERS — ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    function _assertNoShares(address who) internal view {
        assertEq(syShare.balanceOf(who), 0);
    }

    function _assertShareBalance(address who, uint256 expected) internal view {
        assertEq(syShare.balanceOf(who), expected);
    }

    function _assertAssetBalance(address who, uint256 expected) internal view {
        assertEq(asset.balanceOf(who), expected);
    }
}
