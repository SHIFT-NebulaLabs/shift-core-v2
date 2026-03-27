// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SyVaultEpoch} from "src/abstracts/SyVaultEpoch.sol";
import {CycleState, CycleType, RedeemCycle, RedeemRequestStatus, FastRedeemRequestStatus} from "src/types/Types.sol";
import {
    SyVault__ZeroAmount,
    SyVault__BelowMinRedeem,
    SyVault__NoPendingRequest,
    SyVault__RedeemRequestAlreadyPending,
    SyVault__FastCycleNotSettled,
    SyVault__FastRedeemDisabled,
    SyVault__CycleNotLocked,
    SyVault__CycleLocked,
    SyVault__CycleAlreadySettled,
    SyVault__NoClaimableRedeem,
    SyVault__InvalidParam
} from "src/types/Errors.sol";
import {
    NORMAL_REDEEM_CUTOFF,
    NORMAL_REDEEM_LOCK_WINDOW,
    FAST_REDEEM_CUTOFF,
    FAST_REDEEM_LOCK_WINDOW,
    EPOCH_DURATION,
    BASIS_POINTS,
    SHARE_PRICE_PRECISION
} from "src/types/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityPool} from "src/interfaces/ILiquidityPool.sol";

/// @title  SyVaultRedeem
/// @author Shift Protocol
/// @notice Redeem cycle management: request, cancel, settle, and claim logic for
///         both normal (7-day) and fast (1-day) redeem cycles.
abstract contract SyVaultRedeem is SyVaultEpoch {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev cycleId → cycle data. Normal and fast share the same mapping — IDs are globally unique.
    mapping(uint256 cycleId => RedeemCycle cycle) internal s_redeemCycles;

    /// @dev controller → cycleId → pending shares (normal and fast).
    mapping(address controller => mapping(uint256 cycleId => uint256 shares)) internal s_pendingRedeems;

    /// @dev controller → cycleId → owner who submitted the request (for cancellation).
    mapping(address controller => mapping(uint256 cycleId => address owner)) internal s_redeemRequestOwner;

    // ── Active redeem tracking (one active redeem per controller) ───

    /// @dev controller → active cycleId (0 = no active redeem).
    ///      Keyed by controller — the EIP-7540 entity that owns the request and calls claim functions.
    mapping(address controller => uint256 cycleId) internal s_activeRedeemCycleId;

    /// @dev controller → true if active redeem is fast.
    mapping(address controller => bool isFast) internal s_activeRedeemIsFast;

    // ── Cycle counters ─────────────────────────────────────────

    /// @dev Single monotonic ID counter for both normal and fast cycles — ensures no collisions.
    ///      Post-increment: first cycle assigned id=0, then counter increments to 1.
    uint256 internal s_cycleIdCounter;

    /// @dev Currently accepting-requests normal cycle (0 = none allocated yet).
    uint256 internal s_currentNormalCycleId;

    /// @dev Currently accepting-requests fast cycle (0 = none allocated yet).
    uint256 internal s_currentFastCycleId;

    // ── TVL accounting ─────────────────────────────────────────

    /// @dev Total shares locked in all unsettled redeem cycles.
    ///      redeemDue (assets) is computed on demand: s_totalLockedShares × sharePrice / PRECISION.
    uint256 internal s_totalLockedShares;

    /// @dev Total assets in settled-but-unclaimed redeem positions.
    uint256 internal s_claimableRedeemAssets;

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING — USER (via Hub)
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a normal redeem request. Shares locked immediately.
    function requestRedeem(uint256 _shares, address _controller, address _owner)
        external
        onlyHub
        whenRedeemsNotPaused
        returns (uint256 requestId)
    {
        if (_shares == 0) revert SyVault__ZeroAmount();
        if (s_minRedeem > 0 && _shares < s_minRedeem) revert SyVault__BelowMinRedeem();
        // One active redeem per controller at a time.
        if (s_activeRedeemCycleId[_controller] != 0) revert SyVault__RedeemRequestAlreadyPending();

        requestId = _openOrReuseCycle(CycleType.Normal);

        s_redeemCycles[requestId].shares             += _shares;
        s_pendingRedeems[_controller][requestId]     += _shares;
        s_redeemRequestOwner[_controller][requestId]  = _owner;
        s_activeRedeemCycleId[_controller]            = requestId;
        s_activeRedeemIsFast[_controller]             = false;
        s_totalLockedShares                           += _shares;

        // Lock shares in this contract — burned only at settleRedeemBatch().
        IERC20(address(i_share)).safeTransferFrom(_owner, address(this), _shares);

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @notice Cancel a pending normal redeem request and return shares to owner.
    function cancelRedeemRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 shares = s_pendingRedeems[_controller][_requestId];
        if (shares == 0) revert SyVault__NoPendingRequest();

        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (cycle.cycleType != CycleType.Normal) revert SyVault__NoPendingRequest();
        if (currentEpoch() >= cycle.lockEpoch)   revert SyVault__CycleLocked();

        address owner = s_redeemRequestOwner[_controller][_requestId];

        cycle.shares                            -= shares;
        s_pendingRedeems[_controller][_requestId] = 0;
        s_activeRedeemCycleId[_controller]        = 0;
        s_activeRedeemIsFast[_controller]         = false;
        s_totalLockedShares                       -= shares;

        // Return locked shares to original owner.
        IERC20(address(i_share)).safeTransfer(owner, shares);

        emit RedeemCancelRequest(_controller, _requestId, shares);
    }

    /// @notice Submit a fast redeem request. Shares locked immediately.
    function requestFastRedeem(uint256 _shares, address _controller, address _owner)
        external
        onlyHub
        whenRedeemsNotPaused
        returns (uint256 requestId)
    {
        if (!s_fastRedeemEnabled) revert SyVault__FastRedeemDisabled();
        if (_shares == 0) revert SyVault__ZeroAmount();
        if (s_minRedeem > 0 && _shares < s_minRedeem) revert SyVault__BelowMinRedeem();
        // No active redeem of any kind allowed.
        if (s_activeRedeemCycleId[_controller] != 0) revert SyVault__RedeemRequestAlreadyPending();

        requestId = _openOrReuseCycle(CycleType.Fast);

        s_redeemCycles[requestId].shares             += _shares;
        s_pendingRedeems[_controller][requestId]     += _shares;
        s_redeemRequestOwner[_controller][requestId]  = _owner;
        s_activeRedeemCycleId[_controller]            = requestId;
        s_activeRedeemIsFast[_controller]             = true;
        s_totalLockedShares                           += _shares;

        IERC20(address(i_share)).safeTransferFrom(_owner, address(this), _shares);

        emit FastRedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @notice Cancel a pending fast redeem request and return shares to owner.
    function cancelFastRedeemRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 shares = s_pendingRedeems[_controller][_requestId];
        if (shares == 0) revert SyVault__NoPendingRequest();

        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (cycle.cycleType != CycleType.Fast)  revert SyVault__NoPendingRequest();
        if (currentEpoch() >= cycle.lockEpoch)  revert SyVault__CycleLocked();

        address owner = s_redeemRequestOwner[_controller][_requestId];

        cycle.shares                             -= shares;
        s_pendingRedeems[_controller][_requestId] = 0;
        s_activeRedeemCycleId[_controller]        = 0;
        s_activeRedeemIsFast[_controller]         = false;
        s_totalLockedShares                       -= shares;

        IERC20(address(i_share)).safeTransfer(owner, shares);

        emit RedeemCancelRequest(_controller, _requestId, shares);
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING — ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle a locked redeem cycle after Allocator has returned capital.
    function settleRedeemBatch(uint256 _cycleId, uint256 _returnedAmount) external onlyAllocator nonReentrant {
        RedeemCycle storage cycle = s_redeemCycles[_cycleId];
        if (cycle.shares == 0)                revert SyVault__NoPendingRequest();
        if (cycle.settled)                    revert SyVault__CycleAlreadySettled();
        if (currentEpoch() < cycle.lockEpoch) revert SyVault__CycleNotLocked();

        uint256 cycleShares = cycle.shares;

        cycle.returnedAmount = _returnedAmount;

        // cycleRate: gross assets per share, scaled by SHARE_PRICE_PRECISION.
        // Fast redeem fee is NOT deducted here — applied per-controller at claim time in redeem()/withdraw().
        uint256 cycleRate = cycleShares > 0
            ? (_returnedAmount * SHARE_PRICE_PRECISION) / cycleShares
            : 0;

        cycle.cycleRate = cycleRate;
        cycle.settled   = true;

        // Update TVL accounting — full returned amount is claimable (fee deducted per-claim).
        s_totalLockedShares     -= cycleShares;
        s_claimableRedeemAssets += _returnedAmount;

        // INVARIANT: shares burned here — never before.
        i_share.burn(address(this), cycleShares);

        emit RedeemCycleSettled(
            _cycleId,
            uint8(cycle.cycleType),
            _returnedAmount,
            cycleShares,
            cycleRate,
            0 // fee collected per-claim, not at settle
        );
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING — CLAIM (via Hub)
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim a settled redeem — burns shares and transfers assets to receiver.
    function redeem(uint256 _shares, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 assets)
    {
        if (_receiver == address(0)) revert SyVault__InvalidParam();
        if (_shares == 0) revert SyVault__ZeroAmount();

        (uint256 grossAssets, uint256 fee, uint256 netAssets) = _claimRedeemAssets(_controller, _shares);
        assets = netAssets;

        s_pendingRedeems[_controller][s_activeRedeemCycleId[_controller]] -= _shares;
        if (s_pendingRedeems[_controller][s_activeRedeemCycleId[_controller]] == 0) {
            s_activeRedeemCycleId[_controller]  = 0;
            s_activeRedeemIsFast[_controller]   = false;
        }
        s_claimableRedeemAssets -= grossAssets;

        // NOTE: shares already burned at settleRedeemBatch — only asset transfer here.
        if (fee > 0) ILiquidityPool(i_liquidityPool).transferTo(s_feeRecipient, fee);
        ILiquidityPool(i_liquidityPool).transferTo(_receiver, assets);
    }

    /// @notice Claim a settled redeem by specifying exact assets — burns corresponding shares.
    function withdraw(uint256 _assets, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 shares)
    {
        if (_receiver == address(0)) revert SyVault__InvalidParam();
        if (_assets == 0) revert SyVault__ZeroAmount();

        uint256 cycleId       = s_activeRedeemCycleId[_controller];
        uint256 pendingShares = s_pendingRedeems[_controller][cycleId];
        if (pendingShares == 0) revert SyVault__NoClaimableRedeem();

        RedeemCycle storage cycle = s_redeemCycles[cycleId];
        if (!cycle.settled)     revert SyVault__NoClaimableRedeem();

        // _assets is the net amount the controller wants to receive (after any fast redeem fee).
        // Compute gross assets the cycle must yield to cover _assets + fee.
        uint256 grossAssets;
        uint256 fee;
        if (cycle.cycleType == CycleType.Fast && cycle.feeBps > 0
            && !s_fastRedeemFeeWhitelist[_controller])
        {
            // grossAssets = netAssets / (1 - feeBps/BASIS_POINTS)
            grossAssets = (_assets * BASIS_POINTS + BASIS_POINTS - cycle.feeBps - 1)
                / (BASIS_POINTS - cycle.feeBps);
            fee = grossAssets - _assets;
        } else {
            grossAssets = _assets;
        }

        // Compute shares needed to produce grossAssets — round up.
        shares = cycle.cycleRate > 0
            ? (grossAssets * SHARE_PRICE_PRECISION + cycle.cycleRate - 1) / cycle.cycleRate
            : 0;
        if (shares == 0 || shares > pendingShares) revert SyVault__NoClaimableRedeem();

        // Recompute exact gross assets from rounded shares to avoid dust.
        grossAssets = (shares * cycle.cycleRate) / SHARE_PRICE_PRECISION;
        if (fee > 0) fee = grossAssets - _assets;

        s_pendingRedeems[_controller][cycleId] -= shares;
        if (s_pendingRedeems[_controller][cycleId] == 0) {
            s_activeRedeemCycleId[_controller]  = 0;
            s_activeRedeemIsFast[_controller]   = false;
        }
        s_claimableRedeemAssets -= grossAssets;

        if (fee > 0) ILiquidityPool(i_liquidityPool).transferTo(s_feeRecipient, fee);
        ILiquidityPool(i_liquidityPool).transferTo(_receiver, _assets);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Open or reuse the current cycle for the given type.
    ///      Advances to a new cycle id if no cycle exists or current one is past cutoff.
    function _openOrReuseCycle(CycleType _cycleType) internal returns (uint256 cycleId) {
        if (_cycleType == CycleType.Fast) {
            if (s_currentFastCycleId == 0 || currentEpoch() >= s_redeemCycles[s_currentFastCycleId].cutoffEpoch) {
                // Only one unsettled fast cycle at a time — Allocator handles one per day.
                if (s_currentFastCycleId != 0
                    && !s_redeemCycles[s_currentFastCycleId].settled
                    && s_redeemCycles[s_currentFastCycleId].shares > 0) {
                    revert SyVault__FastCycleNotSettled();
                }
                s_currentFastCycleId = s_cycleIdCounter++;
                uint256 epoch = currentEpoch();
                s_redeemCycles[s_currentFastCycleId] = RedeemCycle({
                    cycleType:      CycleType.Fast,
                    shares:         0,
                    cutoffEpoch:    epoch + FAST_REDEEM_CUTOFF,
                    lockEpoch:      epoch + FAST_REDEEM_LOCK_WINDOW,
                    settled:        false,
                    returnedAmount: 0,
                    cycleRate:      0,
                    feeBps:         s_fastRedeemFeeBps
                });
            }
            cycleId = s_currentFastCycleId;
        } else {
            if (s_currentNormalCycleId == 0 || currentEpoch() >= s_redeemCycles[s_currentNormalCycleId].cutoffEpoch) {
                s_currentNormalCycleId = s_cycleIdCounter++;
                uint256 epoch = currentEpoch();
                s_redeemCycles[s_currentNormalCycleId] = RedeemCycle({
                    cycleType:      CycleType.Normal,
                    shares:         0,
                    cutoffEpoch:    epoch + NORMAL_REDEEM_CUTOFF,
                    lockEpoch:      epoch + NORMAL_REDEEM_LOCK_WINDOW,
                    settled:        false,
                    returnedAmount: 0,
                    cycleRate:      0,
                    feeBps:         0
                });
            }
            cycleId = s_currentNormalCycleId;
        }
    }

    /// @dev Extract shared fee+cycle-rate logic used by redeem().
    ///      Returns (grossAssets, fee, netAssets) for the given controller and share amount.
    function _claimRedeemAssets(address _controller, uint256 _shares)
        internal
        view
        returns (uint256 grossAssets, uint256 fee, uint256 netAssets)
    {
        uint256 cycleId       = s_activeRedeemCycleId[_controller];
        uint256 pendingShares = s_pendingRedeems[_controller][cycleId];
        if (pendingShares == 0)         revert SyVault__NoClaimableRedeem();

        RedeemCycle storage cycle = s_redeemCycles[cycleId];
        if (!cycle.settled)             revert SyVault__NoClaimableRedeem();
        if (_shares > pendingShares)    revert SyVault__NoClaimableRedeem();

        // Gross assets from cycle rate.
        grossAssets = (_shares * cycle.cycleRate) / SHARE_PRICE_PRECISION;

        // Deduct fast redeem fee per-controller at claim time.
        // cycle.feeBps is snapshotted at cycle creation — immune to admin fee changes mid-cycle.
        if (cycle.cycleType == CycleType.Fast && cycle.feeBps > 0
            && !s_fastRedeemFeeWhitelist[_controller])
        {
            fee = (grossAssets * cycle.feeBps) / BASIS_POINTS;
        }
        netAssets = grossAssets - fee;
    }

    /// @dev Internal view: assets reserved for locked (unsettled) redeem cycles.
    function _redeemDue() internal view returns (uint256) {
        return (s_totalLockedShares * s_sharePrice) / SHARE_PRICE_PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares in Pending state for a given normal redeem request.
    function pendingRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        // Returns 0 if cycle is settled (moved to claimable).
        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @notice Shares in Claimable state for a given normal redeem request.
    function claimableRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (!cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @notice Shares in Pending state for a given fast redeem request.
    function pendingFastRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (cycle.cycleType != CycleType.Fast || cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @notice Assets in Claimable state for a given fast redeem — fee already deducted.
    function claimableFastRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 assets)
    {
        RedeemCycle storage cycle = s_redeemCycles[_requestId];
        if (cycle.cycleType != CycleType.Fast || !cycle.settled) return 0;
        uint256 shares = s_pendingRedeems[_controller][_requestId];
        if (shares == 0) return 0;
        uint256 gross = (shares * cycle.cycleRate) / SHARE_PRICE_PRECISION;
        // Deduct fast redeem fee unless whitelisted.
        if (s_fastRedeemFeeWhitelist[_controller]) return gross;
        return gross - (gross * cycle.feeBps / BASIS_POINTS);
    }

    /// @notice Active redeem request for a controller.
    function activeRedeemRequest(address _controller)
        external
        view
        returns (uint256 requestId, bool isFast)
    {
        requestId = s_activeRedeemCycleId[_controller];
        isFast    = s_activeRedeemIsFast[_controller];
    }

    /// @notice Total assets reserved for locked redeem cycles not yet settled.
    function redeemDue() external view returns (uint256) {
        return _redeemDue();
    }

    /// @notice Total shares locked in unsettled redeem cycles.
    function pendingRedeemShares() external view returns (uint256) {
        return s_totalLockedShares;
    }

    /// @notice Shares in active circulation, excluding locked redeem shares.
    /// @dev    Keeper denominator: effectiveSupply = totalSupply() − pendingRedeemShares().
    function effectiveSupply() external view returns (uint256) {
        uint256 supply = i_share.totalSupply();
        uint256 locked = s_totalLockedShares;
        return supply > locked ? supply - locked : 0;
    }

    /// @notice Total assets across all settled-but-unclaimed redeem positions.
    function claimableRedeemAssets() external view returns (uint256) {
        return s_claimableRedeemAssets;
    }

    /// @notice Maximum shares claimable by controller (ERC-4626 maxRedeem).
    /// @dev    EIP-7540: in an async vault the "owner" param to maxRedeem maps to the
    ///         controller — the entity that owns the request and calls redeem()/withdraw().
    ///         Pass the controller address, not the original share owner.
    function maxRedeem(address _controller) external view returns (uint256) {
        uint256 cycleId = s_activeRedeemCycleId[_controller];
        if (cycleId == 0) return 0;
        if (!s_redeemCycles[cycleId].settled) return 0;
        return s_pendingRedeems[_controller][cycleId];
    }

    /// @notice Current normal redeem cycle id.
    function currentNormalCycleId() external view returns (uint256) {
        return s_currentNormalCycleId;
    }

    /// @notice Current fast redeem cycle id.
    function currentFastCycleId() external view returns (uint256) {
        return s_currentFastCycleId;
    }

    /// @notice State of a redeem cycle (Pending, Cutoff, Locked, Claimable).
    function currentCycleState(uint256 _cycleId) external view returns (CycleState) {
        RedeemCycle storage cycle = s_redeemCycles[_cycleId];
        if (cycle.settled) return CycleState.Claimable;
        if (block.timestamp >= i_deployTimestamp + (cycle.lockEpoch   * EPOCH_DURATION)) return CycleState.Locked;
        if (block.timestamp >= i_deployTimestamp + (cycle.cutoffEpoch * EPOCH_DURATION)) return CycleState.Cutoff;
        return CycleState.Pending;
    }

    /// @notice Full schedule data for a redeem cycle.
    function redeemCycleSchedule(uint256 _cycleId) external view returns (RedeemCycle memory) {
        return s_redeemCycles[_cycleId];
    }

    /// @notice Pre-flight eligibility check for normal redeem requests.
    /// @dev    PastCutoff is intentionally not returned: requestRedeem() never reverts past cutoff —
    ///         _openOrReuseCycle() simply opens the next cycle. Returning PastCutoff would be a
    ///         false negative that blocks valid transactions on integrating frontends.
    function requestRedeemStatus(address _controller) external view returns (RedeemRequestStatus) {
        if (s_pausedFull || s_pausedRedeems) return RedeemRequestStatus.Paused;
        if (s_activeRedeemCycleId[_controller] != 0) return RedeemRequestStatus.AlreadyPending;
        return RedeemRequestStatus.Ok;
    }

    /// @notice Pre-flight eligibility check for fast redeem requests.
    function requestFastRedeemStatus(address _controller) external view returns (FastRedeemRequestStatus) {
        if (s_pausedFull || s_pausedRedeems) return FastRedeemRequestStatus.Paused;
        if (!s_fastRedeemEnabled) return FastRedeemRequestStatus.Disabled;
        if (s_activeRedeemCycleId[_controller] != 0) return FastRedeemRequestStatus.AlreadyPending;
        if (s_currentFastCycleId != 0
            && currentEpoch() >= s_redeemCycles[s_currentFastCycleId].cutoffEpoch
            && !s_redeemCycles[s_currentFastCycleId].settled
            && s_redeemCycles[s_currentFastCycleId].shares > 0)
            return FastRedeemRequestStatus.FastCycleSettlementPending;
        return FastRedeemRequestStatus.Ok;
    }

}
