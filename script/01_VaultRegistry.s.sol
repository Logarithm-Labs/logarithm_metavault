// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {VaultRegistry} from "../src/VaultRegistry.sol";
import {ArbitrumAddress, BaseAddress} from "./utils/Address.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {Script} from "forge-std/Script.sol";

address constant OWNER = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

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
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast( /* privateKey */ );
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
