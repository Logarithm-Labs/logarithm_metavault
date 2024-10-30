// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ManagedVault} from "managed_basis/src/vault/ManagedVault.sol";

import {ILogarithmVault} from "src/interfaces/ILogarithmVault.sol";
import {IVaultRegistry} from "src/interfaces/IVaultRegistry.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice Vault implementation that is used by vault factory
contract MetaVault is Initializable, ManagedVault {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct WithdrawRequest {
        uint256 requestedAssets;
        uint256 cumulativeRequestedWithdrawalAssets;
        uint256 requestTimestamp;
        address owner;
        address receiver;
        bool isClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.MetaVault
    struct MetaVaultStorage {
        address vaultRegistry;
        // allocation-related state
        EnumerableSet.AddressSet allocatedVaults;
        EnumerableSet.AddressSet claimableVaults;
        mapping(address claimableVault => EnumerableSet.Bytes32Set) allocationWithdrawKeys;
        // user's withdraw related state
        uint256 cumulativeRequestedWithdrawalAssets;
        uint256 cumulativeWithdrawnAssets;
        mapping(address => uint256) nonces;
        mapping(bytes32 withdrawKey => WithdrawRequest) withdrawRequests;
        bool shutdown;
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

    event WithdrawRequested(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawKey, uint256 assets
    );

    event Claimed(address indexed receiver, address indexed owner, bytes32 indexed withdrawKey, uint256 assets);

    event Shutdown();

    event Allocated(address[] targets, uint256[] assets);

    event AllocationWithdraw(address indexed target, uint256 assets, uint256 shares);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MV__InvalidParamLength();
    error MV__InvalidTargetAllocation();
    error MV__NotClaimable();
    error MV__OverAllocation();
    error MV__Shutdown();
    error MV__InvalidCaller();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address vaultRegistry_,
        address owner_,
        address asset_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        $.vaultRegistry = vaultRegistry_;
    }

    function shutdown() external {
        if (_msgSender() != vaultRegistry()) {
            revert MV__InvalidCaller();
        }
        _getMetaVaultStorage().shutdown = true;
        emit Shutdown();
    }

    /*//////////////////////////////////////////////////////////////
                               USER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _requireNotShutdown();
        _harvestPerformanceFeeShares(assets, shares, true);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _harvestPerformanceFeeShares(assets, shares, false);

        MetaVaultStorage storage $ = _getMetaVaultStorage();

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);

        uint256 _idleAssets = idleAssets();
        if (_idleAssets >= assets) {
            allocationClaim();
            IERC20(asset()).safeTransfer(receiver, assets);
        } else {
            uint256 remainingAssets = _allocationWithdrawIdleAssets(assets - _idleAssets);
            if (remainingAssets > 0) {
                uint256 _cumulativeRequestedWithdrawalAssets = cumulativeRequestedWithdrawalAssets();
                _cumulativeRequestedWithdrawalAssets += assets;
                $.cumulativeRequestedWithdrawalAssets = _cumulativeRequestedWithdrawalAssets;

                bytes32 withdrawKey = getWithdrawKey(owner, _useNonce(owner));
                $.withdrawRequests[withdrawKey] = WithdrawRequest({
                    requestedAssets: assets,
                    cumulativeRequestedWithdrawalAssets: _cumulativeRequestedWithdrawalAssets,
                    requestTimestamp: block.timestamp,
                    owner: owner,
                    receiver: receiver,
                    isClaimed: false
                });

                emit WithdrawRequested(caller, receiver, owner, withdrawKey, assets);
            } else {
                IERC20(asset()).safeTransfer(receiver, assets);
            }
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev withdraw idle assets of the logarithm vault
    ///
    /// @return remaining assets
    function _allocationWithdrawIdleAssets(uint256 assets) internal returns (uint256) {
        address[] memory _allocatedVaults = allocatedVaults();
        uint256 index = _allocatedVaults.length;
        // withdraw in reversed order of allocatedVaults
        while (index != 0 && assets != 0) {
            address vault = _allocatedVaults[index - 1];
            uint256 vaultIdleAssets = ILogarithmVault(vault).idleAssets();
            if (vaultIdleAssets > 0) {
                uint256 availableAssets = IERC4626(vault).previewRedeem(IERC4626(vault).balanceOf(address(this)));
                // withdrawal assets should be the most minimum value of assets, vaultIdleAssets and availableAssets
                uint256 withdrawAssets = assets;
                if (withdrawAssets > vaultIdleAssets) {
                    withdrawAssets = vaultIdleAssets;
                }
                if (withdrawAssets > availableAssets) {
                    withdrawAssets = availableAssets;
                }
                uint256 shares = IERC4626(vault).withdraw(withdrawAssets, address(this), address(this));
                unchecked {
                    assets -= withdrawAssets;
                }
                emit AllocationWithdraw(vault, withdrawAssets, shares);
            }
            unchecked {
                index -= 1;
            }
        }
        return assets;
    }

    /// @notice Claim withdrawable assets
    function claim(bytes32 withdrawKey) public returns (uint256) {
        if (!isClaimable(withdrawKey)) {
            revert MV__NotClaimable();
        }
        allocationClaim();
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[withdrawKey];
        $.withdrawRequests[withdrawKey].isClaimed = true;
        $.cumulativeWithdrawnAssets += withdrawRequest.requestedAssets;
        IERC20(asset()).safeTransfer(withdrawRequest.receiver, withdrawRequest.requestedAssets);
        emit Claimed(withdrawRequest.receiver, withdrawRequest.owner, withdrawKey, withdrawRequest.requestedAssets);
        return withdrawRequest.requestedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                             CURATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allocate assets to the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param assets Array of unit values that represents the asset amount to deposit
    function allocate(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _requireNotShutdown();
        allocationClaim();
        uint256 _idleAssets = idleAssets();
        uint256 len = _validateInputParams(targets, assets);
        uint256 assetsAllocated;
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 assetAmount = assets[i];
            if (assetAmount > 0) {
                IERC20(asset()).approve(target, assetAmount);
                IERC4626(target).deposit(assetAmount, address(this));
                _getMetaVaultStorage().allocatedVaults.add(target);
                unchecked {
                    assetsAllocated += assetAmount;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (assetsAllocated > _idleAssets) {
            revert MV__OverAllocation();
        }

        emit Allocated(targets, assets);
    }

    /// @notice Withdraw assets from the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param assets Array of unit values that represents the asset amount to withdraw
    function allocationWithdraw(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _allocationWithdraw(targets, assets, false);
    }

    /// @notice Redeem shares from the logarithm vaults
    ///
    /// @dev targets should be the addresses of logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param shares Array of unit values that represents the share amount to redeem
    function allocationRedeem(address[] calldata targets, uint256[] calldata shares) external onlyOwner {
        _allocationWithdraw(targets, shares, true);
    }

    /// @notice Withdraw assets from the targets
    function _allocationWithdraw(address[] calldata targets, uint256[] calldata amounts, bool isRedeem) internal {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 len = _validateInputParams(targets, amounts);
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 amount = amounts[i];
            if (amount > 0) {
                uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
                uint256 assets;
                uint256 shares;
                if (isRedeem) {
                    shares = amount;
                    assets = IERC4626(target).redeem(shares, address(this), address(this));
                } else {
                    assets = amount;
                    shares = IERC4626(target).withdraw(assets, address(this), address(this));
                }
                emit AllocationWithdraw(target, assets, shares);
                uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
                if (balanceBefore == balanceAfter) {
                    uint256 nonce = ILogarithmVault(target).nonces(address(this));
                    bytes32 withdrawKey = ILogarithmVault(target).getWithdrawKey(address(this), nonce - 1);
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
    }

    /// @notice Claim assets from logarithm vaults
    ///
    /// @dev A decentralized function that can be called by anyone
    function allocationClaim() public {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        address[] memory _claimableVaults = claimableVaults();
        uint256 len = _claimableVaults.length;
        for (uint256 i; i < len;) {
            address claimableVault = _claimableVaults[i];
            bytes32[] memory _allocationWithdrawKeys = allocationWithdrawKeys(claimableVault);
            uint256 keyLen = _allocationWithdrawKeys.length;
            bool allClaimed = true;
            for (uint256 j; j < keyLen;) {
                bytes32 withdrawKey = _allocationWithdrawKeys[j];
                if (ILogarithmVault(claimableVault).isClaimable(withdrawKey)) {
                    ILogarithmVault(claimableVault).claim(withdrawKey);
                    $.allocationWithdrawKeys[claimableVault].remove(withdrawKey);
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
    }

    /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (uint256 requestedAssets, uint256 claimableAssets) = allocationClaimableAssets();
        (, uint256 assets) =
            (assetBalance + allocatedAssets() + requestedAssets + claimableAssets).trySub(pendingWithdrawalAssets());
        return assets;
    }

    /// @notice Assets that are free to allocate
    function idleAssets() public view returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 claimableAssets) = allocationClaimableAssets();
        (, uint256 assets) = (assetBalance + claimableAssets).trySub(pendingWithdrawalAssets());
        return assets;
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
                ++i;
            }
        }
        return assets;
    }

    /// @notice Shows claimable assets that are in the logarithm vault
    ///
    /// @return requestedAssets The claimable assets that are not able to claim from the logarithm vault
    /// @return claimableAssets The claimable assets that are able to claim from the logarithm vault
    function allocationClaimableAssets() public view returns (uint256 requestedAssets, uint256 claimableAssets) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 len = $.claimableVaults.length();
        for (uint256 i; i < len;) {
            address claimableVault = $.claimableVaults.at(i);
            uint256 keyLen = $.allocationWithdrawKeys[claimableVault].length();
            for (uint256 j; j < keyLen;) {
                bytes32 withdrawKey = $.allocationWithdrawKeys[claimableVault].at(j);
                uint256 assets = ILogarithmVault(claimableVault).withdrawRequests(withdrawKey).requestedAssets;
                if (ILogarithmVault(claimableVault).isClaimable(withdrawKey)) {
                    unchecked {
                        claimableAssets += assets;
                    }
                } else {
                    unchecked {
                        requestedAssets += assets;
                    }
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Assets that are requested to be withdraw
    function pendingWithdrawalAssets() public view returns (uint256) {
        return cumulativeRequestedWithdrawalAssets() - cumulativeWithdrawnAssets();
    }

    /// @notice calculate withdraw request key given a user and his nonce
    function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), user, nonce));
    }

    function isClaimable(bytes32 withdrawKey) public view returns (bool) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 claimableAssets) = allocationClaimableAssets();
        WithdrawRequest memory withdrawRequest = withdrawRequests(withdrawKey);
        return !withdrawRequest.isClaimed
            && withdrawRequest.cumulativeRequestedWithdrawalAssets
                <= cumulativeWithdrawnAssets() + assetBalance + claimableAssets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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

    /// @notice validate if target is registered
    function _validateTarget(address target) internal view {
        address _vaultRegistry = vaultRegistry();
        if (_vaultRegistry != address(0)) {
            if (!IVaultRegistry(_vaultRegistry).isRegistered(target)) {
                revert MV__InvalidTargetAllocation();
            }
        }
    }

    /// @dev use nonce for each user and increase it
    function _useNonce(address user) internal returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        // For each vault, the nonce has an initial value of 0, can only be incremented by one, and cannot be
        // decremented or reset. This guarantees that the nonce never overflows.
        unchecked {
            // It is important to do x++ and not ++x here.
            return $.nonces[user]++;
        }
    }

    function _requireNotShutdown() internal view {
        if (isShutdown()) {
            revert MV__Shutdown();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address for the vaultRegistry
    function vaultRegistry() public view returns (address) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.vaultRegistry;
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

    function cumulativeRequestedWithdrawalAssets() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.cumulativeRequestedWithdrawalAssets;
    }

    function cumulativeWithdrawnAssets() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.cumulativeWithdrawnAssets;
    }

    function nonces(address user) public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.nonces[user];
    }

    function withdrawRequests(bytes32 withdrawKey) public view returns (WithdrawRequest memory) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.withdrawRequests[withdrawKey];
    }

    function isShutdown() public view returns (bool) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.shutdown;
    }

    function allocationWithdrawKeys(address vault) public view returns (bytes32[] memory) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.allocationWithdrawKeys[vault].values();
    }
}
