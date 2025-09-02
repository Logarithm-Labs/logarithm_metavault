// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILogarithmVault is IERC4626 {
    function maxRequestWithdraw(address owner) external view returns (uint256);
    function maxRequestRedeem(address owner) external view returns (uint256);
    function requestWithdraw(uint256 assets, address receiver, address owner) external returns (bytes32);
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (bytes32);
    function claim(bytes32 withdrawRequestKey) external returns (uint256);
    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool);
    function isClaimed(bytes32 withdrawRequestKey) external view returns (bool);
    function idleAssets() external view returns (uint256);
    function totalPendingWithdraw() external view returns (int256);
    function entryCost() external view returns (uint256);
    function exitCost() external view returns (uint256);
}
