// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IMetaVault} from "src/interfaces/IMetaVault.sol";

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
        mapping(address vault => bool) isApproved;
        address agent;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.VaultRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_REGISTRY_STORAGE_LOCATION =
        0xeb8ff60d146ce7fa958a118578ef28883928c44fc7c24bb6e5d90448571b7b00;

    function _getVaultRegistryStorage() private pure returns (VaultRegistryStorage storage $) {
        assembly {
            $.slot := VAULT_REGISTRY_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultRegistered(
        address indexed vault, address indexed underlyingAsset, uint256 decimals, string name, string symbol
    );

    event VaultApproved(address indexed vault);
    event VaultUnapproved(address indexed vault);
    event AgentSet(address indexed agent);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error WP__ZeroAddress();
    error WP__VaultNotRegistered();
    error WP__VaultAlreadyRegistered();
    error WP__NotOwnerOrAgent();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier noneZeroAddress(
        address vault
    ) {
        if (vault == address(0)) revert WP__ZeroAddress();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner
    ) external initializer {
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(
        address /*newImplementation*/
    ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner function to set the agent
    ///
    /// @param _agent The address of the agent
    function setAgent(
        address _agent
    ) public noneZeroAddress(_agent) onlyOwner {
        if (agent() != _agent) {
            _getVaultRegistryStorage().agent = _agent;
            emit AgentSet(_agent);
        }
    }

    /// @notice Owner or agent function to register a vault
    ///
    /// @param vault The address of the vault to register
    function register(
        address vault
    ) public noneZeroAddress(vault) {
        _onlyOwnerOrAgent();
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        if ($.registeredVaults.contains(vault)) revert WP__VaultAlreadyRegistered();
        $.registeredVaults.add(vault);
        address underlyingAsset = IERC4626(vault).asset();
        string memory name = IERC4626(vault).name();
        string memory symbol = IERC4626(vault).symbol();
        uint256 decimals = IERC4626(vault).decimals();
        emit VaultRegistered(vault, underlyingAsset, decimals, name, symbol);
    }

    /// @notice Owner function to approve a vault
    ///
    /// @param vault The address of the vault to approve
    function approve(
        address vault
    ) public onlyOwner noneZeroAddress(vault) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        if ($.registeredVaults.contains(vault)) {
            $.isApproved[vault] = true;
            emit VaultApproved(vault);
        } else {
            revert WP__VaultNotRegistered();
        }
    }

    /// @notice Owner function to remove a vault from registered vaults
    ///
    /// @param vault The address of the vault to remove
    function unapprove(
        address vault
    ) public onlyOwner noneZeroAddress(vault) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        if ($.registeredVaults.contains(vault)) {
            $.isApproved[vault] = false;
            emit VaultUnapproved(vault);
        } else {
            revert WP__VaultNotRegistered();
        }
    }

    /// @notice Owner function to shutdown a meta vault
    function shutdownMetaVault(
        address metaVault
    ) public onlyOwner noneZeroAddress(metaVault) {
        IMetaVault(metaVault).shutdown();
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
    function isRegistered(
        address vault
    ) public view returns (bool) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        return $.registeredVaults.contains(vault);
    }

    /// @notice True if an inputted vault is approved
    function isApproved(
        address vault
    ) public view returns (bool) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        return $.isApproved[vault];
    }

    /// @notice Address of the agent
    function agent() public view returns (address) {
        VaultRegistryStorage storage $ = _getVaultRegistryStorage();
        return $.agent;
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _onlyOwnerOrAgent() internal view {
        if (_msgSender() != owner() && _msgSender() != agent()) revert WP__NotOwnerOrAgent();
    }

}
