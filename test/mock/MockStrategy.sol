// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {MockToken} from "./MockToken.sol";
import {LogarithmVault} from "managed_basis/src/vault/LogarithmVault.sol";

contract MockStrategy {
    MockToken public asset;
    LogarithmVault public vault;
    address public product;

    uint256 public utilizedAssets;

    constructor(address asset_, address vault_) {
        asset = MockToken(asset_);
        vault = LogarithmVault(vault_);
    }

    function utilize(uint256 amount) public {
        asset.burn(address(vault), amount);
        utilizedAssets += amount;
    }

    function deutilize(uint256 amount) public {
        asset.mint(address(vault), amount);
        utilizedAssets -= amount;
        vault.processPendingWithdrawRequests();
    }
}
