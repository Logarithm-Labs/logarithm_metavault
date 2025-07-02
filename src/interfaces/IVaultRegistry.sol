// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IVaultRegistry {
    function isRegistered(address vault) external view returns (bool);
    function isApproved(address vault) external view returns (bool);
}
