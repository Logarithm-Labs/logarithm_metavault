// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {MetaVault} from "../../src/MetaVault.sol";
import {VaultRegistry} from "../../src/VaultRegistry.sol";
import {BaseAddress} from "./Address.sol";
import {Script} from "forge-std/Script.sol";

address constant SECURITY_MANAGER = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

contract UpdateSecurityManagerScript is Script {

    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast( /* privateKey */ );
        VaultRegistry vaultRegistry = VaultRegistry(BaseAddress.VAULT_REGISTRY);
        vaultRegistry.updateSecurityManager(BaseAddress.META_VAULT, SECURITY_MANAGER);
        vm.stopBroadcast();

        MetaVault metaVault = MetaVault(BaseAddress.META_VAULT);
        require(metaVault.securityManager() == SECURITY_MANAGER, "Security manager not updated");
    }

}
