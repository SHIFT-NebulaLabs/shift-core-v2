// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISyVault}  from "src/interfaces/ISyVault.sol";
import {ISyShare}  from "src/interfaces/ISyShare.sol";
import {
    SyVault__NotHub,
    SyVault__NotAllocator,
    SyVault__NotAuthorized,
    SyVault__DepositsPaused,
    SyVault__RedeemsPaused,
    SyVault__ZeroAddress
} from "src/types/Errors.sol";
import {EPOCH_DURATION} from "src/types/Constants.sol";

/// @title  SyVaultBase
/// @author Shift Protocol
/// @notice Base abstract contract for the syVault inheritance chain.
///         Holds all immutables, role storage, pause flags, configurable params,
///         whitelists, operator mapping, modifiers, constructor, and currentEpoch().
abstract contract SyVaultBase is ReentrancyGuard, ISyVault {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               VERSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version, follows semantic versioning.
    string public constant VERSION = "1.0.0";

    /*//////////////////////////////////////////////////////////////
                             IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying asset (e.g. USDC).
    IERC20 internal immutable i_asset;

    /// @notice Paired syShare token — minted and burned by this vault only.
    ISyShare internal immutable i_share;

    /// @notice Paired LiquidityPool — holds non-deployed assets.
    address internal immutable i_liquidityPool;

    /// @notice Timestamp of vault deployment — anchor for epoch calculations.
    uint256 internal immutable i_deployTimestamp;

    /// @notice Singleton Hub address.
    address internal immutable i_hub;

    /// @notice Singleton AdminGateway address.
    address internal immutable i_adminGateway;

    /*//////////////////////////////////////////////////////////////
                           ROLE STORAGE
    //////////////////////////////////////////////////////////////*/

    address internal s_keeper;
    address internal s_allocator;
    address internal s_feeRecipient;

    /*//////////////////////////////////////////////////////////////
                           PAUSE FLAGS
    //////////////////////////////////////////////////////////////*/

    bool internal s_pausedDeposits;
    bool internal s_pausedRedeems;
    bool internal s_pausedFull;

    /*//////////////////////////////////////////////////////////////
                       CONFIGURABLE PARAMETERS
    //////////////////////////////////////////////////////////////*/

    uint256 internal s_maxTVL;
    uint256 internal s_minDeposit;
    uint256 internal s_minRedeem;
    uint256 internal s_allocatorActiveOverrideEpochs;
    uint256 internal s_maxSharePriceDelta;      // basis points
    uint256 internal s_maxStalePriceEpochs;
    uint256 internal s_maintenanceFeeInterval;  // epochs between maintenance fee collections
    uint256 internal s_performanceFeeBps;
    uint256 internal s_maintenanceFeeBps;       // annualized basis points
    uint256 internal s_fastRedeemFeeBps;

    /*//////////////////////////////////////////////////////////////
                             WHITELISTS
    //////////////////////////////////////////////////////////////*/

    mapping(address account => bool approved) internal s_depositWhitelist;
    bool internal s_depositWhitelistEnabled;

    /// @dev True if fast redeem requests are accepted. Set at construction, toggled via AdminGateway.
    ///      Cancel, settle, and claim are unaffected — in-flight cycles always complete.
    bool internal s_fastRedeemEnabled;

    /// @dev Accounts exempt from the fast redeem fee.
    mapping(address account => bool exempt) internal s_fastRedeemFeeWhitelist;

    /*//////////////////////////////////////////////////////////////
                        OPERATORS (EIP-7540)
    //////////////////////////////////////////////////////////////*/

    mapping(address controller => mapping(address operator => bool approved)) internal s_operators;

    /*//////////////////////////////////////////////////////////////
                             MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHub() { _onlyHub(); _; }

    function _onlyHub() internal view {
        if (msg.sender != i_hub) revert SyVault__NotHub();
    }

    modifier onlyAllocator() { _onlyAllocator(); _; }

    function _onlyAllocator() internal view {
        if (msg.sender != s_allocator) revert SyVault__NotAllocator();
    }

    modifier onlyAdminGateway() { _onlyAdminGateway(); _; }

    function _onlyAdminGateway() internal view {
        if (msg.sender != i_adminGateway) revert SyVault__NotAuthorized();
    }

    modifier whenDepositsNotPaused() { _whenDepositsNotPaused(); _; }

    function _whenDepositsNotPaused() internal view {
        if (s_pausedFull || s_pausedDeposits) revert SyVault__DepositsPaused();
    }

    modifier whenRedeemsNotPaused() { _whenRedeemsNotPaused(); _; }

    function _whenRedeemsNotPaused() internal view {
        if (s_pausedFull || s_pausedRedeems) revert SyVault__RedeemsPaused();
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _asset         Address of the underlying ERC-20 asset.
    /// @param _share         Address of the paired syShare token.
    /// @param _liquidityPool Address of the paired LiquidityPool.
    /// @param _hub           Address of the singleton Hub.
    /// @param _adminGateway  Address of the singleton AdminGateway.
    /// @param _keeper        Address of the Keeper bot.
    /// @param _allocator     Address of the Allocator EOA.
    /// @param _feeRecipient  Address that receives protocol fees.
    constructor(
        address _asset,
        address _share,
        address _liquidityPool,
        address _hub,
        address _adminGateway,
        address _keeper,
        address _allocator,
        address _feeRecipient
    ) {
        if (_asset         == address(0)) revert SyVault__ZeroAddress();
        if (_share         == address(0)) revert SyVault__ZeroAddress();
        if (_liquidityPool == address(0)) revert SyVault__ZeroAddress();
        if (_hub           == address(0)) revert SyVault__ZeroAddress();
        if (_adminGateway  == address(0)) revert SyVault__ZeroAddress();
        if (_keeper        == address(0)) revert SyVault__ZeroAddress();
        if (_allocator     == address(0)) revert SyVault__ZeroAddress();
        if (_feeRecipient  == address(0)) revert SyVault__ZeroAddress();

        i_asset           = IERC20(_asset);
        i_share           = ISyShare(_share);
        i_liquidityPool   = _liquidityPool;
        i_hub             = _hub;
        i_adminGateway    = _adminGateway;
        // Floor to the nearest epoch boundary so keeper running at :00 every hour stays in sync.
        i_deployTimestamp = block.timestamp - (block.timestamp % EPOCH_DURATION);

        s_keeper          = _keeper;
        s_allocator       = _allocator;
        s_feeRecipient    = _feeRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                          PUBLIC VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Current epoch number — equals requestId for new deposit requests.
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - i_deployTimestamp) / EPOCH_DURATION;
    }
}
