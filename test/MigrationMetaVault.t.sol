// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LogarithmVault} from "managed_basis/vault/LogarithmVault.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {MigrationMetaVault} from "src/MigrationMetaVault.sol";
import {MetaVault} from "src/MetaVault.sol";
import {VaultFactory} from "src/VaultFactory.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

contract MigrationMetaVaultTest is Test {
    uint256 constant THOUSANDx6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    ERC20Mock asset;
    LogarithmVault logVault_1;
    MockStrategy strategy_1;
    LogarithmVault logVault_2;
    MockStrategy strategy_2;

    VaultRegistry registry;
    MigrationMetaVault vault;

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
        registry = DeployHelper.deployVaultRegistry(owner);
        vm.startPrank(owner);
        registry.register(address(logVault_1));
        registry.register(address(logVault_2));
        registry.approve(address(logVault_1));
        registry.approve(address(logVault_2));

        VaultFactory factory = new VaultFactory(address(registry), address(new MigrationMetaVault()), owner);
        vm.startPrank(curator);
        vault = MigrationMetaVault(factory.createVault(false, address(asset), "vault", "vault"));

        // Mint assets for the user (following the same pattern as existing tests)
        asset.mint(user, 10 * THOUSANDx6);

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

    modifier withUserSharesInTargetVault() {
        vm.startPrank(user);
        // Ensure user has enough assets and approve the target vault
        asset.approve(address(logVault_1), THOUSANDx6);
        uint256 sharesBefore = logVault_1.balanceOf(user);
        logVault_1.deposit(THOUSANDx6, user);
        uint256 sharesAfter = logVault_1.balanceOf(user);
        // Verify the deposit actually worked
        assertGt(sharesAfter, sharesBefore, "User should have received shares from target vault");
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             MIGRATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_migrate_successful() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;
        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 vaultBalanceBefore = vault.balanceOf(user);
        uint256 targetVaultBalanceBefore = logVault_1.balanceOf(user);

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 userBalanceAfter = asset.balanceOf(user);
        uint256 vaultBalanceAfter = vault.balanceOf(user);
        uint256 targetVaultBalanceAfter = logVault_1.balanceOf(user);

        // User should have received new vault shares
        assertGt(vaultBalanceAfter, vaultBalanceBefore, "User should have more vault shares");
        assertEq(mintedShares, vaultBalanceAfter - vaultBalanceBefore, "Minted shares should match");

        // User should have fewer target vault shares
        assertEq(
            targetVaultBalanceAfter, targetVaultBalanceBefore - targetShares, "Target vault shares should be reduced"
        );

        // User's asset balance should remain the same (no direct asset transfer)
        assertEq(userBalanceAfter, userBalanceBefore, "User asset balance should remain the same");

        // Vault should now hold the target vault shares (in addition to existing shares from allocation)
        uint256 expectedVaultShares = logVault_1.balanceOf(address(vault));
        assertGe(expectedVaultShares, targetShares, "Vault should hold at least the migrated shares");
    }

    function test_migrate_toReceiver() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;
        uint256 receiverBalanceBefore = vault.balanceOf(receiver);
        uint256 userBalanceBefore = vault.balanceOf(user);

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, receiver);
        vm.stopPrank();

        uint256 receiverBalanceAfter = vault.balanceOf(receiver);
        uint256 userBalanceAfter = vault.balanceOf(user);

        // Receiver should have received new vault shares
        assertEq(receiverBalanceAfter, receiverBalanceBefore + mintedShares, "Receiver should have received shares");

        // User should not have received any new shares
        assertEq(userBalanceAfter, userBalanceBefore, "User should not have received shares");
    }

    function test_migrate_partialShares() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 4; // Migrate only 25% of user's shares
        uint256 userBalanceBefore = vault.balanceOf(user);

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 userBalanceAfter = vault.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + mintedShares, "User should have received partial shares");

        // Verify the target vault shares were transferred correctly
        uint256 expectedVaultShares = logVault_1.balanceOf(address(vault));
        assertGe(expectedVaultShares, targetShares, "Vault should hold at least the migrated shares");
        assertEq(logVault_1.balanceOf(user), THOUSANDx6 - targetShares, "User should have remaining shares");
    }

    function test_migrate_allShares() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6; // Migrate all user's shares
        uint256 userBalanceBefore = vault.balanceOf(user);

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 userBalanceAfter = vault.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + mintedShares, "User should have received all shares");

        // Verify the target vault shares were transferred correctly
        uint256 expectedVaultShares = logVault_1.balanceOf(address(vault));
        assertGe(expectedVaultShares, targetShares, "Vault should hold at least the migrated shares");
        assertEq(logVault_1.balanceOf(user), 0, "User should have no remaining shares");
    }

    function test_migrate_multipleTargets() public afterAllocated withUserSharesInTargetVault {
        // First migrate some shares from logVault_1
        uint256 firstMigrationShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), firstMigrationShares);
        uint256 firstMintedShares = vault.migrate(address(logVault_1), firstMigrationShares, user);

        // Then migrate some shares from logVault_2 (user needs shares in this vault first)
        // User should still have enough assets from the initial 10 * THOUSANDx6 mint
        asset.approve(address(logVault_2), THOUSANDx6);
        logVault_2.deposit(THOUSANDx6, user);
        logVault_2.approve(address(vault), THOUSANDx6 / 2);
        uint256 secondMintedShares = vault.migrate(address(logVault_2), THOUSANDx6 / 2, user);
        vm.stopPrank();

        // Verify both migrations worked
        assertGt(firstMintedShares, 0, "First migration should have minted shares");
        assertGt(secondMintedShares, 0, "Second migration should have minted shares");

        // Verify vault holds shares from both target vaults (including existing allocation)
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertGe(logVault1Shares, firstMigrationShares, "Vault should hold at least first migration shares");
        assertGe(logVault2Shares, THOUSANDx6 / 2, "Vault should hold at least second migration shares");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_migrateExceededMaxShares() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 + 1; // Try to migrate more than user has

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        vm.expectRevert(MigrationMetaVault.MigrationExceededMaxShares.selector);
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateZeroShares() public afterAllocated {
        // Use afterAllocated to ensure target vault is approved, but don't use withUserSharesInTargetVault
        // so user has 0 shares in target vault
        uint256 targetShares = 0;

        vm.startPrank(user);
        // User should have 0 shares in logVault_1 since we didn't use withUserSharesInTargetVault modifier
        uint256 userSharesInTargetVault = logVault_1.balanceOf(user);
        assertEq(userSharesInTargetVault, 0, "User should have 0 shares in target vault");

        logVault_1.approve(address(vault), targetShares);
        vm.expectRevert(MigrationMetaVault.MigrationZeroShares.selector);
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateUnregisteredTarget() public afterAllocated withUserSharesInTargetVault {
        address unregisteredVault = makeAddr("unregisteredVault");
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        vm.expectRevert(MetaVault.MV__InvalidTargetAllocation.selector);
        vault.migrate(unregisteredVault, targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateWithoutApproval() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        // Don't approve the vault to spend target vault shares
        vm.expectRevert(); // Should revert due to insufficient allowance
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateInsufficientApproval() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;
        uint256 insufficientApproval = targetShares - 1;

        vm.startPrank(user);
        logVault_1.approve(address(vault), insufficientApproval);
        vm.expectRevert(); // Should revert due to insufficient allowance
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrate_integrationWithAllocation() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;
        uint256 vaultBalanceBefore = vault.balanceOf(user);
        uint256 totalAssetsBefore = vault.totalAssets();

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Verify the migration increased total assets
        uint256 totalAssetsAfter = vault.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after migration");

        // Verify the user can now withdraw the migrated assets
        uint256 userBalanceAfter = vault.balanceOf(user);
        assertEq(userBalanceAfter, vaultBalanceBefore + mintedShares, "User should have received shares");

        // Test that the migrated shares can be allocated
        vm.startPrank(curator);
        address[] memory targets = new address[](1);
        targets[0] = address(logVault_2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = THOUSANDx6 / 4;
        vault.allocate(targets, amounts);
        vm.stopPrank();

        // Verify allocation worked with migrated assets
        uint256 totalAssetsAfterAllocation = vault.totalAssets();
        assertGe(totalAssetsAfterAllocation, totalAssetsAfter, "Total assets should not decrease after allocation");
    }

    function test_migrate_integrationWithWithdrawal() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Test that the user can withdraw the migrated assets
        uint256 userBalanceBefore = vault.balanceOf(user);
        uint256 userAssetBalanceBefore = asset.balanceOf(user);

        vm.startPrank(user);
        vault.redeem(mintedShares, user, user);
        vm.stopPrank();

        uint256 userBalanceAfter = vault.balanceOf(user);
        uint256 userAssetBalanceAfter = asset.balanceOf(user);

        assertEq(userBalanceAfter, userBalanceBefore - mintedShares, "User shares should be reduced");
        assertGt(userAssetBalanceAfter, userAssetBalanceBefore, "User should receive assets");
    }

    /*//////////////////////////////////////////////////////////////
                             EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_migrate_verySmallAmount() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = 1; // Migrate just 1 wei worth of shares

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Should still work even with very small amounts
        assertGt(mintedShares, 0, "Should mint shares even for very small amounts");
        uint256 expectedVaultShares = logVault_1.balanceOf(address(vault));
        assertGe(expectedVaultShares, targetShares, "Vault should hold at least the migrated shares");
    }

    function test_migrate_afterShutdown() public afterAllocated withUserSharesInTargetVault {
        // Shutdown the vault
        vm.startPrank(owner);
        registry.shutdownMetaVault(address(vault));
        vm.stopPrank();

        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        // Migration should still work after shutdown since it's not a deposit operation
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        assertGt(mintedShares, 0, "Migration should work after shutdown");
    }

    function test_migrate_assetValueConsistency() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);

        // Calculate the asset value of target shares before migration
        uint256 targetSharesAssetValue = logVault_1.previewRedeem(targetShares);

        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Calculate the asset value of minted MetaVault shares after migration
        uint256 mintedSharesAssetValue = vault.previewRedeem(mintedShares);

        // The asset value should be consistent (allowing for small rounding differences)
        // This ensures economic value is preserved during migration
        assertApproxEqRel(
            mintedSharesAssetValue,
            targetSharesAssetValue,
            0.001e18, // 0.1% tolerance for rounding
            "Asset value of shares should remain consistent after migration"
        );

        // Additional verification: check that the user's total asset value hasn't decreased
        uint256 userTotalAssetValueBefore = logVault_1.previewRedeem(THOUSANDx6); // User's original target vault shares
        uint256 userTotalAssetValueAfter = vault.previewRedeem(vault.balanceOf(user)); // User's MetaVault shares

        // User should have at least the same total asset value (allowing for rounding)
        assertGe(
            userTotalAssetValueAfter,
            userTotalAssetValueBefore - targetSharesAssetValue, // Subtract migrated value
            "User's total asset value should not decrease after migration"
        );
    }

    function test_migrate_roundingBehavior() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 3; // Use a non-divisible amount to test rounding

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Verify that the migration handles rounding correctly
        assertGt(mintedShares, 0, "Should handle rounding correctly");

        // The minted shares should correspond to the assets from the target vault
        uint256 expectedAssets = logVault_1.previewRedeem(targetShares);
        uint256 actualAssets = vault.previewRedeem(mintedShares);

        // Allow for small rounding differences
        assertApproxEqRel(actualAssets, expectedAssets, 0.001e18, "Assets should match within rounding tolerance");
    }

    /*//////////////////////////////////////////////////////////////
                             GAS OPTIMIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrate_gasUsage() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);

        uint256 gasBefore = gasleft();
        vault.migrate(address(logVault_1), targetShares, user);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Log gas usage for optimization purposes
        console.log("Gas used for migration:", gasUsed);

        // Ensure gas usage is reasonable (less than 200k gas)
        assertLt(gasUsed, 200_000, "Migration should use reasonable amount of gas");
    }

    /*//////////////////////////////////////////////////////////////
                             STATE VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrate_stateConsistency() public afterAllocated withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;
        uint256 vaultBalanceBefore = vault.balanceOf(user);
        uint256 targetVaultBalanceBefore = logVault_1.balanceOf(user);
        uint256 vaultTotalSupplyBefore = vault.totalSupply();
        uint256 vaultTotalAssetsBefore = vault.totalAssets();

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 vaultBalanceAfter = vault.balanceOf(user);
        uint256 targetVaultBalanceAfter = logVault_1.balanceOf(user);
        uint256 vaultTotalSupplyAfter = vault.totalSupply();
        uint256 vaultTotalAssetsAfter = vault.totalAssets();

        // Verify state consistency
        assertEq(vaultBalanceAfter, vaultBalanceBefore + mintedShares, "User vault balance should increase");
        assertEq(
            targetVaultBalanceAfter,
            targetVaultBalanceBefore - targetShares,
            "User target vault balance should decrease"
        );
        assertEq(vaultTotalSupplyAfter, vaultTotalSupplyBefore + mintedShares, "Total supply should increase");
        assertGt(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Total assets should increase");

        // Verify the vault now holds the target vault shares (in addition to existing shares from allocation)
        uint256 expectedVaultShares = logVault_1.balanceOf(address(vault));
        assertGe(expectedVaultShares, targetShares, "Vault should hold at least the migrated shares");
    }
}
