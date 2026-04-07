// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {FastRedeemRequestStatus} from "src/types/Types.sol";
import {
    SyVault__FastRedeemCapExceeded,
    SyVault__InvalidParam
} from "src/types/Errors.sol";
import {BASIS_POINTS} from "src/types/Constants.sol";

contract SyVaultFastRedeemCapTest is Base {

    /*//////////////////////////////////////////////////////////////
                         DEFAULT VALUE
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeemCapBps_defaultIs100Percent() external view {
        assertEq(vault.fastRedeemCapBps(), BASIS_POINTS);
    }

    /*//////////////////////////////////////////////////////////////
                      SETTER — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_setFastRedeemCapBps(uint256 bps) external {
        bps = bound(bps, 1, BASIS_POINTS);
        vm.prank(admin);
        vault.setFastRedeemCapBps(bps);
        assertEq(vault.fastRedeemCapBps(), bps);
    }

    /*//////////////////////////////////////////////////////////////
                      SETTER — REVERT CASES
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SetFastRedeemCapBps_Zero() external {
        vm.prank(admin);
        vm.expectRevert(SyVault__InvalidParam.selector);
        vault.setFastRedeemCapBps(0);
    }

    function test_RevertWhen_SetFastRedeemCapBps_AboveBasisPoints() external {
        vm.prank(admin);
        vm.expectRevert(SyVault__InvalidParam.selector);
        vault.setFastRedeemCapBps(BASIS_POINTS + 1);
    }

    /*//////////////////////////////////////////////////////////////
              FAST REDEEM — UNDER CAP (HAPPY PATH)
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeem_underCap_succeeds() external {
        // Set cap to 50% of TVL
        vm.prank(admin);
        vault.setFastRedeemCapBps(5000);

        // Give alice 100e18 shares (TVL = 100e18 at 1:1 price)
        _giveShares(alice, 100e18);

        // Request 40e18 shares = 40% of TVL — under 50% cap
        uint256 cycleId = _requestFastRedeem(alice, 40e18);
        assertGt(cycleId, 0);
        assertEq(vault.pendingFastRedeemRequest(cycleId, alice), 40e18);
    }

    function test_fastRedeem_exactlyCap_succeeds() external {
        // Set cap to 50% of TVL
        vm.prank(admin);
        vault.setFastRedeemCapBps(5000);

        // Give alice 100e18 shares (TVL = 100e18 at 1:1 price)
        _giveShares(alice, 100e18);

        // Request exactly 50e18 shares = 50% of TVL — exactly at cap
        uint256 cycleId = _requestFastRedeem(alice, 50e18);
        assertGt(cycleId, 0);
    }

    /*//////////////////////////////////////////////////////////////
              FAST REDEEM — OVER CAP (REVERT)
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_fastRedeem_exceedsCap() external {
        // Set cap to 20% of TVL
        vm.prank(admin);
        vault.setFastRedeemCapBps(2000);

        // Give alice 100e18 shares (TVL = 100e18 at 1:1 price)
        _giveShares(alice, 100e18);

        // Request 30e18 shares = 30% of TVL — exceeds 20% cap
        vm.startPrank(alice);
        syShare.approve(address(vault), 30e18);
        vm.expectRevert(SyVault__FastRedeemCapExceeded.selector);
        hub.requestFastRedeem(VAULT_ID, 30e18, alice, alice);
        vm.stopPrank();
    }

    function test_RevertWhen_fastRedeem_secondRequest_pushesOverCap() external {
        // Set cap to 30% of TVL
        vm.prank(admin);
        vault.setFastRedeemCapBps(3000);

        // Alice gets 50e18, bob gets 50e18 (total TVL = 100e18)
        _giveShares(alice, 50e18);
        _giveShares(bob, 50e18);

        // Alice requests 20e18 = 20% — under cap
        _requestFastRedeem(alice, 20e18);

        // Bob requests 15e18 — total would be 35e18 = 35% — exceeds 30% cap
        vm.startPrank(bob);
        syShare.approve(address(vault), 15e18);
        vm.expectRevert(SyVault__FastRedeemCapExceeded.selector);
        hub.requestFastRedeem(VAULT_ID, 15e18, bob, bob);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
              CAP = 100% (DEFAULT) — NO RESTRICTION
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeem_fullTvl_whenCapIs100Percent() external {
        // Default cap is 100% — user can redeem entire TVL
        uint256 shares = _giveShares(alice, 100e18);

        uint256 cycleId = _requestFastRedeem(alice, shares);
        assertGt(cycleId, 0);
        assertEq(vault.pendingFastRedeemRequest(cycleId, alice), shares);
    }

    /*//////////////////////////////////////////////////////////////
              CAP AFTER CANCEL — FREES ROOM
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeem_capFreedAfterCancel() external {
        // Set cap to 30%
        vm.prank(admin);
        vault.setFastRedeemCapBps(3000);

        _giveShares(alice, 50e18);
        _giveShares(bob, 50e18);

        // Alice takes 25e18 = 25% of TVL
        uint256 cycleId = _requestFastRedeem(alice, 25e18);

        // Alice cancels — frees room
        vm.prank(alice);
        hub.cancelFastRedeemRequest(VAULT_ID, cycleId, alice);

        // Bob can now request 30e18 = 30% — exactly at cap
        _requestFastRedeem(bob, 30e18);
    }

    /*//////////////////////////////////////////////////////////////
              PRE-FLIGHT STATUS — CapExceeded
    //////////////////////////////////////////////////////////////*/

    function test_requestFastRedeemStatus_CapExceeded() external {
        vm.prank(admin);
        vault.setFastRedeemCapBps(2000); // 20%

        _giveShares(alice, 50e18);
        _giveShares(bob, 50e18);

        // Alice fills exactly the cap (20e18 = 20% of 100e18 TVL)
        _requestFastRedeem(alice, 20e18);

        // Status for bob should be CapExceeded
        assertEq(
            uint8(vault.requestFastRedeemStatus(bob)),
            uint8(FastRedeemRequestStatus.CapExceeded)
        );
    }

    function test_requestFastRedeemStatus_Ok_whenUnderCap() external {
        vm.prank(admin);
        vault.setFastRedeemCapBps(5000); // 50%

        uint256 shares = _giveShares(alice, 100e18);

        // No requests yet — still under cap
        assertEq(
            uint8(vault.requestFastRedeemStatus(alice)),
            uint8(FastRedeemRequestStatus.Ok)
        );
    }

    /*//////////////////////////////////////////////////////////////
              CAP CHANGE DOES NOT AFFECT IN-FLIGHT CYCLES
    //////////////////////////////////////////////////////////////*/

    function test_fastRedeem_capLowered_inflightCompletes() external {
        uint256 shares = _giveShares(alice, 100e18);

        // Request 80e18 at default 100% cap
        uint256 cycleId = _requestFastRedeem(alice, 80e18);

        // Lower cap to 10% — in-flight cycle must still settle normally
        vm.prank(admin);
        vault.setFastRedeemCapBps(1000);

        _warpEpochs(20);
        _allocatorSettleCycle(cycleId, 80e18);

        vm.prank(alice);
        uint256 received = hub.redeem(VAULT_ID, 80e18, alice, alice);
        assertEq(received, 80e18);
    }
}
