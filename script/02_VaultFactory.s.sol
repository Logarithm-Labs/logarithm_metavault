// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {BaseAddress, ArbitrumAddress} from "./utils/Address.sol";
import {console2 as console} from "forge-std/console2.sol";

address constant OWNER = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

contract DeployVaultFactoryBase is Script {
    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast( /* privateKey */ );
        VaultFactory factory = new VaultFactory(BaseAddress.VAULT_REGISTRY, address(new MetaVault()), OWNER);
        address vault = factory.createVault(true, BaseAddress.USDC, "ACP USDC Hive Vault", "acpUSDC");
        vm.stopBroadcast();

        console.log("VaultFactory deployed at:", address(factory));
        console.log("Vault deployed at:", vault);
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
