// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {VaultRegistry} from "../src/VaultRegistry.sol";

contract DeployVaultRegistry is Script {
    address owner = 0x2aDF216832582B2826C25914A4a7b565AEBb180D;
    VaultRegistry vaultRegistry = VaultRegistry(0x8adf8f2E67e3fc7D69eee6cB2E9BA8c812848Bb1);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        // DeployHelper.deployVaultRegistry(owner);
        vaultRegistry.upgradeToAndCall(address(new VaultRegistry()), "");
        vm.stopBroadcast();
    }
}
