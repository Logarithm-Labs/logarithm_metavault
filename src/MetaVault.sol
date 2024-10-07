// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ManagedVault} from "managed_basis/src/vault/ManagedVault.sol";

import {ILogarithmVault} from "src/interfaces/ILogarithmVault.sol";
import {IWhitelistProvider} from "src/interfaces/IWhitelistProvider.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice Vault implementation that is used by vault factory
contract MetaVault is Initializable, ManagedVault {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.MetaVault
    struct MetaVaultStorage {
        address whitelistProvider;
        uint256 claimableAssets;
        uint256 assetsToClaim;
        uint256 cumulativeWithdrawAssets;
        uint256 processedWithdrawAssets;
        EnumerableSet.AddressSet allocatedVaults;
        EnumerableSet.AddressSet claimableVaults;
        mapping(address vault => EnumerableSet.Bytes32Set) allocationWithdrawKeys;
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

    /// @notice Claim assets from logarithm vaults
    ///
    /// @dev Decentralized function that can be called by anyone
    function claimAllocations() external {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 len = $.claimableVaults.length();
        uint256 totalClaimedAssets;
        for (uint256 i; i < len;) {
            address claimableVault = $.claimableVaults.at(i);
            uint256 keyLen = $.allocationWithdrawKeys[claimableVault].length();
            bool allClaimed = true;
            for (uint256 j; j < keyLen;) {
                bytes32 withdrawKey = $.allocationWithdrawKeys[claimableVault].at(j);
                if (ILogarithmVault(claimableVault).isClaimable(withdrawKey)) {
                    uint256 claimedAssets = ILogarithmVault(claimableVault).claim(withdrawKey);
                    $.allocationWithdrawKeys[claimableVault].remove(withdrawKey);
                    unchecked {
                        totalClaimedAssets += claimedAssets;
                    }
                } else {
                    allClaimed = false;
                }
                unchecked {
                    ++j;
                }
            }

            if (allClaimed) {
                $.claimableVaults.remove(claimableVault);
            }

            unchecked {
                ++i;
            }
        }

        if (totalClaimedAssets > 0) {
            uint256 _claimableAssets = claimableAssets();
            uint256 remainingAssets = _claimableAssets > totalClaimedAssets ? _claimableAssets - totalClaimedAssets : 0;
            $.claimableAssets = remainingAssets;
        }
    }

    /// @notice Assets that are free to allocate
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - assetsToClaim();
    }

    /// @notice Assets that are allocated
    function allocatedAssets() public view returns (uint256) {
        address[] memory _allocatedVaults = allocatedVaults();
        uint256 len = _allocatedVaults.length;
        uint256 assets;
        for (uint256 i; i < len;) {
            address allocatedVault = _allocatedVaults[i];
            uint256 shares = IERC4626(allocatedVault).balanceOf(address(this));
            unchecked {
                assets += IERC4626(allocatedVault).previewRedeem(shares);
            }
        }
        return assets;
    }

    function pendingWithdrawAssets() public view returns (uint256) {}

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        return idleAssets() + allocatedAssets() + claimableAssets();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw assets from the targets
    function _withdrawAllocations(address[] calldata targets, uint256[] calldata amounts, bool isRedeem) internal {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 len = _validateInputParams(targets, amounts);
        uint256 requestedAssets;
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 amount = amounts[i];
            if (amount > 0) {
                uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
                uint256 assets;
                if (isRedeem) {
                    assets = IERC4626(target).redeem(amount, address(this), address(this));
                } else {
                    assets = amount;
                    IERC4626(target).withdraw(amount, address(this), address(this));
                }
                uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
                if (balanceBefore == balanceAfter) {
                    unchecked {
                        requestedAssets += assets;
                    }
                    uint256 nonce = ILogarithmVault(target).nonces(address(this));
                    bytes32 withdrawKey = ILogarithmVault(target).getWithdrawKey(address(this), nonce);
                    $.claimableVaults.add(target);
                    $.allocationWithdrawKeys[target].add(withdrawKey);
                }
            }
            if (IERC4626(target).balanceOf(address(this)) == 0) {
                $.allocatedVaults.remove(target);
            }
            unchecked {
                ++i;
            }
        }
        if (requestedAssets > 0) {
            $.claimableAssets += requestedAssets;
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

    /// @notice Assets that are requested to claim from logarithm vaults
    function claimableAssets() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.claimableAssets;
    }

    /// @notice Assets that are reserved for users' claim
    function assetsToClaim() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.assetsToClaim;
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
