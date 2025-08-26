// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {VaultFactory} from "src/VaultFactory.sol";
import {MetaVault} from "src/MetaVault.sol";

contract VaultFactoryTest is Test {
    VaultFactory public factory;
    address vaultImpl;

    function setUp() public {
        vaultImpl = address(new MetaVault());
        factory = new VaultFactory(address(0), vaultImpl, address(this));
    }

    function test_impl() public view {
        assertEq(factory.implementation(), vaultImpl);
    }

    function test_createVault_noneUpgradable() public {
        address proxy = factory.createVault(false, address(0), "Test Vault", "TV");
        string memory name = IERC20(proxy).name();
        string memory symbol = IERC20(proxy).symbol();
        assertEq(name, "Test Vault");
        assertEq(symbol, "TV");
    }

    function test_createVault_upgradable() public {
        address proxy = factory.createVault(true, address(0), "Test Vault", "TV");
        string memory name = IERC20(proxy).name();
        string memory symbol = IERC20(proxy).symbol();
        assertEq(name, "Test Vault");
        assertEq(symbol, "TV");
    }

    function test_createVault_multiple() public {
        address proxyOne = factory.createVault(false, address(0), "Test Vault 1", "TV 1");
        address proxyTwo = factory.createVault(true, address(0), "Test Vault 2", "TV 2");
        address proxyThree = factory.createVault(false, address(0), "Test Vault 3", "TV 3");
        uint256 len = factory.getProxyListLength();
        assertEq(len, 3);
        assertFalse(factory.isProxy(address(this)));
        assertTrue(factory.isProxy(proxyOne));
        assertTrue(factory.isProxy(proxyTwo));
        assertTrue(factory.isProxy(proxyThree));
        assertTrue(factory.isPrioritized(proxyThree));
        assertTrue(factory.isPrioritized(proxyThree));
        assertTrue(factory.isPrioritized(proxyThree));
        assertFalse(factory.getProxyConfig(proxyOne).upgradeable);
        assertTrue(factory.getProxyConfig(proxyTwo).upgradeable);
        assertFalse(factory.getProxyConfig(proxyThree).upgradeable);
    }
}
