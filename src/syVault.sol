// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SyVaultRedeem} from "src/abstracts/SyVaultRedeem.sol";
import {SyVaultBase}   from "src/abstracts/SyVaultBase.sol";
import {ISyVault}      from "src/interfaces/ISyVault.sol";
import {ILiquidityPool} from "src/interfaces/ILiquidityPool.sol";
import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}     from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC7540Deposit, IERC7540Redeem} from "src/interfaces/IERC7540.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {
    SyVault__ZeroAmount,
    SyVault__BelowMinDeposit,
    SyVault__DepositNotAllowed,
    SyVault__InvalidOwner,
    SyVault__NoPendingRequest,
    SyVault__NoClaimableDeposit,
    SyVault__AsyncVault,
    SyVault__InvalidParam,
    SyVault__InvalidFeeConfig,
    SyVault__ZeroSettlementPrice,
    SyVault__InvalidOverrideEpochs
} from "src/types/Errors.sol";
import {
    SHARE_PRICE_PRECISION,
    BASIS_POINTS,
    MAX_FAST_REDEEM_FEE_BPS,
    EPOCHS_PER_YEAR,
    EPOCH_DURATION
} from "src/types/Constants.sol";
import {DepositRequestStatus} from "src/types/Types.sol";

/// @title  syVault
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Per-vault async yield vault — EIP-7540 + EIP-4626 partial + EIP-7575 + EIP-7887.
/// @dev    Core accounting contract. Manages deposit settlement (hourly epochs), normal and fast
///         redeem cycles, share price, fee logic, whitelists, and allocator allowance.
///
///         All user write functions are called via Hub (onlyHub enforced).
///         Bot functions (epochSettle, settleRedeemBatch) are called directly.
///         All view functions are public.
///
///         Deposit flow:   requestDeposit → epochSettle → deposit/mint
///         Redeem flow:    requestRedeem  → [lock] → returnCapital → settleRedeemBatch → redeem/withdraw
///         Fast redeem:    requestFastRedeem → [lock] → returnCapital → settleRedeemBatch → redeem/withdraw
///
///         Key invariants:
///         - Shares minted ONLY at deposit()/mint() claim — never at requestDeposit().
///         - Shares burned ONLY at settleRedeemBatch() — never before.
///         - returnCapital() MUST precede settleRedeemBatch(). Never invert.
///         - cancelRedeemRequest/cancelDepositRequest always available, even when paused.
contract SyVault is SyVaultRedeem {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev epoch → total pending assets for that epoch.
    mapping(uint256 epoch => uint256 assets) private s_pendingDepositsByEpoch;

    /// @dev controller → epoch → pending assets (cleared to 0 after claim).
    mapping(address controller => mapping(uint256 epoch => uint256 assets)) private s_pendingDeposits;

    /// @dev controller → epoch → owner who made the deposit (for cancellation refund).
    mapping(address controller => mapping(uint256 epoch => address owner)) private s_depositRequestOwner;

    /// @dev controller → ordered list of epochs with pending/claimable deposits.
    mapping(address controller => uint256[]) private s_controllerDepositEpochs;

    /// @dev controller → epoch → true if the epoch was ever pushed to s_controllerDepositEpochs.
    ///      Prevents duplicate entries caused by cancel + re-deposit in the same epoch.
    mapping(address controller => mapping(uint256 epoch => bool pushed)) private s_epochPushed;

    /// @dev controller → index to start iterating s_controllerDepositEpochs from.
    ///      Advanced past fully claimed settled entries to avoid O(n) iteration over dead epochs.
    mapping(address controller => uint256 index) private s_depositClaimIndex;

    /// @dev epoch → share price at settlement (0 = not yet settled; set to >=1 at epochSettle).
    mapping(uint256 epoch => uint256 sharePrice) private s_epochSettlementPrice;

    /// @dev Total pending deposit assets across all epochs.
    uint256 private s_totalPendingDeposits;

    /// @dev Total settled-but-unclaimed deposit assets across all epochs.
    ///      Incremented at epochSettle when pending moves to claimable; decremented as users claim.
    ///      Used by tvlComponents() to correctly exclude committed assets from pool contribution.
    uint256 private s_totalClaimableDeposits;

    /*//////////////////////////////////////////////////////////////
              CONSTRUCTOR (called by concrete child contracts)
    //////////////////////////////////////////////////////////////*/

    /// @param _asset             Address of the underlying ERC-20 asset.
    /// @param _share             Address of the paired syShare token.
    /// @param _liquidityPool     Address of the paired LiquidityPool.
    /// @param _hub               Address of the singleton Hub.
    /// @param _adminGateway      Address of the singleton AdminGateway.
    /// @param _keeper            Address of the Keeper bot.
    /// @param _allocator         Address of the Allocator EOA.
    /// @param _feeRecipient      Address that receives protocol fees.
    /// @param _initialSharePrice Initial share price in raw asset units (e.g. 1e6 for USDC).
    /// @param _fastRedeemEnabled True to enable fast redeem requests at launch; false to disable.
    constructor(
        address _asset,
        address _share,
        address _liquidityPool,
        address _hub,
        address _adminGateway,
        address _keeper,
        address _allocator,
        address _feeRecipient,
        uint256 _initialSharePrice,
        bool    _fastRedeemEnabled
    ) SyVaultBase(_asset, _share, _liquidityPool, _hub, _adminGateway, _keeper, _allocator, _feeRecipient) {
        if (_initialSharePrice == 0) revert SyVault__InvalidParam();
        s_sharePrice        = _initialSharePrice;
        s_hwm               = _initialSharePrice;
        s_cycleIdCounter                 = 1; // 0 reserved as "no active redeem" sentinel
        s_fastRedeemEnabled              = _fastRedeemEnabled;
        s_fastRedeemCapBps               = BASIS_POINTS; // 100% of TVL = unlimited by default
        s_allocatorActiveOverrideEpochs  = 2;
        // Precision floor: minimum share amount that maps to at least 1 raw asset unit.
        // Prevents dust redeem cycles that would settle with cycleRate = 0 on low-decimal assets.
        // Admin can override via setMinRedeem(). Auto-zeroed on deprecation via AdminGateway.
        uint8 assetDecimals = IERC20Metadata(address(_asset)).decimals();
        s_minRedeem = assetDecimals < 18 ? 10 ** (18 - assetDecimals) : 1;
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL HOOK — epoch settle (deposit side)
    //////////////////////////////////////////////////////////////*/

    /// @dev Called by SyVaultEpoch.epochSettle() after effectivePrice is determined.
    ///      Marks the epoch settled and deducts pendingAssets from s_totalPendingDeposits.
    function _onEpochSettle(uint256 _epochToSettle, uint256 _effectivePrice) internal override {
        // A zero settlement price would corrupt deposit claims (shares = assets / price = ∞).
        // This is defense-in-depth: setter validation makes this unreachable under correct config.
        // Recovery: GUARDIAN/ADMIN can call epochSettle(0) to reuse the previous non-zero price.
        if (_effectivePrice == 0) revert SyVault__ZeroSettlementPrice();
        s_epochSettlementPrice[_epochToSettle] = _effectivePrice;
        uint256 pendingAssets = s_pendingDepositsByEpoch[_epochToSettle];
        if (pendingAssets > 0) {
            s_totalPendingDeposits   -= pendingAssets;
            s_totalClaimableDeposits += pendingAssets;
        }
    }

    /*//////////////////////////////////////////////////////////////
              EXTERNAL STATE-CHANGING — USER (via Hub)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function requestDeposit(uint256 _assets, address _controller, address _owner)
        external
        onlyHub
        whenDepositsNotPaused
        returns (uint256 requestId)
    {
        if (_assets == 0) revert SyVault__ZeroAmount();
        if (s_minDeposit > 0 && _assets < s_minDeposit) revert SyVault__BelowMinDeposit();

        // Single eligibility gate — delegates pause, whitelist, stale price, and TVL checks
        // to maxDeposit(). Call requestDepositStatus() for the specific rejection reason.
        if (_assets > maxDeposit(_controller)) revert SyVault__DepositNotAllowed();

        requestId = currentEpoch();

        // Track epoch and owner — multiple deposits per (controller, epoch) accumulate.
        // s_epochPushed prevents duplicates if the controller cancels and re-deposits in the same epoch.
        if (!s_epochPushed[_controller][requestId]) {
            s_controllerDepositEpochs[_controller].push(requestId);
            s_epochPushed[_controller][requestId] = true;
            s_depositRequestOwner[_controller][requestId] = _owner;
        } else if (s_depositRequestOwner[_controller][requestId] != _owner) {
            revert SyVault__InvalidOwner();
        }

        s_pendingDeposits[_controller][requestId]   += _assets;
        s_pendingDepositsByEpoch[requestId]          += _assets;
        s_totalPendingDeposits                       += _assets;

        // Pull assets from owner directly into the LiquidityPool — never touch this contract.
        i_asset.safeTransferFrom(_owner, i_liquidityPool, _assets);

        emit DepositRequest(_controller, _owner, requestId, msg.sender, _assets);
    }

    /// @inheritdoc ISyVault
    function cancelDepositRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 assets = s_pendingDeposits[_controller][_requestId];
        if (assets == 0) revert SyVault__NoPendingRequest();
        // Can only cancel before the epoch is settled.
        if (s_epochSettlementPrice[_requestId] > 0) revert SyVault__NoPendingRequest();

        address owner = s_depositRequestOwner[_controller][_requestId];

        s_pendingDeposits[_controller][_requestId] = 0;
        s_pendingDepositsByEpoch[_requestId]        -= assets;
        s_totalPendingDeposits                      -= assets;

        // Return assets from the LiquidityPool directly to the original owner.
        ILiquidityPool(i_liquidityPool).transferTo(owner, assets);

        emit DepositCancelRequest(_controller, _requestId, assets);
    }

    /// @inheritdoc ISyVault
    function deposit(uint256 _assets, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 shares)
    {
        shares = _consumeDepositEpochsByAssets(_controller, _assets);
        if (shares == 0) revert SyVault__NoClaimableDeposit();
        // Assets already reside in LiquidityPool — no transfer needed here.
        i_share.mint(_receiver, shares);
    }

    /// @inheritdoc ISyVault
    function mint(uint256 _shares, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 assets)
    {
        if (_shares == 0) revert SyVault__ZeroAmount();
        assets = _consumeDepositEpochsByShares(_controller, _shares);
        if (assets == 0) revert SyVault__NoClaimableDeposit();
        i_share.mint(_receiver, _shares);
    }

    /// @inheritdoc ISyVault
    function setOperator(address _controller, address _operator, bool _approved)
        external
        onlyHub
        returns (bool)
    {
        s_operators[_controller][_operator] = _approved;
        emit OperatorSet(_controller, _operator, _approved);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPERS — deposit epoch iteration
    //////////////////////////////////////////////////////////////*/

    /// @dev Asset-based claim path for deposit(). Iterates epochs oldest-first starting from
    ///      s_depositClaimIndex to skip already-drained entries. Pass _assets = 0 to claim all.
    ///      Advances s_depositClaimIndex past settled, fully-drained entries as it goes.
    function _consumeDepositEpochsByAssets(address _controller, uint256 _assets)
        internal
        returns (uint256 sharesOut)
    {
        uint256[] storage epochs = s_controllerDepositEpochs[_controller];
        uint256 len              = epochs.length;
        uint256 remaining        = _assets;

        for (uint256 i = s_depositClaimIndex[_controller]; i < len; ++i) {
            uint256 epoch       = epochs[i];
            uint256 settlePrice = s_epochSettlementPrice[epoch];
            if (settlePrice == 0) continue; // not yet settled — index cannot advance past unsettled entries

            uint256 pending = s_pendingDeposits[_controller][epoch];
            if (pending == 0) {
                // Settled and fully claimed — advance start index past this dead entry.
                if (i == s_depositClaimIndex[_controller]) s_depositClaimIndex[_controller] = i + 1;
                continue;
            }

            uint256 epochAssets = (_assets == 0)
                ? pending
                : (pending < remaining ? pending : remaining);

            sharesOut += (epochAssets * SHARE_PRICE_PRECISION) / settlePrice;
            s_pendingDeposits[_controller][epoch] -= epochAssets;
            s_totalClaimableDeposits              -= epochAssets;

            // If fully drained, advance start index.
            if (s_pendingDeposits[_controller][epoch] == 0 && i == s_depositClaimIndex[_controller]) {
                s_depositClaimIndex[_controller] = i + 1;
            }

            if (_assets != 0) {
                remaining -= epochAssets;
                if (remaining == 0) break;
            }
        }
    }

    /// @dev Share-based claim path for mint(). Iterates epochs oldest-first starting from
    ///      s_depositClaimIndex. Advances s_depositClaimIndex past settled, fully-drained entries.
    ///      Returns assets consumed; returns 0 if the requested shares cannot be fully filled.
    function _consumeDepositEpochsByShares(address _controller, uint256 _sharesTarget)
        internal
        returns (uint256 assetsOut)
    {
        uint256[] storage epochs = s_controllerDepositEpochs[_controller];
        uint256 len              = epochs.length;
        uint256 sharesRemaining  = _sharesTarget;

        for (uint256 i = s_depositClaimIndex[_controller]; i < len; ++i) {
            uint256 epoch       = epochs[i];
            uint256 settlePrice = s_epochSettlementPrice[epoch];
            if (settlePrice == 0) continue;

            uint256 pending = s_pendingDeposits[_controller][epoch];
            if (pending == 0) {
                // Settled and fully claimed — advance start index past this dead entry.
                if (i == s_depositClaimIndex[_controller]) s_depositClaimIndex[_controller] = i + 1;
                continue;
            }

            uint256 epochMaxShares = (pending * SHARE_PRICE_PRECISION) / settlePrice;
            uint256 epochShares    = epochMaxShares < sharesRemaining ? epochMaxShares : sharesRemaining;

            // Round up assets to avoid over-minting; cap to pending to absorb dust.
            uint256 epochAssets = (epochShares * settlePrice + SHARE_PRICE_PRECISION - 1) / SHARE_PRICE_PRECISION;
            if (epochAssets > pending) epochAssets = pending;
            epochShares = (epochAssets * SHARE_PRICE_PRECISION) / settlePrice;

            // Cap after round-trip: rounding up epochAssets can inflate epochShares above
            // sharesRemaining on low-decimal assets (e.g. USDC), causing underflow.
            if (epochShares > sharesRemaining) epochShares = sharesRemaining;

            assetsOut       += epochAssets;
            sharesRemaining -= epochShares;
            s_pendingDeposits[_controller][epoch] -= epochAssets;
            s_totalClaimableDeposits              -= epochAssets;

            // If fully drained, advance start index.
            if (s_pendingDeposits[_controller][epoch] == 0 && i == s_depositClaimIndex[_controller]) {
                s_depositClaimIndex[_controller] = i + 1;
            }

            if (sharesRemaining == 0) break;
        }

        if (sharesRemaining > 0) assetsOut = 0; // signal incomplete fill
    }

    /*//////////////////////////////////////////////////////////////
              EXTERNAL STATE-CHANGING — ADMIN GATEWAY (PAUSE)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function pauseDeposits() external onlyAdminGateway {
        s_pausedDeposits = true;
        emit VaultPaused("deposits");
    }

    /// @inheritdoc ISyVault
    function pauseRedeems() external onlyAdminGateway {
        s_pausedRedeems = true;
        emit VaultPaused("redeems");
    }

    /// @inheritdoc ISyVault
    function pause() external onlyAdminGateway {
        s_pausedFull = true;
        emit VaultPaused("full");
    }

    /// @inheritdoc ISyVault
    function unpauseDeposits() external onlyAdminGateway {
        s_pausedDeposits = false;
        emit VaultUnpaused("deposits");
    }

    /// @inheritdoc ISyVault
    function unpauseRedeems() external onlyAdminGateway {
        s_pausedRedeems = false;
        emit VaultUnpaused("redeems");
    }

    /// @inheritdoc ISyVault
    function unpause() external onlyAdminGateway {
        s_pausedFull = false;
        emit VaultUnpaused("full");
    }

    /*//////////////////////////////////////////////////////////////
          EXTERNAL STATE-CHANGING — ADMIN GATEWAY (ROLE SETTERS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setKeeper(address _keeper) external onlyAdminGateway {
        emit KeeperUpdated(s_keeper, _keeper);
        s_keeper = _keeper;
    }

    /// @inheritdoc ISyVault
    function setAllocator(address _allocator) external onlyAdminGateway {
        emit AllocatorUpdated(s_allocator, _allocator);
        s_allocator            = _allocator;
        s_allocatorActive      = false;
        s_allocatorActiveSkips = 0;
    }

    /// @inheritdoc ISyVault
    function setFeeRecipient(address _feeRecipient) external onlyAdminGateway {
        emit FeeRecipientUpdated(s_feeRecipient, _feeRecipient);
        s_feeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
        EXTERNAL STATE-CHANGING — ADMIN GATEWAY (PARAM SETTERS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setMaxTvl(uint256 _maxTVL) external onlyAdminGateway {
        emit MaxTvlUpdated(s_maxTVL, _maxTVL);
        s_maxTVL = _maxTVL;
    }

    /// @inheritdoc ISyVault
    function setMinDeposit(uint256 _minDeposit) external onlyAdminGateway {
        emit MinDepositUpdated(s_minDeposit, _minDeposit);
        s_minDeposit = _minDeposit;
    }

    /// @inheritdoc ISyVault
    function setMinRedeem(uint256 _minRedeem) external onlyAdminGateway {
        emit MinRedeemUpdated(s_minRedeem, _minRedeem);
        s_minRedeem = _minRedeem;
    }

    /// @inheritdoc ISyVault
    function setAllocatorActiveOverrideEpochs(uint256 _epochs) external onlyAdminGateway {
        if (_epochs == 0 || _epochs > 24) revert SyVault__InvalidOverrideEpochs();
        emit AllocatorActiveOverrideEpochsUpdated(s_allocatorActiveOverrideEpochs, _epochs);
        s_allocatorActiveOverrideEpochs = _epochs;
    }

    /// @inheritdoc ISyVault
    function setMaxSharePriceDelta(uint256 _delta) external onlyAdminGateway {
        emit MaxSharePriceDeltaUpdated(s_maxSharePriceDelta, _delta);
        s_maxSharePriceDelta = _delta;
    }

    /// @inheritdoc ISyVault
    function setMaxStalePriceEpochs(uint256 _epochs) external onlyAdminGateway {
        emit MaxStalePriceEpochsUpdated(s_maxStalePriceEpochs, _epochs);
        s_maxStalePriceEpochs = _epochs;
    }

    /// @inheritdoc ISyVault
    function setMaintenanceFeeInterval(uint256 _interval) external onlyAdminGateway {
        // Hard cap: interval cannot exceed one year. Defense-in-depth — when maintenanceFeeBps = 0
        // the cross-param guard below evaluates to 0 and passes for any interval, so an extreme
        // value could be set and later combined with a non-zero bps to produce a near-full-price
        // deduction in one collection. The cap makes this setter self-sufficient (F-01).
        if (_interval > EPOCHS_PER_YEAR) revert SyVault__InvalidParam();
        // Cross-param guard: bps × interval must be < BASIS_POINTS × EPOCHS_PER_YEAR.
        // A product >= this threshold means the fee per interval equals or exceeds the full price,
        // which would reduce the share price to zero on the next collection.
        if (_interval > 0 && s_maintenanceFeeBps * _interval >= BASIS_POINTS * EPOCHS_PER_YEAR) {
            revert SyVault__InvalidFeeConfig();
        }
        emit MaintenanceFeeIntervalUpdated(s_maintenanceFeeInterval, _interval);
        s_maintenanceFeeInterval = _interval;
    }

    /// @inheritdoc ISyVault
    function setPerformanceFeeBps(uint256 _bps) external onlyAdminGateway {
        if (_bps > BASIS_POINTS) revert SyVault__InvalidParam();
        emit PerformanceFeeBpsUpdated(s_performanceFeeBps, _bps);
        s_performanceFeeBps = _bps;
    }

    /// @inheritdoc ISyVault
    function setMaintenanceFeeBps(uint256 _bps) external onlyAdminGateway {
        // Disallow 100% (>= BASIS_POINTS) — a single collection at 100% bps would zero the price.
        if (_bps >= BASIS_POINTS) revert SyVault__InvalidParam();
        // Cross-param guard: see setMaintenanceFeeInterval for rationale.
        if (_bps > 0 && _bps * s_maintenanceFeeInterval >= BASIS_POINTS * EPOCHS_PER_YEAR) {
            revert SyVault__InvalidFeeConfig();
        }
        emit MaintenanceFeeBpsUpdated(s_maintenanceFeeBps, _bps);
        s_maintenanceFeeBps = _bps;
    }

    /// @inheritdoc ISyVault
    function setFastRedeemFeeBps(uint256 _bps) external onlyAdminGateway {
        if (_bps > MAX_FAST_REDEEM_FEE_BPS) revert SyVault__InvalidParam();
        emit FastRedeemFeeBpsUpdated(s_fastRedeemFeeBps, _bps);
        s_fastRedeemFeeBps = _bps;
    }

    /// @inheritdoc ISyVault
    function setFastRedeemCapBps(uint256 _bps) external onlyAdminGateway {
        if (_bps == 0 || _bps > BASIS_POINTS) revert SyVault__InvalidParam();
        emit FastRedeemCapBpsUpdated(s_fastRedeemCapBps, _bps);
        s_fastRedeemCapBps = _bps;
    }

    /*//////////////////////////////////////////////////////////////
         EXTERNAL STATE-CHANGING — ADMIN GATEWAY (WHITELISTS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setDepositWhitelistEnabled(bool _enabled) external onlyAdminGateway {
        emit DepositWhitelistEnabledUpdated(_enabled);
        s_depositWhitelistEnabled = _enabled;
    }

    /// @inheritdoc ISyVault
    function setDepositWhitelist(address _account, bool _approved) external onlyAdminGateway {
        s_depositWhitelist[_account] = _approved;
        emit DepositWhitelistUpdated(_account, _approved);
    }

    /// @inheritdoc ISyVault
    function setFastRedeemFeeWhitelist(address _account, bool _approved) external onlyAdminGateway {
        s_fastRedeemFeeWhitelist[_account] = _approved;
        emit FastRedeemFeeWhitelistUpdated(_account, _approved);
    }

    /// @inheritdoc ISyVault
    function setFastRedeemEnabled(bool _enabled) external onlyAdminGateway {
        s_fastRedeemEnabled = _enabled;
        emit FastRedeemEnabledUpdated(_enabled);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW — EIP-7540
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function pendingDepositRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 assets)
    {
        // EIP-7540: pending and claimable are mutually exclusive. Once settled, return 0.
        if (s_epochSettlementPrice[_requestId] > 0) return 0;
        return s_pendingDeposits[_controller][_requestId];
    }

    /// @inheritdoc ISyVault
    function claimableDepositRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 assets)
    {
        // Epoch is settled when settlement price is recorded; pending assets become claimable.
        if (s_epochSettlementPrice[_requestId] == 0) return 0;
        return s_pendingDeposits[_controller][_requestId];
    }

    /// @inheritdoc ISyVault
    function isOperator(address _controller, address _operator) external view returns (bool) {
        return s_operators[_controller][_operator];
    }

    /*//////////////////////////////////////////////////////////////
                  EXTERNAL VIEW — EIP-4626 PARTIAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function totalAssets() external view returns (uint256) {
        // EIP-4626 estimate. Stale by at most 1 epoch. Includes unrealized P&L via sharePrice.
        return (s_sharePrice * i_share.totalSupply()) / SHARE_PRICE_PRECISION;
    }

    /// @inheritdoc ISyVault
    function convertToShares(uint256 _assets) external view returns (uint256 shares) {
        shares = (_assets * SHARE_PRICE_PRECISION) / s_sharePrice;
    }

    /// @inheritdoc ISyVault
    function convertToAssets(uint256 _shares) external view returns (uint256 assets) {
        assets = (_shares * s_sharePrice) / SHARE_PRICE_PRECISION;
    }

    /// @inheritdoc ISyVault
    /// @dev Public (not external) so requestDeposit() can call it internally as the single
    ///      eligibility gate — avoids duplicating whitelist, stale price, and TVL checks.
    function maxDeposit(address _receiver) public view returns (uint256) {
        if (!_isStarted()) return 0;
        if (s_pausedFull || s_pausedDeposits) return 0;
        if (s_depositWhitelistEnabled && !s_depositWhitelist[_receiver]) return 0;
        // Stale price guard — block new deposits if keeper has fallen too far behind.
        if (s_maxStalePriceEpochs > 0) {
            uint256 current = currentEpoch();
            uint256 stale   = current > s_nextEpochToSettle ? current - s_nextEpochToSettle : 0;
            if (stale >= s_maxStalePriceEpochs) return 0;
        }
        uint256 available;
        if (s_maxTVL == 0) {
            available = type(uint256).max;
        } else {
            uint256 tvl  = (s_sharePrice * i_share.totalSupply()) / SHARE_PRICE_PRECISION;
            uint256 used = tvl + s_totalPendingDeposits + s_totalClaimableDeposits;
            available = used >= s_maxTVL ? 0 : s_maxTVL - used;
        }
        // If remaining room is below minDeposit, no deposit can succeed — signal unavailable.
        if (s_minDeposit > 0 && available < s_minDeposit) return 0;
        return available;
    }

    /// @inheritdoc ISyVault
    /// @dev Always reverts — async vault has no synchronous price preview (EIP-7540 compliance).
    function previewDeposit(uint256) external pure returns (uint256) { revert SyVault__AsyncVault(); }

    /// @inheritdoc ISyVault
    function previewMint(uint256) external pure returns (uint256) { revert SyVault__AsyncVault(); }

    /// @inheritdoc ISyVault
    function previewRedeem(uint256) external pure returns (uint256) { revert SyVault__AsyncVault(); }

    /// @inheritdoc ISyVault
    function previewWithdraw(uint256) external pure returns (uint256) { revert SyVault__AsyncVault(); }

    /*//////////////////////////////////////////////////////////////
               EXTERNAL VIEW — PRE-FLIGHT ELIGIBILITY CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function requestDepositStatus(address _controller) external view returns (DepositRequestStatus) {
        if (!_isStarted()) return DepositRequestStatus.NotStarted;
        if (s_pausedFull || s_pausedDeposits) return DepositRequestStatus.Paused;
        if (s_depositWhitelistEnabled && !s_depositWhitelist[_controller]) return DepositRequestStatus.NotWhitelisted;
        if (s_maxStalePriceEpochs > 0) {
            uint256 current = currentEpoch();
            uint256 stale   = current > s_nextEpochToSettle ? current - s_nextEpochToSettle : 0;
            if (stale >= s_maxStalePriceEpochs) return DepositRequestStatus.StalePrice;
        }
        if (s_maxTVL > 0) {
            uint256 used = (s_sharePrice * i_share.totalSupply()) / SHARE_PRICE_PRECISION + s_totalPendingDeposits + s_totalClaimableDeposits;
            if (used >= s_maxTVL) return DepositRequestStatus.TVLExceeded;
        }
        return DepositRequestStatus.Ok;
    }

    /// @inheritdoc ISyVault
    /// @dev Complements requestDepositStatus() — that check is amount-agnostic; this one validates the amount.
    function checkDepositAmount(uint256 _assets) external view returns (DepositRequestStatus) {
        if (s_minDeposit > 0 && _assets < s_minDeposit) return DepositRequestStatus.BelowMinDeposit;
        return DepositRequestStatus.Ok;
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL VIEW — EIP-4626 ASSET
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function asset() external view returns (address) {
        return address(i_asset);
    }

    /// @inheritdoc ISyVault
    function sharePriceDecimals() external view returns (uint8) {
        return IERC20Metadata(address(i_asset)).decimals();
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL VIEW — EIP-7575
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function share() external view returns (address) {
        return address(i_share);
    }

    /*//////////////////////////////////////////////////////////////
                     EXTERNAL VIEW — EIP-165
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return _interfaceId == type(IERC165).interfaceId
            || _interfaceId == type(IERC7540Deposit).interfaceId
            || _interfaceId == type(IERC7540Redeem).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW — SYVAULT-SPECIFIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function epochEnd() external view returns (uint256) {
        if (!_isStarted()) return type(uint256).max;
        uint256 epoch = currentEpoch();
        return s_epochOrigin + ((epoch + 1) * EPOCH_DURATION);
    }

    /// @inheritdoc ISyVault
    function investableLiquidity() external view returns (uint256) {
        return ILiquidityPool(i_liquidityPool).allocatorAllowance();
    }

    /// @inheritdoc ISyVault
    function tvlComponents() external view returns (uint256 poolContrib, uint256 stratReserved) {
        uint256 pool     = ILiquidityPool(i_liquidityPool).balance();
        uint256 reserved = _redeemDue()
                         + s_claimableRedeemAssets
                         + s_totalPendingDeposits
                         + s_totalClaimableDeposits;
        if (pool >= reserved) {
            poolContrib   = pool - reserved;
            stratReserved = 0;
        } else {
            poolContrib   = 0;
            stratReserved = reserved - pool;
        }
    }

    /// @inheritdoc ISyVault
    function pendingDepositAssets() external view returns (uint256) {
        return s_totalPendingDeposits;
    }

    /// @inheritdoc ISyVault
    function totalClaimableDeposits() external view returns (uint256) {
        return s_totalClaimableDeposits;
    }

    /*//////////////////////////////////////////////////////////////
                  EXTERNAL VIEW — ROLES & CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function keeper() external view returns (address) { return s_keeper; }

    /// @inheritdoc ISyVault
    function allocator() external view returns (address) { return s_allocator; }

    /// @inheritdoc ISyVault
    function feeRecipient() external view returns (address) { return s_feeRecipient; }

    /// @inheritdoc ISyVault
    function adminGateway() external view returns (address) { return i_adminGateway; }

    /// @inheritdoc ISyVault
    function maxTvl()    external view returns (uint256) { return s_maxTVL; }

    /// @inheritdoc ISyVault
    function minDeposit() external view returns (uint256) { return s_minDeposit; }

    /// @inheritdoc ISyVault
    function minRedeem() external view returns (uint256) { return s_minRedeem; }

    /// @inheritdoc ISyVault
    function maxSharePriceDelta() external view returns (uint256) { return s_maxSharePriceDelta; }

    /// @inheritdoc ISyVault
    function maxStalePriceEpochs() external view returns (uint256) { return s_maxStalePriceEpochs; }

    /// @inheritdoc ISyVault
    function maintenanceFeeInterval() external view returns (uint256) { return s_maintenanceFeeInterval; }

    /// @inheritdoc ISyVault
    function performanceFeeBps() external view returns (uint256) { return s_performanceFeeBps; }

    /// @inheritdoc ISyVault
    function maintenanceFeeBps() external view returns (uint256) { return s_maintenanceFeeBps; }

    /// @inheritdoc ISyVault
    function fastRedeemFeeBps() external view returns (uint256) { return s_fastRedeemFeeBps; }

    /// @inheritdoc ISyVault
    function fastRedeemCapBps() external view returns (uint256) { return s_fastRedeemCapBps; }

    /// @inheritdoc ISyVault
    function depositWhitelistEnabled() external view returns (bool) { return s_depositWhitelistEnabled; }

    /// @inheritdoc ISyVault
    function fastRedeemEnabled() external view returns (bool) { return s_fastRedeemEnabled; }

    /// @inheritdoc ISyVault
    function isPaused() external view returns (bool deposits, bool redeems, bool full) {
        deposits = s_pausedDeposits;
        redeems  = s_pausedRedeems;
        full     = s_pausedFull;
    }
}
