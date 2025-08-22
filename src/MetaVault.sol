// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";

import {ManagedVault} from "managed_basis/vault/ManagedVault.sol";
import {AllocationManager} from "./AllocationManager.sol";
import {VaultAdapter} from "./VaultAdapter.sol";

import {IVaultRegistry} from "src/interfaces/IVaultRegistry.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice Vault implementation that is used by vault factory
/// @dev This smart contract is for allocating/deallocating assets to/from the vaults
/// @dev For the target vaults, they are LogarithmVaults (Async-one) and standard ERC4626 vaults
contract MetaVault is Initializable, ManagedVault, AllocationManager, NoncesUpgradeable {
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
        // user's withdraw related state
        uint256 cumulativeRequestedWithdrawalAssets;
        uint256 cumulativeWithdrawnAssets;
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

    /// @dev Emitted when a withdraw request is created against the core vault.
    event WithdrawRequested(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        bytes32 withdrawKey,
        uint256 assets,
        uint256 shares
    );

    /// @dev Emitted when a withdraw request is claimed.
    event Claimed(address indexed receiver, address indexed owner, bytes32 indexed withdrawKey, uint256 assets);

    /// @dev Emitted when the vault is shutdown.
    event Shutdown();

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MV__InvalidParamLength();
    error MV__InvalidTargetAllocation();
    error MV__NotClaimable();
    error MV__OverAllocation();
    error MV__Shutdown();
    error MV__InvalidCaller();
    error MV__ExceededMaxRequestWithdraw(address owner, uint256 assets, uint256 max);
    error MV__ExceededMaxRequestRedeem(address owner, uint256 shares, uint256 max);
    error MV__ZeroShares();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

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

    /// @notice Shutdown the vault when the vault is inactive.
    ///
    /// @dev Only callable by the vault registry
    /// @dev This function is used to prevent any further deposits
    /// @dev Redeem all shares from the logarithm vaults
    function shutdown() external {
        if (_msgSender() != vaultRegistry()) {
            revert MV__InvalidCaller();
        }
        _getMetaVaultStorage().shutdown = true;

        // redeem all shares from the logarithm vaults
        address[] memory _allocatedTargets = allocatedTargets();
        uint256 len = _allocatedTargets.length;
        for (uint256 i; i < len;) {
            address target = _allocatedTargets[i];
            uint256 shares = IERC4626(target).balanceOf(address(this));
            _redeemAllocation(target, shares, address(this));
            unchecked {
                ++i;
            }
        }
        emit Shutdown();
    }

    /*//////////////////////////////////////////////////////////////
                               USER LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        return isShutdown() ? 0 : super.maxDeposit(receiver);
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address receiver) public view virtual override returns (uint256) {
        return isShutdown() ? 0 : super.maxMint(receiver);
    }

    /// @dev This is limited by the idle assets (including target vault idle assets).
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        uint256 assets = super.maxWithdraw(owner);
        uint256 totalIdleAssets = getTotalIdleAssets();
        return assets > totalIdleAssets ? totalIdleAssets : assets;
    }

    /// @dev This is limited by the idle assets (including target vault idle assets).
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 shares = super.maxRedeem(owner);
        // should be rounded floor so that the derived assets can't exceed total idle
        uint256 redeemableShares = _convertToShares(getTotalIdleAssets(), Math.Rounding.Floor);
        return shares > redeemableShares ? redeemableShares : shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        if (shares == 0) {
            revert MV__ZeroShares();
        }
        super._deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _claimAllocations();
        _withdrawFromTargetIdleAssets(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Withdraw from target vault idle assets to fulfill immediate withdrawal requests
    /// @param requestedAssets The amount of assets requested for immediate withdrawal
    function _withdrawFromTargetIdleAssets(uint256 requestedAssets) internal {
        if (requestedAssets == 0) return;

        // Check if we need more assets from target vaults
        uint256 idleAssetsAvailable = idleAssets();
        if (idleAssetsAvailable >= requestedAssets) return; // Already have enough

        uint256 additionalNeeded = requestedAssets - idleAssetsAvailable;

        // Withdraw from target vault idle assets
        address[] memory targets = allocatedTargets();
        uint256 len = targets.length;
        if (len > 0) {
            for (uint256 i; i < len && additionalNeeded > 0;) {
                address target = targets[i];

                // Check if target vault has idle assets that can be withdrawn immediately
                uint256 targetIdleAssets = VaultAdapter.tryGetIdleAssets(target);
                if (targetIdleAssets > 0) {
                    uint256 assetsToWithdraw = Math.min(additionalNeeded, targetIdleAssets);

                    if (assetsToWithdraw > 0) {
                        // Withdraw idle assets immediately from target vault
                        _withdrawAllocation(target, assetsToWithdraw, address(this));
                        additionalNeeded -= assetsToWithdraw;
                    }
                }
                unchecked {
                    i++;
                }
            }
        }
    }

    /// @notice Returns the maximum amount of the underlying asset that can be
    /// requested to withdraw from the owner balance in the Vault,
    /// through a requestWithdraw call.
    function maxRequestWithdraw(address owner) public view returns (uint256) {
        return super.maxWithdraw(owner);
    }

    /// @notice Returns the maximum amount of Vault shares that can be
    /// requested to redeem from the owner balance in the Vault,
    /// through a requestRedeem call.
    function maxRequestRedeem(address owner) public view returns (uint256) {
        return super.maxRedeem(owner);
    }

    /// @notice Requests to withdraw assets.
    /// If idle assets are available in the Vault, they are withdrawn synchronously
    /// within the `requestWithdraw` call, while any shortfall amount remains
    /// pending for execution by the system.
    ///
    /// @dev Burns shares from owner and sends exactly assets of underlying tokens
    /// to receiver if the idle assets is enough.
    /// If the idle assets is not enough, creates a withdraw request with
    /// the shortfall assets while sending the idle assets to receiver.
    ///
    /// @return The withdraw key that will be used in the claim function.
    /// None zero bytes32 value if the requested asset amount is bigger than the idle assets,
    /// otherwise zero bytes32 value.
    function requestWithdraw(uint256 assets, address receiver, address owner) public virtual returns (bytes32) {
        uint256 maxRequestAssets = maxRequestWithdraw(owner);
        if (assets > maxRequestAssets) {
            revert MV__ExceededMaxRequestWithdraw(owner, assets, maxRequestAssets);
        }
        uint256 maxAssets = maxWithdraw(owner);
        uint256 assetsToWithdraw = assets > maxAssets ? maxAssets : assets;
        // always assetsToWithdraw <= assets
        uint256 assetsToRequest = assets - assetsToWithdraw;

        uint256 shares = previewWithdraw(assets);
        uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
        uint256 sharesToRequest = shares - sharesToRedeem;

        if (assetsToWithdraw > 0) _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

        if (assetsToRequest > 0) {
            _requestWithdrawFromAllocations(assetsToRequest);
            return _requestWithdraw(_msgSender(), receiver, owner, assetsToRequest, sharesToRequest);
        }
        return bytes32(0);
    }

    /// @notice Requests to redeem shares.
    /// If idle assets are available in the Vault, they are withdrawn synchronously
    /// within the `requestWithdraw` call, while any shortfall amount remains
    /// pending for execution by the system.
    ///
    /// @dev Burns exactly shares from owner and sends assets of underlying tokens
    /// to receiver if the idle assets is enough,
    /// If the idle assets is not enough, creates a withdraw request with
    /// the shortfall assets while sending the idle assets to receiver.
    ///
    /// @return The withdraw key that will be used in the claim function.
    /// None zero bytes32 value if the requested asset amount is bigger than the idle assets,
    /// otherwise zero bytes32 value.
    function requestRedeem(uint256 shares, address receiver, address owner) public virtual returns (bytes32) {
        uint256 maxRequestShares = maxRequestRedeem(owner);
        if (shares > maxRequestShares) {
            revert MV__ExceededMaxRequestRedeem(owner, shares, maxRequestShares);
        }

        uint256 assets = previewRedeem(shares);
        uint256 maxAssets = maxWithdraw(owner);

        uint256 assetsToWithdraw = assets > maxAssets ? maxAssets : assets;
        // always assetsToWithdraw <= assets
        uint256 assetsToRequest = assets - assetsToWithdraw;

        uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
        uint256 sharesToRequest = shares - sharesToRedeem;

        if (assetsToWithdraw > 0) _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

        if (assetsToRequest > 0) {
            _requestWithdrawFromAllocations(assetsToRequest);
            return _requestWithdraw(_msgSender(), receiver, owner, assetsToRequest, sharesToRequest);
        }
        return bytes32(0);
    }

    /// @dev requestWithdraw/requestRedeem common workflow.
    function _requestWithdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assetsToRequest,
        uint256 sharesToRequest
    ) internal virtual returns (bytes32) {
        _updateHwmWithdraw(sharesToRequest);

        if (caller != owner) {
            _spendAllowance(owner, caller, sharesToRequest);
        }
        _burn(owner, sharesToRequest);

        MetaVaultStorage storage $ = _getMetaVaultStorage();
        uint256 _cumulativeRequestedWithdrawalAssets = cumulativeRequestedWithdrawalAssets();
        _cumulativeRequestedWithdrawalAssets += assetsToRequest;
        $.cumulativeRequestedWithdrawalAssets = _cumulativeRequestedWithdrawalAssets;

        bytes32 withdrawKey = getWithdrawKey(owner, _useNonce(owner));
        $.withdrawRequests[withdrawKey] = WithdrawRequest({
            requestedAssets: assetsToRequest,
            cumulativeRequestedWithdrawalAssets: _cumulativeRequestedWithdrawalAssets,
            requestTimestamp: block.timestamp,
            owner: owner,
            receiver: receiver,
            isClaimed: false
        });

        emit WithdrawRequested(caller, receiver, owner, withdrawKey, assetsToRequest, sharesToRequest);

        return withdrawKey;
    }

    /// @dev Automatically withdraw from allocations to fulfill user withdrawal requests
    /// @param requestedAssets The amount of assets requested by the user
    function _requestWithdrawFromAllocations(uint256 requestedAssets) internal {
        if (requestedAssets == 0) return;

        uint256 remainingRequested = requestedAssets;

        if (remainingRequested > 0) {
            address[] memory targets = allocatedTargets();
            uint256 targetsLength = targets.length;

            if (targetsLength > 0) {
                // Sort targets by exit cost (ascending order)
                address[] memory sortedTargets = _sortTargetsByExitCost(targets);

                for (uint256 i; i < targetsLength && remainingRequested > 0;) {
                    address target = sortedTargets[i];
                    uint256 targetShares = VaultAdapter.shareBalanceOf(target, address(this));

                    if (targetShares > 0) {
                        // Calculate how much we can withdraw from this target's shares
                        uint256 targetAssets = VaultAdapter.tryPreviewAssets(target, targetShares);
                        uint256 assetsToWithdraw = Math.min(remainingRequested, targetAssets);

                        if (assetsToWithdraw > 0) {
                            _withdrawAllocation(target, assetsToWithdraw, address(this));
                            remainingRequested -= assetsToWithdraw;
                        }
                    }
                    unchecked {
                        i++;
                    }
                }
            }
        }
    }

    /// @dev Sort targets by exit cost in ascending order
    /// @param targets Array of target vault addresses
    /// @return Sorted array of targets by exit cost
    function _sortTargetsByExitCost(address[] memory targets) internal view returns (address[] memory) {
        uint256 targetsLength = targets.length;
        if (targetsLength <= 1) return targets;

        // Simple bubble sort by exit cost (ascending)
        for (uint256 i; i < targetsLength - 1;) {
            for (uint256 j; j < targetsLength - i - 1;) {
                uint256 currentExitCost = VaultAdapter.tryGetExitCost(targets[j]);
                uint256 nextExitCost = VaultAdapter.tryGetExitCost(targets[j + 1]);

                if (currentExitCost > nextExitCost) {
                    // Swap
                    address temp = targets[j];
                    targets[j] = targets[j + 1];
                    targets[j + 1] = temp;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        return targets;
    }

    /// @notice Get total idle assets including MetaVault and target vault idle assets
    /// @return Total idle assets available for immediate withdrawal
    function getTotalIdleAssets() public view returns (uint256) {
        uint256 metaVaultIdle = idleAssets();
        uint256 targetVaultsIdle = getTargetVaultsIdleAssets();
        return metaVaultIdle + targetVaultsIdle;
    }

    /// @dev Get total idle assets from all target vaults
    /// @return Total idle assets from target vaults
    function getTargetVaultsIdleAssets() public view returns (uint256) {
        address[] memory targets = allocatedTargets();
        uint256 totalIdle;
        uint256 len = targets.length;
        for (uint256 i; i < len;) {
            unchecked {
                totalIdle += VaultAdapter.tryGetIdleAssets(targets[i]);
                ++i;
            }
        }
        return totalIdle;
    }

    /// @notice Claim withdrawable assets
    function claim(bytes32 withdrawKey) public returns (uint256) {
        if (!isClaimable(withdrawKey)) {
            revert MV__NotClaimable();
        }
        _claimAllocations();
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

    /// @notice Allocate the idle assets to the logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param assets Unit value array to be deposited to the target vaults
    function allocate(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _requireNotShutdown();
        _claimAllocations();
        uint256 _idleAssets = idleAssets();
        uint256 len = targets.length;
        if (assets.length != len) revert MV__InvalidParamLength();
        uint256 assetsAllocated;
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 assetAmount = assets[i];
            if (assetAmount > 0) {
                _allocate(target, assetAmount);
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
    }

    /// @notice Withdraw assets from the logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param assets Unit value array to be withdrawn from the target vaults
    function withdrawAllocations(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _withdrawAllocationBatch(targets, assets, address(this));
    }

    /// @notice Redeem shares from the logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param shares Unit value array to be redeemed from the target vaults
    function redeemAllocations(address[] calldata targets, uint256[] calldata shares) external onlyOwner {
        _redeemAllocationBatch(targets, shares, address(this));
    }

    /// @notice Claim assets from logarithm vaults
    ///
    /// @dev A decentralized function that can be called by anyone
    function claimAllocations() public {
        _claimAllocations();
    }

    function harvestPerformanceFee() public onlyOwner {
        _harvestPerformanceFeeShares();
    }

    /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (uint256 requestedAssets, uint256 claimableAssets) = allocationPendingAndClaimable();
        (, uint256 assets) =
            (assetBalance + allocatedAssets() + requestedAssets + claimableAssets).trySub(assetsToClaim());
        return assets;
    }

    /// @notice Assets that are free to allocate
    function idleAssets() public view returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 claimableAssets) = allocationPendingAndClaimable();
        (, uint256 assets) = (assetBalance + claimableAssets).trySub(assetsToClaim());
        return assets;
    }

    /// @notice Assets that are requested to withdraw from logarithm vaults
    function pendingWithdrawals() public view returns (uint256) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (uint256 requestedAssets, uint256 claimableAssets) = allocationPendingAndClaimable();
        (, uint256 assets) = assetsToClaim().trySub(assetBalance + claimableAssets + requestedAssets);
        return assets;
    }

    /// @notice Assets that should be claimed
    function assetsToClaim() public view returns (uint256) {
        return cumulativeRequestedWithdrawalAssets() - cumulativeWithdrawnAssets();
    }

    /// @notice calculate withdraw request key given a user and his nonce
    function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), user, nonce));
    }

    function isClaimable(bytes32 withdrawKey) public view returns (bool) {
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 claimableAssets) = allocationPendingAndClaimable();
        WithdrawRequest memory withdrawRequest = withdrawRequests(withdrawKey);

        if (withdrawRequest.isClaimed) return false;

        // Check if we have enough assets directly available
        uint256 directlyAvailable = assetBalance + claimableAssets;
        return withdrawRequest.cumulativeRequestedWithdrawalAssets <= cumulativeWithdrawnAssets() + directlyAvailable;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev validate if target is registered
    function _validateTarget(address target) internal view {
        address _vaultRegistry = vaultRegistry();
        if (_vaultRegistry != address(0)) {
            if (!IVaultRegistry(_vaultRegistry).isApproved(target)) {
                revert MV__InvalidTargetAllocation();
            }
        }
    }

    function _requireNotShutdown() internal view {
        if (isShutdown()) {
            revert MV__Shutdown();
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ABSTRACT ALLOCATION MANAGER IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    function _allocationAsset() internal view virtual override returns (address) {
        return asset();
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address for the vaultRegistry
    function vaultRegistry() public view returns (address) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.vaultRegistry;
    }

    function cumulativeRequestedWithdrawalAssets() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.cumulativeRequestedWithdrawalAssets;
    }

    function cumulativeWithdrawnAssets() public view returns (uint256) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.cumulativeWithdrawnAssets;
    }

    function withdrawRequests(bytes32 withdrawKey) public view returns (WithdrawRequest memory) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.withdrawRequests[withdrawKey];
    }

    function isShutdown() public view returns (bool) {
        MetaVaultStorage storage $ = _getMetaVaultStorage();
        return $.shutdown;
    }
}
