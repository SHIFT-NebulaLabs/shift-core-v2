// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {AdminGateway} from "src/AdminGateway.sol";
import {AddressRegistry} from "src/AddressRegistry.sol";
import {SyShare} from "src/SyShare.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {SyVault} from "src/SyVault.sol";
import {VaultState} from "src/types/Types.sol";
import {ADMIN_ROLE, GUARDIAN_ROLE} from "src/types/Constants.sol";
import {
    AdminGateway__NotAuthorized,
    AdminGateway__ZeroAddress
} from "src/types/Errors.sol";

/// @dev Tests for AdminGateway using a real TimelockController deployment.
///      minDelay = 0 allows instant timelock execution without time travel.
///      A dedicated `gwRegistry` is deployed with `gateway` as its sole adminGateway,
///      since AddressRegistry has an immutable adminGateway field.
contract AdminGatewayTest is Base {

    AdminGateway      internal gateway;
    AddressRegistry   internal gwRegistry; // registry governed by gateway (not Base admin EOA)

    address internal timelockAdmin = makeAddr("timelockAdmin");
    address internal guardian      = makeAddr("guardian");

    function setUp() public override {
        // OZ v5 TimelockController uses _DONE_TIMESTAMP = 1 as a sentinel.
        // Foundry starts block.timestamp at 1, so schedule(delay=0) sets timestamp=1=_DONE_TIMESTAMP,
        // making the operation appear "Done" immediately. Warp past it before deploying anything.
        vm.warp(1 hours);
        super.setUp();

        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = timelockAdmin;
        executors[0] = timelockAdmin;

        // Pre-compute the gateway address so we can pass it to gwRegistry constructor.
        uint256 nonce = vm.getNonce(address(this));
        address predictedGateway = vm.computeCreateAddress(address(this), nonce + 1);

        // Registry that gateway will administer (gateway is immutable adminGateway).
        gwRegistry = new AddressRegistry(predictedGateway);

        gateway = new AdminGateway(
            0,              // minDelay = 0 for tests
            proposers,
            executors,
            address(0),     // no additional admin
            address(gwRegistry)
        );

        require(address(gateway) == predictedGateway, "gateway address prediction failed");

        vm.startPrank(address(gateway));
        gateway.grantRole(ADMIN_ROLE,    timelockAdmin);
        gateway.grantRole(GUARDIAN_ROLE, guardian);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ZeroAddressRegistry() external {
        address[] memory p = new address[](1);
        address[] memory e = new address[](1);
        p[0] = timelockAdmin;
        e[0] = timelockAdmin;

        vm.expectRevert(AdminGateway__ZeroAddress.selector);
        new AdminGateway(0, p, e, address(0), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                       PAUSE — GUARDIAN (immediate)
    //////////////////////////////////////////////////////////////*/

    function test_guardian_canPauseDeposits() external {
        (SyVault testVault, uint256 id) = _freshVault();

        vm.prank(guardian);
        gateway.pauseVaultDeposits(id);

        (bool dep,,) = testVault.isPaused();
        assertTrue(dep);
    }

    function test_guardian_canPauseRedeems() external {
        (SyVault testVault, uint256 id) = _freshVault();

        vm.prank(guardian);
        gateway.pauseVaultRedeems(id);

        (, bool red,) = testVault.isPaused();
        assertTrue(red);
    }

    function test_guardian_canFullPause() external {
        (SyVault testVault, uint256 id) = _freshVault();

        vm.prank(guardian);
        gateway.pauseVault(id);

        (,, bool full) = testVault.isPaused();
        assertTrue(full);
    }

    function test_RevertWhen_NotGuardian_Pause() external {
        (, uint256 id) = _freshVault();

        vm.prank(alice);
        vm.expectRevert(AdminGateway__NotAuthorized.selector);
        gateway.pauseVaultDeposits(id);
    }

    /*//////////////////////////////////////////////////////////////
                      UNPAUSE — ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    function test_admin_canUnpause() external {
        (SyVault testVault, uint256 id) = _freshVault();

        vm.prank(guardian);
        gateway.pauseVault(id);

        vm.prank(timelockAdmin);
        gateway.unpauseVault(id);

        (,, bool full) = testVault.isPaused();
        assertFalse(full);
    }

    function test_RevertWhen_NotAdmin_Unpause() external {
        (, uint256 id) = _freshVault();

        vm.prank(guardian);
        gateway.pauseVault(id);

        vm.prank(alice);
        vm.expectRevert(AdminGateway__NotAuthorized.selector);
        gateway.unpauseVault(id);
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY EPOCH SETTLE
    //////////////////////////////////////////////////////////////*/

    function test_guardian_canEmergencyEpochSettle() external {
        (SyVault testVault, uint256 id) = _freshVault();
        _warpEpochs(1);

        uint256 priceBefore = testVault.latestSharePrice();

        vm.prank(guardian);
        gateway.emergencyEpochSettle(id);

        assertEq(testVault.latestSharePrice(), priceBefore);
    }

    function test_admin_canEmergencyEpochSettle() external {
        (SyVault testVault, uint256 id) = _freshVault();
        _warpEpochs(1);

        vm.prank(timelockAdmin);
        gateway.emergencyEpochSettle(id);

        assertEq(testVault.latestSharePrice(), INITIAL_PRICE);
    }

    function test_RevertWhen_NotGuardianOrAdmin_EmergencySettle() external {
        (, uint256 id) = _freshVault();
        _warpEpochs(1);

        vm.prank(alice);
        vm.expectRevert(AdminGateway__NotAuthorized.selector);
        gateway.emergencyEpochSettle(id);
    }

    /*//////////////////////////////////////////////////////////////
              KEEPER / ALLOCATOR ROTATION — ADMIN (immediate)
    //////////////////////////////////////////////////////////////*/

    function test_admin_canSetKeeper() external {
        (SyVault testVault, uint256 id) = _freshVault();
        address newKeeper = makeAddr("newKeeper");

        vm.prank(timelockAdmin);
        gateway.setKeeper(id, newKeeper);

        assertEq(testVault.keeper(), newKeeper);
    }

    function test_admin_canSetAllocator() external {
        (SyVault testVault, uint256 id) = _freshVault();
        address newAllocator = makeAddr("newAllocator");

        vm.prank(timelockAdmin);
        gateway.setAllocator(id, newAllocator);

        assertEq(testVault.allocator(), newAllocator);
    }

    function test_admin_canSetMaxTvl() external {
        (SyVault testVault, uint256 id) = _freshVault();

        vm.prank(timelockAdmin);
        gateway.setMaxTvl(id, 500_000e18);

        assertEq(testVault.maxTvl(), 500_000e18);
    }

    /*//////////////////////////////////////////////////////////////
              VAULT LIFECYCLE — TIMELOCK (self-execution)
    //////////////////////////////////////////////////////////////*/

    function test_setVaultState_viaTimelock() external {
        (, uint256 id) = _freshVault();

        // Vault starts Active; transition to Deprecated is valid
        bytes memory data = abi.encodeCall(gateway.setVaultState, (id, VaultState.Deprecated));
        _timelockExecute(data);

        assertEq(uint8(gwRegistry.getVaultState(id)), uint8(VaultState.Deprecated));
    }

    function test_setVaultState_invalidTransition_reverts() external {
        // Fresh vault starts at Pending; going straight to Deprecated is invalid
        (, uint256 id) = _freshVaultPending();

        bytes memory data = abi.encodeCall(gateway.setVaultState, (id, VaultState.Deprecated));
        bytes32 opId = _timelockSchedule(data);

        vm.prank(timelockAdmin);
        vm.expectRevert(); // AdminGateway__InvalidTransition wrapped in timelock failure
        gateway.execute(address(gateway), 0, data, bytes32(0), opId);
    }

    function test_registerVault_viaTimelock() external {
        (SyVault testVault,) = _freshVaultUnregistered();
        address shareAddr = address(testVault.share());

        bytes memory data = abi.encodeCall(
            gateway.registerVault,
            (address(testVault), address(0x1), shareAddr, address(0))
        );
        _timelockExecute(data);

        assertEq(gwRegistry.vaultCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                    FEE SETTERS — TIMELOCK (financial)
    //////////////////////////////////////////////////////////////*/

    function test_setPerformanceFeeBps_viaTimelock() external {
        (SyVault testVault, uint256 id) = _freshVault();

        bytes memory data = abi.encodeCall(gateway.setPerformanceFeeBps, (id, 2000));
        _timelockExecute(data);

        assertEq(testVault.performanceFeeBps(), 2000);
    }

    function test_setFeeRecipient_viaTimelock() external {
        (SyVault testVault, uint256 id) = _freshVault();
        address newRecip = makeAddr("newRecip");

        bytes memory data = abi.encodeCall(gateway.setFeeRecipient, (id, newRecip));
        _timelockExecute(data);

        assertEq(testVault.feeRecipient(), newRecip);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy a fresh vault with `gateway` as adminGateway, register+activate in gwRegistry.
    function _freshVault() internal returns (SyVault v, uint256 id) {
        v = _deployVaultWithAdminGateway(address(gateway));

        address shareAddr = address(v.share()); // evaluate before prank
        vm.prank(address(gateway)); // gateway IS the adminGateway of gwRegistry
        id = gwRegistry.registerVault(address(v), address(pool), shareAddr, address(0));
        vm.prank(address(gateway));
        gwRegistry.setVaultState(id, VaultState.Active);
    }

    /// @dev Deploy and register a vault but leave it in Pending state.
    function _freshVaultPending() internal returns (SyVault v, uint256 id) {
        v = _deployVaultWithAdminGateway(address(gateway));

        address shareAddr = address(v.share());
        vm.prank(address(gateway));
        id = gwRegistry.registerVault(address(v), address(pool), shareAddr, address(0));
        // state stays Pending
    }

    /// @dev Deploy a vault but do NOT register it.
    function _freshVaultUnregistered() internal returns (SyVault v, uint256 id) {
        v = _deployVaultWithAdminGateway(address(gateway));
        id = 0;
    }

    function _deployVaultWithAdminGateway(address _gateway) internal returns (SyVault) {
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 2);

        SyShare share2 = new SyShare("FreshShare", "FS", predicted);
        new LiquidityPool(address(asset), predicted); // pool at nonce+1
        SyVault v = new SyVault(
            address(asset), address(share2), address(pool),
            address(hub), _gateway, keeper, allocator, feeRecip, INITIAL_PRICE, true
        );
        return v;
    }

    function _timelockExecute(bytes memory data) internal {
        bytes32 salt        = bytes32(0);
        bytes32 predecessor = bytes32(0);

        vm.startPrank(timelockAdmin);
        gateway.schedule(address(gateway), 0, data, predecessor, salt, 0);
        gateway.execute(address(gateway), 0, data, predecessor, salt);
        vm.stopPrank();
    }

    function _timelockSchedule(bytes memory data) internal returns (bytes32 opId) {
        bytes32 salt        = bytes32(0);
        bytes32 predecessor = bytes32(0);
        opId = gateway.hashOperation(address(gateway), 0, data, predecessor, salt);

        vm.prank(timelockAdmin);
        gateway.schedule(address(gateway), 0, data, predecessor, salt, 0);
    }
}
