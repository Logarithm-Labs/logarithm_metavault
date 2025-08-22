// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ILogarithmVault {
    struct WithdrawRequest {
        uint256 requestedAssets;
        uint256 accRequestedWithdrawAssets;
        uint256 requestTimestamp;
        address owner;
        address receiver;
        bool isPrioritized;
        bool isClaimed;
    }

    function maxRequestWithdraw(address owner) external view returns (uint256);
    function maxRequestRedeem(address owner) external view returns (uint256);
    function requestWithdraw(uint256 assets, address receiver, address owner) external returns (bytes32);
    function requestRedeem(uint256 shares, address receiver, address owner) external returns (bytes32);
    function claim(bytes32 withdrawRequestKey) external returns (uint256);
    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool);
    function withdrawRequests(bytes32 withdrawRequestKey) external view returns (WithdrawRequest memory);
    function nonces(address user) external view returns (uint256);
    function getWithdrawKey(address user, uint256 nonce) external view returns (bytes32);
    function idleAssets() external view returns (uint256);
    function entryCost() external view returns (uint256);
    function exitCost() external view returns (uint256);
    function totalPendingWithdraw() external view returns (int256);
    function processPendingWithdrawRequests() external returns (uint256);
}
