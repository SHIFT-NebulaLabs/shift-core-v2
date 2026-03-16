// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ReentrancyGuard}   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISyVault}          from "src/interfaces/ISyVault.sol";
import {ILiquidityPool}    from "src/interfaces/ILiquidityPool.sol";
import {
    LiquidityPool__NotAuthorized,
    LiquidityPool__ExceedsAllowance,
    LiquidityPool__InsufficientBalance,
    LiquidityPool__ZeroAddress
} from "src/types/Errors.sol";

/// @title  LiquidityPool
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Per-vault asset custody contract.
/// @dev    Holds non-deployed assets. Fund-moving functions are nonReentrant.
///         Only the Allocator can call deployCapital() and returnCapital().
///         deployCapital() enforces allocatorAllowance cap to limit per-epoch exposure.
///         returnCapital() must never revert if funds are already in the pool.
contract LiquidityPool is ReentrancyGuard, ILiquidityPool {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying asset token held by this pool.
    IERC20 private immutable i_asset;

    /// @notice Paired syVault — queried for redeemDue() and role checks.
    address private immutable i_vault;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function to the current Allocator as reported by the paired syVault.
    ///      Reads dynamically so that allocator rotation via AdminGateway is reflected immediately.
    modifier onlyAllocator() { _onlyAllocator(); _; }

    function _onlyAllocator() internal view {
        if (msg.sender != ISyVault(i_vault).allocator()) revert LiquidityPool__NotAuthorized();
    }

    /// @dev Restricts function to the paired syVault.
    modifier onlyVault() { _onlyVault(); _; }

    function _onlyVault() internal view {
        if (msg.sender != i_vault) revert LiquidityPool__NotAuthorized();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _asset  Address of the underlying ERC-20 asset.
    /// @param _vault  Address of the paired syVault.
    constructor(address _asset, address _vault) {
        if (_asset == address(0) || _vault == address(0)) revert LiquidityPool__ZeroAddress();
        i_asset = IERC20(_asset);
        i_vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILiquidityPool
    function deployCapital(uint256 _amount) external onlyAllocator nonReentrant {
        uint256 allowance = allocatorAllowance();
        if (_amount > allowance) revert LiquidityPool__ExceedsAllowance();
        if (_amount > i_asset.balanceOf(address(this))) revert LiquidityPool__InsufficientBalance();

        i_asset.safeTransfer(msg.sender, _amount);
        emit CapitalDeployed(_amount, block.timestamp);
    }

    /// @inheritdoc ILiquidityPool
    function transferTo(address _recipient, uint256 _amount) external onlyVault nonReentrant {
        if (_amount > i_asset.balanceOf(address(this))) revert LiquidityPool__InsufficientBalance();
        i_asset.safeTransfer(_recipient, _amount);
    }

    /// @inheritdoc ILiquidityPool
    function returnCapital(uint256 _amount) external onlyAllocator nonReentrant {
        i_asset.safeTransferFrom(msg.sender, address(this), _amount);

        emit CapitalReturned(_amount, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILiquidityPool
    /// @dev Reserved = redeemDue + claimableRedeemAssets + pendingDepositAssets.
    ///      pendingDepositAssets are reserved because users can still cancel those requests —
    ///      deploying them would leave the pool unable to honour cancellations.
    ///      Once epochSettle() processes a batch, pendingDepositAssets drops to zero for
    ///      those deposits and they become deployable TVL.
    function allocatorAllowance() public view returns (uint256) {
        uint256 poolBalance   = i_asset.balanceOf(address(this));
        uint256 redeemDueAmt  = ISyVault(i_vault).redeemDue();
        uint256 claimableAmt  = ISyVault(i_vault).claimableRedeemAssets();
        uint256 pendingAmt    = ISyVault(i_vault).pendingDepositAssets();
        uint256 reserved      = redeemDueAmt + claimableAmt + pendingAmt;
        // SECURITY: underflow protected — reserved should never exceed balance in a healthy vault.
        return poolBalance > reserved ? poolBalance - reserved : 0;
    }

    /// @inheritdoc ILiquidityPool
    function balance() external view returns (uint256) {
        return i_asset.balanceOf(address(this));
    }

    /// @inheritdoc ILiquidityPool
    function asset() external view returns (address) {
        return address(i_asset);
    }

    /// @inheritdoc ILiquidityPool
    function vault() external view returns (address) {
        return i_vault;
    }
}
