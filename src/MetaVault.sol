// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice vault implementation that is used by vault factory
contract MetaVault is Initializable, ERC4626Upgradeable, OwnableUpgradeable {
    function initialize(string calldata name, string calldata symbol) external initializer {
        __ERC20_init(name, symbol);
    }
}
