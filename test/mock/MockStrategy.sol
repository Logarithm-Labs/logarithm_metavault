// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockToken} from "./MockToken.sol";
import {MockLogVault} from "./MockLogVault.sol";

contract MockStrategy {
    MockToken asset;
    MockLogVault vault;

    uint256 public utilizedAssets;

    constructor(address asset_, address vault_) {
        asset = MockToken(asset_);
        vault = MockLogVault(vault_);
    }

    function utilize(uint256 amount) public {
        asset.transferFrom(address(vault), address(this), amount);
        utilizedAssets += amount;
    }

    function deutilize(uint256 amount) public {
        asset.transfer(address(vault), amount);
        utilizedAssets -= amount;
        vault.processPendingWithdrawRequests();
    }
}
