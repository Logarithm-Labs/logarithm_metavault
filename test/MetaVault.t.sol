// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MockToken} from "test/mock/MockToken.sol";
import {MockLogVault} from "test/mock/MockLogVault.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {MetaVault} from "src/MetaVault.sol";

contract MetaVaultTest is Test {
    uint256 constant THOUSANDx6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("owner");
    MockToken asset;
    MockLogVault logVault_1;
    MockLogVault logVault_2;

    VaultRegistry registry;
    MetaVault vault;

    function setUp() public {
        asset = new MockToken();
        logVault_1 = new MockLogVault();
        logVault_1.initialize(owner, address(asset));
        logVault_2 = new MockLogVault();
        logVault_2.initialize(owner, address(asset));

        registry = new VaultRegistry();
        registry.initialize(owner);
        vm.startPrank(owner);
        registry.register(address(logVault_1));
        registry.register(address(logVault_2));

        vault = new MetaVault();

        vault.initialize(address(registry), curator, address(asset), "vault", "vault");

        asset.mint(user, 100 * THOUSANDx6);

        vm.startPrank(user);
        asset.approve(address(vault), 100 * THOUSANDx6);
        vault.deposit(100 * THOUSANDx6, user);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             CURATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_allocate() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;
        vault.allocate(targets, amounts);
        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6);
    }

    function test_revert_allocateWithUnregisteredTarget() public {
        address unregisteredVault = makeAddr("unRV");
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = unregisteredVault;
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;
        vm.expectRevert(MetaVault.MV__InvalidTargetAllocation.selector);
        vault.allocate(targets, amounts);
    }
}
