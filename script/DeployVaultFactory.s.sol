// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MetaVault} from "../src/MetaVault.sol";
import {BaseAddress} from "./utils/Address.sol";

contract DeployVaultFactory is Script {
    address owner = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        VaultFactory factory = new VaultFactory(BaseAddress.VAULT_REGISTRY, address(new MetaVault()), owner);
        factory.createVault(true, BaseAddress.USDC, "Tal's Vault", "TV");
        vm.stopBroadcast();
    }
}

contract UpgradeMetaVault is Script {
    address owner = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        VaultFactory factory = VaultFactory(BaseAddress.VAULT_FACTORY);
        factory.upgradeTo(address(new MetaVault()));
        vm.stopBroadcast();
    }
}
