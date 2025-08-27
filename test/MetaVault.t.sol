// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LogarithmVault} from "@managed_basis/vault/LogarithmVault.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {AllocationManager} from "src/AllocationManager.sol";
import {MetaVault} from "src/MetaVault.sol";
import {VaultFactory} from "src/VaultFactory.sol";
import {VaultAdapter} from "src/library/VaultAdapter.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

contract MetaVaultTest is Test {
    uint256 constant THOUSAND_6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("owner");
    ERC20Mock asset;
    LogarithmVault logVaultOne;
    MockStrategy strategyOne;
    LogarithmVault logVaultTwo;
    MockStrategy strategyTwo;

    VaultRegistry registry;
    MetaVault vault;

    function setUp() public {
        vm.startPrank(owner);
        asset = new ERC20Mock();
        logVaultOne = LogarithmVault(
            address(
                new ERC1967Proxy(
                    address(new LogarithmVault()),
                    abi.encodeWithSelector(
                        LogarithmVault.initialize.selector, owner, address(asset), address(0), 0, 0, "m", "m"
                    )
                )
            )
        );
        strategyOne = new MockStrategy(address(asset), address(logVaultOne));
        logVaultOne.setStrategy(address(strategyOne));
        logVaultOne.setSecurityManager(owner);
        logVaultTwo = LogarithmVault(
            address(
                new ERC1967Proxy(
                    address(new LogarithmVault()),
                    abi.encodeWithSelector(
                        LogarithmVault.initialize.selector, owner, address(asset), address(0), 0, 0, "m", "m"
                    )
                )
            )
        );
        strategyTwo = new MockStrategy(address(asset), address(logVaultTwo));
        logVaultTwo.setStrategy(address(strategyTwo));
        logVaultTwo.setSecurityManager(owner);
        registry = DeployHelper.deployVaultRegistry(owner);
        vm.startPrank(owner);
        registry.register(address(logVaultOne));
        registry.register(address(logVaultTwo));
        registry.approve(address(logVaultOne));
        registry.approve(address(logVaultTwo));

        VaultFactory factory = new VaultFactory(address(registry), address(new MetaVault()), owner);
        vm.startPrank(curator);
        vault = MetaVault(factory.createVault(false, address(asset), "vault", "vault"));

        asset.mint(user, 10 * THOUSAND_6);

        vm.startPrank(user);
        asset.approve(address(vault), 5 * THOUSAND_6);
        vault.deposit(5 * THOUSAND_6, user);
        vm.stopPrank();
    }

    modifier afterAllocated() {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;
        vault.allocate(targets, amounts);
        _;
    }

    modifier afterFullyUtilized() {
        strategyOne.utilize(THOUSAND_6);
        strategyTwo.utilize(THOUSAND_6);
        _;
    }

    modifier afterPartiallyUtilized() {
        strategyOne.utilize(THOUSAND_6 / 2);
        strategyTwo.utilize(THOUSAND_6 / 2);
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
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;
        vault.allocate(targets, amounts);
        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6);
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6);
        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets[0], targets[0]);
        assertEq(allocatedTargets[1], targets[1]);
        assertEq(vault.totalAssets(), 5 * THOUSAND_6);
    }

    function test_allocate_notFirst() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;
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
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;
        vm.expectRevert(MetaVault.MV__InvalidTargetAllocation.selector);
        vault.allocate(targets, amounts);
    }

    function test_revert_allocateWithOverAllocation() public afterAllocated afterFullyUtilized {
        vm.startPrank(user);
        vault.requestWithdraw(THOUSAND_6 * 4, user, user, type(uint256).max);
        assertEq(vault.idleAssets(), 0, "idleAssets should be 0");
        strategyOne.deutilize(THOUSAND_6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6 / 2;
        vm.expectRevert(MetaVault.MV__OverAllocation.selector);
        vault.allocate(targets, amounts);
    }

    function test_withdrawAllocations_withIdle() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.withdrawAllocations(targets, amounts);
        assertEq(logVaultOne.balanceOf(address(vault)), 0);
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6);
        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets.length, 1);
        assertEq(allocatedTargets[0], address(logVaultTwo));
        assertEq(vault.totalAssets(), 5 * THOUSAND_6);

        assertEq(vault.idleAssets(), 4 * THOUSAND_6);
    }

    function test_withdrawAllocations_woIdle() public afterAllocated {
        strategyOne.utilize(THOUSAND_6);
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.redeemAllocations(targets, amounts);

        assertEq(logVaultOne.balanceOf(address(vault)), 0);
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6);

        address[] memory allocatedTargets = vault.allocatedTargets();
        assertEq(allocatedTargets.length, 1);
        assertEq(allocatedTargets[0], address(logVaultTwo));

        address[] memory claimableTargets = vault.claimableTargets();
        assertEq(claimableTargets.length, 1);
        assertEq(claimableTargets[0], address(logVaultOne));

        assertEq(vault.allocatedAssets(), THOUSAND_6);
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 1000000000);
        assertEq(claimableAssets, 0);
        assertEq(vault.totalAssets(), 4 * THOUSAND_6 + 1000000000);
        assertEq(vault.idleAssets(), 3 * THOUSAND_6);

        strategyOne.deutilize(THOUSAND_6);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 1000000000);
        assertEq(vault.totalAssets(), 4 * THOUSAND_6 + 1000000000);
        assertEq(vault.idleAssets(), 3 * THOUSAND_6 + 1000000000, "idle assets should be increased");

        vault.claimAllocations();
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0);
        assertEq(claimableAssets, 0);
        // last redeem receives the whole
        assertEq(vault.totalAssets(), 5 * THOUSAND_6);
        assertEq(vault.idleAssets(), 3 * THOUSAND_6 + THOUSAND_6);
    }

    /*//////////////////////////////////////////////////////////////
                          USER WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_whenIdleEnough_woAllocation() public afterAllocated {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");
        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.withdraw(THOUSAND_6, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, THOUSAND_6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, THOUSAND_6, "total assets should be decreased");
    }

    function test_withdraw_whenIdleEnough_withAllocation() public afterAllocated {
        strategyOne.utilize(THOUSAND_6);
        strategyTwo.utilize(THOUSAND_6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.redeemAllocations(targets, amounts);
        strategyOne.deutilize(THOUSAND_6);

        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 4000000000, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.withdraw(35 * THOUSAND_6 / 10, user, user);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 35 * THOUSAND_6 / 10, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 3500000000, "total assets should be decreased");
    }

    function test_withdraw_whenIdleNotEnough_whenIdleFromCoreEnough() public afterAllocated afterPartiallyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.requestWithdraw(4 * THOUSAND_6, user, user, type(uint256).max);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 4 * THOUSAND_6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 4 * THOUSAND_6, "total assets should be decreased");
    }

    function test_withdraw_whenIdleNotEnough_whenIdleFromCoreNotEnough() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        vault.requestWithdraw(4 * THOUSAND_6, user, user, type(uint256).max);
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, 3 * THOUSAND_6, "user balance should be increased");
        assertEq(totalAssetsBefore - totalAssetsAfter, 4 * THOUSAND_6, "total assets should be decreased");

        bytes32 withdrawKey = vault.getWithdrawKey(user, 0);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");

        assertEq(vault.totalAssets(), totalAssetsAfter, "total assets remains the same after withdrawal of allocation");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");

        strategyOne.deutilize(THOUSAND_6);
        strategyTwo.deutilize(THOUSAND_6);

        assertEq(vault.totalAssets(), totalAssetsAfter, "total assets remains the same after withdrawal of allocation");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");

        vault.claim(withdrawKey);
        balAfter = asset.balanceOf(user);
        assertEq(balAfter - balBefore, 4 * THOUSAND_6, "user balance should be increased");
        assertEq(vault.totalAssets(), THOUSAND_6, "total assets");
    }

    function test_shutdown() public afterAllocated {
        strategyOne.utilize(THOUSAND_6);
        uint256 balanceBefore = asset.balanceOf(user);
        vm.startPrank(owner);
        registry.shutdownMetaVault(address(vault));
        vm.startPrank(user);
        uint256 shares = vault.balanceOf(user);
        bytes32 withdrawKey = vault.requestRedeem(shares, owner, owner, 0);
        strategyOne.deutilize(THOUSAND_6);
        assertEq(vault.totalAssets(), 0, "total assets should be 0 after shutdown");
        assertEq(vault.totalSupply(), 0, "total supply should be 0 after shutdown");
        vault.claim(withdrawKey);
        uint256 balanceAfter = asset.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, 5 * THOUSAND_6, "user balance should be increased");
    }

    function test_process_withdrawals_withIdleOfLogVault() public afterAllocated {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, type(uint256).max);
        assertEq(withdrawKey, bytes32(0), "shouldn't create withdraw request");
        assertEq(vault.pendingWithdrawals(), 0, "0 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, amount, "user balance should be increased by amount");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVaultOne.balanceOf(address(vault)), 0, "log vault has 0 shares");
        assertEq(asset.balanceOf(address(vault)), 0, "vault has 0 assets");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
    }

    function test_process_withdrawals_withAsyncRedeemAllocation() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, type(uint256).max);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.pendingWithdrawals(), 0, "0 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, idleAssets, "user balance should be increased by idle");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVaultOne.balanceOf(address(vault)), 0, "0 shares");
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSAND_6, "THOUSAND_6 requested");
        assertEq(claimableAssets, 0, "no claimable allocation");

        uint256 processedAmount = THOUSAND_6 / 4;
        strategyOne.deutilize(processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSAND_6, "pending THOUSAND_6");
        assertEq(claimableAssets, 0, "0 claimable allocation");

        assertEq(asset.balanceOf(address(logVaultOne)), processedAmount, "processedAmount withdrawn");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");

        strategyOne.deutilize(THOUSAND_6 - processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0, "pending -");
        assertEq(claimableAssets, THOUSAND_6, "THOUSAND_6 claimable allocation");

        assertEq(asset.balanceOf(address(logVaultOne)), THOUSAND_6, "assets withdrawn from core");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
    }

    function test_exploit_externalClaim() public afterAllocated afterFullyUtilized {
        uint256 idleAssets = vault.idleAssets();
        assertEq(idleAssets, 3 * THOUSAND_6, "idleAssets");

        uint256 balBefore = asset.balanceOf(user);
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        uint256 totalAssetsBefore = vault.totalAssets();
        vm.startPrank(user);
        uint256 amount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, type(uint256).max);
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.pendingWithdrawals(), 0, "THOUSAND_6 pending withdrawals");
        uint256 balAfter = asset.balanceOf(user);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(balAfter - balBefore, idleAssets, "user balance should be increased by idle");
        assertEq(totalAssetsBefore - totalAssetsAfter, amount, "total assets should be decreased by amount");

        assertEq(logVaultOne.balanceOf(address(vault)), 0, "0 shares");
        (uint256 requestedAssets, uint256 claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSAND_6, "THOUSAND_6 requested");
        assertEq(claimableAssets, 0, "no claimable allocation");

        uint256 processedAmount = THOUSAND_6 / 4;
        strategyOne.deutilize(processedAmount);
        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, THOUSAND_6, "pending THOUSAND_6");
        assertEq(claimableAssets, 0, "0 claimable allocation");

        assertEq(asset.balanceOf(address(logVaultOne)), processedAmount, "processedAmount withdrawn");
        assertEq(asset.balanceOf(address(vault)), 0, "assets withdrawn from core");
        assertFalse(vault.isClaimable(withdrawKey), "not claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");

        strategyOne.deutilize(THOUSAND_6 - processedAmount);

        // user can claim the assets
        vm.startPrank(user);
        bytes32[] memory withdrawKeys = vault.withdrawKeysFor(address(logVaultOne));
        for (uint256 i = 0; i < withdrawKeys.length; i++) {
            logVaultOne.claim(withdrawKeys[i]);
        }

        (requestedAssets, claimableAssets) = vault.allocationPendingAndClaimable();
        assertEq(requestedAssets, 0, "request assets should be 0");
        assertEq(claimableAssets, 0, "claimable assets should be 0");

        assertEq(asset.balanceOf(address(logVaultOne)), 0, "assets withdrawn from core");
        assertEq(asset.balanceOf(address(vault)), THOUSAND_6, "assets withdrawn from core");
        assertTrue(vault.isClaimable(withdrawKey), "claimable");
        assertEq(vault.idleAssets(), 0, "no idle");
        assertEq(vault.pendingWithdrawals(), 0, "no pending withdrawals");
        assertEq(vault.totalAssets(), THOUSAND_6, "total assets should be 1000");

        vm.startPrank(user);
        vault.claim(withdrawKey);
        balAfter = asset.balanceOf(user);
        assertEq(balAfter - balBefore, amount, "user balance should be increased");

        bytes32[] memory withdrawKeysAfter = vault.withdrawKeysFor(address(logVaultOne));
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
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = 2 * THOUSAND_6;

        vault.allocate(targets, amounts);

        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6, "First target allocation");
        assertEq(logVaultTwo.balanceOf(address(vault)), 2 * THOUSAND_6, "Second target allocation");
        assertEq(vault.allocatedTargets().length, 2, "Should have two allocated targets");
        assertEq(vault.allocatedAssets(), 3 * THOUSAND_6, "Total allocated assets");
    }

    function test_withdrawAllocationBatch_integration() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6 / 2;
        amounts[1] = THOUSAND_6 / 2;

        vault.withdrawAllocations(targets, amounts);

        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6 / 2, "Remaining shares for logVaultOne");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6 / 2, "Remaining shares for logVaultTwo");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
        assertEq(vault.allocatedAssets(), THOUSAND_6, "Total allocated assets should be reduced");
    }

    function test_redeemAllocationBatch_integration() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory shares = new uint256[](2);
        shares[0] = THOUSAND_6 / 2;
        shares[1] = THOUSAND_6 / 2;

        vault.redeemAllocations(targets, shares);

        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6 / 2, "Remaining shares for logVaultOne");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6 / 2, "Remaining shares for logVaultTwo");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
    }

    function test_claimAllocations_cleanup() public afterAllocated {
        // Make strategies utilize assets
        strategyOne.utilize(THOUSAND_6);
        strategyTwo.utilize(THOUSAND_6);

        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;

        vault.withdrawAllocations(targets, amounts);

        // Verify claimable targets
        assertEq(vault.claimableTargets().length, 2, "Should have two claimable targets");

        // Deutilize to make claimable
        strategyOne.deutilize(THOUSAND_6);
        strategyTwo.deutilize(THOUSAND_6);

        // Claim allocations
        vault.claimAllocations();

        // Verify cleanup
        assertEq(vault.claimableTargets().length, 0, "Should have no claimable targets after claiming");
        assertEq(vault.allocatedTargets().length, 0, "Should have no allocated targets after claiming");

        // Verify withdraw keys cleanup
        assertEq(vault.withdrawKeysFor(address(logVaultOne)).length, 0, "Should have no withdraw keys for logVaultOne");
        assertEq(vault.withdrawKeysFor(address(logVaultTwo)).length, 0, "Should have no withdraw keys for logVaultTwo");
    }

    function test_allocatedAssets_perTarget() public afterAllocated {
        uint256 allocatedForTarget1 = vault.allocatedAssetsFor(address(logVaultOne));
        assertEq(allocatedForTarget1, THOUSAND_6, "Allocated assets for logVaultOne");

        uint256 allocatedForTarget2 = vault.allocatedAssetsFor(address(logVaultTwo));
        assertEq(allocatedForTarget2, THOUSAND_6, "Allocated assets for logVaultTwo");

        uint256 totalAllocated = vault.allocatedAssets();
        assertEq(totalAllocated, 2 * THOUSAND_6, "Total allocated assets");
    }

    function test_allocationPendingAndClaimable_states() public afterAllocated {
        // Initially no pending or claimable
        (uint256 pending, uint256 claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Should have no pending assets initially");
        assertEq(claimable, 0, "Should have no claimable assets initially");

        // Make strategy utilize assets and withdraw
        strategyOne.utilize(THOUSAND_6);
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.withdrawAllocations(targets, amounts);

        // Check pending state
        (pending, claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, THOUSAND_6, "Should have pending assets");
        assertEq(claimable, 0, "Should have no claimable assets yet");

        // Deutilize to make claimable
        strategyOne.deutilize(THOUSAND_6);

        // Check claimable state
        (pending, claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Should have no pending assets after deutilize");
        assertEq(claimable, THOUSAND_6, "Should have claimable assets after deutilize");
    }

    /*//////////////////////////////////////////////////////////////
                            EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allocate_zeroAmounts() public {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        vault.allocate(targets, amounts);

        assertEq(logVaultOne.balanceOf(address(vault)), 0, "Should not allocate for zero amount");
        assertEq(logVaultTwo.balanceOf(address(vault)), 0, "Should not allocate for zero amount");
        assertEq(vault.allocatedTargets().length, 0, "Should have no allocated targets for zero amounts");
    }

    function test_withdrawAllocation_zeroAmounts() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;

        vault.withdrawAllocations(targets, amounts);

        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6, "Should not withdraw for zero amount");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6, "Should not withdraw for zero amount");
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets allocated");
    }

    function test_redeemAllocation_zeroShares() public afterAllocated {
        vm.startPrank(curator);
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory shares = new uint256[](2);
        shares[0] = 0;
        shares[1] = 0;

        vault.redeemAllocations(targets, shares);

        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6, "Should not redeem for zero shares");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6, "Should not redeem for zero shares");
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
        assertEq(vault.allocatedAssets(), 2 * THOUSAND_6, "Should still have allocated assets");
    }

    /*//////////////////////////////////////////////////////////////
                            INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullAllocationLifecycle() public {
        vm.startPrank(curator);

        // 1. Initial allocation
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = THOUSAND_6;
        amounts[1] = THOUSAND_6;

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), 2 * THOUSAND_6, "Initial allocation");

        // 2. Partial withdrawal
        address[] memory withdrawTargets = new address[](1);
        withdrawTargets[0] = address(logVaultOne);
        uint256[] memory withdrawAmounts = new uint256[](1);
        withdrawAmounts[0] = THOUSAND_6 / 2;

        vault.withdrawAllocations(withdrawTargets, withdrawAmounts);
        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6 / 2, "Partial withdrawal");
        assertEq(vault.allocatedAssets(), 3 * THOUSAND_6 / 2, "Reduced allocated assets");

        // 3. Partial redemption
        address[] memory redeemTargets = new address[](1);
        redeemTargets[0] = address(logVaultTwo);
        uint256[] memory redeemShares = new uint256[](1);
        redeemShares[0] = THOUSAND_6 / 2;

        vault.redeemAllocations(redeemTargets, redeemShares);
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6 / 2, "Partial redemption");
        assertEq(vault.allocatedAssets(), THOUSAND_6, "Further reduced allocated assets");

        // 4. Final state verification
        assertEq(vault.allocatedTargets().length, 2, "Should still have both targets");
        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6 / 2, "Final logVaultOne balance");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6 / 2, "Final logVaultTwo balance");
    }

    function test_claimAllocationsWithExternalInterference() public afterAllocated {
        // Make strategy utilize assets
        strategyOne.utilize(THOUSAND_6);

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.withdrawAllocations(targets, amounts);

        // Verify claimable state
        assertEq(vault.claimableTargets().length, 1, "Should have one claimable target");
        bytes32[] memory withdrawKeys = vault.withdrawKeysFor(address(logVaultOne));
        assertEq(withdrawKeys.length, 1, "Should have one withdraw key");

        // Deutilize to make claimable first
        strategyOne.deutilize(THOUSAND_6);

        // Now simulate external claim
        vm.startPrank(address(vault));
        logVaultOne.claim(withdrawKeys[0]);
        vm.stopPrank();

        // Now claim allocations should clean up
        vault.claimAllocations();

        // Verify cleanup
        assertEq(vault.claimableTargets().length, 0, "Should have no claimable targets after external claim");
        assertEq(
            vault.withdrawKeysFor(address(logVaultOne)).length, 0, "Should have no withdraw keys after external claim"
        );
        assertEq(vault.allocatedTargets().length, 1, "Should have only logVaultTwo allocated");
    }

    function test_multipleAllocationCycles() public {
        vm.startPrank(curator);

        // First cycle
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), THOUSAND_6, "First allocation cycle");

        // Withdraw and reallocate
        vault.withdrawAllocations(targets, amounts);
        assertEq(vault.allocatedAssets(), 0, "After withdrawal");

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), THOUSAND_6, "Second allocation cycle");

        // Add second target
        targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        amounts = new uint256[](2);
        amounts[0] = 0; // No change to first target
        amounts[1] = THOUSAND_6; // Add second target

        vault.allocate(targets, amounts);
        assertEq(vault.allocatedAssets(), 2 * THOUSAND_6, "Third allocation cycle with second target");
        assertEq(vault.allocatedTargets().length, 2, "Should have two allocated targets");
    }

    /*//////////////////////////////////////////////////////////////
                    MAX WITHDRAW AND MAX REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxWithdraw_withIdleAssets() public afterAllocated afterPartiallyUtilized {
        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets() + vault.getTargetVaultsIdleAssets();

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal total idle assets");
        assertEq(maxWithdrawAmount, 4 * THOUSAND_6, "Should be 4x THOUSAND_6 (initial deposit - utilized)");
    }

    function test_maxWithdraw_withNoIdleAssets() public afterAllocated afterFullyUtilized {
        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets();

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal only MetaVault idle assets");
        assertEq(maxWithdrawAmount, 3 * THOUSAND_6, "Should be 3x THOUSAND_6 (initial deposit - allocated)");
    }

    function test_maxRedeem_withIdleAssets() public afterAllocated afterPartiallyUtilized {
        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 totalIdleAssets = vault.getTotalIdleAssets();
        uint256 expectedShares = vault.previewDeposit(totalIdleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should convert idle assets to shares");
        assertEq(maxRedeemShares, 4 * THOUSAND_6, "Should be 4x THOUSAND_6");
    }

    function test_maxRedeem_withNoIdleAssets() public afterAllocated afterFullyUtilized {
        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 idleAssets = vault.idleAssets();
        uint256 expectedShares = vault.previewDeposit(idleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should be limited by idle assets");
        assertEq(maxRedeemShares, 3 * THOUSAND_6, "Should be 3x THOUSAND_6");
    }

    function test_maxRedeem_floorRounding() public afterAllocated afterFullyUtilized {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Add small amount of idle assets to test rounding
        strategyOne.deutilize(1000); // Small amount
        strategyTwo.deutilize(1000);

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
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 2 * THOUSAND_6, "Target vault idle assets");

        // Test withdrawal that requires target vault assets
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSAND_6;
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
        // Set different exit costs - logVaultOne has lower exit cost
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 50); // Lower exit cost
        logVaultTwo.setEntryAndExitCost(0, 500); // Higher exit cost
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 2 * THOUSAND_6, "Target vault idle assets");

        // Withdraw should prioritize logVaultOne due to lower exit cost
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSAND_6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Check that logVaultOne was used first (lower exit cost)
        uint256 logVault1Idle = VaultAdapter.tryIdleAssets(address(logVaultOne));
        uint256 logVault2Idle = VaultAdapter.tryIdleAssets(address(logVaultTwo));

        assertLt(logVault1Idle, THOUSAND_6, "logVaultOne idle should be reduced first");
        assertEq(logVault2Idle, THOUSAND_6, "logVaultTwo idle should remain unchanged");
    }

    function test_withdrawFromTargetIdleAssets_partialTargetUsage()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Add limited idle assets to target vaults
        strategyOne.deutilize(THOUSAND_6 / 2);
        strategyTwo.deutilize(THOUSAND_6 / 2);

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Target vault idle assets");

        // Withdraw amount that exceeds MetaVault idle but is within total available
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSAND_6;
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
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets");

        // Withdraw should only use MetaVault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 2 * THOUSAND_6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertEq(finalIdle, THOUSAND_6, "Should have 1x THOUSAND_6 remaining idle");
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
        logVaultOne.setEntryAndExitCost(0, 300); // Higher exit cost
        logVaultTwo.setEntryAndExitCost(0, 100); // Lower exit cost
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal that exceeds idle assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        // Should prioritize logVaultTwo due to lower exit cost
        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check that assets were withdrawn from lower exit cost vault first
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault2Shares, 0, "logVaultTwo shares should be 0");
        assertGt(logVault1Shares, 0, "logVaultOne shares should be reduced");
    }

    function test_requestWithdrawFromAllocations_multipleTargets()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 150);
        logVaultTwo.setEntryAndExitCost(0, 75);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request large withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should be used due to large request amount
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_requestWithdrawFromAllocations_zeroRequest()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal that can be fulfilled with idle assets only
        vm.startPrank(user);
        uint256 requestAmount = 2 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        // No withdraw request should be created since all assets are available as idle
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault1Shares, THOUSAND_6, "logVaultOne shares should remain unchanged");
        assertEq(logVault2Shares, THOUSAND_6, "logVaultTwo shares should remain unchanged");
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
        logVaultOne.setEntryAndExitCost(0, 200);
        logVaultTwo.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check that lower exit cost vault was prioritized
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault2Shares, 0, "logVaultTwo (lower exit cost) should be used first");
        assertGt(logVault1Shares, 0, "logVaultOne (higher exit cost) should be used after");
    }

    function test_requestWithdraw_maxRequestExceeded() public afterAllocated assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxRequest = vault.maxRequestWithdraw(user);
        uint256 exceedAmount = maxRequest + 1;

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MetaVault.MV__ExceededMaxRequestWithdraw.selector, user, exceedAmount, maxRequest)
        );
        vault.requestWithdraw(exceedAmount, user, user, type(uint256).max);
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
        logVaultOne.setEntryAndExitCost(0, 150);
        logVaultTwo.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive some assets immediately");

        // Check withdraw request
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, THOUSAND_6, "Should request remaining amount");
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
        logVaultOne.setEntryAndExitCost(0, 300);
        logVaultTwo.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares / 2; // Redeem half of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user, 0);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Check that lower exit cost vault was prioritized
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault2Shares, THOUSAND_6, "logVaultTwo (lower exit cost) should remain unchanged");
        assertEq(logVault1Shares, THOUSAND_6, "logVaultOne (higher exit cost) should remain unchanged initially");
    }

    function test_requestRedeem_maxRequestExceeded() public afterAllocated {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxRequest = vault.maxRequestRedeem(user);
        uint256 exceedShares = maxRequest + 1;

        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MetaVault.MV__ExceededMaxRequestRedeem.selector, user, exceedShares, maxRequest)
        );
        vault.requestRedeem(exceedShares, user, user, 0);
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
        logVaultOne.setEntryAndExitCost(0, 200);
        logVaultTwo.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user, 0);
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
        logVaultOne.setEntryAndExitCost(0, 10000);
        logVaultTwo.setEntryAndExitCost(0, 50000);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request despite high exit costs");

        // Should still prioritize by exit cost (lower first)
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault1Shares, 0, "logVaultOne (lower exit cost) should be used first");
        assertGt(logVault2Shares, 0, "logVaultTwo (higher exit cost) should be used after");
    }

    function test_edgeCase_zeroExitCost() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set zero exit cost
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 0);
        logVaultTwo.setEntryAndExitCost(0, 0);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request with zero exit costs");

        // Both vaults should be used equally since they have same exit cost
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault1Shares, 0, "logVaultOne shares should be 0");
        assertEq(logVault2Shares, THOUSAND_6, "logVaultTwo shares shouldn't be used");
    }

    function test_edgeCase_singleTargetVault() public afterAllocated assertPendingWithdrawalsZero {
        // Remove second target
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultTwo);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSAND_6;
        vault.withdrawAllocations(targets, amounts);
        vm.stopPrank();

        // Set exit cost for remaining vault
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        // Utilize assets
        strategyOne.utilize(THOUSAND_6);

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 4 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6 + 1;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request with single target");

        // Only logVaultOne should be used
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
    }

    function test_edgeCase_shutdownVault() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Shutdown the vault
        vm.startPrank(owner);
        registry.shutdownMetaVault(address(vault));
        vm.stopPrank();

        // Try to request withdrawal after shutdown
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        bytes32 withdrawKey = vault.requestRedeem(userShares, user, user, 0);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request even after shutdown");

        // Check that vault is shutdown
        assertTrue(vault.isShutdown(), "Vault should be shutdown");
    }

    function test_edgeCase_verySmallAmounts() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request very small withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 1000; // Very small amount
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        // Should not create withdraw request for small amounts
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request for small amounts");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));

        assertEq(logVault1Shares, THOUSAND_6, "logVaultOne shares should remain unchanged");
        assertEq(logVault2Shares, THOUSAND_6, "logVaultTwo shares should remain unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    FULLY UTILIZED ASSET TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullyUtilized_maxWithdraw() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.idleAssets(); // Only MetaVault idle assets

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal only MetaVault idle assets");
        assertEq(maxWithdrawAmount, 3 * THOUSAND_6, "Should be 3x THOUSAND_6 (initial deposit - allocated)");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults should have no idle assets");
    }

    function test_fullyUtilized_maxRedeem() public afterAllocated afterFullyUtilized {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 150);
        logVaultTwo.setEntryAndExitCost(0, 300);
        vm.stopPrank();

        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 idleAssets = vault.idleAssets();
        uint256 expectedShares = vault.previewDeposit(idleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should be limited by MetaVault idle assets");
        assertLt(maxRedeemShares, vault.balanceOf(user), "Should be less than user's total shares");
        assertEq(vault.getTotalIdleAssets(), 3 * THOUSAND_6, "Total idle should be only MetaVault idle");
    }

    function test_fullyUtilized_requestWithdraw()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request withdrawal that exceeds idle assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive idle assets immediately");

        // Check withdraw request for remaining amount
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, THOUSAND_6, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");

        // Target vault shares should remain unchanged since they're fully utilized
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVaultOne shares should be 0");
        assertGt(logVault2Shares, 0, "logVaultTwo shares shouldn't be 0");
    }

    function test_fullyUtilized_requestRedeem() public afterAllocated afterFullyUtilized assertPendingWithdrawalsZero {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 200);
        logVaultTwo.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user, 0);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Check withdraw request
        MetaVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertGt(request.requestedAssets, 0, "Should request remaining amount");
        assertFalse(request.isClaimed, "Request should not be claimed yet");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSAND_6, "logVaultOne shares should be unchanged");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_fullyUtilized_withdrawFromTargetIdleAssets()
        public
        afterAllocated
        afterFullyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets after full utilization");

        // Withdraw should only use MetaVault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 2 * THOUSAND_6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertEq(finalIdle, THOUSAND_6, "Should have 1x THOUSAND_6 remaining idle");

        // Target vault shares should remain unchanged
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSAND_6, "logVaultOne shares should remain unchanged");
        assertEq(logVault2Shares, THOUSAND_6, "logVaultTwo shares should remain unchanged");
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
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 maxWithdrawAmount = vault.maxWithdraw(user);
        uint256 expectedMax = vault.getTotalIdleAssets(); // MetaVault + target vault idle assets

        assertEq(maxWithdrawAmount, expectedMax, "maxWithdraw should equal total idle assets");
        assertGt(maxWithdrawAmount, 3 * THOUSAND_6, "Should be greater than MetaVault idle due to target vault idle");
        assertEq(vault.getTargetVaultsIdleAssets(), THOUSAND_6, "Target vaults should have THOUSAND_6 idle assets");
    }

    function test_partiallyUtilized_maxRedeem()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 150);
        logVaultTwo.setEntryAndExitCost(0, 300);
        vm.stopPrank();

        uint256 maxRedeemShares = vault.maxRedeem(user);
        uint256 totalIdleAssets = vault.getTotalIdleAssets();
        uint256 expectedShares = vault.previewDeposit(totalIdleAssets);

        assertEq(maxRedeemShares, expectedShares, "maxRedeem should convert total idle assets to shares");
        assertGt(maxRedeemShares, 0, "Should be able to redeem some shares");
        assertEq(totalIdleAssets, 4 * THOUSAND_6, "Total idle should be MetaVault + target vault idle");
    }

    function test_partiallyUtilized_requestWithdraw()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Target vault idle assets");

        // Request withdrawal that requires target vault assets
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // User should receive idle assets immediately
        uint256 userBalance = asset.balanceOf(user);
        assertGt(userBalance, 0, "User should receive idle assets immediately");

        // Target vault shares should be reduced due to idle assets
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_partiallyUtilized_requestRedeem()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 200);
        logVaultTwo.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Target vault idle assets");

        // Request redemption
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 redeemShares = userShares * 4 / 5; // Redeem 80% of shares
        bytes32 withdrawKey = vault.requestRedeem(redeemShares, user, user, 0);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Target vault shares should be reduced
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_partiallyUtilized_withdrawFromTargetIdleAssets()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Target vault idle assets");

        // Withdraw should use both MetaVault and target vault idle assets
        vm.startPrank(user);
        uint256 withdrawAmount = 4 * THOUSAND_6;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        uint256 finalIdle = vault.idleAssets();
        assertLt(finalIdle, initialIdle, "Idle assets should be reduced");

        // Target vault shares should be reduced
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    /*//////////////////////////////////////////////////////////////
                    MIXED UTILIZATION SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_mixedUtilization_scenario1() public afterAllocated assertPendingWithdrawalsZero {
        // Partially utilize logVaultOne, fully utilize logVaultTwo
        strategyOne.utilize(THOUSAND_6 / 2);
        strategyTwo.utilize(THOUSAND_6);

        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6 / 2, "Only logVaultOne should have idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should have their shares reduced when creating withdraw requests
        // logVaultOne shares should be reduced due to idle assets withdrawal
        // logVaultTwo shares should be reduced due to withdraw request creation
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVaultOne shares should be 0");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_mixedUtilization_scenario2() public afterAllocated assertPendingWithdrawalsZero {
        // Fully utilize logVaultOne, partially utilize logVaultTwo
        strategyOne.utilize(THOUSAND_6);
        strategyTwo.utilize(THOUSAND_6 / 2);

        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 200);
        logVaultTwo.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6 / 2, "Only logVaultTwo should have idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Both vaults should have their shares reduced when creating withdraw requests
        // logVaultOne shares should be reduced due to withdraw request creation
        // logVaultTwo shares should be reduced due to idle assets withdrawal
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");
    }

    function test_mixedUtilization_scenario3() public afterAllocated {
        // Partially utilize both vaults with different amounts
        strategyOne.utilize(THOUSAND_6 * 3 / 4);
        strategyTwo.utilize(THOUSAND_6 / 4);

        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 150);
        logVaultTwo.setEntryAndExitCost(0, 100);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Total target vault idle assets");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        // No withdraw request should be created since all assets are available as idle
        assertEq(withdrawKey, bytes32(0), "Should not create withdraw request");

        // Both vaults should have their shares reduced due to idle assets withdrawal
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertLt(logVault1Shares, THOUSAND_6, "logVaultOne shares should be reduced");
        assertLt(logVault2Shares, THOUSAND_6, "logVaultTwo shares should be reduced");

        // logVaultTwo should be used more due to lower exit cost
        assertLt(logVault2Shares, logVault1Shares, "logVaultTwo should be used more due to lower exit cost");
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
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 0, "No target vault idle assets after full utilization");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");

        // Target vault shares should remain unchanged since they're fully utilized
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, 0, "logVaultOne shares should be 0");
        assertGt(logVault2Shares, 0, "logVaultTwo shares shouldn't be 0");
    }

    function test_utilizationTransition_fullToPartial()
        public
        afterAllocated
        afterPartiallyUtilized
        assertPendingWithdrawalsZero
    {
        // Set exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        uint256 initialIdle = vault.idleAssets();
        uint256 targetIdle = vault.getTargetVaultsIdleAssets();

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, THOUSAND_6, "Target vaults should have idle assets after deutilization");

        // Request withdrawal
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey == bytes32(0), "Shouldn't create withdraw request");

        // Target vault shares should be reduced due to idle assets
        uint256 logVault1Shares = logVaultOne.balanceOf(address(vault));
        uint256 logVault2Shares = logVaultTwo.balanceOf(address(vault));
        assertEq(logVault1Shares, THOUSAND_6 / 2, "logVaultOne shares should be changed");
        assertEq(logVault2Shares, THOUSAND_6 / 2, "logVaultTwo shares should be changed");
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

        assertEq(initialIdle, 3 * THOUSAND_6, "Initial idle assets");
        assertEq(targetIdle, 0, "Target vault idle assets");

        // Set initial exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 100);
        logVaultTwo.setEntryAndExitCost(0, 200);
        vm.stopPrank();

        // Request withdrawal with initial exit costs
        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6;
        bytes32 withdrawKey1 = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey1 != bytes32(0), "Should create first withdraw request");

        // Change exit costs
        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(0, 300);
        logVaultTwo.setEntryAndExitCost(0, 150);
        vm.stopPrank();

        // Request another withdrawal with new exit costs
        vm.startPrank(user);
        bytes32 withdrawKey2 = vault.requestWithdraw(THOUSAND_6 / 2, user, user, type(uint256).max);
        vm.stopPrank();

        assertTrue(withdrawKey2 != bytes32(0), "Should create second withdraw request");

        // Both requests should be valid
        assertTrue(withdrawKey1 != withdrawKey2, "Withdraw keys should be different");
    }

    function test_requestWithdraw_withStrategyInRebalancing() public afterAllocated afterFullyUtilized {
        assertEq(logVaultOne.balanceOf(address(vault)), THOUSAND_6, "logVaultOne shares should be THOUSAND_6");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6, "logVaultTwo shares should be THOUSAND_6");

        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVaultOne);
        uint256[] memory shares = new uint256[](1);
        shares[0] = THOUSAND_6;
        vault.redeemAllocations(targets, shares);
        vm.stopPrank();

        assertEq(logVaultOne.balanceOf(address(vault)), 0, "logVaultOne shares should be 0");
        assertEq(logVaultTwo.balanceOf(address(vault)), THOUSAND_6, "logVaultTwo shares should be THOUSAND_6");

        vm.startPrank(user);
        uint256 requestAmount = 4 * THOUSAND_6 + THOUSAND_6 / 2;
        bytes32 withdrawKey = vault.requestWithdraw(requestAmount, user, user, type(uint256).max);
        assertTrue(withdrawKey != bytes32(0), "Should create withdraw request");
        assertEq(vault.totalAssets(), THOUSAND_6 / 2, "total assets should be THOUSAND_6 / 2");
    }

    /*//////////////////////////////////////////////////////////////
                            ALLOCATION COST
    //////////////////////////////////////////////////////////////*/

    uint256 strategyOneEntryCost = 0.002 ether;
    uint256 strategyOneExitCost = 0.003 ether;
    uint256 strategyTwoEntryCost = 0.001 ether;
    uint256 strategyTwoExitCost = 0.001 ether;

    address protocol = makeAddr("protocol");

    modifier withCostableTargetVaults() {
        // deposit to lag vaults on behalf of protocol
        uint256 protocolDeposit = THOUSAND_6;
        asset.mint(protocol, 2 * protocolDeposit);
        vm.startPrank(protocol);
        asset.approve(address(logVaultOne), protocolDeposit);
        logVaultOne.deposit(protocolDeposit, protocol);
        strategyOne.utilize(protocolDeposit);
        asset.approve(address(logVaultTwo), protocolDeposit);
        logVaultTwo.deposit(protocolDeposit, protocol);
        strategyTwo.utilize(protocolDeposit);
        vm.stopPrank();

        vm.startPrank(owner);
        logVaultOne.setEntryAndExitCost(strategyOneEntryCost, strategyOneExitCost);
        logVaultTwo.setEntryAndExitCost(strategyTwoEntryCost, strategyTwoExitCost);
        vm.stopPrank();
        _;
    }

    uint256 entryCostBps = 15;

    modifier withEntryCost() {
        vm.startPrank(curator);
        vault.setEntryCost(entryCostBps);
        vm.stopPrank();
        _;
    }

    function test_costReservation() public withEntryCost withCostableTargetVaults {
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        asset.approve(address(vault), THOUSAND_6);
        uint256 shares = vault.deposit(THOUSAND_6, user);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        uint256 expectedCost = THOUSAND_6 * entryCostBps / (1e4 + entryCostBps) + 1;
        assertEq(vault.reservedAllocationCost(), expectedCost, "Reserved allocation cost should be ");
        assertEq(vault.previewRedeem(shares), THOUSAND_6 - expectedCost, "Redeem should return the correct amount");
    }

    function test_idleAssets_afterDeposit() public withEntryCost withCostableTargetVaults {
        vm.startPrank(user);
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        asset.approve(address(vault), THOUSAND_6);
        vault.deposit(THOUSAND_6, user);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        assertEq(vault.idleAssets(), THOUSAND_6 * 6, "Idle assets should be THOUSAND_6 * 6");
    }

    function test_utilizeCostReservation() public withEntryCost withCostableTargetVaults {
        vm.startPrank(user);
        asset.approve(address(vault), THOUSAND_6);
        vault.deposit(THOUSAND_6, user);
        vm.stopPrank();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6 / 2;
        assets[1] = THOUSAND_6 / 2;
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(curator);
        vault.allocate(targets, assets);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        assertApproxEqAbs(vault.reservedAllocationCost(), 0, 1000, "Reserved allocation cost should be 0");
    }

    function test_revert_utilizeCostReservation() public withEntryCost withCostableTargetVaults {
        vm.startPrank(user);
        asset.approve(address(vault), THOUSAND_6);
        vault.deposit(THOUSAND_6, user);
        vm.stopPrank();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6 / 2;
        assets[1] = THOUSAND_6;
        vm.startPrank(curator);
        vm.expectRevert(AllocationManager.AM__InsufficientReservedAllocationCost.selector);
        vault.allocate(targets, assets);
    }

    function test_totalAssets_afterAllocation() public withEntryCost withCostableTargetVaults {
        uint256 initTotalAssets = vault.totalAssets();
        vm.startPrank(user);
        asset.approve(address(vault), THOUSAND_6);
        vault.deposit(THOUSAND_6, user);
        vm.stopPrank();
        uint256 reservedAllocationCost = vault.reservedAllocationCost();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6 / 2;
        assets[1] = THOUSAND_6 / 2;
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(curator);
        vault.allocate(targets, assets);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        assertEq(vault.totalAssets(), initTotalAssets + THOUSAND_6 - reservedAllocationCost, "Total assets");
        assertEq(vault.totalAssets(), totalAssetsBefore, "total assets should be the same");
    }

    /*//////////////////////////////////////////////////////////////
                         WITHDRAW WITH SLIPPAGE
    //////////////////////////////////////////////////////////////*/

    modifier afterDepositWithCostReservation() {
        vm.startPrank(curator);
        vault.setEntryCost(entryCostBps);
        vm.stopPrank();
        vm.startPrank(user);
        asset.approve(address(vault), 2 * THOUSAND_6);
        vault.deposit(2 * THOUSAND_6, user);
        vm.stopPrank();
        _;
    }

    modifier afterAllocate() {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 reservedAllocationCostBefore = vault.reservedAllocationCost();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6;
        assets[1] = THOUSAND_6;
        vm.startPrank(curator);
        vault.allocate(targets, assets);
        vm.stopPrank();
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets");
        assertEq(vault.idleAssets(), THOUSAND_6 * 5, "Idle assets");
        assertEq(vault.getTargetVaultsIdleAssets(), THOUSAND_6 * 2, "Target vaults idle assets");
        _;
    }

    modifier afterUtilizedFully() {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 reservedAllocationCostBefore = vault.reservedAllocationCost();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6;
        assets[1] = THOUSAND_6;
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(curator);
        vault.allocate(targets, assets);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        strategyOne.utilize(THOUSAND_6);
        strategyTwo.utilize(THOUSAND_6);
        uint256 sharePriceAfterUtilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterUtilize, sharePriceAfter, "Share price should be the same after utilize");
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets");
        assertEq(vault.idleAssets(), THOUSAND_6 * 5, "Idle assets");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets");
        _;
    }

    modifier afterUtilizedPartially() {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 reservedAllocationCostBefore = vault.reservedAllocationCost();
        address[] memory targets = new address[](2);
        targets[0] = address(logVaultOne);
        targets[1] = address(logVaultTwo);
        uint256[] memory assets = new uint256[](2);
        assets[0] = THOUSAND_6;
        assets[1] = THOUSAND_6;
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(curator);
        vault.allocate(targets, assets);
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");
        strategyOne.utilize(THOUSAND_6 / 2);
        strategyTwo.utilize(THOUSAND_6 / 2);
        uint256 sharePriceAfterUtilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterUtilize, sharePriceAfter, "Share price should be the same after utilize");
        assertEq(vault.totalAssets(), totalAssetsBefore, "Total assets");
        assertEq(vault.idleAssets(), THOUSAND_6 * 5, "Idle assets");
        assertEq(vault.getTargetVaultsIdleAssets(), THOUSAND_6, "Target vaults idle assets");
        _;
    }

    uint256 initIdle = THOUSAND_6 * 5;

    function test_requestWithdrawWithSlippage_whenIdleEnough()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterAllocate
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6;
        uint256 previewedShares = vault.previewWithdraw(amount);
        assertEq(previewedShares, amount, "Previewed assets should be amount");
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, previewedShares);
        assertTrue(withdrawKey == bytes32(0), "Withdraw key should be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        assertEq(vault.totalAssets(), totalAssetsBefore - amount, "Total assets should be decreased by amount");
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(
            vault.getTargetVaultsIdleAssets(),
            logVaultTwo.idleAssets(),
            "Target vaults idle assets should be logVaultTwo idle assets"
        );
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6, "User shares should be redeemed for less than amount");
    }

    function test_requestWithdrawWithSlippage_whenIdleEnough_withPartialUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedPartially
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6;
        uint256 previewedShares = vault.previewWithdraw(amount);
        assertEq(previewedShares, amount, "Previewed assets should be amount");
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, previewedShares);
        assertTrue(withdrawKey == bytes32(0), "Withdraw key should be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        assertEq(vault.totalAssets(), totalAssetsBefore - amount, "Total assets should be decreased by amount");
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6, "User shares should be redeemed for less than amount");
    }

    function test_requestWithdrawWithSlippage_whenIdleNotEnough_withPartialUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedPartially
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedShares = vault.previewWithdraw(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 totalIdle = vault.getTotalIdleAssets();

        uint256 logOneReservedCostBefore = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostBefore = strategyTwo.reservedExecutionCost();
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, previewedShares);
        assertTrue(withdrawKey != bytes32(0), "Withdraw key shouldn't be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        uint256 logOneReservedCostAfter = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostAfter = strategyTwo.reservedExecutionCost();
        uint256 exitCost =
            logTwoReservedCostAfter + logOneReservedCostAfter - logOneReservedCostBefore - logTwoReservedCostBefore;

        assertEq(
            vault.totalAssets(),
            totalAssetsBefore - amount - exitCost,
            "Total assets should be decreased by amount and exit cost"
        );
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + totalIdle, "User assets should be increased by totalIdle");
        assertLt(totalIdle, amount, "Total idle should be less than amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6 / 2, "User shares should be redeemed for less than amount");

        strategyOne.deutilize(THOUSAND_6 / 2);
        strategyTwo.deutilize(THOUSAND_6 / 2);
        uint256 sharePriceAfterDeutilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterDeutilize, sharePriceAfter, "Share price should be the same after deutilize");
        vault.claim(withdrawKey);
        uint256 sharePriceAfterClaim = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterClaim, sharePriceAfter, "Share price should be the same after claim");
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
    }

    function test_requestWithdrawWithSlippage_whenIdleNotEnough_withFullyUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedFully
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedShares = vault.previewWithdraw(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 totalIdle = vault.getTotalIdleAssets();

        uint256 logOneReservedCostBefore = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostBefore = strategyTwo.reservedExecutionCost();
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user, previewedShares);
        assertTrue(withdrawKey != bytes32(0), "Withdraw key shouldn't be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        uint256 logOneReservedCostAfter = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostAfter = strategyTwo.reservedExecutionCost();
        uint256 exitCost =
            logTwoReservedCostAfter + logOneReservedCostAfter - logOneReservedCostBefore - logTwoReservedCostBefore;

        assertEq(
            vault.totalAssets(),
            totalAssetsBefore - amount - exitCost,
            "Total assets should be decreased by amount and exit cost"
        );
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + totalIdle, "User assets should be increased by totalIdle");
        assertLt(totalIdle, amount, "Total idle should be less than amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6 / 2, "User shares should be redeemed for less than amount");

        strategyOne.deutilize(THOUSAND_6);
        strategyTwo.deutilize(THOUSAND_6);
        uint256 sharePriceAfterDeutilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterDeutilize, sharePriceAfter, "Share price should be the same after deutilize");
        vault.claim(withdrawKey);
        uint256 sharePriceLast = vault.convertToAssets(1e10);
        assertEq(sharePriceLast, sharePriceAfter, "Share price should be the same after claim");
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
    }

    function test_requestRedeemWithSlippage_whenIdleEnough()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterAllocate
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6;
        uint256 previewedAssets = vault.previewRedeem(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestRedeem(amount, user, user, previewedAssets);
        assertTrue(withdrawKey == bytes32(0), "Withdraw key should be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        assertEq(vault.totalAssets(), totalAssetsBefore - amount, "Total assets should be decreased by amount");
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(
            vault.getTargetVaultsIdleAssets(),
            logVaultTwo.idleAssets(),
            "Target vaults idle assets should be logVaultTwo idle assets"
        );
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6, "User shares should be redeemed for less than amount");
    }

    function test_requestRedeemWithSlippage_whenIdleEnough_withPartialUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedPartially
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6;
        uint256 previewedAssets = vault.previewRedeem(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestRedeem(amount, user, user, previewedAssets);
        assertTrue(withdrawKey == bytes32(0), "Withdraw key should be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        assertEq(vault.totalAssets(), totalAssetsBefore - amount, "Total assets should be decreased by amount");
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + amount, "User assets should be increased by amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6, "User shares should be redeemed for less than amount");
    }

    function test_requestRedeemWithSlippage_whenIdleNotEnough_withPartialUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedPartially
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedAssets = vault.previewRedeem(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 totalIdle = vault.getTotalIdleAssets();

        uint256 logOneReservedCostBefore = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostBefore = strategyTwo.reservedExecutionCost();
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestRedeem(amount, user, user, previewedAssets);
        assertTrue(withdrawKey != bytes32(0), "Withdraw key shouldn't be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        uint256 logOneReservedCostAfter = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostAfter = strategyTwo.reservedExecutionCost();
        uint256 exitCost =
            logTwoReservedCostAfter + logOneReservedCostAfter - logOneReservedCostBefore - logTwoReservedCostBefore;

        assertEq(
            vault.totalAssets(),
            totalAssetsBefore - previewedAssets - exitCost,
            "Total assets should be decreased by amount and exit cost"
        );
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + totalIdle, "User assets should be increased by totalIdle");
        assertLt(totalIdle, amount, "Total idle should be less than amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6 / 2, "User shares should be redeemed for less than amount");

        strategyOne.deutilize(THOUSAND_6 / 2);
        strategyTwo.deutilize(THOUSAND_6 / 2);
        uint256 sharePriceAfterDeutilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterDeutilize, sharePriceAfter, "Share price should be the same after deutilize");
        vault.claim(withdrawKey);
        uint256 sharePriceAfterClaim = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterClaim, sharePriceAfter, "Share price should be the same after claim");
        assertEq(
            asset.balanceOf(user),
            userAssetsBefore + previewedAssets,
            "User assets should be increased by previewedAssets"
        );
    }

    function test_requestRedeemWithSlippage_whenIdleNotEnough_withFullyUtilization()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedFully
    {
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedAssets = vault.previewRedeem(amount);
        uint256 userAssetsBefore = asset.balanceOf(user);
        uint256 totalIdle = vault.getTotalIdleAssets();

        uint256 logOneReservedCostBefore = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostBefore = strategyTwo.reservedExecutionCost();
        uint256 sharePriceBefore = vault.convertToAssets(1e10);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestRedeem(amount, user, user, previewedAssets);
        assertTrue(withdrawKey != bytes32(0), "Withdraw key shouldn't be 0");
        vm.stopPrank();
        uint256 sharePriceAfter = vault.convertToAssets(1e10);
        assertEq(sharePriceBefore, sharePriceAfter, "Share price should be the same");

        uint256 logOneReservedCostAfter = strategyOne.reservedExecutionCost();
        uint256 logTwoReservedCostAfter = strategyTwo.reservedExecutionCost();
        uint256 exitCost =
            logTwoReservedCostAfter + logOneReservedCostAfter - logOneReservedCostBefore - logTwoReservedCostBefore;

        assertEq(
            vault.totalAssets(),
            totalAssetsBefore - previewedAssets - exitCost,
            "Total assets should be decreased by amount and exit cost"
        );
        assertEq(vault.idleAssets(), 0, "Idle assets should be 0");
        assertEq(vault.getTargetVaultsIdleAssets(), 0, "Target vaults idle assets should be 0");
        assertEq(asset.balanceOf(user), userAssetsBefore + totalIdle, "User assets should be increased by totalIdle");
        assertLt(totalIdle, amount, "Total idle should be less than amount");
        uint256 userShares = vault.balanceOf(user);
        assertLt(vault.previewRedeem(userShares), THOUSAND_6 / 2, "User shares should be redeemed for less than amount");

        strategyOne.deutilize(THOUSAND_6);
        strategyTwo.deutilize(THOUSAND_6);
        uint256 sharePriceAfterDeutilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterDeutilize, sharePriceAfter, "Share price should be the same after deutilize");
        vault.claim(withdrawKey);
        uint256 sharePriceAfterClaim = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterClaim, sharePriceAfter, "Share price should be the same after claim");
        assertEq(
            asset.balanceOf(user),
            userAssetsBefore + previewedAssets,
            "User assets should be increased by previewedAssets"
        );
    }

    function test_sharePriceConsistency_claimAllocations()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedFully
    {
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;

        uint256 previewedAssets = vault.previewRedeem(amount);
        vm.startPrank(user);
        bytes32 withdrawKey = vault.requestRedeem(amount, user, user, previewedAssets);
        assertTrue(withdrawKey != bytes32(0), "Withdraw key shouldn't be 0");
        vm.stopPrank();

        uint256 sharePriceBefore = vault.convertToAssets(1e10);

        strategyOne.deutilize(THOUSAND_6);
        strategyTwo.deutilize(THOUSAND_6);

        uint256 sharePriceAfterDeutilize = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterDeutilize, sharePriceBefore, "Share price should be the same after deutilize");
        (uint256 pending, uint256 claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Pending should be 0");
        assertEq(claimable, 1497503495, "Claimable should be amount");
        uint256 assetBalanceBefore = asset.balanceOf(address(vault));
        vault.claimAllocations();
        uint256 assetBalanceAfter = asset.balanceOf(address(vault));
        assertEq(assetBalanceAfter, assetBalanceBefore + claimable, "Asset balance should be increased by claimable");
        (pending, claimable) = vault.allocationPendingAndClaimable();
        assertEq(pending, 0, "Pending should be 0");
        assertEq(claimable, 0, "Claimable should be 0");
        uint256 sharePriceAfterClaim = vault.convertToAssets(1e10);
        assertEq(sharePriceAfterClaim, sharePriceAfterDeutilize, "Share price should be the same after claim");
    }

    function test_requestWithdraw_slippage()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedFully
    {
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedShares = vault.previewWithdraw(amount);
        uint256 maxShareToBurn = previewedShares - 1;
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(MetaVault.MV__ExceededMaxSharesToBurn.selector, maxShareToBurn, previewedShares)
        );
        vault.requestWithdraw(amount, user, user, maxShareToBurn);
    }

    function test_requestRedeem_slippage()
        public
        withCostableTargetVaults
        afterDepositWithCostReservation
        afterUtilizedFully
    {
        uint256 amount = initIdle + THOUSAND_6 * 3 / 2;
        uint256 previewedAssets = vault.previewRedeem(amount);
        uint256 minAssetsToReceive = previewedAssets + 1;
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                MetaVault.MV__ExceededMinAssetsToReceive.selector, minAssetsToReceive, previewedAssets
            )
        );
        vault.requestRedeem(amount, user, user, minAssetsToReceive);
    }
}
