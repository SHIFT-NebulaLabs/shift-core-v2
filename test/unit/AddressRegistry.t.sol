// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Base} from "test/Base.t.sol";
import {AddressRegistry} from "src/AddressRegistry.sol";
import {SyShare} from "src/SyShare.sol";
import {LiquidityPool} from "src/LiquidityPool.sol";
import {SyVault} from "src/SyVault.sol";
import {VaultState} from "src/types/Types.sol";
import {
    AddressRegistry__NotAuthorized,
    AddressRegistry__ZeroAddress,
    AddressRegistry__VaultNotFound,
    AddressRegistry__IncompatibleVault
} from "src/types/Errors.sol";

/// @dev Minimal contract that implements supportsInterface but always returns false.
///      Used to test the IncompatibleVault guard without triggering ABI-decode failures on EOAs.
contract MockIncompatibleVault {
    function supportsInterface(bytes4) external pure returns (bool) { return false; }
}

contract AddressRegistryTest is Base {

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ZeroAdminGateway() external {
        vm.expectRevert(AddressRegistry__ZeroAddress.selector);
        new AddressRegistry(address(0));
    }

    function test_adminGateway_returnsCorrectAddress() external view {
        assertEq(registry.adminGateway(), admin);
    }

    /*//////////////////////////////////////////////////////////////
                         registerVault
    //////////////////////////////////////////////////////////////*/

    function test_registerVault_returnsVaultId() external view {
        assertEq(VAULT_ID, 1);
        assertEq(registry.vaultCount(), 1);
    }

    function test_registerVault_storesAddresses() external view {
        assertEq(registry.getSyVault(VAULT_ID),       address(vault));
        assertEq(registry.getLiquidityPool(VAULT_ID), address(pool));
        assertEq(registry.getSyShare(VAULT_ID),       address(syShare));
        assertEq(registry.getSyOft(VAULT_ID),         address(0));
    }

    function test_registerVault_initialStatePending() external {
        uint256 nonce = vm.getNonce(address(this));
        address predictedVault2 = vm.computeCreateAddress(address(this), nonce + 2);

        SyShare share2  = new SyShare("S2", "S2", predictedVault2);
        LiquidityPool pool2  = new LiquidityPool(address(asset), predictedVault2);
        SyVault vault2  = new SyVault(
            address(asset), address(share2), address(pool2),
            address(hub), admin, keeper, allocator, feeRecip, INITIAL_PRICE, true
        );

        vm.prank(admin);
        uint256 id2 = registry.registerVault(address(vault2), address(pool2), address(share2), address(0));

        assertEq(uint8(registry.getVaultState(id2)), uint8(VaultState.Pending));
        assertEq(id2, 2);
    }

    function test_RevertWhen_RegisterVault_NotAdminGateway() external {
        vm.prank(alice);
        vm.expectRevert(AddressRegistry__NotAuthorized.selector);
        registry.registerVault(address(vault), address(pool), address(syShare), address(0));
    }

    function test_RevertWhen_RegisterVault_ZeroSyVaultAddress() external {
        vm.prank(admin);
        vm.expectRevert(AddressRegistry__ZeroAddress.selector);
        registry.registerVault(address(0), address(pool), address(syShare), address(0));
    }

    function test_RevertWhen_RegisterVault_IncompatibleVault() external {
        // Use a contract that returns false from supportsInterface (EOAs cause ABI-decode failure with no selector)
        address mockVault = address(new MockIncompatibleVault());
        vm.prank(admin);
        vm.expectRevert(AddressRegistry__IncompatibleVault.selector);
        registry.registerVault(mockVault, address(pool), address(syShare), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          setVaultState
    //////////////////////////////////////////////////////////////*/

    function test_setVaultState_transitions() external {
        assertEq(uint8(registry.getVaultState(VAULT_ID)), uint8(VaultState.Active));

        vm.prank(admin);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);
        assertEq(uint8(registry.getVaultState(VAULT_ID)), uint8(VaultState.Deprecated));
    }

    function test_RevertWhen_SetVaultState_NotAdminGateway() external {
        vm.prank(alice);
        vm.expectRevert(AddressRegistry__NotAuthorized.selector);
        registry.setVaultState(VAULT_ID, VaultState.Deprecated);
    }

    function test_RevertWhen_SetVaultState_VaultNotFound() external {
        vm.prank(admin);
        vm.expectRevert(AddressRegistry__VaultNotFound.selector);
        registry.setVaultState(999, VaultState.Deprecated);
    }

    /*//////////////////////////////////////////////////////////////
                          setVaultOft
    //////////////////////////////////////////////////////////////*/

    function test_setVaultOft_updatesAddress() external {
        address newOFT = makeAddr("newOFT");

        vm.prank(admin);
        registry.setVaultOft(VAULT_ID, newOFT);

        assertEq(registry.getSyOft(VAULT_ID), newOFT);
    }

    function test_RevertWhen_SetVaultOft_VaultNotFound() external {
        vm.prank(admin);
        vm.expectRevert(AddressRegistry__VaultNotFound.selector);
        registry.setVaultOft(999, makeAddr("oft"));
    }

    /*//////////////////////////////////////////////////////////////
                       setContractAddress / getContractAddress
    //////////////////////////////////////////////////////////////*/

    function test_setContractAddress_storesAndRetrieves() external {
        bytes32 key = keccak256("Hub");
        address newAddr = makeAddr("newHub");

        vm.prank(admin);
        registry.setContractAddress(key, newAddr);

        assertEq(registry.getContractAddress(key), newAddr);
    }

    function test_RevertWhen_SetContractAddress_ZeroAddress() external {
        bytes32 key = keccak256("Hub");
        vm.prank(admin);
        vm.expectRevert(AddressRegistry__ZeroAddress.selector);
        registry.setContractAddress(key, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                      view — NOT FOUND
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_GetVault_NotFound() external {
        vm.expectRevert(AddressRegistry__VaultNotFound.selector);
        registry.getSyVault(999);
    }

    function test_getContractAddress_returnsZeroForUnsetKey() external view {
        assertEq(registry.getContractAddress(keccak256("NonExistent")), address(0));
    }
}
