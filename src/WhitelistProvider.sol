// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title WhitelistProvider
/// @author Logarithm Labs
/// @notice Store whitelisted vaults that are allowed to use in meta vaults
contract WhitelistProvider is UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.WhitelistProvider
    struct WhitelistProviderStorage {
        EnumerableSet.AddressSet whitelistSet;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.WhitelistProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WhitelistProviderStorageLocation =
        0xeb8ff60d146ce7fa958a118578ef28883928c44fc7c24bb6e5d90448571b7b00;

    function _getWhitelistProviderStorage() private pure returns (WhitelistProviderStorage storage $) {
        assembly {
            $.slot := WhitelistProviderStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error WP__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonZeroAddress(address vault) {
        if (vault == address(0)) {
            revert WP__ZeroAddress();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner function to whitelist a vault
    function whitelist(address vault) public onlyOwner nonZeroAddress(vault) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        $.whitelistSet.add(vault);
    }

    /// @notice Owner function to remove a vault from whitelists
    function removeWhitelist(address vault) public onlyOwner nonZeroAddress(vault) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        $.whitelistSet.remove(vault);
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address array of whitelisted vaults
    function whitelistedVaults() public view returns (address[] memory) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        return $.whitelistSet.values();
    }

    /// @notice True if an inputted vault is whitelisted
    function isWhitelisted(address vault) public view returns (bool) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        return $.whitelistSet.contains(vault);
    }
}
