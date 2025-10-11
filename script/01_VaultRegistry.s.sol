// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {VaultRegistry} from "../src/VaultRegistry.sol";
import {ArbitrumAddress, BaseAddress} from "./utils/Address.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {Script} from "forge-std/Script.sol";

address constant OWNER = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;

contract DeployVaultRegistryBase is Script {

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        DeployHelper.deployVaultRegistry(OWNER);
        vm.stopBroadcast();
    }

}

contract UpgradeVaultRegistryBase is Script {

    VaultRegistry vaultRegistry = VaultRegistry(BaseAddress.VAULT_REGISTRY);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        vaultRegistry.upgradeToAndCall(address(new VaultRegistry()), "");
        vm.stopBroadcast();
    }

}

contract DeployVaultRegistryArbitrum is Script {

    VaultRegistry vaultRegistry = VaultRegistry(ArbitrumAddress.VAULT_REGISTRY);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        DeployHelper.deployVaultRegistry(OWNER);
        vm.stopBroadcast();
    }

}

contract UpgradeVaultRegistryArbitrum is Script {

    VaultRegistry vaultRegistry = VaultRegistry(ArbitrumAddress.VAULT_REGISTRY);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        vaultRegistry.upgradeToAndCall(address(new VaultRegistry()), "");
        vm.stopBroadcast();
    }

}
