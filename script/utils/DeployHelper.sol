// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VaultRegistry} from "src/VaultRegistry.sol";
import {VaultFactory} from "src/VaultFactory.sol";
import {MetaVault} from "src/MetaVault.sol";

library DeployHelper {
    function deployVaultRegistry(address owner) internal returns (VaultRegistry) {
        return VaultRegistry(
            address(
                new ERC1967Proxy(
                    address(new VaultRegistry()), abi.encodeWithSelector(VaultRegistry.initialize.selector, owner)
                )
            )
        );
    }
}
