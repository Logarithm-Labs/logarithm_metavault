// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {MigrationMetaVault} from "../src/MigrationMetaVault.sol";
import {BaseAddress, ArbitrumAddress} from "./utils/Address.sol";

address constant OWNER = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;
address constant CURATOR = 0xF600833BDB1150442B4d355d52653B3896140827;

contract DeployVaultFactoryBase is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        VaultFactory factory = new VaultFactory(BaseAddress.VAULT_REGISTRY, address(new MetaVault()), OWNER);
        factory.createVault(true, BaseAddress.USDC, CURATOR, "ACP MetaVault", "AMV");
        vm.stopBroadcast();
    }
}

contract UpgradeMetaVaultBase is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        VaultFactory factory = VaultFactory(BaseAddress.VAULT_FACTORY);
        factory.upgradeTo(address(new MetaVault()));
        vm.stopBroadcast();
    }
}

contract DeployVaultFactoryArbitrum is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        VaultFactory factory =
            new VaultFactory(ArbitrumAddress.VAULT_REGISTRY, address(new MigrationMetaVault()), OWNER);
        factory.createVault(true, ArbitrumAddress.USDC, CURATOR, "Tal Vault", "TV");
        vm.stopBroadcast();
    }
}

contract UpgradeMigrationMetaVaultArbitrum is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        VaultFactory factory = VaultFactory(ArbitrumAddress.VAULT_FACTORY);
        factory.upgradeTo(address(new MigrationMetaVault()));
        vm.stopBroadcast();
    }
}
