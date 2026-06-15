// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    EPOCH_DURATION,
    NORMAL_REDEEM_CYCLE_DURATION,
    NORMAL_REDEEM_CUTOFF,
    NORMAL_REDEEM_LOCK_WINDOW,
    FAST_REDEEM_CYCLE_DURATION,
    FAST_REDEEM_CUTOFF,
    FAST_REDEEM_LOCK_WINDOW,
    EPOCHS_PER_YEAR
} from "src/types/Constants.sol";

/// @notice Guards the epoch-timing constants against an inconsistent re-tune (e.g. the 1h→6h
///         change). Cutoff must precede lock, lock must precede cycle end, and the year/cycle
///         durations must still match wall-clock expectations — otherwise redeem cycles or the
///         maintenance-fee proration silently break.
contract ConstantsTest is Test {
    // Ordering invariant: a request cutoff happens before cancellations lock, which happens
    // before the cycle ends. If lock == cycle, the cancellation buffer disappears.
    function test_normalRedeemOrdering() public pure {
        assertLt(NORMAL_REDEEM_CUTOFF, NORMAL_REDEEM_LOCK_WINDOW, "cutoff < lock");
        assertLt(NORMAL_REDEEM_LOCK_WINDOW, NORMAL_REDEEM_CYCLE_DURATION, "lock < cycle");
    }

    function test_fastRedeemOrdering() public pure {
        assertLt(FAST_REDEEM_CUTOFF, FAST_REDEEM_LOCK_WINDOW, "cutoff < lock");
        assertLt(FAST_REDEEM_LOCK_WINDOW, FAST_REDEEM_CYCLE_DURATION, "lock < cycle");
    }

    // Wall-clock commitments that must survive any epoch-length change.
    function test_wallClockDurations() public pure {
        assertEq(NORMAL_REDEEM_CYCLE_DURATION * EPOCH_DURATION, 7 days, "normal cycle = 7d");
        assertEq(FAST_REDEEM_CYCLE_DURATION * EPOCH_DURATION, 1 days, "fast cycle = 24h");
        assertEq(EPOCHS_PER_YEAR * EPOCH_DURATION, 365 days, "epochs/year = 365d");
    }

    // Epoch boundaries must align to clean UTC marks (a day must be a whole number of epochs).
    function test_epochDividesDay() public pure {
        assertEq(uint256(1 days) % EPOCH_DURATION, 0, "day is a whole number of epochs");
    }
}
