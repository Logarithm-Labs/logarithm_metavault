// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ManagedVault} from "managed_basis/src/vault/ManagedVault.sol";

import {IWhitelistProvider} from "src/interfaces/IWhitelistProvider.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice Vault implementation that is used by vault factory
contract MetaVault is Initializable, ManagedVault {
    using EnumerableSet for EnumerableSet.AddressSet;
    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.MetaVault
    struct MetaVaultStorage {
        address whitelistProvider;
        EnumerableSet.AddressSet allocatedVaults;
        EnumerableSet.AddressSet claimableVaults;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.MetaVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MetaVaultStorageLocation =
        0x0c9c14a36e226d0a9f80ba48176ee448a64ee896f7fda99c4ab51d9d0f9abd00;

    function _getMetaVaultStorage() private pure returns (MetaVaultStorage storage $) {
        assembly {
            $.slot := MetaVaultStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MV__InvalidParamLength();
    error MV__InvalidTargetAllocation();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address whitelistProvider_,
        address owner_,
        address asset_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        $.whitelistProvider = whitelistProvider_;
    }

    /*//////////////////////////////////////////////////////////////
                             CURATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allocate assets to the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are whitelisted
    /// @param assets Array of unit values that represents the asset amount to deposit
    function allocate(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        uint256 len = _validateInputParams(targets, assets);
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 assetAmount = assets[i];
            if (assetAmount > 0) {
                IERC20(asset()).approve(target, assetAmount);
                IERC4626(target).deposit(assetAmount, address(this));
                _getMetaVaultStorage().allocatedVaults.add(target);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Withdraw assets from the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are whitelisted
    /// @param assets Array of unit values that represents the asset amount to withdraw
    function withdrawAllocations(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _withdrawAllocations(targets, assets, false);
    }

    /// @notice Redeem shares from the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are whitelisted
    /// @param shares Array of unit values that represents the share amount to redeem
    function redeemAllocations(address[] calldata targets, uint256[] calldata shares) external onlyOwner {
        _withdrawAllocations(targets, shares, true);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw assets from the targets
    function _withdrawAllocations(address[] calldata targets, uint256[] calldata amounts, bool isRedeem) internal {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 len = _validateInputParams(targets, amounts);
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 amount = amounts[i];
            if (amount > 0) {
                uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
                if (isRedeem) {
                    IERC4626(target).redeem(amount, address(this), address(this));
                } else {
                    IERC4626(target).withdraw(amount, address(this), address(this));
                }
                uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
                if (balanceBefore == balanceAfter) $.claimableVaults.add(target);
            }
            if (IERC4626(target).balanceOf(address(this)) == 0) {
                $.allocatedVaults.remove(target);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice validate params arrays' length
    ///
    /// @return length of array
    function _validateInputParams(address[] calldata targets, uint256[] calldata values)
        internal
        pure
        returns (uint256)
    {
        uint256 len = targets.length;
        if (values.length != len) {
            revert MV__InvalidParamLength();
        }
        return len;
    }

    /// @notice validate if target is whitelisted
    function _validateTarget(address target) internal view {
        address _whitelistProvider = whitelistProvider();
        if (_whitelistProvider != address(0)) {
            if (!IWhitelistProvider(_whitelistProvider).isWhitelisted(target)) {
                revert MV__InvalidTargetAllocation();
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address for the whitelistProvider
    function whitelistProvider() public view returns (address) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.whitelistProvider;
    }

    /// @notice Array of allocated vaults' addresses
    function allocatedVaults() public view returns (address[] memory) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.allocatedVaults.values();
    }

    /// @notice Array of claimable vaults' addresses
    function claimableVaults() public view returns (address[] memory) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.claimableVaults.values();
    }
}
