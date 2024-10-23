// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {LogarithmVault} from "managed_basis/src/vault/LogarithmVault.sol";

contract MockLogVault is LogarithmVault {
    function initialize(address owner_, address asset_) public {
        this.initialize(owner_, asset_, address(0), 0.005 ether, 0.005 ether, "Mock", "Mock");
    }
}
