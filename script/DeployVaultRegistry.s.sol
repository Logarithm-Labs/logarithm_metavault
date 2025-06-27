// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";

contract DeployVaultRegistry is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        DeployHelper.deployVaultRegistry(0x2aDF216832582B2826C25914A4a7b565AEBb180D);
        vm.stopBroadcast();
    }
}
