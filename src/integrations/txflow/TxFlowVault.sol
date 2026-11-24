// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SyVault} from "src/syVault.sol";
import {ILiquidityPool} from "src/interfaces/ILiquidityPool.sol";
import {CycleType, RedeemCycle} from "src/types/Types.sol";
import {SHARE_PRICE_PRECISION} from "src/types/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Shift V2 vault with fast redemptions backed by its Arbitrum USDC pool.
/// @custom:security-contact team@shiftprotocol.xyz
contract TxFlowVault is SyVault {
    /// @notice Settlement exceeds uncommitted cash or changes a fast cycle's gross payout.
    error TxFlowVault__ReserveUnavailable();

    constructor(
        address asset_,
        address share_,
        address pool_,
        address hub_,
        address admin_,
        address keeper_,
        address executor_,
        address feeRecipient_,
        uint256 initialPrice_
    ) SyVault(asset_, share_, pool_, hub_, admin_, keeper_, executor_, feeRecipient_, initialPrice_, true) {
        s_fastRedeemCapBps = 1_000;
    }

    /// @notice Maximum additional shares backed by available pool cash and the current cycle limit.
    function fastRedeemCapacityShares() external view returns (uint256) {
        if (!s_fastRedeemEnabled || s_pausedFull || s_pausedRedeems) return 0;
        RedeemCycle storage fast = s_redeemCycles[s_currentFastCycleId];
        if (!fast.settled && fast.shares != 0 && currentEpoch() >= fast.cutoffEpoch) return 0;
        return _liquidFastShares();
    }

    function _freePool() private view returns (uint256) {
        (uint256 free,) = this.tvlComponents();
        return free;
    }

    function _liquidFastShares() internal view override returns (uint256) {
        uint256 supply = i_share.totalSupply();
        uint256 nav = Math.mulDiv(supply, s_sharePrice, SHARE_PRICE_PRECISION);
        uint256 capAssets = Math.mulDiv(nav, Math.min(s_fastRedeemCapBps, 1_000), 10_000);
        uint256 capShares = Math.mulDiv(capAssets, SHARE_PRICE_PRECISION, s_sharePrice);
        RedeemCycle storage fast = s_redeemCycles[s_currentFastCycleId];
        uint256 used = fast.settled ? 0 : fast.shares;
        uint256 cashShares = Math.mulDiv(_freePool(), SHARE_PRICE_PRECISION, s_sharePrice);
        return Math.min(
            capShares > used ? capShares - used : 0,
            cashShares > s_totalLockedShares ? cashShares - s_totalLockedShares : 0
        );
    }

    function _checkSettlementFunds(RedeemCycle storage cycle, uint256 amount) internal view override {
        uint256 free = _freePool();
        if (cycle.cycleType == CycleType.Fast) {
            if (
                amount == 0 || amount != Math.mulDiv(cycle.shares, s_sharePrice, SHARE_PRICE_PRECISION) || amount > free
            ) {
                revert TxFlowVault__ReserveUnavailable();
            }
        } else {
            RedeemCycle storage fast = s_redeemCycles[s_currentFastCycleId];
            uint256 protectedCash = fast.settled ? 0 : Math.mulDiv(fast.shares, s_sharePrice, SHARE_PRICE_PRECISION);
            if (amount > free || protectedCash > free - amount) revert TxFlowVault__ReserveUnavailable();
        }
    }
}
