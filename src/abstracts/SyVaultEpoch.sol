// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SyVaultBase} from "src/abstracts/SyVaultBase.sol";
import {SharePriceSnapshot} from "src/types/Types.sol";
import {
    SyVault__NotKeeper,
    SyVault__EpochNotElapsed,
    SyVault__SharePriceDeltaExceeded,
    SyVault__RangeTooLarge,
    SyVault__InvalidRange
} from "src/types/Errors.sol";
import {
    ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS,
    MAX_HISTORY_RANGE,
    BASIS_POINTS,
    SHARE_PRICE_PRECISION,
    EPOCHS_PER_YEAR
} from "src/types/Constants.sol";

/// @title  SyVaultEpoch
/// @author Shift Protocol
/// @notice Epoch settlement, share price tracking, Hwm, and performance/maintenance fee logic.
abstract contract SyVaultEpoch is SyVaultBase {

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 internal s_sharePrice;
    uint256 internal s_previousSharePrice;
    uint256 internal s_hwm;

    /// @dev Ring buffer: epoch % MAX_HISTORY_RANGE → SharePriceSnapshot.
    SharePriceSnapshot[720] internal s_sharePriceHistory;

    /// @dev Ring buffer: epoch % MAX_HISTORY_RANGE → Hwm value.
    uint256[720] internal s_hwmHistory;

    /// @dev Next epoch the Keeper must settle. stalePriceEpochs = currentEpoch() - s_nextEpochToSettle.
    uint256 internal s_nextEpochToSettle;

    bool    internal s_allocatorActive;

    /// @dev Consecutive epochs where epochSettle skipped price update due to allocatorActive.
    uint256 internal s_allocatorActiveSkips;

    /// @dev Last epoch at which performance or maintenance fee was collected.
    uint256 internal s_lastFeeCollectionEpoch;

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL STATE-CHANGING — KEEPER
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle pending deposits and update share price. Called every epoch by Keeper.
    /// @dev    Keeper can call with any price. AdminGateway can call with 0 only (GUARDIAN/ADMIN emergency).
    ///         Skips price update if allocatorActive = true (uses previous price).
    ///         After ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS consecutive skips, proceeds with proposed price.
    ///         Collects performance fee (mints shares if sharePrice > Hwm).
    ///         Collects maintenance fee every feeCollectionInterval epochs (deducts from TVL).
    ///         Emits SharePriceUpdated, PerformanceFeeCollected, and conditionally MaintenanceFeeCollected.
    /// @param  _sharePrice Proposed share price in raw asset units per whole share. For a 6-decimal
    ///                     asset (e.g. USDC): 1 token/share = 1e6. For an 18-decimal asset (e.g. WETH):
    ///                     1 token/share = 1e18. Keeper formula: (TVL_raw * SHARE_PRICE_PRECISION) /
    ///                     effectiveSupply(). Pass 0 to reuse the previous price (emergency/AdminGateway).
    function epochSettle(uint256 _sharePrice) external {
        // Keeper can call with any price. AdminGateway (GUARDIAN/ADMIN route) can call with 0 only.
        if (msg.sender != s_keeper) {
            if (msg.sender != i_adminGateway || _sharePrice != 0) revert SyVault__NotKeeper();
        }
        uint256 epochToSettle = s_nextEpochToSettle;
        if (epochToSettle >= currentEpoch()) revert SyVault__EpochNotElapsed();

        uint256 prevPrice      = s_sharePrice;
        uint256 effectivePrice = _resolveEffectivePrice(_sharePrice, prevPrice);

        effectivePrice = _collectFees(epochToSettle, effectivePrice);

        _onEpochSettle(epochToSettle, effectivePrice);

        s_previousSharePrice = prevPrice;
        s_sharePrice         = effectivePrice;
        s_sharePriceHistory[epochToSettle % MAX_HISTORY_RANGE] = SharePriceSnapshot({
            sharePrice:  effectivePrice,
            totalSupply: i_share.totalSupply(),
            timestamp:   block.timestamp
        });
        s_hwmHistory[epochToSettle % MAX_HISTORY_RANGE] = s_hwm;
        s_nextEpochToSettle = epochToSettle + 1;

        emit SharePriceUpdated(epochToSettle, effectivePrice, prevPrice, i_share.totalSupply(), block.timestamp);
    }

    /// @dev Resolves the effective share price for this epoch.
    ///      Returns the previous price on emergency (0) or while allocator is within grace period.
    ///      Accepts the proposed price after ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS consecutive skips.
    function _resolveEffectivePrice(uint256 _proposed, uint256 _prev) internal returns (uint256) {
        if (_proposed == 0) return _prev;

        if (s_allocatorActive) {
            s_allocatorActiveSkips++;
            if (s_allocatorActiveSkips >= ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS) {
                s_allocatorActive      = false;
                s_allocatorActiveSkips = 0;
                return _proposed;
            }
            return _prev;
        }

        if (_prev > 0 && s_maxSharePriceDelta > 0) {
            uint256 delta = _proposed > _prev
                ? ((_proposed - _prev) * BASIS_POINTS) / _prev
                : ((_prev - _proposed) * BASIS_POINTS) / _prev;
            if (delta > s_maxSharePriceDelta) revert SyVault__SharePriceDeltaExceeded();
        }
        return _proposed;
    }

    /// @dev Applies maintenance fee (share price deduction) and performance fee (share dilution).
    ///      Returns the price after maintenance deduction (performance fee does not change price).
    function _collectFees(uint256 _epoch, uint256 _price) internal returns (uint256) {
        uint256 supply = i_share.totalSupply();

        // ── Performance fee ────────────────────────────────────────────────────────────────
        // Evaluated against the gross reported price before maintenance deduction, so the
        // Hwm comparison is never affected by operational costs.
        uint256 hwm            = s_hwm;
        uint256 feeSharesMinted;
        if (_price > hwm && s_performanceFeeBps > 0) {
            uint256 grossPrice = _price; // pre-dilution price — used for HWM and event
            if (supply > 0) {
                // Dilution model: feeShares = (price - Hwm) * supply * feeBps / (price * BASIS_POINTS)
                feeSharesMinted = ((_price - hwm) * supply * s_performanceFeeBps)
                    / (_price * BASIS_POINTS);
                if (feeSharesMinted > 0) {
                    i_share.mint(s_feeRecipient, feeSharesMinted);
                    // Adjust price to reflect dilution: TVL is invariant (P × S = newP × (S + feeShares)).
                    // Without this, s_sharePrice × totalSupply overcounts TVL by P × feeShares.
                    _price = (_price * supply) / (supply + feeSharesMinted);
                }
            }
            // HWM tracks the gross reported price — not the post-dilution price.
            // Dilution at grossPrice already "pays" the fee; comparing future prices
            // against the post-dilution price would allow a second fee collection on the same gain.
            s_hwm = grossPrice;
            emit PerformanceFeeCollected(_epoch, grossPrice, hwm, feeSharesMinted);
        }

        // ── Maintenance fee ────────────────────────────────────────────────────────────────
        // Condition: a full interval has elapsed since the last collection (or since vault start).
        // Uses elapsed-since-last rather than epoch % interval to:
        //   (a) avoid charging a full interval fee at epoch 0 (only 1 epoch elapsed);
        //   (b) correctly collect during keeper catch-up even if an interval epoch was missed.
        if (s_maintenanceFeeInterval > 0 && s_maintenanceFeeBps > 0
            && (_epoch - s_lastFeeCollectionEpoch >= s_maintenanceFeeInterval))
        {
            uint256 priceBefore  = _price;
            uint256 feeDeduction = (_price * s_maintenanceFeeBps * s_maintenanceFeeInterval)
                / (BASIS_POINTS * EPOCHS_PER_YEAR);
            _price = _price > feeDeduction ? _price - feeDeduction : 0;

            emit MaintenanceFeeCollected(
                _epoch,
                (feeDeduction * supply) / SHARE_PRICE_PRECISION,
                priceBefore,
                _price
            );
            s_lastFeeCollectionEpoch = _epoch;
        }

        return _price;
    }

    /// @notice Signal that the allocator is mid-operation (bridging, deploying to strategy).
    /// @dev    onlyAllocator. When true, epochSettle skips share price update for up to
    ///         ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS before overriding with proposed price.
    ///         Call with false once the operation completes and NAV is accurate again.
    function setAllocatorActive(bool _active) external onlyAllocator {
        s_allocatorActive      = _active;
        s_allocatorActiveSkips = 0;
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL HOOK (overridden in child)
    //////////////////////////////////////////////////////////////*/

    /// @dev Called during epochSettle after effectivePrice is computed.
    ///      Subclass (SyVault) uses this to settle pending deposits.
    function _onEpochSettle(uint256 _epochToSettle, uint256 _effectivePrice) internal virtual;

    /*//////////////////////////////////////////////////////////////
                            PUBLIC VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Latest settled share price in raw asset units per whole share.
    ///         For a 6-decimal asset (e.g. USDC): 1 token/share = 1e6.
    ///         For an 18-decimal asset (e.g. WETH): 1 token/share = 1e18.
    function latestSharePrice() external view returns (uint256) {
        return s_sharePrice;
    }

    /// @notice Full performance snapshot — epoch, prices, supply, timestamp, HWM.
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
        )
    {
        uint256 lastSettled = s_nextEpochToSettle > 0 ? s_nextEpochToSettle - 1 : 0;
        epoch              = lastSettled;
        sharePrice         = s_sharePrice;
        previousSharePrice = s_previousSharePrice;
        totalSupply        = i_share.totalSupply();
        timestamp          = s_sharePriceHistory[lastSettled % MAX_HISTORY_RANGE].timestamp;
        hwm                = s_hwm;
    }

    /// @notice Share price history for a given epoch range. Max range: 720 epochs (30d).
    function getSharePriceHistory(uint256 _fromEpoch, uint256 _toEpoch)
        external
        view
        returns (SharePriceSnapshot[] memory snapshots)
    {
        if (_fromEpoch > _toEpoch) revert SyVault__InvalidRange();
        if (_toEpoch - _fromEpoch >= MAX_HISTORY_RANGE) revert SyVault__RangeTooLarge();
        uint256 len = _toEpoch - _fromEpoch + 1;
        snapshots = new SharePriceSnapshot[](len);
        for (uint256 i; i < len; ++i) {
            snapshots[i] = s_sharePriceHistory[(_fromEpoch + i) % MAX_HISTORY_RANGE];
        }
    }

    /// @notice Current High Water Mark. Same units as latestSharePrice() —
    ///         raw asset units per whole share. Updated upward only on each performance fee collection.
    function latestHwm() external view returns (uint256) {
        return s_hwm;
    }

    /// @notice HWM values over an epoch range. Same 720-epoch ring buffer.
    function getHwmHistory(uint256 _fromEpoch, uint256 _toEpoch)
        external
        view
        returns (uint256[] memory hwmValues)
    {
        if (_fromEpoch > _toEpoch) revert SyVault__InvalidRange();
        if (_toEpoch - _fromEpoch >= MAX_HISTORY_RANGE) revert SyVault__RangeTooLarge();
        uint256 len = _toEpoch - _fromEpoch + 1;
        hwmValues = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            hwmValues[i] = s_hwmHistory[(_fromEpoch + i) % MAX_HISTORY_RANGE];
        }
    }

    /// @notice Number of consecutive epochs without a share price update from the Keeper.
    function stalePriceEpochs() external view returns (uint256) {
        uint256 current = currentEpoch();
        return current > s_nextEpochToSettle ? current - s_nextEpochToSettle : 0;
    }

    /// @notice True if the Allocator is currently operating.
    function allocatorActive() external view returns (bool) {
        return s_allocatorActive;
    }

}
