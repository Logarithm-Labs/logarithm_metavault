// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {BaseAddress, ArbitrumAddress} from "./utils/Address.sol";

address constant OWNER = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;

contract DeployVaultFactoryBase is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        VaultFactory factory = new VaultFactory(BaseAddress.VAULT_REGISTRY, address(new MetaVault()), OWNER);
        factory.createVault(true, BaseAddress.USDC, "Tal's Vault", "TV");
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
        VaultFactory factory = new VaultFactory(ArbitrumAddress.VAULT_REGISTRY, address(new MetaVault()), OWNER);
        factory.createVault(true, ArbitrumAddress.USDC, "Tal Vault", "TV");
        vm.stopBroadcast();
    }
}

contract UpgradeMetaVaultArbitrum is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        VaultFactory factory = VaultFactory(ArbitrumAddress.VAULT_FACTORY);
        factory.upgradeTo(address(new MetaVault()));
        vm.stopBroadcast();
    }
}
