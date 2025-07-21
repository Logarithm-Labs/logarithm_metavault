// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IMetaVault {
    function initialize(
        address VaultRegistry_,
        address owner_,
        address asset_,
        string calldata name_,
        string calldata symbol_
    ) external;
    function shutdown() external;
}
