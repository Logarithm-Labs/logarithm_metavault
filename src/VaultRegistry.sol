// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title VaultRegistry
/// @author Logarithm Labs
/// @notice Store vaults that are allowed to use as targets in meta vaults
contract VaultRegistry is UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.VaultRegistry
    struct VaultRegistryStorage {
        EnumerableSet.AddressSet registeredVaults;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.VaultRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultRegistryStorageLocation =
        0xeb8ff60d146ce7fa958a118578ef28883928c44fc7c24bb6e5d90448571b7b00;

    function _getVaultRegistryStorage() private pure returns (VaultRegistryStorage storage $) {
        assembly {
            $.slot := VaultRegistryStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);

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

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner function to register a vault
    function register(address vault) public onlyOwner nonZeroAddress(vault) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        $.registeredVaults.add(vault);
        emit VaultAdded(vault);
    }

    /// @notice Owner function to remove a vault from registers
    function remove(address vault) public onlyOwner nonZeroAddress(vault) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        $.registeredVaults.remove(vault);
        emit VaultRemoved(vault);
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address array of registered vaults
    function registeredVaults() public view returns (address[] memory) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        return $.registeredVaults.values();
    }

    /// @notice True if an inputted vault is registered
    function isRegistered(address vault) public view returns (bool) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        return $.registeredVaults.contains(vault);
    }
}
