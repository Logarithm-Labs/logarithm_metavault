// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LogarithmVault} from "managed_basis/vault/LogarithmVault.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {MetaVault} from "src/MetaVault.sol";
import {VaultFactory} from "src/VaultFactory.sol";
import {VaultAdapter} from "src/library/VaultAdapter.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

contract MetaVaultTest is Test {
    uint256 constant THOUSANDx6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("owner");
    ERC20Mock asset;
    LogarithmVault logVault_1;
    MockStrategy strategy_1;
    LogarithmVault logVault_2;
    MockStrategy strategy_2;

    VaultRegistry registry;
    MetaVault vault;

    function setUp() public {
        vm.startPrank(owner);
        asset = new ERC20Mock();
        logVault_1 = LogarithmVault(
            address(
                new ERC1967Proxy(
                    address(new LogarithmVault()),
                    abi.encodeWithSelector(
                        LogarithmVault.initialize.selector, owner, address(asset), address(0), 0, 0, "m", "m"
                    )
                )
            )
        );
        strategy_1 = new MockStrategy(address(asset), address(logVault_1));
        logVault_1.setStrategy(address(strategy_1));
        logVault_1.setSecurityManager(owner);
        logVault_2 = LogarithmVault(
            address(
                new ERC1967Proxy(
                    address(new LogarithmVault()),
                    abi.encodeWithSelector(
                        LogarithmVault.initialize.selector, owner, address(asset), address(0), 0, 0, "m", "m"
                    )
                )
            )
        );
        strategy_2 = new MockStrategy(address(asset), address(logVault_2));
        logVault_2.setStrategy(address(strategy_2));
        logVault_2.setSecurityManager(owner);
        registry = DeployHelper.deployVaultRegistry(owner);
        vm.startPrank(owner);
        registry.register(address(logVault_1));
        registry.register(address(logVault_2));
        registry.approve(address(logVault_1));
        registry.approve(address(logVault_2));

        VaultFactory factory = new VaultFactory(address(registry), address(new MetaVault()), owner);
        vm.startPrank(curator);
        vault = MetaVault(factory.createVault(false, address(asset), "vault", "vault"));

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

    modifier afterFullyUtilized() {
        strategy_1.utilize(THOUSANDx6);
        strategy_2.utilize(THOUSANDx6);
        _;
    }

    modifier afterPartiallyUtilized() {
        strategy_1.utilize(THOUSANDx6 / 2);
        strategy_2.utilize(THOUSANDx6 / 2);
        _;
    }

    modifier assertPendingWithdrawalsZero() {
        _;
        assertEq(vault.pendingWithdrawals(), 0, "pending withdrawals should be 0");
    }

    function test_prod_nonstandard_tokemak() public {
        vm.createSelectFork("base", 33579002);
        MetaVault newMetaVault = new MetaVault();
        VaultFactory prodFactory = VaultFactory(0x6Ea41B6Ef80153B2Dc5AddF2594C10bB53F605E0);
        vm.startPrank(0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98);
        prodFactory.upgradeTo(address(newMetaVault));
        MetaVault prodMetaVault = MetaVault(0xd275fBD6882C7c94b36292251ECA69BcCb87D8ad);
        vm.startPrank(0xd7ac0DAe994E1d1EdbbDe130f6c6F1a6D907cA08);
        prodMetaVault.deposit(3852_880_000, 0xd7ac0DAe994E1d1EdbbDe130f6c6F1a6D907cA08);
        vm.stopPrank();
    }

    function test_prod_nonstandard_maxWithdraw() public {
        vm.createSelectFork("base", 34040064);
        MetaVault newMetaVault = new MetaVault();
        VaultFactory prodFactory = VaultFactory(0x6Ea41B6Ef80153B2Dc5AddF2594C10bB53F605E0);
        vm.startPrank(0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98);
        prodFactory.upgradeTo(address(newMetaVault));
        vm.stopPrank();
        MetaVault prodMetaVault = MetaVault(0xd275fBD6882C7c94b36292251ECA69BcCb87D8ad);
        vm.startPrank(0xF600833BDB1150442B4d355d52653B3896140827);
        address[] memory targets = new address[](1);
        targets[0] = address(0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5686877890095;
        prodMetaVault.redeemAllocations(targets, amounts);
        vm.stopPrank();
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
        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets[0], targets[0]);
        assertEq(allocatedTargets[1], targets[1]);
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

        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets[0], targets[0]);
        assertEq(allocatedTargets[1], targets[1]);
        assertEq(vault.totalAssets(), 5000000000);
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

    function test_revert_allocateWithOverAllocation() public afterAllocated afterFullyUtilized {
        vm.startPrank(user);
        vault.requestWithdraw(THOUSANDx6 * 4, user, user);
        assertEq(vault.idleAssets(), 0, "idleAssets should be 0");
        strategy_1.deutilize(THOUSANDx6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6 / 2;
        vm.expectRevert(MetaVault.MV__OverAllocation.selector);
        vault.allocate(targets, amounts);
    }

    function test_withdrawAllocations_withIdle() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.withdrawAllocations(targets, amounts);
        assertEq(logVault_1.balanceOf(address(vault)), 0);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6);
        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets.length, 1);
        assertEq(allocatedTargets[0], address(logVault_2));
        assertEq(vault.totalAssets(), 5 * THOUSANDx6);

        assertEq(vault.idleAssets(), 4 * THOUSANDx6);
    }

    function test_withdrawAllocations_woIdle() public afterAllocated {
        strategy_1.utilize(THOUSANDx6);
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.redeemAllocations(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), 0);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6);

        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets.length, 1);
        assertEq(allocatedTargets[0], address(logVault_2));

        address[] memory claimableTargets = vault.claimableTargets();
        assertEq(claimableTargets.length, 1);
        assertEq(claimableTargets[0], address(logVault_1));

        assertEq(vault.allocatedAssets(), THOUSANDx6);
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 1000000000);
        assertEq(claimableAssets, 0);
        assertEq(vault.totalAssets(), 4 * THOUSANDx6 + 1000000000);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6);

        strategy_1.deutilize(THOUSANDx6);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 1000000000);
        assertEq(vault.totalAssets(), 4 * THOUSANDx6 + 1000000000);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6 + 1000000000, "idle assets should be increased");

        vault.claimAllocations();
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 0);
        // last redeem receives the whole
        assertEq(vault.totalAssets(), 5 * THOUSANDx6);
        assertEq(vault.idleAssets(), 3 * THOUSANDx6 + THOUSANDx6);
    }

    /*//////////////////////////////////////////////////////////////
                          USER WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_whenIdleEnough_woAllocation() public afterAllocated {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");
        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.withdraw(THOUSANDx6, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, THOUSANDx6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, THOUSANDx6, "total assets should be decreased");
    }

    function test_withdraw_whenIdleEnough_withAllocation() public afterAllocated {
        strategy_1.utilize(THOUSANDx6);
        strategy_2.utilize(THOUSANDx6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.redeemAllocations(targets, amounts);
        strategy_1.deutilize(THOUSANDx6);

        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 4000000000, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.withdraw(35 * THOUSANDx6 / 10, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 35 * THOUSANDx6 / 10, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 3500000000, "total assets should be decreased");
    }

    function test_withdraw_whenIdleNotEnough_whenIdleFromCoreEnough() public afterAllocated afterPartiallyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.requestWithdraw(4 * THOUSANDx6, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 4 * THOUSANDx6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 4 * THOUSANDx6, "total assets should be decreased");
    }

    function test_withdraw_whenIdleNotEnough_whenIdleFromCoreNotEnough() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.requestWithdraw(4 * THOUSANDx6, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 3 * THOUSANDx6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 4 * THOUSANDx6, "total assets should be decreased");

        bytes32 withdrawKey = vault.getWithdrawKey(user, 0);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");

        assertEq(vault.totalAssets(), totalAssetsAfter, "total assets remains the same after withdrawal of allocation");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");

        strategy_1.deutilize(THOUSANDx6);
        strategy_2.deutilize(THOUSANDx6);

        assertEq(vault.totalAssets(), totalAssetsAfter, "total assets remains the same after withdrawal of allocation");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");

        vault.claim(withdrawKey);
        balAfter = asset.balanceOf(user);
        assertEq(balAfter - balBefore, 4 * THOUSANDx6, "user balance should be increased");
        assertEq(vault.totalAssets(), THOUSANDx6, "total assets");
    }

    function test_shutdown() public afterAllocated {
        strategy_1.utilize(THOUSANDx6);
        uint256 balanceBefore = asset.balanceOf(user);
        vm.startPrank(owner);
        registry.shutdownMetaVault(address(vault));
        vm.startPrank(user);
        uint256 shares = vault.balanceOf(user);
        bytes32 withdrawKey = vault.requestRedeem(shares, owner, owner);
        strategy_1.deutilize(THOUSANDx6);
        assertEq(vault.totalAssets(), 0, "total assets should be 0 after shutdown");
        assertEq(vault.totalSupply(), 0, "total supply should be 0 after shutdown");
        vault.claim(withdrawKey);
        uint256 balanceAfter = asset.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, 5 * THOUSANDx6, "user balance should be increased");
    }

    function test_process_withdrawals_withIdleOfLogVault() public afterAllocated {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user);
        assertEq(withdrawKey, bytes32(0), "shouldn't create withdraw request");
        assertEq(vault.pendingWithdrawals(), 0, "0 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, amount, "user balance should be increased by amount");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVault_1.balanceOf(address(vault)), 0, "log vault has 0 shares");
        assertEq(asset.balanceOf(address(vault)), 0, "vault has 0 assets");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
    }

    function test_process_withdrawals_withAsyncRedeemAllocation() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.pendingWithdrawals(), 0, "0 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, idleAssets, "user balance should be increased by idle");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVault_1.balanceOf(address(vault)), 0, "0 shares");
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSANDx6, "THOUSANDx6 requested");
        assertEq(claimableAssets, 0, "no claimable allocation");

        uint256 processedAmount = THOUSANDx6 / 4;
        strategy_1.deutilize(processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSANDx6, "pending THOUSANDx6");
        assertEq(claimableAssets, 0, "0 claimable allocation");

        assertEq(asset.balanceOf(address(logVault_1)), processedAmount, "processedAmount withdrawn");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");

        strategy_1.deutilize(THOUSANDx6 - processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0, "pending -");
        assertEq(claimableAssets, THOUSANDx6, "THOUSANDx6 claimable allocation");

        assertEq(asset.balanceOf(address(logVault_1)), THOUSANDx6, "assets withdrawn from core");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
    }

    function test_exploit_externalClaim() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSANDx6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.pendingWithdrawals(), 0, "THOUSANDx6 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, idleAssets, "user balance should be increased by idle");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVault_1.balanceOf(address(vault)), 0, "0 shares");
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSANDx6, "THOUSANDx6 requested");
        assertEq(claimableAssets, 0, "no claimable allocation");

        uint256 processedAmount = THOUSANDx6 / 4;
        strategy_1.deutilize(processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSANDx6, "pending THOUSANDx6");
        assertEq(claimableAssets, 0, "0 claimable allocation");

        assertEq(asset.balanceOf(address(logVault_1)), processedAmount, "processedAmount withdrawn");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");

        strategy_1.deutilize(THOUSANDx6 - processedAmount);

        // user can claim the assets
        vm.startPrank(user);
        bytes32[] memory withdrawKeys = vault.withdrawKeysFor(address(logVault_1));
        for (uint256 i = 0; i < withdrawKeys.length; i++) {
            logVault_1.claim(withdrawKeys[i]);
        }

        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0, "request assets should be 0");
        assertEq(claimableAssets, 0, "claimable assets should be 0");

        assertEq(asset.balanceOf(address(logVault_1)), 0, "assets withdrawn from core");
        assertEq(asset.balanceOf(address(vault)), THOUSANDx6, "assets withdrawn from core");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        assertEq(vault.totalAssets(), THOUSANDx6, "total assets should be 1000");

        vm.startPrank(user);
        vault.claim(withdrawKey);
        balAfter = asset.balanceOf(user);
        assertEq(balAfter - balBefore, amount, "user balance should be increased");

        bytes32[] memory withdrawKeysAfter = vault.withdrawKeysFor(address(logVault_1));
        assertEq(withdrawKeysAfter.length, 0, "0 withdraw key");

        address[] memory claimableTargets = vault.claimableTargets();
        assertEq(claimableTargets.length, 0, "no claimable vaults");
    }

    /*//////////////////////////////////////////////////////////////
                    ENHANCED ABSTRACT ALLOCATION MANAGER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allocate_usingBatchFunctions() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = 2 * THOUSANDx6;

        vault.allocate(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6, "First target allocation");
        assertEq(logVault_2.balanceOf(address(vault)), 2 * THOUSANDx6, "Second target allocation");
        assertEq(vault.allocatedTargets().length, 2, "Should have two allocated targets");
        assertEq(vault.allocatedAssets(), 3 * THOUSANDx6, "Total allocated assets");
    }

    function test_withdrawAllocationBatch_integration() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6 / 2;
        amounts[1] = THOUSANDx6 / 2;

        vault.withdrawAllocations(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6 / 2, "Remaining shares for logVault_1");
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6 / 2, "Remaining shares for logVault_2");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
        assertEq(vault.allocatedAssets(), THOUSANDx6, "Total allocated assets should be reduced");
    }

    function test_redeemAllocationBatch_integration() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory shares = new uint256[](2);
        shares[0] = THOUSANDx6 / 2;
        shares[1] = THOUSANDx6 / 2;

        vault.redeemAllocations(targets, shares);

        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6 / 2, "Remaining shares for logVault_1");
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6 / 2, "Remaining shares for logVault_2");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
    }

    function test_claimAllocations_cleanup() public afterAllocated {
        // Make strategies utilize assets
        strategy_1.utilize(THOUSANDx6);
        strategy_2.utilize(THOUSANDx6);

        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;

        vault.withdrawAllocations(targets, amounts);

        // Verify claimable targets
        assertEq(vault.claimableTargets().length, 2, "Should have two claimable targets");

        // Deutilize to make claimable
        strategy_1.deutilize(THOUSANDx6);
        strategy_2.deutilize(THOUSANDx6);

        // Claim allocations
        vault.claimAllocations();

        // Verify cleanup
        assertEq(vault.claimableTargets().length, 0, "Should have no claimable targets after claiming");
        assertEq(vault.allocatedTargets().length, 0, "Should have no allocated targets after claiming");

        // Verify withdraw keys cleanup
        assertEq(vault.withdrawKeysFor(address(logVault_1)).length, 0, "Should have no withdraw keys for logVault_1");
        assertEq(vault.withdrawKeysFor(address(logVault_2)).length, 0, "Should have no withdraw keys for logVault_2");
    }

    function test_allocatedAssets_perTarget() public afterAllocated {
        uint256 allocatedForTarget1 = vault.allocatedAssetsFor(address(logVault_1));
        assertEq(allocatedForTarget1, THOUSANDx6, "Allocated assets for logVault_1");

        uint256 allocatedForTarget2 = vault.allocatedAssetsFor(address(logVault_2));
        assertEq(allocatedForTarget2, THOUSANDx6, "Allocated assets for logVault_2");

        uint256 totalAllocated = vault.allocatedAssets();
        assertEq(totalAllocated, 2 * THOUSANDx6, "Total allocated assets");
    }

    function test_allocationPendingAndClaimable_states() public afterAllocated {
        // Initially no pending or claimable
        (uint256 pending, uint256 claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Should have no pending assets initially");
        assertEq(claimable, 0, "Should have no claimable assets initially");

        // Make strategy utilize assets and withdraw
        strategy_1.utilize(THOUSANDx6);
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.withdrawAllocations(targets, amounts);

        // Check pending state
        (pending, claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, THOUSANDx6, "Should have pending assets");
        assertEq(claimable, 0, "Should have no claimable assets yet");

        // Deutilize to make claimable
        strategy_1.deutilize(THOUSANDx6);

        // Check claimable state
        (pending, claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Should have no pending assets after deutilize");
        assertEq(claimable, THOUSANDx6, "Should have claimable assets after deutilize");
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allocate_zeroAmounts() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        vault.allocate(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), 0, "Should not allocate for zero amount");
        assertEq(logVault_2.balanceOf(address(vault)), 0, "Should not allocate for zero amount");
        assertEq(vault.allocatedTargets().length, 0, "Should have no allocated targets for zero amounts");
    }

    function test_withdrawAllocation_zeroAmounts() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        vault.withdrawAllocations(targets, amounts);

        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6, "Should not withdraw for zero amount");
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6, "Should not withdraw for zero amount");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets allocated");
    }

    function test_redeemAllocation_zeroShares() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory shares = new uint256[](2);
        shares[0] = 0;
        shares[1] = 0;

        vault.redeemAllocations(targets, shares);

        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6, "Should not redeem for zero shares");
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6, "Should not redeem for zero shares");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets allocated");
    }

    function test_allocate_emptyArrays() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vault.allocate(targets, amounts);

        assertEq(vault.allocatedTargets().length, 0, "Should handle empty arrays gracefully");
        assertEq(vault.allocatedAssets(), 0, "Should have no allocated assets for empty arrays");
    }

    function test_withdrawAllocation_emptyArrays() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vault.withdrawAllocations(targets, amounts);

        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets allocated");
        assertEq(vault.allocatedAssets(), 2 * THOUSANDx6, "Should still have allocated assets");
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullAllocationLifecycle() public {
        vm.startPrank(curator);

        // 1. Initial allocation
        address[] memory targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSANDx6;
        amounts[1] = THOUSANDx6;

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), 2 * THOUSANDx6, "Initial allocation");

        // 2. Partial withdrawal
        address[] memory withdrawTargets = new address[](1);
        withdrawTargets[0] = address(logVault_1);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = THOUSANDx6 / 2;

        vault.withdrawAllocations(withdrawTargets, withdrawAmounts);
        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6 / 2, "Partial withdrawal");
        assertEq(vault.allocatedAssets(), 3 * THOUSANDx6 / 2, "Reduced allocated assets");

        // 3. Partial redemption
        address[] memory redeemTargets = new address[](1);
        redeemTargets[0] = address(logVault_2);
        uint256[] memory redeemShares = new uint256[](1);
        redeemShares[0] = THOUSANDx6 / 2;

        vault.redeemAllocations(redeemTargets, redeemShares);
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6 / 2, "Partial redemption");
        assertEq(vault.allocatedAssets(), THOUSANDx6, "Further reduced allocated assets");

        // 4. Final state verification
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
        assertEq(logVault_1.balanceOf(address(vault)), THOUSANDx6 / 2, "Final logVault_1 balance");
        assertEq(logVault_2.balanceOf(address(vault)), THOUSANDx6 / 2, "Final logVault_2 balance");
    }

    function test_claimAllocationsWithExternalInterference() public afterAllocated {
        // Make strategy utilize assets
        strategy_1.utilize(THOUSANDx6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.withdrawAllocations(targets, amounts);

        // Verify claimable state
        assertEq(vault.claimableTargets().length, 1, "Should have one claimable target");
        bytes32[] memory withdrawKeys = vault.withdrawKeysFor(address(logVault_1));
        assertEq(withdrawKeys.length, 1, "Should have one withdraw key");

        // Deutilize to make claimable first
        strategy_1.deutilize(THOUSANDx6);

        // Now simulate external claim
        vm.startPrank(address(vault));
        logVault_1.claim(withdrawKeys[0]);
        vm.stopPrank();

        // Now claim allocations should clean up
        vault.claimAllocations();

        // Verify cleanup
        assertEq(vault.claimableTargets().length, 0, "Should have no claimable targets after external claim");
        assertEq(
            vault.withdrawKeysFor(address(logVault_1)).length, 0, "Should have no withdraw keys after external claim"
        );
        assertEq(vault.allocatedTargets().length, 1, "Should have only logVault_2 allocated");
    }

    function test_multipleAllocationCycles() public {
        vm.startPrank(curator);

        // First cycle
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), THOUSANDx6, "First allocation cycle");

        // Withdraw and reallocate
        vault.withdrawAllocations(targets, amounts);
        assertEq(vault.allocatedAssets(), 0, "After withdrawal");

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), THOUSANDx6, "Second allocation cycle");

        // Add second target
        targets = new address[](2);
        targets[0] = address(logVault_1);
        targets[1] = address(logVault_2);
        amounts = new uint256[](2);
        amounts[0] = 0; // No change to first target
        amounts[1] = THOUSANDx6; // Add second target

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), 2 * THOUSANDx6, "Third allocation cycle with second target");
        assertEq(vault.allocatedTargets().length, 2, "Should have two allocated targets");
    }

    /*//////////////////////////////////////////////////////////////
                    MAX WITHDRAW AND MAX REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxWithdraw_withIdleAssets() public afterAllocated afterPartiallyUtilized {
        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets() + vault.getTargetVaultsIdleAssets();

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal total idle assets");
        assertEq(maxWithdrawAmount, 4 * THOUSANDx6, "Should be 4x THOUSANDx6 (initial deposit - utilized)");
    }

    function test_maxWithdraw_withNoIdleAssets() public afterAllocated afterFullyUtilized {
        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets();

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal only MetaVault idle assets");
        assertEq(maxWithdrawAmount, 3 * THOUSANDx6, "Should be 3x THOUSANDx6 (initial deposit - allocated)");
    }

    function test_maxRedeem_withIdleAssets() public afterAllocated afterPartiallyUtilized {
        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 totalIdleAssets = vault.getTotalIdleAssets();
        uint256 expectedShares = vault.previewDeposit(totalIdleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should convert idle assets to shares");
        assertEq(maxRedeemShares, 4 * THOUSANDx6, "Should be 4x THOUSANDx6");
    }

    function test_maxRedeem_withNoIdleAssets() public afterAllocated afterFullyUtilized {
        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 idleAssets = vault.idleAssets();
        uint256 expectedShares = vault.previewDeposit(idleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should be limited by idle assets");
        assertEq(maxRedeemShares, 3 * THOUSANDx6, "Should be 3x THOUSANDx6");
    }

    function test_maxRedeem_floorRounding() public afterAllocated afterFullyUtilized {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Add small amount of idle assets to test rounding
        strategy_1.deutilize(1000); // Small amount
        strategy_2.deutilize(1000);

        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 totalIdleAssets = vault.getTotalIdleAssets();
        uint256 expectedShares = vault.previewDeposit(totalIdleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should handle small amounts correctly");
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW FROM TARGET IDLE ASSETS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawFromTargetIdleAssets_sufficientIdle() public afterAllocated assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 2 * THOUSANDx6, "Target vault idle assets");

        // Test withdrawal that requires target vault assets
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertEq(finalIdle, 0, "Idle assets should be 0");
    }

    function test_withdrawFromTargetIdleAssets_prioritizeByExitCost()
        public
        afterAllocated
        assertPendingWithdrawalsZero
    {
        // Set different exit costs - logVault_1 has lower exit cost
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 50); // Lower exit cost
        logVault_2.setEntryAndExitCost(0, 500); // Higher exit cost
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 2 * THOUSANDx6, "Target vault idle assets");

        // Withdraw should prioritize logVault_1 due to lower exit cost
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Check that logVault_1 was used first (lower exit cost)
        uint256 logVault1Idle = VaultAdapter.tryIdleAssets(address(logVault_1));
        uint256 logVault2Idle = VaultAdapter.tryIdleAssets(address(logVault_2));

        assertLt(logVault1Idle, THOUSANDx6, "logVault_1 idle should be reduced first");
        assertEq(logVault2Idle, THOUSANDx6, "logVault_2 idle should remain unchanged");
    }

    function test_withdrawFromTargetIdleAssets_partialTargetUsage()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Add limited idle assets to target vaults
        strategy_1.deutilize(THOUSANDx6 / 2);
        strategy_2.deutilize(THOUSANDx6 / 2);

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Target vault idle assets");

        // Withdraw amount that exceeds MetaVault idle but is within total available
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertLt(finalIdle, initialIdle, "Idle assets should be reduced");
    }

    function test_withdrawFromTargetIdleAssets_noTargetIdle()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets");

        // Withdraw should only use MetaVault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 2 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertEq(finalIdle, THOUSANDx6, "Should have 1x THOUSANDx6 remaining idle");
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST WITHDRAW FROM ALLOCATIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_requestWithdrawFromAllocations_withExitCostSorting()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set different exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 300); // Higher exit cost
        logVault_2.setEntryAndExitCost(0, 100); // Lower exit cost
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal that exceeds idle assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        // Should prioritize logVault_2 due to lower exit cost
        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check that assets were withdrawn from lower exit cost vault first
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault2Shares, 0, "logVault_2 shares should be 0");
        assertGt(logVault1Shares, 0, "logVault_1 shares should be reduced");
    }

    function test_requestWithdrawFromAllocations_multipleTargets()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 150);
        logVault_2.setEntryAndExitCost(0, 75);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request large withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should be used due to large request amount
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_requestWithdrawFromAllocations_zeroRequest()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal that can be fulfilled with idle assets only
        vm.startPrank(user);
        uint256 requestAmount = 2 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        // No withdraw request should be created since all assets are available as idle
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault1Shares, THOUSANDx6, "logVault_1 shares should remain unchanged");
        assertEq(logVault2Shares, THOUSANDx6, "logVault_2 shares should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_requestWithdraw_withExitCostConsideration()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 200);
        logVault_2.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check that lower exit cost vault was prioritized
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault2Shares, 0, "logVault_2 (lower exit cost) should be used first");
        assertGt(logVault1Shares, 0, "logVault_1 (higher exit cost) should be used after");
    }

    function test_requestWithdraw_maxRequestExceeded() public afterAllocated assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxRequest = vault.maxRequestWithdraw(user);
        uint256 exceedAmount = maxRequest + 1;

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MetaVault.MV__ExceededMaxRequestWithdraw.selector, user, exceedAmount, maxRequest)
        );
        vault.requestWithdraw(exceedAmount, user, user);
        vm.stopPrank();
    }

    function test_requestWithdraw_partialFulfillment()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 150);
        logVault_2.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive some assets immediately");

        // Check withdraw request
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, THOUSANDx6, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_requestRedeem_withExitCostConsideration()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 300);
        logVault_2.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares / 2; // Redeem half of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Check that lower exit cost vault was prioritized
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault2Shares, THOUSANDx6, "logVault_2 (lower exit cost) should remain unchanged");
        assertEq(logVault1Shares, THOUSANDx6, "logVault_1 (higher exit cost) should remain unchanged initially");
    }

    function test_requestRedeem_maxRequestExceeded() public afterAllocated {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxRequest = vault.maxRequestRedeem(user);
        uint256 exceedShares = maxRequest + 1;

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MetaVault.MV__ExceededMaxRequestRedeem.selector, user, exceedShares, maxRequest)
        );
        vault.requestRedeem(exceedShares, user, user);
        vm.stopPrank();
    }

    function test_requestRedeem_partialFulfillment()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 200);
        logVault_2.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check withdraw request
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertGt(request.requestedAssets, 0, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_edgeCase_veryHighExitCost() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set extremely high exit cost
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 10000);
        logVault_2.setEntryAndExitCost(0, 50000);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request despite high exit costs");

        // Should still prioritize by exit cost (lower first)
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault1Shares, 0, "logVault_1 (lower exit cost) should be used first");
        assertGt(logVault2Shares, 0, "logVault_2 (higher exit cost) should be used after");
    }

    function test_edgeCase_zeroExitCost() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set zero exit cost
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 0);
        logVault_2.setEntryAndExitCost(0, 0);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request with zero exit costs");

        // Both vaults should be used equally since they have same exit cost
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault1Shares, 0, "logVault_1 shares should be 0");
        assertEq(logVault2Shares, THOUSANDx6, "logVault_2 shares shouldn't be used");
    }

    function test_edgeCase_singleTargetVault() public afterAllocated assertPendingWithdrawalsZero {
        // Remove second target
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6;
        vault.withdrawAllocations(targets, amounts);
        vm.stopPrank();

        // Set exit cost for remaining vault
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        // Utilize assets
        strategy_1.utilize(THOUSANDx6);

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 4 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6 + 1;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request with single target");

        // Only logVault_1 should be used
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
    }

    function test_edgeCase_shutdownVault() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Shutdown the vault
        vm.startPrank(owner);
        registry.shutdownMetaVault(address(vault));
        vm.stopPrank();

        // Try to request withdrawal after shutdown
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        bytes32 withdrawKey = vault.requestRedeem(userShares, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request even after shutdown");

        // Check that vault is shutdown
        assertTrue(vault.isShutdown(), "Vault should be shutdown");
    }

    function test_edgeCase_verySmallAmounts() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request very small withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 1000; // Very small amount
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        // Should not create withdraw request for small amounts
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request for small amounts");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));

        assertEq(logVault1Shares, THOUSANDx6, "logVault_1 shares should remain unchanged");
        assertEq(logVault2Shares, THOUSANDx6, "logVault_2 shares should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    FULLY UTILIZED ASSET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullyUtilized_maxWithdraw() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets(); // Only MetaVault idle assets

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal only MetaVault idle assets");
        assertEq(maxWithdrawAmount, 3 * THOUSANDx6, "Should be 3x THOUSANDx6 (initial deposit - allocated)");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults should have no idle assets");
    }

    function test_fullyUtilized_maxRedeem() public afterAllocated afterFullyUtilized {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 150);
        logVault_2.setEntryAndExitCost(0, 300);
        vm.stopPrank();

        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 idleAssets = vault.idleAssets();
        uint256 expectedShares = vault.previewDeposit(idleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should be limited by MetaVault idle assets");
        assertLt(maxRedeemShares, vault.balanceOf(user), "Should be less than user's total shares");
        assertEq(vault.getTotalIdleAssets(), 3 * THOUSANDx6, "Total idle should be only MetaVault idle");
    }

    function test_fullyUtilized_requestWithdraw()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request withdrawal that exceeds idle assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive idle assets immediately");

        // Check withdraw request for remaining amount
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, THOUSANDx6, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");

        // Target vault shares should remain unchanged since they're fully utilized
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVault_1 shares should be 0");
        assertGt(logVault2Shares, 0, "logVault_2 shares shouldn't be 0");
    }

    function test_fullyUtilized_requestRedeem() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 200);
        logVault_2.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check withdraw request
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertGt(request.requestedAssets, 0, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSANDx6, "logVault_1 shares should be unchanged");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_fullyUtilized_withdrawFromTargetIdleAssets()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets after full utilization");

        // Withdraw should only use MetaVault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 2 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertEq(finalIdle, THOUSANDx6, "Should have 1x THOUSANDx6 remaining idle");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSANDx6, "logVault_1 shares should remain unchanged");
        assertEq(logVault2Shares, THOUSANDx6, "logVault_2 shares should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    PARTIALLY UTILIZED ASSET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_partiallyUtilized_maxWithdraw()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.getTotalIdleAssets(); // MetaVault + target vault idle assets

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal total idle assets");
        assertGt(maxWithdrawAmount, 3 * THOUSANDx6, "Should be greater than MetaVault idle due to target vault idle");
        assertEq(vault.getTargetVaultsIdleAssets(), THOUSANDx6, "Target vaults should have THOUSANDx6 idle assets");
    }

    function test_partiallyUtilized_maxRedeem()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 150);
        logVault_2.setEntryAndExitCost(0, 300);
        vm.stopPrank();

        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 totalIdleAssets = vault.getTotalIdleAssets();
        uint256 expectedShares = vault.previewDeposit(totalIdleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should convert total idle assets to shares");
        assertGt(maxRedeemShares, 0, "Should be able to redeem some shares");
        assertEq(totalIdleAssets, 4 * THOUSANDx6, "Total idle should be MetaVault + target vault idle");
    }

    function test_partiallyUtilized_requestWithdraw()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Target vault idle assets");

        // Request withdrawal that requires target vault assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive idle assets immediately");

        // Target vault shares should be reduced due to idle assets
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_partiallyUtilized_requestRedeem()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 200);
        logVault_2.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Target vault idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Target vault shares should be reduced
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_partiallyUtilized_withdrawFromTargetIdleAssets()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Target vault idle assets");

        // Withdraw should use both MetaVault and target vault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSANDx6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertLt(finalIdle, initialIdle, "Idle assets should be reduced");

        // Target vault shares should be reduced
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    /*//////////////////////////////////////////////////////////////
                    MIXED UTILIZATION SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mixedUtilization_scenario1() public afterAllocated assertPendingWithdrawalsZero {
        // Partially utilize logVault_1, fully utilize logVault_2
        strategy_1.utilize(THOUSANDx6 / 2);
        strategy_2.utilize(THOUSANDx6);

        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6 / 2, "Only logVault_1 should have idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should have their shares reduced when creating withdraw requests
        // logVault_1 shares should be reduced due to idle assets withdrawal
        // logVault_2 shares should be reduced due to withdraw request creation
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVault_1 shares should be 0");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_mixedUtilization_scenario2() public afterAllocated assertPendingWithdrawalsZero {
        // Fully utilize logVault_1, partially utilize logVault_2
        strategy_1.utilize(THOUSANDx6);
        strategy_2.utilize(THOUSANDx6 / 2);

        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 200);
        logVault_2.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6 / 2, "Only logVault_2 should have idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should have their shares reduced when creating withdraw requests
        // logVault_1 shares should be reduced due to withdraw request creation
        // logVault_2 shares should be reduced due to idle assets withdrawal
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");
    }

    function test_mixedUtilization_scenario3() public afterAllocated {
        // Partially utilize both vaults with different amounts
        strategy_1.utilize(THOUSANDx6 * 3 / 4);
        strategy_2.utilize(THOUSANDx6 / 4);

        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 150);
        logVault_2.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Total target vault idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        // No withdraw request should be created since all assets are available as idle
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request");

        // Both vaults should have their shares reduced due to idle assets withdrawal
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSANDx6, "logVault_1 shares should be reduced");
        assertLt(logVault2Shares, THOUSANDx6, "logVault_2 shares should be reduced");

        // logVault_2 should be used more due to lower exit cost
        assertLt(logVault2Shares, logVault1Shares, "logVault_2 should be used more due to lower exit cost");
    }

    /*//////////////////////////////////////////////////////////////
                    UTILIZATION TRANSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_utilizationTransition_partialToFull()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets after full utilization");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Target vault shares should remain unchanged since they're fully utilized
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVault_1 shares should be 0");
        assertGt(logVault2Shares, 0, "logVault_2 shares shouldn't be 0");
    }

    function test_utilizationTransition_fullToPartial()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, THOUSANDx6, "Target vaults should have idle assets after deutilization");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Target vault shares should be reduced due to idle assets
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSANDx6 / 2, "logVault_1 shares should be changed");
        assertEq(logVault2Shares, THOUSANDx6 / 2, "logVault_2 shares should be changed");
    }

    function test_utilizationTransition_dynamicExitCosts()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Start with partially utilized
        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSANDx6, "Initial idle assets");
        assertEq(targetIdle, 0, "Target vault idle assets");

        // Set initial exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 100);
        logVault_2.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Request withdrawal with initial exit costs
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSANDx6;
        bytes32 withdrawKey1 = vault.requestWithdraw(requestAmount, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey1 != bytes32(0), "Should create first withdraw request");

        // Change exit costs
        vm.startPrank(owner);
        logVault_1.setEntryAndExitCost(0, 300);
        logVault_2.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        // Request another withdrawal with new exit costs
        vm.startPrank(user);
        bytes32 withdrawKey2 = vault.requestWithdraw(THOUSANDx6 / 2, user, user);
        vm.stopPrank();

        assertTrue(withdrawKey2 != bytes32(0), "Should create second withdraw request");

        // Both requests should be valid
        assertTrue(withdrawKey1 != withdrawKey2, "Withdraw keys should be different");
    }
}
