// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";

import {VaultRegistry} from "src/VaultRegistry.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

contract VaultRegistryTest is Test {
    VaultRegistry provider;
    address owner = makeAddr("owner");
    address vault1 = makeAddr("vault1");
    address vault2 = makeAddr("vault2");

    function setUp() public {
        provider = DeployHelper.deployVaultRegistry(owner);
    }

    function test_register() public {
        vm.startPrank(owner);
        provider.register(vault1);
        assertTrue(provider.isRegistered(vault1));
        assertFalse(provider.isRegistered(vault2));
        provider.register(vault2);
        assertTrue(provider.isRegistered(vault2));
        address[] memory registers = provider.registeredVaults();
        assertEq(vault1, registers[0]);
        assertEq(vault2, registers[1]);
    }

    function test_removeRegister() public {
        vm.startPrank(owner);
        provider.register(vault1);
        provider.register(vault2);
        provider.remove(vault1);
        assertTrue(provider.isRegistered(vault2));
        assertFalse(provider.isRegistered(vault1));
        address[] memory registers = provider.registeredVaults();
        assertEq(vault2, registers[0]);
    }
}
