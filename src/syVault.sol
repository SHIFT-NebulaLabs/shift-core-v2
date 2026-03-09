// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165}         from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ISyVault}        from "src/interfaces/ISyVault.sol";
import {ISyShare}        from "src/interfaces/ISyShare.sol";
import {ILiquidityPool}  from "src/interfaces/ILiquidityPool.sol";
import {VaultState, CycleState, CycleType, RedeemCycle, SharePriceSnapshot} from "src/types/Types.sol";
import {
    SyVault__NotHub,
    SyVault__NotKeeper,
    SyVault__NotAllocator,
    SyVault__NotAuthorized,
    SyVault__Paused,
    SyVault__DepositsPaused,
    SyVault__RedeemsPaused,
    SyVault__MaxTVLExceeded,
    SyVault__NotWhitelisted,
    SyVault__InvalidVaultState,
    SyVault__CycleInCutoff,
    SyVault__CycleNotLocked,
    SyVault__CycleAlreadySettled,
    SyVault__RedeemRequestAlreadyPending,
    SyVault__NoClaimableDeposit,
    SyVault__NoClaimableRedeem,
    SyVault__NoPendingRequest,
    SyVault__SharePriceDeltaExceeded,
    SyVault__InvalidSharePrice,
    SyVault__NotOwnerOrOperator,
    SyVault__InvalidOwner,
    SyVault__RangeTooLarge,
    SyVault__InvalidRange,
    SyVault__EpochNotElapsed,
    SyVault__ZeroAmount,
    SyVault__AsyncVault
} from "src/types/Errors.sol";
import {
    EPOCH_DURATION,
    NORMAL_REDEEM_CYCLE_DURATION,
    NORMAL_REDEEM_CUTOFF,
    NORMAL_REDEEM_LOCK_WINDOW,
    FAST_REDEEM_CYCLE_DURATION,
    FAST_REDEEM_CUTOFF,
    FAST_REDEEM_LOCK_WINDOW,
    ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS,
    MAX_HISTORY_RANGE,
    BASIS_POINTS,
    SHARE_PRICE_PRECISION,
    INTERFACE_ID_ERC7540_DEPOSIT,
    INTERFACE_ID_ERC7540_REDEEM,
    INTERFACE_ID_ERC7540_OPERATOR,
    INTERFACE_ID_ERC7575
} from "src/types/Constants.sol";

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
abstract contract SyVault is ReentrancyGuard, ISyVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // ── Version ────────────────────────────────────────────────

    /// @notice Contract version, follows semantic versioning.
    string public constant VERSION = "1.0.0";

    // ── Immutables ─────────────────────────────────────────────

    /// @notice Underlying asset (e.g. USDC).
    IERC20 private immutable i_asset;

    /// @notice Paired syShare token — minted and burned by this vault only.
    ISyShare private immutable i_share;

    /// @notice Paired LiquidityPool — holds non-deployed assets.
    address private immutable i_liquidityPool;

    /// @notice Timestamp of vault deployment — anchor for epoch calculations.
    uint256 private immutable i_deployTimestamp;

    // ── Roles ──────────────────────────────────────────────────

    address private immutable i_hub;
    address private immutable i_adminGateway;
    address private s_keeper;
    address private s_allocator;
    address private s_feeRecipient;

    // ── Pause flags ────────────────────────────────────────────

    bool private s_pausedDeposits;
    bool private s_pausedRedeems;
    bool private s_pausedFull;

    // ── Share price & HWM ──────────────────────────────────────

    uint256 private s_sharePrice;
    uint256 private s_previousSharePrice;
    uint256 private s_hwm;

    /// @dev Ring buffer: epoch % MAX_HISTORY_RANGE → SharePriceSnapshot.
    SharePriceSnapshot[720] private s_sharePriceHistory;

    /// @dev Ring buffer: epoch % MAX_HISTORY_RANGE → HWM value.
    uint256[720] private s_hwmHistory;

    // ── Epoch accounting ───────────────────────────────────────

    /// @dev Next epoch the Keeper must settle. stalePriceEpochs = currentEpoch() - s_nextEpochToSettle.
    uint256 private s_nextEpochToSettle;
    bool    private s_allocatorActive;
    /// @dev Consecutive epochs where epochSettle skipped price update due to allocatorActive.
    uint256 private s_allocatorActiveSkips;
    uint256 private s_lastAllocatorAction;

    // ── Pending deposits ───────────────────────────────────────

    /// @dev epoch → total pending assets for that epoch.
    mapping(uint256 epoch => uint256 assets) private s_pendingDepositsByEpoch;

    /// @dev controller → epoch → pending assets (cleared to 0 after claim).
    mapping(address controller => mapping(uint256 epoch => uint256 assets)) private s_pendingDeposits;

    /// @dev controller → epoch → owner who made the deposit (for cancellation refund).
    mapping(address controller => mapping(uint256 epoch => address owner)) private s_depositRequestOwner;

    /// @dev controller → ordered list of epochs with pending/claimable deposits.
    mapping(address controller => uint256[]) private s_controllerDepositEpochs;

    /// @dev epoch → share price at settlement (0 = not yet settled; set to >=1 at epochSettle).
    mapping(uint256 epoch => uint256 sharePrice) private s_epochSettlementPrice;

    /// @dev Total pending deposit assets across all epochs.
    uint256 private s_totalPendingDeposits;

    // ── Redeem cycles ──────────────────────────────────────────

    /// @dev cycleId → cycle data. Normal and fast share the same mapping — IDs are globally unique.
    mapping(uint256 cycleId => RedeemCycle cycle) private s_redeemCycles;

    /// @dev controller → cycleId → pending shares (normal and fast).
    mapping(address controller => mapping(uint256 cycleId => uint256 shares)) private s_pendingRedeems;

    /// @dev controller → cycleId → owner who submitted the request (for cancellation).
    mapping(address controller => mapping(uint256 cycleId => address owner)) private s_redeemRequestOwner;

    // ── Active redeem tracking (one active redeem per owner) ───

    /// @dev owner → active cycleId (0 = no active redeem).
    mapping(address owner => uint256 cycleId) private s_activeRedeemCycleId;

    /// @dev owner → true if active redeem is fast.
    mapping(address owner => bool isFast) private s_activeRedeemIsFast;

    // ── Cycle counters ─────────────────────────────────────────

    /// @dev Single monotonic ID counter for both normal and fast cycles — ensures no collisions.
    uint256 private s_nextCycleId;

    /// @dev Currently accepting-requests normal cycle (0 = none allocated yet).
    uint256 private s_currentNormalCycleId;

    /// @dev Currently accepting-requests fast cycle (0 = none allocated yet).
    uint256 private s_currentFastCycleId;

    // ── TVL accounting ─────────────────────────────────────────

    /// @dev Total shares locked in all unsettled redeem cycles.
    ///      redeemDue (assets) is computed on demand: s_totalLockedShares × sharePrice / PRECISION.
    uint256 private s_totalLockedShares;

    /// @dev Total assets in settled-but-unclaimed redeem positions.
    uint256 private s_claimableRedeemAssets;

    // ── Configurable parameters ────────────────────────────────

    uint256 private s_maxTVL;
    uint256 private s_maxSharePriceDelta;   // basis points
    uint256 private s_maxStalePriceEpochs;
    uint256 private s_maintenanceFeeInterval; // epochs between maintenance fee collections
    uint256 private s_performanceFeeBps;
    uint256 private s_maintenanceFeeBps;     // annualized basis points
    uint256 private s_fastRedeemFeeBps;

    // ── Whitelists ─────────────────────────────────────────────

    mapping(address account => bool approved) private s_depositWhitelist;
    bool private s_depositWhitelistEnabled;

    /// @dev Accounts exempt from the fast redeem fee.
    mapping(address account => bool exempt) private s_fastRedeemFeeWhitelist;

    // ── Operators (EIP-7540) ────────────────────────────────────

    mapping(address controller => mapping(address operator => bool approved)) private s_operators;

    // ── Last settled epoch per pending deposit batch ────────────

    uint256 private s_lastFeeCollectionEpoch;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHub() {
        if (msg.sender != i_hub) revert SyVault__NotHub();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != s_keeper) revert SyVault__NotKeeper();
        _;
    }

    modifier onlyAllocator() {
        if (msg.sender != s_allocator) revert SyVault__NotAllocator();
        _;
    }

    modifier whenDepositsNotPaused() {
        if (s_pausedFull || s_pausedDeposits) revert SyVault__DepositsPaused();
        _;
    }

    modifier whenRedeemsNotPaused() {
        if (s_pausedFull || s_pausedRedeems) revert SyVault__RedeemsPaused();
        _;
    }

    modifier onlyAdminGateway() {
        if (msg.sender != i_adminGateway) revert SyVault__NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
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
    constructor(
        address _asset,
        address _share,
        address _liquidityPool,
        address _hub,
        address _adminGateway,
        address _keeper,
        address _allocator,
        address _feeRecipient,
        uint256 _initialSharePrice
    ) {
        i_asset          = IERC20(_asset);
        i_share          = ISyShare(_share);
        i_liquidityPool  = _liquidityPool;
        i_hub            = _hub;
        i_adminGateway   = _adminGateway;
        i_deployTimestamp = block.timestamp;

        s_keeper         = _keeper;
        s_allocator      = _allocator;
        s_feeRecipient   = _feeRecipient;
        s_sharePrice     = _initialSharePrice;
        s_hwm            = _initialSharePrice;
        s_nextCycleId    = 1; // 0 reserved as "no active redeem" sentinel
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

        // Deposit whitelist check (on controller, since controller owns the claim).
        if (s_depositWhitelistEnabled && !s_depositWhitelist[_controller]) {
            revert SyVault__NotWhitelisted();
        }

        // MaxTVL check: current TVL + pending deposits + new assets must not exceed cap.
        if (s_maxTVL > 0) {
            uint256 _tvl = (s_sharePrice * i_share.totalSupply()) / SHARE_PRICE_PRECISION;
            if (_tvl + s_totalPendingDeposits + _assets > s_maxTVL) {
                revert SyVault__MaxTVLExceeded();
            }
        }

        requestId = currentEpoch();

        // Track epoch and owner — one owner allowed per (controller, epoch) combination.
        if (s_pendingDeposits[_controller][requestId] == 0) {
            s_controllerDepositEpochs[_controller].push(requestId);
            s_depositRequestOwner[_controller][requestId] = _owner;
        } else if (s_depositRequestOwner[_controller][requestId] != _owner) { // TODO: should check if the request has been already submitted ? or is implicit ?
            revert SyVault__InvalidOwner();
        }

        s_pendingDeposits[_controller][requestId]    += _assets;
        s_pendingDepositsByEpoch[requestId]           += _assets;
        s_totalPendingDeposits                        += _assets;

        // Pull assets from owner directly into the LiquidityPool — never touch this contract.
        i_asset.safeTransferFrom(_owner, i_liquidityPool, _assets);

        emit DepositRequest(_controller, _owner, requestId, msg.sender, _assets);
    }

    /// @inheritdoc ISyVault
    function cancelDepositRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 _assets = s_pendingDeposits[_controller][_requestId];
        if (_assets == 0) revert SyVault__NoPendingRequest();
        // Can only cancel before the epoch is settled.
        if (s_epochSettlementPrice[_requestId] > 0) revert SyVault__NoPendingRequest();

        address _owner = s_depositRequestOwner[_controller][_requestId];

        s_pendingDeposits[_controller][_requestId]  = 0;
        s_pendingDepositsByEpoch[_requestId]         -= _assets;
        s_totalPendingDeposits                       -= _assets;

        // Return assets from the LiquidityPool directly to the original owner.
        ILiquidityPool(i_liquidityPool).transferTo(_owner, _assets);

        emit DepositCancelRequest(_controller, _requestId, _assets);
    }

    /// @inheritdoc ISyVault
    function requestRedeem(uint256 _shares, address _controller, address _owner)
        external
        onlyHub
        whenRedeemsNotPaused
        returns (uint256 requestId)
    {
        if (_shares == 0) revert SyVault__ZeroAmount();
        // One active redeem per owner at a time.
        if (s_activeRedeemCycleId[_owner] != 0) revert SyVault__RedeemRequestAlreadyPending();

        // Advance to next cycle if the current one is past cutoff.
        if (s_currentNormalCycleId == 0 || currentEpoch() >= s_redeemCycles[s_currentNormalCycleId].cutoffEpoch) {
            s_currentNormalCycleId = s_nextCycleId++;
            uint256 _epoch = currentEpoch();
            s_redeemCycles[s_currentNormalCycleId] = RedeemCycle({
                cycleType:      CycleType.Normal,
                shares:         0,
                cutoffEpoch:    _epoch + NORMAL_REDEEM_CUTOFF,
                lockEpoch:      _epoch + NORMAL_REDEEM_LOCK_WINDOW,
                settled:        false,
                returnedAmount: 0,
                cycleRate:      0
            });
        }

        requestId = s_currentNormalCycleId;
        s_redeemCycles[requestId].shares              += _shares;
        s_pendingRedeems[_controller][requestId]      += _shares;
        s_redeemRequestOwner[_controller][requestId]   = _owner;
        s_activeRedeemCycleId[_owner]                  = requestId;
        s_activeRedeemIsFast[_owner]                   = false;
        s_totalLockedShares                            += _shares;

        // Lock shares in this contract — burned only at settleRedeemBatch().
        IERC20(address(i_share)).safeTransferFrom(_owner, address(this), _shares);

        emit RedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @inheritdoc ISyVault
    function cancelRedeemRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 _shares = s_pendingRedeems[_controller][_requestId];
        if (_shares == 0) revert SyVault__NoPendingRequest();

        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (_cycle.cycleType != CycleType.Normal) revert SyVault__NoPendingRequest();
        if (currentEpoch() >= _cycle.lockEpoch)   revert SyVault__CycleNotLocked();

        address _owner = s_redeemRequestOwner[_controller][_requestId];

        _cycle.shares                            -= _shares;
        s_pendingRedeems[_controller][_requestId] = 0;
        s_activeRedeemCycleId[_owner]             = 0;
        s_activeRedeemIsFast[_owner]              = false;
        s_totalLockedShares                       -= _shares;

        // Return locked shares to original owner.
        IERC20(address(i_share)).safeTransfer(_owner, _shares);

        emit RedeemCancelRequest(_controller, _requestId, _shares);
    }

    /// @inheritdoc ISyVault
    function requestFastRedeem(uint256 _shares, address _controller, address _owner)
        external
        onlyHub
        whenRedeemsNotPaused
        returns (uint256 requestId)
    {
        if (_shares == 0) revert SyVault__ZeroAmount();
        // No active redeem of any kind allowed.
        if (s_activeRedeemCycleId[_owner] != 0) revert SyVault__RedeemRequestAlreadyPending();

        // Advance to next cycle if the current one is past cutoff.
        if (s_currentFastCycleId == 0 || currentEpoch() >= s_redeemCycles[s_currentFastCycleId].cutoffEpoch) {
            s_currentFastCycleId = s_nextCycleId++;
            uint256 _epoch = currentEpoch();
            s_redeemCycles[s_currentFastCycleId] = RedeemCycle({
                cycleType:      CycleType.Fast,
                shares:         0,
                cutoffEpoch:    _epoch + FAST_REDEEM_CUTOFF,
                lockEpoch:      _epoch + FAST_REDEEM_LOCK_WINDOW,
                settled:        false,
                returnedAmount: 0,
                cycleRate:      0
            });
        }

        requestId = s_currentFastCycleId;
        s_redeemCycles[requestId].shares              += _shares;
        s_pendingRedeems[_controller][requestId]      += _shares;
        s_redeemRequestOwner[_controller][requestId]   = _owner;
        s_activeRedeemCycleId[_owner]                  = requestId;
        s_activeRedeemIsFast[_owner]                   = true;
        s_totalLockedShares                            += _shares;

        IERC20(address(i_share)).safeTransferFrom(_owner, address(this), _shares);

        emit FastRedeemRequest(_controller, _owner, requestId, msg.sender, _shares);
    }

    /// @inheritdoc ISyVault
    function cancelFastRedeemRequest(uint256 _requestId, address _controller) external onlyHub {
        uint256 _shares = s_pendingRedeems[_controller][_requestId];
        if (_shares == 0) revert SyVault__NoPendingRequest();

        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (_cycle.cycleType != CycleType.Fast)  revert SyVault__NoPendingRequest();
        if (currentEpoch() >= _cycle.lockEpoch)  revert SyVault__CycleNotLocked();

        address _owner = s_redeemRequestOwner[_controller][_requestId];

        _cycle.shares                            -= _shares;
        s_pendingRedeems[_controller][_requestId] = 0;
        s_activeRedeemCycleId[_owner]             = 0;
        s_activeRedeemIsFast[_owner]              = false;
        s_totalLockedShares                       -= _shares;

        IERC20(address(i_share)).safeTransfer(_owner, _shares);

        emit RedeemCancelRequest(_controller, _requestId, _shares);
    }

    /// @inheritdoc ISyVault
    function deposit(uint256 _assets, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 shares)
    {
        // Iterate controller's deposit epochs oldest-first, consume settled ones.
        uint256[] storage _epochs = s_controllerDepositEpochs[_controller]; // TODO: the variable should not have "_" at the beginning only the input ones.
        uint256 _len              = _epochs.length;
        uint256 _remaining        = _assets; // 0 = claim all

        for (uint256 i; i < _len; ++i) {
            uint256 _epoch      = _epochs[i];
            uint256 _settlePrice = s_epochSettlementPrice[_epoch];
            if (_settlePrice == 0) continue; // not yet settled

            uint256 _pending = s_pendingDeposits[_controller][_epoch];
            if (_pending == 0) continue; // already fully claimed

            uint256 _epochAssets;
            if (_assets == 0) {
                // Claim-all mode.
                _epochAssets = _pending;
            } else {
                _epochAssets = _pending < _remaining ? _pending : _remaining;
                _remaining  -= _epochAssets;
            }

            shares += (_epochAssets * SHARE_PRICE_PRECISION) / _settlePrice; // TODO: carefull with the precision!
            s_pendingDeposits[_controller][_epoch] -= _epochAssets;

            if (_assets != 0 && _remaining == 0) break;
        }

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

        uint256[] storage _epochs  = s_controllerDepositEpochs[_controller];
        uint256 _len               = _epochs.length;
        uint256 _sharesRemaining   = _shares;

        for (uint256 i; i < _len; ++i) {
            uint256 _epoch       = _epochs[i];
            uint256 _settlePrice = s_epochSettlementPrice[_epoch];
            if (_settlePrice == 0) continue;

            uint256 _pending = s_pendingDeposits[_controller][_epoch];
            if (_pending == 0) continue;

            // Max shares this epoch's pending assets can produce.
            uint256 _epochMaxShares = (_pending * SHARE_PRICE_PRECISION) / _settlePrice;
            uint256 _epochShares    = _epochMaxShares < _sharesRemaining
                ? _epochMaxShares
                : _sharesRemaining;

            // Corresponding assets (round up to avoid over-minting).
            uint256 _epochAssets = (_epochShares * _settlePrice + SHARE_PRICE_PRECISION - 1)
                / SHARE_PRICE_PRECISION;
            // Cap to available pending to absorb rounding.
            if (_epochAssets > _pending) _epochAssets = _pending;
            // Recalculate shares from capped assets.
            _epochShares = (_epochAssets * SHARE_PRICE_PRECISION) / _settlePrice;

            assets            += _epochAssets;
            _sharesRemaining  -= _epochShares;
            s_pendingDeposits[_controller][_epoch] -= _epochAssets;

            if (_sharesRemaining == 0) break;
        }

        if (assets == 0 || _sharesRemaining > 0) revert SyVault__NoClaimableDeposit();
        i_share.mint(_receiver, _shares);
    }

    /// @inheritdoc ISyVault
    function redeem(uint256 _shares, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 assets)
    {
        if (_shares == 0) revert SyVault__ZeroAmount();

        uint256 _cycleId       = s_activeRedeemCycleId[_controller];
        uint256 _pendingShares = s_pendingRedeems[_controller][_cycleId];
        if (_pendingShares == 0)                     revert SyVault__NoClaimableRedeem();

        RedeemCycle storage _cycle = s_redeemCycles[_cycleId];
        if (!_cycle.settled)                          revert SyVault__NoClaimableRedeem();
        if (_shares > _pendingShares)                 revert SyVault__NoClaimableRedeem();

        // Gross assets from cycle rate.
        uint256 _grossAssets = (_shares * _cycle.cycleRate) / SHARE_PRICE_PRECISION;

        // Deduct fast redeem fee per-controller at claim time.
        uint256 _fee;
        if (_cycle.cycleType == CycleType.Fast && s_fastRedeemFeeBps > 0
            && !s_fastRedeemFeeWhitelist[_controller])
        {
            _fee = (_grossAssets * s_fastRedeemFeeBps) / BASIS_POINTS;
        }
        assets = _grossAssets - _fee;

        s_pendingRedeems[_controller][_cycleId] -= _shares;
        if (s_pendingRedeems[_controller][_cycleId] == 0) {
            s_activeRedeemCycleId[_controller]   = 0;
            s_activeRedeemIsFast[_controller]    = false;
        }
        s_claimableRedeemAssets -= _grossAssets;

        // NOTE: shares already burned at settleRedeemBatch — only asset transfer here.
        if (_fee > 0) ILiquidityPool(i_liquidityPool).transferTo(s_feeRecipient, _fee);
        ILiquidityPool(i_liquidityPool).transferTo(_receiver, assets);
    }

    /// @inheritdoc ISyVault
    function withdraw(uint256 _assets, address _receiver, address _controller)
        external
        onlyHub
        nonReentrant
        returns (uint256 shares)
    {
        if (_assets == 0) revert SyVault__ZeroAmount();

        uint256 _cycleId       = s_activeRedeemCycleId[_controller];
        uint256 _pendingShares = s_pendingRedeems[_controller][_cycleId];
        if (_pendingShares == 0) revert SyVault__NoClaimableRedeem();

        RedeemCycle storage _cycle = s_redeemCycles[_cycleId];
        if (!_cycle.settled)     revert SyVault__NoClaimableRedeem();

        // _assets is the net amount the controller wants to receive (after any fast redeem fee).
        // Compute gross assets the cycle must yield to cover _assets + fee.
        uint256 _grossAssets;
        uint256 _fee;
        if (_cycle.cycleType == CycleType.Fast && s_fastRedeemFeeBps > 0
            && !s_fastRedeemFeeWhitelist[_controller])
        {
            // grossAssets = netAssets / (1 - feeBps/BASIS_POINTS)
            _grossAssets = (_assets * BASIS_POINTS + BASIS_POINTS - s_fastRedeemFeeBps - 1)
                / (BASIS_POINTS - s_fastRedeemFeeBps);
            _fee = _grossAssets - _assets;
        } else {
            _grossAssets = _assets;
        }

        // Compute shares needed to produce grossAssets — round up.
        shares = _cycle.cycleRate > 0
            ? (_grossAssets * SHARE_PRICE_PRECISION + _cycle.cycleRate - 1) / _cycle.cycleRate
            : 0;
        if (shares == 0 || shares > _pendingShares) revert SyVault__NoClaimableRedeem();

        // Recompute exact gross assets from rounded shares to avoid dust.
        _grossAssets = (shares * _cycle.cycleRate) / SHARE_PRICE_PRECISION;
        if (_fee > 0) _fee = _grossAssets - _assets;

        s_pendingRedeems[_controller][_cycleId] -= shares;
        if (s_pendingRedeems[_controller][_cycleId] == 0) {
            s_activeRedeemCycleId[_controller]   = 0;
            s_activeRedeemIsFast[_controller]    = false;
        }
        s_claimableRedeemAssets -= _grossAssets;

        if (_fee > 0) ILiquidityPool(i_liquidityPool).transferTo(s_feeRecipient, _fee);
        ILiquidityPool(i_liquidityPool).transferTo(_receiver, _assets);
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
                    EXTERNAL STATE-CHANGING — KEEPER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function epochSettle(uint256 _sharePrice) external onlyKeeper {
        uint256 _epochToSettle = s_nextEpochToSettle;
        if (_epochToSettle >= currentEpoch()) revert SyVault__EpochNotElapsed();

        // ── 1. Determine effective price ───────────────────────────────────────────────────
        uint256 _effectivePrice;
        uint256 _prevPrice = s_sharePrice;

        if (_sharePrice == 0) {
            // Emergency fallback — use current stored price unchanged.
            _effectivePrice = _prevPrice;
        } else if (s_allocatorActive) {
            s_allocatorActiveSkips++;
            if (s_allocatorActiveSkips >= ALLOCATOR_ACTIVE_OVERRIDE_EPOCHS) {
                // Override: allocator has been active too long — accept proposed price.
                _effectivePrice     = _sharePrice;
                s_allocatorActive   = false;
                s_allocatorActiveSkips = 0;
            } else {
                // Still within grace period — keep previous price.
                _effectivePrice = _prevPrice;
            }
        } else {
            // Normal path: validate delta against maxSharePriceDelta.
            if (_prevPrice > 0 && s_maxSharePriceDelta > 0) {
                uint256 _delta = _sharePrice > _prevPrice
                    ? ((_sharePrice - _prevPrice) * BASIS_POINTS) / _prevPrice
                    : ((_prevPrice - _sharePrice) * BASIS_POINTS) / _prevPrice;
                if (_delta > s_maxSharePriceDelta) revert SyVault__SharePriceDeltaExceeded();
            }
            _effectivePrice = _sharePrice;
        }

        // ── 2. Maintenance fee ──────────────────────────────────────────────────────────────
        if (
            s_maintenanceFeeInterval > 0 &&
            s_maintenanceFeeBps > 0 &&
            _epochToSettle > 0 &&
            (_epochToSettle % s_maintenanceFeeInterval) == 0
        ) {
            uint256 _sharePriceBefore = _effectivePrice;
            // Proportional deduction: annualised fee × (interval / 8760 epochs per year).
            uint256 _feeDeduction =
                (_effectivePrice * s_maintenanceFeeBps * s_maintenanceFeeInterval)
                / (BASIS_POINTS * 8760);
            _effectivePrice = _effectivePrice > _feeDeduction ? _effectivePrice - _feeDeduction : 0;

            emit MaintenanceFeeCollected(
                _epochToSettle,
                (_feeDeduction * i_share.totalSupply()) / SHARE_PRICE_PRECISION,
                _sharePriceBefore,
                _effectivePrice
            );
            s_lastFeeCollectionEpoch = _epochToSettle;
        }

        // ── 3. Performance fee ──────────────────────────────────────────────────────────────
        uint256 _hwm = s_hwm;
        uint256 _feeSharesMinted;
        if (_effectivePrice > _hwm && s_performanceFeeBps > 0) {
            uint256 _supply = i_share.totalSupply();
            if (_supply > 0) {
                // Dilution model: feeShares = (price - HWM) × supply × feeBps / (price × BASIS_POINTS)
                _feeSharesMinted =
                    ((_effectivePrice - _hwm) * _supply * s_performanceFeeBps)
                    / (_effectivePrice * BASIS_POINTS);
                if (_feeSharesMinted > 0) {
                    i_share.mint(s_feeRecipient, _feeSharesMinted);
                }
            }
            s_hwm = _effectivePrice;
        }
        emit PerformanceFeeCollected(_epochToSettle, _effectivePrice, _hwm, _feeSharesMinted);

        // ── 4. Settle pending deposits ──────────────────────────────────────────────────────
        // Mark the epoch settled — use effectivePrice, or sentinel 1 if price is 0 (edge case).
        s_epochSettlementPrice[_epochToSettle] = _effectivePrice > 0 ? _effectivePrice : 1;
        uint256 _pendingAssets = s_pendingDepositsByEpoch[_epochToSettle];
        if (_pendingAssets > 0) {
            s_totalPendingDeposits -= _pendingAssets;
        }

        // ── 5. Update share price and ring buffers ──────────────────────────────────────────
        s_previousSharePrice = _prevPrice;
        s_sharePrice         = _effectivePrice;
        s_sharePriceHistory[_epochToSettle % MAX_HISTORY_RANGE] = SharePriceSnapshot({
            sharePrice:  _effectivePrice,
            totalSupply: i_share.totalSupply(),
            timestamp:   block.timestamp
        });
        s_hwmHistory[_epochToSettle % MAX_HISTORY_RANGE] = s_hwm;

        s_nextEpochToSettle = _epochToSettle + 1;

        emit SharePriceUpdated(
            _epochToSettle,
            _effectivePrice,
            _prevPrice,
            i_share.totalSupply(),
            block.timestamp
        );
    }

    /*//////////////////////////////////////////////////////////////
                   EXTERNAL STATE-CHANGING — ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function settleRedeemBatch(uint256 _cycleId, uint256 _returnedAmount) external onlyAllocator nonReentrant {
        RedeemCycle storage _cycle = s_redeemCycles[_cycleId];
        if (_cycle.shares == 0)                revert SyVault__NoPendingRequest();
        if (_cycle.settled)                    revert SyVault__CycleAlreadySettled();
        if (currentEpoch() < _cycle.lockEpoch) revert SyVault__CycleNotLocked();

        uint256 _cycleShares = _cycle.shares;

        _cycle.returnedAmount = _returnedAmount;

        // cycleRate: gross assets per share, scaled by SHARE_PRICE_PRECISION.
        // Fast redeem fee is NOT deducted here — applied per-controller at claim time in redeem()/withdraw().
        uint256 _cycleRate = _cycleShares > 0
            ? (_returnedAmount * SHARE_PRICE_PRECISION) / _cycleShares
            : 0;

        _cycle.cycleRate = _cycleRate;
        _cycle.settled   = true;

        // Update TVL accounting — full returned amount is claimable (fee deducted per-claim).
        s_totalLockedShares     -= _cycleShares;
        s_claimableRedeemAssets += _returnedAmount;

        // INVARIANT: shares burned here — never before.
        i_share.burn(address(this), _cycleShares);

        emit RedeemCycleSettled(
            _cycleId,
            uint8(_cycle.cycleType),
            _returnedAmount,
            _cycleShares,
            _cycleRate,
            0 // fee collected per-claim, not at settle
        );
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
    function pendingRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        // Returns 0 if cycle is settled (moved to claimable).
        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (_cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @inheritdoc ISyVault
    function claimableRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (!_cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @inheritdoc ISyVault
    function pendingFastRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 shares)
    {
        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (_cycle.cycleType != CycleType.Fast || _cycle.settled) return 0;
        return s_pendingRedeems[_controller][_requestId];
    }

    /// @inheritdoc ISyVault
    function claimableFastRedeemRequest(uint256 _requestId, address _controller)
        external
        view
        returns (uint256 assets)
    {
        RedeemCycle storage _cycle = s_redeemCycles[_requestId];
        if (_cycle.cycleType != CycleType.Fast || !_cycle.settled) return 0;
        uint256 _shares = s_pendingRedeems[_controller][_requestId];
        if (_shares == 0) return 0;
        uint256 _gross = (_shares * _cycle.cycleRate) / SHARE_PRICE_PRECISION;
        // Deduct fast redeem fee unless whitelisted.
        if (s_fastRedeemFeeWhitelist[_controller]) return _gross;
        return _gross - (_gross * s_fastRedeemFeeBps / BASIS_POINTS);
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
    function maxDeposit(address _receiver) external view returns (uint256) {
        if (s_pausedFull || s_pausedDeposits) return 0;
        if (s_depositWhitelistEnabled && !s_depositWhitelist[_receiver]) return 0;
        // Stale price guard — block new deposits if keeper has fallen too far behind.
        if (s_maxStalePriceEpochs > 0) {
            uint256 _current = currentEpoch();
            uint256 _stale   = _current > s_nextEpochToSettle ? _current - s_nextEpochToSettle : 0;
            if (_stale >= s_maxStalePriceEpochs) return 0;
        }
        if (s_maxTVL == 0) return type(uint256).max;
        uint256 _tvl  = (s_sharePrice * i_share.totalSupply()) / SHARE_PRICE_PRECISION;
        uint256 _used = _tvl + s_totalPendingDeposits;
        return _used >= s_maxTVL ? 0 : s_maxTVL - _used;
    }

    /// @inheritdoc ISyVault
    function maxRedeem(address _owner) external view returns (uint256) {
        uint256 _cycleId = s_activeRedeemCycleId[_owner];
        if (_cycleId == 0) return 0;
        if (!s_redeemCycles[_cycleId].settled) return 0;
        return s_pendingRedeems[_owner][_cycleId];
    }

    /// @inheritdoc ISyVault
    function previewDeposit(uint256) external pure returns (uint256) {
        revert SyVault__AsyncVault();
    }

    /// @inheritdoc ISyVault
    function previewMint(uint256) external pure returns (uint256) {
        revert SyVault__AsyncVault();
    }

    /// @inheritdoc ISyVault
    function previewRedeem(uint256) external pure returns (uint256) {
        revert SyVault__AsyncVault();
    }

    /// @inheritdoc ISyVault
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert SyVault__AsyncVault();
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
        return _interfaceId == INTERFACE_ID_ERC7540_DEPOSIT
            || _interfaceId == INTERFACE_ID_ERC7540_REDEEM
            || _interfaceId == INTERFACE_ID_ERC7540_OPERATOR
            || _interfaceId == INTERFACE_ID_ERC7575;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW — SYVAULT-SPECIFIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function epochEnd() external view returns (uint256) {
        uint256 _epoch = currentEpoch();
        return i_deployTimestamp + ((_epoch + 1) * EPOCH_DURATION);
    }

    /// @inheritdoc ISyVault
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - i_deployTimestamp) / EPOCH_DURATION;
    }

    /// @inheritdoc ISyVault
    function currentNormalCycleId() external view returns (uint256) {
        return s_currentNormalCycleId;
    }

    /// @inheritdoc ISyVault
    function currentFastCycleId() external view returns (uint256) {
        return s_currentFastCycleId;
    }

    /// @inheritdoc ISyVault
    function currentCycleState(uint256 _cycleId) external view returns (CycleState) {
        RedeemCycle storage _cycle = s_redeemCycles[_cycleId];
        if (_cycle.settled) return CycleState.Claimable;
        if (block.timestamp >= i_deployTimestamp + (_cycle.lockEpoch   * EPOCH_DURATION)) return CycleState.Locked;
        if (block.timestamp >= i_deployTimestamp + (_cycle.cutoffEpoch * EPOCH_DURATION)) return CycleState.Cutoff;
        return CycleState.Pending;
    }

    /// @inheritdoc ISyVault
    function redeemCycleSchedule(uint256 _cycleId) external view returns (RedeemCycle memory) {
        return s_redeemCycles[_cycleId];
    }

    /// @inheritdoc ISyVault
    function latestSharePrice() external view returns (uint256) {
        return s_sharePrice;
    }

    /// @inheritdoc ISyVault
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
        uint256 _lastSettled = s_nextEpochToSettle > 0 ? s_nextEpochToSettle - 1 : 0;
        epoch              = _lastSettled;
        sharePrice         = s_sharePrice;
        previousSharePrice = s_previousSharePrice;
        totalSupply        = i_share.totalSupply();
        timestamp          = s_sharePriceHistory[_lastSettled % MAX_HISTORY_RANGE].timestamp;
        hwm                = s_hwm;
    }

    /// @inheritdoc ISyVault
    function getSharePriceHistory(uint256 _fromEpoch, uint256 _toEpoch)
        external
        view
        returns (SharePriceSnapshot[] memory snapshots)
    {
        if (_fromEpoch > _toEpoch) revert SyVault__InvalidRange();
        if (_toEpoch - _fromEpoch >= MAX_HISTORY_RANGE) revert SyVault__RangeTooLarge();
        uint256 _len = _toEpoch - _fromEpoch + 1;
        snapshots = new SharePriceSnapshot[](_len);
        for (uint256 i; i < _len; ++i) {
            snapshots[i] = s_sharePriceHistory[(_fromEpoch + i) % MAX_HISTORY_RANGE];
        }
    }

    /// @inheritdoc ISyVault
    function latestHWM() external view returns (uint256) {
        return s_hwm;
    }

    /// @inheritdoc ISyVault
    function getHWMHistory(uint256 _fromEpoch, uint256 _toEpoch)
        external
        view
        returns (uint256[] memory hwmValues)
    {
        if (_fromEpoch > _toEpoch) revert SyVault__InvalidRange();
        if (_toEpoch - _fromEpoch >= MAX_HISTORY_RANGE) revert SyVault__RangeTooLarge();
        uint256 _len = _toEpoch - _fromEpoch + 1;
        hwmValues = new uint256[](_len);
        for (uint256 i; i < _len; ++i) {
            hwmValues[i] = s_hwmHistory[(_fromEpoch + i) % MAX_HISTORY_RANGE];
        }
    }

    /// @inheritdoc ISyVault
    function activeRedeemRequest(address _owner)
        external
        view
        returns (uint256 requestId, bool isFast)
    {
        requestId = s_activeRedeemCycleId[_owner];
        isFast    = s_activeRedeemIsFast[_owner];
    }

    /// @inheritdoc ISyVault
    function stalePriceEpochs() external view returns (uint256) {
        uint256 _current = currentEpoch();
        return _current > s_nextEpochToSettle ? _current - s_nextEpochToSettle : 0;
    }

    /// @inheritdoc ISyVault
    function allocatorActive() external view returns (bool) {
        return s_allocatorActive;
    }

    /// @inheritdoc ISyVault
    function lastAllocatorAction() external view returns (uint256) {
        return s_lastAllocatorAction;
    }

    /// @inheritdoc ISyVault
    function redeemDue() external view returns (uint256) {
        return (s_totalLockedShares * s_sharePrice) / SHARE_PRICE_PRECISION;
    }

    /// @inheritdoc ISyVault
    function investableLiquidity() external view returns (uint256) {
        uint256 _poolBalance = i_asset.balanceOf(i_liquidityPool);
        uint256 _redeemDue   = (s_totalLockedShares * s_sharePrice) / SHARE_PRICE_PRECISION;
        uint256 _reserved    = _redeemDue + s_claimableRedeemAssets;
        return _poolBalance > _reserved ? _poolBalance - _reserved : 0;
    }

    /// @inheritdoc ISyVault
    function pendingDepositAssets() external view returns (uint256) {
        return s_totalPendingDeposits;
    }

    /// @inheritdoc ISyVault
    function claimableRedeemAssets() external view returns (uint256) {
        return s_claimableRedeemAssets;
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
    function maxTVL() external view returns (uint256) { return s_maxTVL; }

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
    function depositWhitelistEnabled() external view returns (bool) { return s_depositWhitelistEnabled; }

    /// @inheritdoc ISyVault
    function isPaused() external view returns (bool deposits, bool redeems, bool full) {
        deposits = s_pausedDeposits;
        redeems  = s_pausedRedeems;
        full     = s_pausedFull;
    }

    /*//////////////////////////////////////////////////////////////
              EXTERNAL STATE-CHANGING — ALLOCATOR (SIGNAL)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setAllocatorActive(bool _active) external onlyAllocator {
        s_allocatorActive      = _active;
        s_allocatorActiveSkips = 0;
        s_lastAllocatorAction  = block.timestamp;
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
        emit ParameterUpdated("keeper", abi.encode(s_keeper), abi.encode(_keeper));
        s_keeper = _keeper;
    }

    /// @inheritdoc ISyVault
    function setAllocator(address _allocator) external onlyAdminGateway {
        emit ParameterUpdated("allocator", abi.encode(s_allocator), abi.encode(_allocator));
        s_allocator = _allocator;
    }

    /// @inheritdoc ISyVault
    function setFeeRecipient(address _feeRecipient) external onlyAdminGateway {
        emit ParameterUpdated("feeRecipient", abi.encode(s_feeRecipient), abi.encode(_feeRecipient));
        s_feeRecipient = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
        EXTERNAL STATE-CHANGING — ADMIN GATEWAY (PARAM SETTERS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setMaxTVL(uint256 _maxTVL) external onlyAdminGateway {
        emit ParameterUpdated("maxTVL", abi.encode(s_maxTVL), abi.encode(_maxTVL));
        s_maxTVL = _maxTVL;
    }

    /// @inheritdoc ISyVault
    function setMaxSharePriceDelta(uint256 _delta) external onlyAdminGateway {
        emit ParameterUpdated("maxSharePriceDelta", abi.encode(s_maxSharePriceDelta), abi.encode(_delta));
        s_maxSharePriceDelta = _delta;
    }

    /// @inheritdoc ISyVault
    function setMaxStalePriceEpochs(uint256 _epochs) external onlyAdminGateway {
        emit ParameterUpdated("maxStalePriceEpochs", abi.encode(s_maxStalePriceEpochs), abi.encode(_epochs));
        s_maxStalePriceEpochs = _epochs;
    }

    /// @inheritdoc ISyVault
    function setMaintenanceFeeInterval(uint256 _interval) external onlyAdminGateway {
        emit ParameterUpdated("maintenanceFeeInterval", abi.encode(s_maintenanceFeeInterval), abi.encode(_interval));
        s_maintenanceFeeInterval = _interval;
    }

    /// @inheritdoc ISyVault
    function setPerformanceFeeBps(uint256 _bps) external onlyAdminGateway {
        emit ParameterUpdated("performanceFeeBps", abi.encode(s_performanceFeeBps), abi.encode(_bps));
        s_performanceFeeBps = _bps;
    }

    /// @inheritdoc ISyVault
    function setMaintenanceFeeBps(uint256 _bps) external onlyAdminGateway {
        emit ParameterUpdated("maintenanceFeeBps", abi.encode(s_maintenanceFeeBps), abi.encode(_bps));
        s_maintenanceFeeBps = _bps;
    }

    /// @inheritdoc ISyVault
    function setFastRedeemFeeBps(uint256 _bps) external onlyAdminGateway {
        emit ParameterUpdated("fastRedeemFeeBps", abi.encode(s_fastRedeemFeeBps), abi.encode(_bps));
        s_fastRedeemFeeBps = _bps;
    }

    /*//////////////////////////////////////////////////////////////
         EXTERNAL STATE-CHANGING — ADMIN GATEWAY (WHITELISTS)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyVault
    function setDepositWhitelistEnabled(bool _enabled) external onlyAdminGateway {
        emit ParameterUpdated("depositWhitelistEnabled", abi.encode(s_depositWhitelistEnabled), abi.encode(_enabled));
        s_depositWhitelistEnabled = _enabled;
    }

    /// @inheritdoc ISyVault
    function setDepositWhitelist(address _account, bool _approved) external onlyAdminGateway {
        s_depositWhitelist[_account] = _approved;
        emit WhitelistUpdated("deposit", _account, _approved);
    }

    /// @inheritdoc ISyVault
    function setFastRedeemFeeWhitelist(address _account, bool _approved) external onlyAdminGateway {
        s_fastRedeemFeeWhitelist[_account] = _approved;
        emit WhitelistUpdated("fastRedeemFee", _account, _approved);
    }
}
