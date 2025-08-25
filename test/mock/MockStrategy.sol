// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LogarithmVault} from "@managed_basis/vault/LogarithmVault.sol";

contract MockStrategy {
    ERC20Mock public asset;
    LogarithmVault public vault;
    address public product;

    uint256 public utilizedAssets;
    uint256 public executionCost;

    constructor(address asset_, address vault_) {
        asset = ERC20Mock(asset_);
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

    function processAssetsToWithdraw() public {}

    function reserveExecutionCost(uint256 cost) public {
        executionCost = cost;
    }

    function reservedExecutionCost() public view returns (uint256) {
        return executionCost;
    }
}
