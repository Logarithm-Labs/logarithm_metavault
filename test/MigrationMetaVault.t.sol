// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LogarithmVault} from "@managed_basis/vault/LogarithmVault.sol";
import {MockStrategy} from "test/mock/MockStrategy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {MigrationMetaVault} from "src/MigrationMetaVault.sol";
import {MetaVault} from "src/MetaVault.sol";
import {VaultFactory} from "src/VaultFactory.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {VaultAdapter} from "src/library/VaultAdapter.sol";

contract MigrationMetaVaultTest is Test {
    uint256 constant THOUSANDx6 = 1_000_000_000;
    address owner = makeAddr("owner");
    address curator = makeAddr("curator");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
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
                        LogarithmVault.initialize.selector,
                        owner,
                        address(asset),
                        address(0),
                        0.001 ether,
                        0.001 ether,
                        "m",
                        "m"
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
                        LogarithmVault.initialize.selector, owner, address(asset), address(0), 0.002 ether, 0, "m", "m"
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
        asset.mint(user2, 10 * THOUSANDx6);
    }

    modifier withUserSharesInTargetVault() {
        vm.startPrank(user);
        // Ensure user has enough assets and approve the target vault
        asset.approve(address(logVault_1), THOUSANDx6);
        uint256 sharesBefore = logVault_1.balanceOf(user);
        logVault_1.deposit(THOUSANDx6, user);
        strategy_1.utilize(THOUSANDx6);
        uint256 sharesAfter = logVault_1.balanceOf(user);
        // Verify the deposit actually worked
        assertGt(sharesAfter, sharesBefore, "User should have received shares from target vault");
        vm.stopPrank();
        _;
    }

    modifier withUser2SharesInTargetVault() {
        vm.startPrank(user2);
        // Ensure user has enough assets and approve the target vault
        asset.approve(address(logVault_1), THOUSANDx6);
        uint256 sharesBefore = logVault_1.balanceOf(user2);
        logVault_1.deposit(THOUSANDx6, user2);
        strategy_1.utilize(THOUSANDx6 / 2);
        uint256 sharesAfter = logVault_1.balanceOf(user2);
        // Verify the deposit actually worked
        assertGt(sharesAfter, sharesBefore, "User should have received shares from target vault");
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             MIGRATION LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_migrate_successful() public withUserSharesInTargetVault {
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

    function test_migrate_toReceiver() public withUserSharesInTargetVault {
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

    function test_migrate_partialShares() public withUserSharesInTargetVault {
        uint256 maxTargetShares = logVault_1.balanceOf(user);
        uint256 targetShares = maxTargetShares / 4; // Migrate only 25% of user's shares
        uint256 userBalanceBefore = vault.balanceOf(user);
        uint256 vaultBalanceBefore = logVault_1.balanceOf(address(vault));

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 userBalanceAfter = vault.balanceOf(user);
        assertEq(userBalanceAfter, userBalanceBefore + mintedShares, "User should have received partial shares");

        // Verify the target vault shares were transferred correctly
        uint256 vaultSharesAfter = logVault_1.balanceOf(address(vault));
        assertEq(vaultSharesAfter, vaultBalanceBefore + targetShares, "Vault should hold the amount of migrated shares");
        assertEq(logVault_1.balanceOf(user), maxTargetShares - targetShares, "User should have remaining shares");
    }

    function test_migrate_allShares() public withUserSharesInTargetVault {
        uint256 targetShares = logVault_1.balanceOf(user); // Migrate all user's shares
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

    function test_migrate_multipleTargets() public withUserSharesInTargetVault {
        // First migrate some shares from logVault_1
        uint256 firstMigrationShares = THOUSANDx6 / 2;

        uint256 sharePriceBefore = vault.previewRedeem(1e18);

        vm.startPrank(user);
        logVault_1.approve(address(vault), firstMigrationShares);
        uint256 firstMintedShares = vault.migrate(address(logVault_1), firstMigrationShares, user);

        uint256 sharePriceAfter = vault.previewRedeem(1e18);

        // Then migrate some shares from logVault_2 (user needs shares in this vault first)
        // User should still have enough assets from the initial 10 * THOUSANDx6 mint
        asset.approve(address(logVault_2), THOUSANDx6);
        logVault_2.deposit(THOUSANDx6, user);
        logVault_2.approve(address(vault), THOUSANDx6 / 2);
        uint256 secondMintedShares = vault.migrate(address(logVault_2), THOUSANDx6 / 2, user);
        vm.stopPrank();

        uint256 sharePriceAfter2 = vault.previewRedeem(1e18);

        // Verify both migrations worked
        assertGt(firstMintedShares, 0, "First migration should have minted shares");
        assertGt(secondMintedShares, 0, "Second migration should have minted shares");

        // Verify vault holds shares from both target vaults (including existing allocation)
        uint256 logVault1Shares = logVault_1.balanceOf(address(vault));
        uint256 logVault2Shares = logVault_2.balanceOf(address(vault));
        assertGe(logVault1Shares, firstMigrationShares, "Vault should hold at least first migration shares");
        assertEq(logVault2Shares, 0, "Vault shouldn't hold second migration shares");
        assertEq(sharePriceAfter, sharePriceBefore, "Share price should increase after first migration");
        assertEq(sharePriceAfter2, sharePriceAfter, "Share price should increase after second migration");
    }

    function test_migrate_multipleUsers_sharePriceConsistent()
        public
        withUserSharesInTargetVault
        withUser2SharesInTargetVault
    {
        uint256 targetShares = logVault_1.balanceOf(user);
        uint256 targetShares2 = logVault_1.balanceOf(user2);
        uint256 conversionRate = vault.previewRedeem(1e18);

        uint256 userAssetsBefore = logVault_1.previewRedeem(targetShares);
        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        uint256 conversionRateAfter = vault.previewRedeem(1e18);
        uint256 userAssetsAfter = vault.previewRedeem(mintedShares);

        uint256 user2AssetsBefore = logVault_1.previewRedeem(targetShares2);
        vm.startPrank(user2);
        logVault_1.approve(address(vault), targetShares2);
        uint256 mintedShares2 = vault.migrate(address(logVault_1), targetShares2, user2);
        vm.stopPrank();

        uint256 conversionRateAfter2 = vault.previewRedeem(1e18);
        uint256 user2AssetsAfter = vault.previewRedeem(mintedShares2);

        assertEq(userAssetsAfter, userAssetsBefore, "User should have same assets");
        assertEq(user2AssetsAfter, user2AssetsBefore, "User2 should have same assets");
        assertEq(conversionRateAfter, conversionRate, "Conversion rate should be the same");
        assertEq(conversionRateAfter2, conversionRate, "Conversion rate should be the same");
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_revert_migrateExceededMaxShares() public withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 + 1; // Try to migrate more than user has

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        vm.expectRevert(MigrationMetaVault.MigrationExceededMaxShares.selector);
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateZeroShares() public {
        // Use  to ensure target vault is approved, but don't use withUserSharesInTargetVault
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

    function test_revert_migrateUnregisteredTarget() public withUserSharesInTargetVault {
        address unregisteredVault = makeAddr("unregisteredVault");
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        vm.expectRevert(MetaVault.MV__InvalidTargetAllocation.selector);
        vault.migrate(unregisteredVault, targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateWithoutApproval() public withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        // Don't approve the vault to spend target vault shares
        vm.expectRevert(); // Should revert due to insufficient allowance
        vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();
    }

    function test_revert_migrateInsufficientApproval() public withUserSharesInTargetVault {
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

    function test_migrate_integrationWithWithdrawal() public withUserSharesInTargetVault {
        uint256 targetShares = THOUSANDx6 / 2;

        vm.startPrank(user);
        logVault_1.approve(address(vault), targetShares);
        uint256 mintedShares = vault.migrate(address(logVault_1), targetShares, user);
        vm.stopPrank();

        // Test that the user can withdraw the migrated assets
        uint256 userBalanceBefore = vault.balanceOf(user);
        uint256 userAssetBalanceBefore = asset.balanceOf(user);

        vm.startPrank(user);
        bytes32 requestId = vault.requestRedeem(mintedShares, user, user);
        vm.stopPrank();

        uint256 userBalanceAfter = vault.balanceOf(user);
        uint256 userAssetBalanceAfter = asset.balanceOf(user);

        assertEq(userBalanceAfter, userBalanceBefore - mintedShares, "User shares should be reduced");
        assertEq(userAssetBalanceAfter, userAssetBalanceBefore, "User shouldn't receive assets");

        strategy_1.deutilize(THOUSANDx6 / 2);
        vault.claim(requestId);
        userAssetBalanceAfter = asset.balanceOf(user);
        assertGt(userAssetBalanceAfter, userAssetBalanceBefore, "User should receive assets");
    }

    /*//////////////////////////////////////////////////////////////
                             EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_migrate_afterShutdown() public withUserSharesInTargetVault {
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

    function test_migrate_assetValueConsistency() public withUserSharesInTargetVault {
        uint256 originalShares = logVault_1.balanceOf(user);
        uint256 targetShares = originalShares / 2;

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
        uint256 userTotalAssetValueBefore = logVault_1.previewRedeem(originalShares); // User's original target vault shares
        uint256 userTotalAssetValueAfter = vault.previewRedeem(vault.balanceOf(user)); // User's MetaVault shares

        // User should have at least the same total asset value (allowing for rounding)
        assertGe(
            userTotalAssetValueBefore - targetSharesAssetValue, // Subtract migrated value
            userTotalAssetValueAfter,
            "User's total asset value should not decrease after migration"
        );
    }

    function test_migrate_roundingBehavior() public withUserSharesInTargetVault {
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
                             STATE VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrate_stateConsistency() public withUserSharesInTargetVault {
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
