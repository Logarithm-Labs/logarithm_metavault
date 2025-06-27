// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";

import {VaultRegistry} from "src/VaultRegistry.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {VaultMock} from "test/mock/VaultMock.sol";

contract VaultRegistryTest is Test {
    VaultRegistry provider;
    address owner = makeAddr("owner");
    address vault1 = makeAddr("vault1");
    address vault2 = makeAddr("vault2");
    VaultMock vaultMock1 = new VaultMock();
    VaultMock vaultMock2 = new VaultMock();

    function setUp() public {
        provider = DeployHelper.deployVaultRegistry(owner);
    }

    function test_register() public {
        vm.startPrank(owner);
        provider.register(address(vaultMock1));
        assertTrue(provider.isRegistered(address(vaultMock1)));
        assertFalse(provider.isRegistered(address(vaultMock2)));
        provider.register(address(vaultMock2));
        assertTrue(provider.isRegistered(address(vaultMock2)));
        address[] memory registers = provider.registeredVaults();
        assertEq(address(vaultMock1), registers[0]);
        assertEq(address(vaultMock2), registers[1]);
    }

    function test_revert_register_already_registered() public {
        vm.startPrank(owner);
        provider.register(address(vaultMock1));
        vm.expectRevert(VaultRegistry.WP__VaultAlreadyRegistered.selector);
        provider.register(address(vaultMock1));
    }

    function test_approve() public {
        vm.startPrank(owner);
        provider.register(address(vaultMock1));
        provider.approve(address(vaultMock1));
        assertTrue(provider.isApproved(address(vaultMock1)));
    }

    function test_revert_approve_unregistered() public {
        vm.startPrank(owner);
        vm.expectRevert(VaultRegistry.WP__VaultNotRegistered.selector);
        provider.approve(address(vaultMock2));
    }

    function test_unapprove() public {
        vm.startPrank(owner);
        provider.register(address(vaultMock1));
        provider.approve(address(vaultMock1));
        provider.unapprove(address(vaultMock1));
        assertFalse(provider.isApproved(address(vaultMock1)));
    }

    function test_revert_unapprove_unregistered() public {
        vm.startPrank(owner);
        vm.expectRevert(VaultRegistry.WP__VaultNotRegistered.selector);
        provider.unapprove(address(vaultMock2));
    }
}
