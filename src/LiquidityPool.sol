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
    LiquidityPool__InsufficientBalance
} from "src/types/Errors.sol";

/// @title  LiquidityPool
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Per-vault asset custody contract.
/// @dev    Holds non-deployed assets. Fund-moving functions are nonReentrant.
///         Only the Allocator can call deployCapital() and returnCapital().
///         deployCapital() enforces allocatorAllowance cap to limit per-epoch exposure.
///         returnCapital() must never revert if funds are already in the pool.
abstract contract LiquidityPool is ReentrancyGuard, ILiquidityPool {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Underlying asset token held by this pool.
    IERC20 private immutable i_asset;

    /// @notice Paired syVault — queried for redeemDue() and role checks.
    address private immutable i_vault;

    /// @notice Allocator address — the only account that can deploy and return capital.
    address private immutable i_allocator;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function to the Allocator.
    modifier onlyAllocator() {
        if (msg.sender != i_allocator) revert LiquidityPool__NotAuthorized();
        _;
    }

    /// @dev Restricts function to the paired syVault.
    modifier onlyVault() {
        if (msg.sender != i_vault) revert LiquidityPool__NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _asset      Address of the underlying ERC-20 asset.
    /// @param _vault      Address of the paired syVault.
    /// @param _allocator  Address of the Allocator EOA.
    constructor(address _asset, address _vault, address _allocator) {
        i_asset     = IERC20(_asset);
        i_vault     = _vault;
        i_allocator = _allocator;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILiquidityPool
    function deployCapital(uint256 _amount) external onlyAllocator nonReentrant {
        uint256 _allowance = allocatorAllowance();
        if (_amount > _allowance) revert LiquidityPool__ExceedsAllowance();
        if (_amount > i_asset.balanceOf(address(this))) revert LiquidityPool__InsufficientBalance();

        i_asset.safeTransfer(i_allocator, _amount);
        emit CapitalDeployed(_amount, block.timestamp);
    }

    /// @inheritdoc ILiquidityPool
    function transferTo(address _recipient, uint256 _amount) external onlyVault nonReentrant {
        if (_amount > i_asset.balanceOf(address(this))) revert LiquidityPool__InsufficientBalance();
        i_asset.safeTransfer(_recipient, _amount);
    }

    /// @inheritdoc ILiquidityPool
    function returnCapital(uint256 _amount) external onlyAllocator nonReentrant {
        // Transfer from Allocator into pool — must never revert if funds are already here. //TODO
        i_asset.safeTransferFrom(i_allocator, address(this), _amount);

        emit CapitalReturned(_amount, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILiquidityPool
    /// @dev redeemDue and claimableRedeemAssets are read from the paired syVault.
    function allocatorAllowance() public view returns (uint256) {
        uint256 _balance   = i_asset.balanceOf(address(this));
        uint256 _redeemDue = ISyVault(i_vault).redeemDue();
        uint256 _claimable = ISyVault(i_vault).claimableRedeemAssets();
        uint256 _reserved  = _redeemDue + _claimable;
        // SECURITY: underflow protected — reserved should never exceed balance in a healthy vault.
        return _balance > _reserved ? _balance - _reserved : 0;
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
