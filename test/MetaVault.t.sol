// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MockToken} from "test/mock/MockToken.sol";
import {MockLogVault} from "test/mock/MockLogVault.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {MetaVault} from "src/MetaVault.sol";

contract MetaVaultTest is Test {
    uint256 constant THOUSANDx6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("owner");
    MockToken asset;
    MockLogVault logVault_1;
    MockStrategy strategy_1;
    MockLogVault logVault_2;
    MockStrategy strategy_2;

    VaultRegistry registry;
    MetaVault vault;

    function setUp() public {
        vm.startPrank(owner);
        asset = new MockToken();
        logVault_1 = new MockLogVault();
        logVault_1.initialize(owner, address(asset));
        strategy_1 = new MockStrategy(address(asset), address(logVault_1));
        logVault_1.setStrategy(address(strategy_1));
        logVault_2 = new MockLogVault();
        logVault_2.initialize(owner, address(asset));
        strategy_2 = new MockStrategy(address(asset), address(logVault_2));
        logVault_2.setStrategy(address(strategy_2));

        registry = new VaultRegistry();
        registry.initialize(owner);
        vm.startPrank(owner);
        registry.register(address(logVault_1));
        registry.register(address(logVault_2));

        vault = new MetaVault();

        vault.initialize(address(registry), curator, address(asset), "vault", "vault");

        asset.mint(user, 5 * THOUSANDx6);

        vm.startPrank(user);
        asset.approve(address(vault), 5 * THOUSANDx6);
        vault.deposit(5 * THOUSANDx6, user);
        vm.stopPrank();
    }

    modifier afterAllocated() {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;
        vault.allocate(targets, amounts);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CURATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_allocate_first() public {
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
        address[] memory allocatedVaults = vault.allocatedVaults();
        assertEq(allocatedVaults[0], targets[0]);
        assertEq(allocatedVaults[1], targets[1]);
        assertEq(vault.totalAssets(), 5 * THOUSANDx6);
    }

    function test_allocate_notFirst() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;
        vault.allocate(targets, amounts);
        vault.allocate(targets, amounts);

        address[] memory allocatedVaults = vault.allocatedVaults();
        assertEq(allocatedVaults[0], targets[0]);
        assertEq(allocatedVaults[1], targets[1]);
        assertEq(vault.totalAssets(), 4999999998);
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

    function test_allocationWithdraw_withIdle() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.allocationWithdraw(targets, amounts);
        assertEq(logVault_1.balanceOf(address(vault)), 0);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6);
        address[] memory allocatedVaults = vault.allocatedVaults();
        assertEq(allocatedVaults.length, 1);
        assertEq(allocatedVaults[0], address(logVault_2));
        assertEq(vault.totalAssets(), 5 * THOUSANDx6);

        assertEq(vault.idleAssets(), 4 * THOUSANDx6);
    }

    function test_allocationWithdraw_woIdle() public afterAllocated {
        strategy_1.utilize(THOUSANDx6);
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.allocationRedeem(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), 0);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6);

        address[] memory allocatedVaults = vault.allocatedVaults();
        assertEq(allocatedVaults.length, 1);
        assertEq(allocatedVaults[0], address(logVault_2));

        address[] memory claimableVaults = vault.claimableVaults();
        assertEq(claimableVaults.length, 1);
        assertEq(claimableVaults[0], address(logVault_1));

        assertEq(vault.allocatedAssets(), THOUSANDx6);
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationClaimableAssets();
        assertEq(requestedAssets, 995024875);
        assertEq(claimableAssets, 0);
        assertEq(vault.totalAssets(), 4 * THOUSANDx6 + 995024875);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6);

        strategy_1.deutilize(THOUSANDx6);
        (requestedAssets, claimableAssets) = vault.allocationClaimableAssets();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 995024875);
        assertEq(vault.totalAssets(), 4 * THOUSANDx6 + 995024875);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6 + 995024875, "idle assets should be increased");

        vault.allocationClaim();
        (requestedAssets, claimableAssets) = vault.allocationClaimableAssets();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 0);
        // last redeem receives the whole
        assertEq(vault.totalAssets(), 5 * THOUSANDx6);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6 + THOUSANDx6);
    }
}
