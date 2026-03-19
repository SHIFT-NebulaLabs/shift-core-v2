// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CycleState, RedeemCycle, SharePriceSnapshot, DepositRequestStatus, RedeemRequestStatus, FastRedeemRequestStatus} from "src/types/Types.sol";

/// @title  ISyVault
/// @author Shift Protocol
/// @notice Full interface for syVault — EIP-7540 async vault with EIP-4626 partial compliance,
///         EIP-7575 share discovery, EIP-7887 cancellation, and fast redeem extension.
/// @dev    All user write functions are called via Hub (onlyHub enforced on syVault).
///         Bot functions (epochSettle, settleRedeemBatch) call syVault directly.
///         All view functions are public.

interface ISyVault {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a deposit request is submitted.
    /// @param  controller  Address that owns the request and can claim.
    /// @param  owner       Address whose assets were used.
    /// @param  requestId   Current epoch at request time — use as key for pending/claimable queries.
    /// @param  sender      msg.sender at request time.
    /// @param  assets      Asset amount deposited.
    event DepositRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 assets
    );

    /// @notice Emitted when a pending deposit request is cancelled.
    /// @param  controller  Address that owned the request.
    /// @param  requestId   Epoch at which the request was submitted.
    /// @param  assets      Assets returned to owner.
    event DepositCancelRequest(address indexed controller, uint256 indexed requestId, uint256 assets);

    /// @notice Emitted when a pending normal or fast redeem request is cancelled.
    /// @param  controller  Address that owned the request.
    /// @param  requestId   Cycle id at which the request was submitted.
    /// @param  shares      Shares returned to owner.
    event RedeemCancelRequest(address indexed controller, uint256 indexed requestId, uint256 shares);

    /// @notice Emitted when a normal redeem request is submitted.
    /// @param  controller  Address that owns the request and can claim.
    /// @param  owner       Address whose shares were locked.
    /// @param  requestId   Current normal cycle id at request time.
    /// @param  sender      msg.sender at request time.
    /// @param  shares      Shares locked.
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    /// @notice Emitted when a fast redeem request is submitted.
    /// @param  controller  Address that owns the request and can claim.
    /// @param  owner       Address whose shares were locked.
    /// @param  requestId   Current fast cycle id at request time.
    /// @param  sender      msg.sender at request time.
    /// @param  shares      Shares locked.
    event FastRedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );

    /// @notice Emitted when a normal or fast redeem cycle is settled by the Allocator.
    /// @param  cycleId         Cycle identifier.
    /// @param  cycleType       Normal or fast.
    /// @param  returnedAmount  Assets returned by Allocator via returnCapital().
    /// @param  cycleShares     Total shares burned in this settlement.
    /// @param  cycleRate       returnedAmount / cycleShares, scaled by SHARE_PRICE_PRECISION.
    /// @param  feeCollected    Fast redeem fee collected (0 for normal cycles).
    event RedeemCycleSettled(
        uint256 cycleId,
        uint8   cycleType,
        uint256 returnedAmount,
        uint256 cycleShares,
        uint256 cycleRate,
        uint256 feeCollected
    );

    /// @notice Emitted every epochSettle() — always, even when allocatorActive skips price update.
    /// @param  epoch               Epoch number at settlement.
    /// @param  sharePrice          Share price at settlement, scaled by SHARE_PRICE_PRECISION.
    /// @param  previousSharePrice  Share price from previous epoch.
    /// @param  totalSupply         syShare totalSupply at settlement.
    /// @param  timestamp           block.timestamp at settlement.
    event SharePriceUpdated(
        uint256 epoch,
        uint256 sharePrice,
        uint256 previousSharePrice,
        uint256 totalSupply,
        uint256 timestamp
    );

    /// @notice Emitted every epochSettle() — always, even with feeSharesMinted = 0.
    /// @param  epoch           Epoch number.
    /// @param  sharePrice      Share price after fee.
    /// @param  previousHwm     High water mark before this epoch.
    /// @param  feeSharesMinted Shares minted to feeRecipient (0 if sharePrice <= Hwm or fee = 0).
    event PerformanceFeeCollected(
        uint256 epoch,
        uint256 sharePrice,
        uint256 previousHwm,
        uint256 feeSharesMinted
    );

    /// @notice Emitted every feeCollectionInterval epochs — always, even with feeAssets = 0.
    /// @param  epoch           Epoch number.
    /// @param  feeAssets       Assets equivalent deducted from TVL (0 if maintenanceFee = 0).
    /// @param  sharePriceBefore Share price before maintenance fee deduction.
    /// @param  sharePriceAfter  Share price after maintenance fee deduction.
    event MaintenanceFeeCollected(
        uint256 epoch,
        uint256 feeAssets,
        uint256 sharePriceBefore,
        uint256 sharePriceAfter
    );

    /// @notice Emitted when an operator is approved or revoked by a controller.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Emitted when any deposit, redeem, or full pause is activated.
    /// @param  scope  "deposits", "redeems", or "full".
    event VaultPaused(string scope);

    /// @notice Emitted when a pause is lifted.
    /// @param  scope  "deposits", "redeems", or "full".
    event VaultUnpaused(string scope);

    /// @notice Emitted when the Keeper address is rotated.
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    /// @notice Emitted when the Allocator address is rotated.
    event AllocatorUpdated(address indexed oldAllocator, address indexed newAllocator);

    /// @notice Emitted when the fee recipient is changed.
    event FeeRecipientUpdated(address indexed oldFeeRecipient, address indexed newFeeRecipient);

    /// @notice Emitted when the max TVL cap is changed (0 = unlimited).
    event MaxTvlUpdated(uint256 oldMaxTvl, uint256 newMaxTvl);

    /// @notice Emitted when the minimum deposit amount is changed (0 = no minimum).
    event MinDepositUpdated(uint256 oldMinDeposit, uint256 newMinDeposit);

    /// @notice Emitted when the max share price delta per epoch is changed.
    event MaxSharePriceDeltaUpdated(uint256 oldDelta, uint256 newDelta);

    /// @notice Emitted when the max stale price epochs threshold is changed.
    event MaxStalePriceEpochsUpdated(uint256 oldEpochs, uint256 newEpochs);

    /// @notice Emitted when the maintenance fee collection interval is changed.
    event MaintenanceFeeIntervalUpdated(uint256 oldInterval, uint256 newInterval);

    /// @notice Emitted when the performance fee basis points is changed.
    event PerformanceFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the maintenance fee basis points is changed.
    event MaintenanceFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the fast redeem fee basis points is changed.
    event FastRedeemFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when the deposit whitelist is enabled or disabled.
    event DepositWhitelistEnabledUpdated(bool enabled);

    /// @notice Emitted when a deposit whitelist entry is added or removed.
    event DepositWhitelistUpdated(address indexed account, bool approved);

    /// @notice Emitted when a fast redeem fee whitelist entry is added or removed.
    event FastRedeemFeeWhitelistUpdated(address indexed account, bool approved);

    /*//////////////////////////////////////////////////////////////
                        EIP-7540 — WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a deposit request. Assets transferred from owner to LiquidityPool immediately.
    /// @dev    Pending state. Settled at next epochSettle(). requestId = currentEpoch().
    ///         Only callable via Hub.
    /// @param  assets      Amount of underlying asset to deposit.
    /// @param  controller  Address that will own the request and can claim shares.
    /// @param  owner       Address whose assets are used — must be msg.sender unless operator approved.
    /// @return requestId   Current epoch number — use as key for pending/claimable queries.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Cancel a pending deposit request and return assets to owner.
    /// @dev    Only available before the next epochSettle() processes the request.
    ///         Always callable — bypasses pause. Only callable via Hub.
    /// @param  requestId   Epoch at which the deposit request was submitted.
    /// @param  controller  Controller that owns the request.
    function cancelDepositRequest(uint256 requestId, address controller) external;

    /// @notice Submit a normal redeem request. Shares locked immediately.
    /// @dev    Pending state. Added to current 7-day cycle. requestId = currentNormalCycleId().
    ///         If the current cycle is past its cutoff epoch, the request automatically goes to the next cycle.
    ///         Only callable via Hub.
    /// @param  shares      Shares to redeem.
    /// @param  controller  Address that will own the request and can claim assets.
    /// @param  owner       Address whose shares are locked — must be msg.sender unless operator approved.
    /// @return requestId   Current normal cycle id — use as key for pending/claimable queries.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Cancel a pending normal redeem request and return shares to owner.
    /// @dev    Only available before the cycle lock epoch (epoch 144). Always callable — bypasses pause.
    ///         Only callable via Hub.
    /// @param  requestId   Normal cycle id at which the redeem request was submitted.
    /// @param  controller  Controller that owns the request.
    function cancelRedeemRequest(uint256 requestId, address controller) external;

    /// @notice Submit a fast redeem request. Shares locked immediately.
    /// @dev    Pending state. 1-day cycle. requestId = currentFastCycleId().
    ///         Reverts with SyVault__RedeemRequestAlreadyPending if any active redeem exists.
    ///         Only callable via Hub.
    /// @param  shares      Shares to fast-redeem.
    /// @param  controller  Address that will own the request and can claim assets.
    /// @param  owner       Address whose shares are locked — must be msg.sender unless operator approved.
    /// @return requestId   Current fast cycle id.
    function requestFastRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    /// @notice Cancel a pending fast redeem request and return shares to owner.
    /// @dev    Only available before fast cycle lock epoch (epoch 20). Always callable — bypasses pause.
    ///         Only callable via Hub.
    /// @param  requestId   Fast cycle id at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    function cancelFastRedeemRequest(uint256 requestId, address controller) external;

    /// @notice Claim a settled deposit — mints shares to receiver.
    /// @dev    Does NOT transfer assets — already happened at requestDeposit(). Only callable via Hub.
    ///         Shares minted = claimable assets / sharePrice at settlement epoch.
    /// @param  assets      Claimable asset amount (pass 0 to claim entire claimable balance).
    /// @param  receiver    Address that will receive minted shares.
    /// @param  controller  Controller that owns the deposit request.
    /// @return shares      Shares minted to receiver.
    function deposit(uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Claim a settled deposit by specifying exact shares — mints shares to receiver.
    /// @dev    EIP-7540 compliance. Debits corresponding assets from claimable balance.
    ///         Only callable via Hub.
    /// @param  shares      Exact number of shares to mint.
    /// @param  receiver    Address that will receive minted shares.
    /// @param  controller  Controller that owns the deposit request.
    /// @return assets      Assets debited from claimable balance.
    function mint(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claim a settled redeem — burns shares and transfers assets to receiver.
    /// @dev    Does NOT lock shares — already happened at requestRedeem(). Only callable via Hub.
    ///         Fast redeem fee deducted from assets at claim if applicable.
    /// @param  shares      Shares to redeem (must match locked amount).
    /// @param  receiver    Address that will receive assets.
    /// @param  controller  Controller that owns the redeem request.
    /// @return assets      Assets transferred to receiver (net of fast redeem fee if applicable).
    function redeem(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    /// @notice Claim a settled redeem by specifying exact assets — burns corresponding shares.
    /// @dev    EIP-7540 compliance. Only callable via Hub.
    /// @param  assets      Exact asset amount to receive.
    /// @param  receiver    Address that will receive assets.
    /// @param  controller  Controller that owns the redeem request.
    /// @return shares      Shares burned.
    function withdraw(uint256 assets, address receiver, address controller)
        external
        returns (uint256 shares);

    /// @notice Delegate request management to an operator.
    /// @dev    Only callable via Hub. EIP-7540 compliance.
    ///         controller is msg.sender at Hub level, passed explicitly since Hub is always msg.sender here.
    /// @param  controller  Address whose operator list is modified.
    /// @param  operator    Address to approve or revoke.
    /// @param  approved    True to approve, false to revoke.
    /// @return             Always true (EIP-7540 compliance).
    function setOperator(address controller, address operator, bool approved) external returns (bool);

    /*//////////////////////////////////////////////////////////////
                       EIP-7540 — VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Assets in Pending state for a given deposit request.
    /// @param  requestId   Epoch at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return assets      Pending asset amount.
    function pendingDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 assets);

    /// @notice Assets in Claimable state for a given deposit request.
    /// @param  requestId   Epoch at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return assets      Claimable asset amount.
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 assets);

    /// @notice Shares in Pending state for a given normal redeem request.
    /// @param  requestId   Normal cycle id at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return shares      Pending share amount.
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    /// @notice Shares in Claimable state for a given normal redeem request.
    /// @param  requestId   Normal cycle id at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return shares      Claimable share amount.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    /// @notice Shares in Pending state for a given fast redeem request.
    /// @param  requestId   Fast cycle id at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return shares      Pending share amount.
    function pendingFastRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    /// @notice Assets in Claimable state for a given fast redeem — fee already deducted.
    /// @param  requestId   Fast cycle id at which the request was submitted.
    /// @param  controller  Controller that owns the request.
    /// @return assets      Net claimable asset amount after fast redeem fee.
    function claimableFastRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 assets);

    /// @notice Check operator approval status.
    /// @param  controller  Controller that granted (or did not grant) the approval.
    /// @param  operator    Address to check.
    /// @return             True if operator is approved by controller.
    function isOperator(address controller, address operator) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                     EIP-4626 PARTIAL — VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the underlying ERC-20 asset (e.g. USDC).
    /// @dev    EIP-4626. Frontend must call asset() to know which token to approve before requestDeposit().
    function asset() external view returns (address);

    /// @notice Total assets managed by the vault — estimate for display only.
    /// @dev    = sharePrice × totalSupply. Stale by at most 1 epoch. Includes unrealized P&L.
    /// @return Total asset estimate.
    function totalAssets() external view returns (uint256);

    /// @notice Convert assets to shares at the current share price.
    /// @dev    Indicative. Use for UI display. Not a guaranteed rate.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Convert shares to assets at the current share price.
    /// @dev    Indicative. Use for UI display. Not a guaranteed rate.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Maximum assets depositable by receiver.
    /// @dev    Returns 0 if deposits are paused, receiver not whitelisted, or maxTVL reached.
    ///         TVL is computed as sharePrice × totalSupply() — this is TOTAL TVL, which includes
    ///         shares locked for pending redeems. Those shares are burned at settleRedeemBatch(),
    ///         not at claimRedeemRequest(). Deposit capacity therefore only opens up after the
    ///         Allocator settles a redeem batch — not when users claim their assets.
    ///         Additionally, queued pending deposit assets are included in the cap check, so
    ///         headroom = maxTVL - (sharePrice × totalSupply()) - pendingDepositAssets.
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice Maximum shares redeemable by owner.
    /// @dev    Returns claimable shares for this owner.
    function maxRedeem(address owner) external view returns (uint256);

    /// @notice Single-call eligibility check for requestDeposit — use in FE to surface a reason.
    /// @param  controller  Address that will own the request.
    /// @return status      Ok if request can proceed; otherwise the blocking reason.
    function requestDepositStatus(address controller) external view returns (DepositRequestStatus status);

    /// @notice Amount-level check — returns BelowMinDeposit if assets < minDeposit, otherwise Ok.
    /// @dev    Complement to requestDepositStatus() which is amount-agnostic.
    function checkDepositAmount(uint256 assets) external view returns (DepositRequestStatus status);

    /// @notice Single-call eligibility check for requestRedeem — use in FE to surface a reason.
    /// @param  owner   Address that will lock shares.
    /// @return status  Ok if request can proceed; PastCutoff means it will open a new cycle (not blocking).
    function requestRedeemStatus(address owner) external view returns (RedeemRequestStatus status);

    /// @notice Pre-flight check for requestFastRedeem(). Returns the reason the call would revert, or Ok.
    /// @param  owner   Address that will lock shares.
    /// @return status  Ok if request can proceed; otherwise the blocking reason.
    function requestFastRedeemStatus(address owner) external view returns (FastRedeemRequestStatus status);

    /// @notice MUST revert — async vault, no synchronous preview. EIP-7540 compliance.
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice MUST revert — async vault, no synchronous preview. EIP-7540 compliance.
    function previewMint(uint256 shares) external view returns (uint256);

    /// @notice MUST revert — async vault, no synchronous preview. EIP-7540 compliance.
    function previewRedeem(uint256 shares) external view returns (uint256);

    /// @notice MUST revert — async vault, no synchronous preview. EIP-7540 compliance.
    function previewWithdraw(uint256 assets) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                         EIP-7575 — VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the syShare token for this vault.
    /// @dev    Required by EIP-7575 for bidirectional vault/share discovery.
    function share() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                      EIP-165 — INTERFACE DETECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns true for ERC-7540 deposit, redeem, operator, and ERC-7575 interface IDs.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                    KEEPER — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle pending deposits and update share price. Called every epoch by Keeper.
    /// @dev    Callable by Keeper (any price) or AdminGateway (sharePrice = 0 only, emergency path).
    ///         Pass sharePrice = 0 to use previous price — valid for both Keeper and AdminGateway.
    ///         Skips price update if allocatorActive = true (uses previous price).
    ///         After ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS consecutive skips, proceeds with proposed price.
    ///         Collects performance fee (mints shares if sharePrice > HWM).
    ///         Collects maintenance fee every feeCollectionInterval epochs (deducts from TVL).
    ///         Emits SharePriceUpdated, PerformanceFeeCollected, and conditionally MaintenanceFeeCollected.
    /// @param  sharePrice  Proposed share price, scaled by SHARE_PRICE_PRECISION. 0 = use previous.
    function epochSettle(uint256 sharePrice) external;

    /*//////////////////////////////////////////////////////////////
                    ALLOCATOR — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle a locked redeem cycle after Allocator has returned capital.
    /// @dev    onlyAllocator. nonReentrant. cycleRate = returnedAmount / cycleShares. Burns shares.
    ///         Invariant: returnCapital() on LiquidityPool MUST be called before this. Never invert.
    ///         Fast redeem fee deducted from returnedAmount before computing cycleRate.
    /// @param  cycleId         Cycle identifier — same value used as requestId by controllers.
    /// @param  returnedAmount  Asset amount returned via returnCapital() for this specific cycle.
    function settleRedeemBatch(uint256 cycleId, uint256 returnedAmount) external;

    /*//////////////////////////////////////////////////////////////
                      SYVAULT-SPECIFIC — VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Timestamp at which the current epoch ends.
    function epochEnd() external view returns (uint256);

    /// @notice Current epoch number — equals requestId for new deposit requests.
    function currentEpoch() external view returns (uint256);

    /// @notice Current normal redeem cycle id — equals requestId for new normal redeem requests.
    function currentNormalCycleId() external view returns (uint256);

    /// @notice Current fast redeem cycle id — equals requestId for new fast redeem requests.
    function currentFastCycleId() external view returns (uint256);

    /// @notice State of a redeem cycle (Pending, Cutoff, Locked, Claimable).
    /// @param  cycleId  Cycle identifier. Works for both normal and fast cycles.
    function currentCycleState(uint256 cycleId) external view returns (CycleState);

    /// @notice Full schedule data for a redeem cycle.
    /// @param  cycleId  Cycle identifier.
    function redeemCycleSchedule(uint256 cycleId) external view returns (RedeemCycle memory);

    /// @notice Latest share price in raw asset units per whole share.
    ///         Precision = asset decimals. Use sharePriceDecimals() to interpret.
    ///         e.g. USDC vault: 1.05 USDC/share = 1_050_000 (6 decimals).
    function latestSharePrice() external view returns (uint256);

    /// @notice Decimals used by sharePrice, HWM, and TVL values.
    ///         Equal to the underlying asset's decimals (e.g. 6 for USDC, 18 for WETH).
    ///         Equivalent to IERC20Metadata(asset()).decimals() — exposed here for
    ///         integrators who read vault values without separately querying the asset.
    function sharePriceDecimals() external view returns (uint8);

    /// @notice Full performance snapshot — epoch, prices, supply, timestamp, HWM.
    /// @dev    Use for real-time APY display without an indexer.
    function latestPerformance()
        external
        view
        returns (
            uint256 epoch,
            uint256 sharePrice,
            uint256 previousSharePrice,
            uint256 totalSupply,
            uint256 timestamp,
            uint256 hwm
        );

    /// @notice Share price history for a given epoch range. Max range: 720 epochs (30d).
    /// @param  fromEpoch  Start epoch (inclusive).
    /// @param  toEpoch    End epoch (inclusive).
    function getSharePriceHistory(uint256 fromEpoch, uint256 toEpoch)
        external
        view
        returns (SharePriceSnapshot[] memory);

    /// @notice Current High Water Mark. Same units as latestSharePrice() —
    ///         raw asset units per whole share. Updated upward only on performance fee collection.
    function latestHwm() external view returns (uint256);

    /// @notice HWM values over an epoch range. Same 720-epoch ring buffer.
    /// @param  fromEpoch  Start epoch (inclusive).
    /// @param  toEpoch    End epoch (inclusive).
    function getHwmHistory(uint256 fromEpoch, uint256 toEpoch)
        external
        view
        returns (uint256[] memory);

    /// @notice Active redeem request for an owner.
    /// @dev    Returns (0, false) if no active request. requestId equals cycleId — use directly
    ///         with redeemCycleSchedule(), pendingRedeemRequest(), or claimableRedeemRequest().
    /// @param  owner  Address to query.
    /// @return requestId  Active cycle id (0 if none).
    /// @return isFast     True if the active request is a fast redeem.
    function activeRedeemRequest(address owner)
        external
        view
        returns (uint256 requestId, bool isFast);

    /// @notice Number of consecutive epochs without a share price update from the Keeper.
    function stalePriceEpochs() external view returns (uint256);

    /// @notice True if the Allocator is currently operating. Keeper uses previous price when true.
    function allocatorActive() external view returns (bool);

    /// @notice Total assets reserved for locked redeem cycles not yet settled.
    function redeemDue() external view returns (uint256);

    /// @notice Total shares locked in unsettled redeem cycles.
    function pendingRedeemShares() external view returns (uint256);

    /// @notice Shares in active circulation, excluding locked redeem shares.
    /// @dev    Keeper denominator for sharePrice = TVL / effectiveSupply().
    function effectiveSupply() external view returns (uint256);

    /// @notice Investable liquidity: LiquidityPool.balance − redeemDue − claimableRedeemAssets.
    function investableLiquidity() external view returns (uint256);

    /// @notice Total assets across all pending (pre-settlement) deposit requests.
    function pendingDepositAssets() external view returns (uint256);

    /// @notice Total assets across all settled-but-unclaimed redeem positions.
    function claimableRedeemAssets() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                   ROLES & CONFIGURATION — VIEW
    //////////////////////////////////////////////////////////////*/

    function keeper()                  external view returns (address);
    function allocator()               external view returns (address);
    function feeRecipient()            external view returns (address);
    function adminGateway()            external view returns (address);
    /// @notice Maximum TVL cap in raw asset units. 0 = no cap.
    /// @dev    Enforced as: sharePrice × totalSupply() + pendingDepositAssets + newAssets <= maxTVL.
    ///         totalSupply() is TOTAL supply — includes shares locked for pending redeems.
    ///         The cap therefore reflects full economic exposure, not just freely tradable shares.
    function maxTvl()                  external view returns (uint256);
    function minDeposit()              external view returns (uint256);
    function maxSharePriceDelta()      external view returns (uint256);
    function maxStalePriceEpochs()     external view returns (uint256);
    function maintenanceFeeInterval()  external view returns (uint256);
    function performanceFeeBps()       external view returns (uint256);
    function maintenanceFeeBps()       external view returns (uint256);
    function fastRedeemFeeBps()        external view returns (uint256);
    function depositWhitelistEnabled() external view returns (bool);

    /// @notice Current pause state of the vault.
    /// @return deposits  True if deposits are paused.
    /// @return redeems   True if redeems are paused.
    /// @return full      True if vault is fully paused.
    function isPaused() external view returns (bool deposits, bool redeems, bool full);

    /*//////////////////////////////////////////////////////////////
               ALLOCATOR — SIGNAL STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Signal that the allocator is mid-operation (bridging, deploying to strategy).
    /// @dev    onlyAllocator. When true, epochSettle skips share price update for up to
    ///         ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS before overriding with proposed price.
    ///         Call with false once the operation completes and NAV is accurate again.
    function setAllocatorActive(bool active) external;

    /*//////////////////////////////////////////////////////////////
               ADMIN GATEWAY — PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause deposit requests. onlyAdminGateway.
    function pauseDeposits()   external;
    /// @notice Pause redeem requests. onlyAdminGateway.
    function pauseRedeems()    external;
    /// @notice Full vault pause — blocks deposits and redeems. onlyAdminGateway.
    function pause()           external;
    /// @notice Lift deposit pause. onlyAdminGateway.
    function unpauseDeposits() external;
    /// @notice Lift redeem pause. onlyAdminGateway.
    function unpauseRedeems()  external;
    /// @notice Lift full pause. onlyAdminGateway.
    function unpause()         external;

    /*//////////////////////////////////////////////////////////////
               ADMIN GATEWAY — ROLE SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Replace the Keeper address. onlyAdminGateway.
    function setKeeper(address keeper) external;
    /// @notice Replace the Allocator address. onlyAdminGateway.
    function setAllocator(address allocator) external;
    /// @notice Replace the fee recipient address. onlyAdminGateway.
    function setFeeRecipient(address feeRecipient) external;

    /*//////////////////////////////////////////////////////////////
               ADMIN GATEWAY — PARAMETER SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the maximum TVL cap (raw asset units). 0 = no cap. onlyAdminGateway.
    /// @dev    TVL uses TOTAL share supply (including redeem-locked shares), so the cap only
    ///         loosens after settleRedeemBatch() burns the redeemed shares — not after user claims.
    function setMaxTvl(uint256 maxTVL) external;
    /// @notice Set the minimum deposit amount (raw asset units). 0 = no minimum. onlyAdminGateway.
    function setMinDeposit(uint256 minDeposit) external;
    /// @notice Set max allowed share price move per epoch in basis points. onlyAdminGateway.
    function setMaxSharePriceDelta(uint256 delta) external;
    /// @notice Set max epochs the keeper can be behind before deposits are blocked. onlyAdminGateway.
    function setMaxStalePriceEpochs(uint256 epochs) external;
    /// @notice Set epoch interval between maintenance fee collections. onlyAdminGateway.
    function setMaintenanceFeeInterval(uint256 interval) external;
    /// @notice Set performance fee in basis points. onlyAdminGateway.
    function setPerformanceFeeBps(uint256 bps) external;
    /// @notice Set annualised maintenance fee in basis points. onlyAdminGateway.
    function setMaintenanceFeeBps(uint256 bps) external;
    /// @notice Set fast redeem fee in basis points. onlyAdminGateway.
    function setFastRedeemFeeBps(uint256 bps) external;

    /*//////////////////////////////////////////////////////////////
               ADMIN GATEWAY — WHITELISTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable or disable the deposit whitelist. onlyAdminGateway.
    function setDepositWhitelistEnabled(bool enabled) external;
    /// @notice Add or remove an account from the deposit whitelist. onlyAdminGateway.
    function setDepositWhitelist(address account, bool approved) external;
    /// @notice Add or remove an account from the fast redeem fee exempt whitelist. onlyAdminGateway.
    function setFastRedeemFeeWhitelist(address account, bool approved) external;
}
