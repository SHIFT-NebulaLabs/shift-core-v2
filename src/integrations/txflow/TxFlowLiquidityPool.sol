// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LiquidityPool} from "src/LiquidityPool.sol";
import {ISyVault} from "src/interfaces/ISyVault.sol";
import {SHARE_PRICE_PRECISION} from "src/types/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Keeps the TxFlow reserve in native Arbitrum USDC alongside the standard V2 liabilities.
/// @custom:security-contact team@shiftprotocol.xyz
contract TxFlowLiquidityPool is LiquidityPool {
    ISyVault private immutable i_txFlowVault;

    constructor(address asset_, address vault_) LiquidityPool(asset_, vault_) {
        i_txFlowVault = ISyVault(vault_);
    }

    /// @inheritdoc LiquidityPool
    function allocatorAllowance() public view override returns (uint256) {
        uint256 nav =
            Math.mulDiv(i_txFlowVault.effectiveSupply(), i_txFlowVault.latestSharePrice(), SHARE_PRICE_PRECISION);
        uint256 target = nav / 10;
        uint256 due = i_txFlowVault.redeemDue();
        uint256 extra = target > due ? target - due : 0;
        uint256 allowance = super.allocatorAllowance();
        return allowance > extra ? allowance - extra : 0;
    }
}
