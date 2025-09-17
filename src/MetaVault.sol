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

import {CostAwareManagedVault} from "./CostAwareManagedVault.sol";
import {AllocationManager} from "./AllocationManager.sol";
import {VaultAdapter} from "./library/VaultAdapter.sol";
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";

/// @title MetaVault
/// @author Logarithm Labs
/// @notice Vault implementation that is used by vault factory
/// @dev This smart contract is for allocating/deallocating assets to/from the vaults
/// @dev For the target vaults, they are LogarithmVaults (Async-one) and standard ERC4626 vaults
contract MetaVault is Initializable, AllocationManager, CostAwareManagedVault, NoncesUpgradeable {
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
    bytes32 private constant META_VAULT_STORAGE_LOCATION =
        0x0c9c14a36e226d0a9f80ba48176ee448a64ee896f7fda99c4ab51d9d0f9abd00;

    function _getMetaVaultStorage() private pure returns (MetaVaultStorage storage $) {
        assembly {
            $.slot := META_VAULT_STORAGE_LOCATION
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
    event Claimed(address indexed caller, bytes32 indexed withdrawKey, uint256 assets);

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
    error MV__ExceededMinAssetsToReceive(uint256 minAssetsToReceive, uint256 assets);

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
            uint256 shares = VaultAdapter.shareBalanceOf(target, address(this));
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
        return Math.min(assets, totalIdleAssets);
    }

    /// @dev This is limited by the idle assets (including target vault idle assets).
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 shares = super.maxRedeem(owner);
        // should be rounded floor so that the derived assets can't exceed total idle
        uint256 redeemableShares = _convertToShares(getTotalIdleAssets(), Math.Rounding.Floor);
        return Math.min(shares, redeemableShares);
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
        uint256 idleAssetsAvailable = idleAssets();
        if (idleAssetsAvailable < assets) {
            _withdrawFromTargetIdleAssets(assets - idleAssetsAvailable);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Returns the maximum amount of Vault shares that can be
    /// requested to redeem from the owner balance in the Vault,
    /// through a requestRedeem call.
    function maxRequestRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 totalIdleAssets = getTotalIdleAssets();
        uint256 assetsToWithdraw = Math.min(assets, totalIdleAssets);
        uint256 assetsToRequest = assets - assetsToWithdraw;
        uint256 exitCost = _previewAllocationExitCostOnRaw(assetsToRequest);
        uint256 shares = _convertToShares(assets + exitCost, Math.Rounding.Ceil);
        return shares;
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 totalIdleAssets = getTotalIdleAssets();
        uint256 assetsToWithdraw = Math.min(assets, totalIdleAssets);
        uint256 assetsToRequest = assets - assetsToWithdraw;
        uint256 exitCost = _previewAllocationExitCostOnTotal(assetsToRequest);
        assets -= exitCost;
        return assets;
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
    function requestRedeem(uint256 shares, address receiver, address owner, uint256 minAssetsToReceive)
        public
        virtual
        returns (bytes32)
    {
        uint256 maxRequestShares = maxRequestRedeem(owner);
        if (shares > maxRequestShares) {
            revert MV__ExceededMaxRequestRedeem(owner, shares, maxRequestShares);
        }

        uint256 assets = previewRedeem(shares);
        if (assets < minAssetsToReceive) {
            revert MV__ExceededMinAssetsToReceive(minAssetsToReceive, assets);
        }

        return _processRequest(assets, shares, receiver, owner);
    }

    function _processRequest(uint256 assets, uint256 shares, address receiver, address owner)
        internal
        returns (bytes32)
    {
        uint256 maxAssets = maxWithdraw(owner);
        uint256 assetsToWithdraw = Math.min(assets, maxAssets);
        // always assetsToWithdraw <= assets
        uint256 assetsToRequest = assets - assetsToWithdraw;

        uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
        uint256 sharesToRequest = shares - sharesToRedeem;

        if (assetsToWithdraw > 0) _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

        if (assetsToRequest > 0) {
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

        _withdrawFromAllocations(assetsToRequest);

        return withdrawKey;
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
                totalIdle += VaultAdapter.tryIdleAssets(targets[i]);
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
        emit Claimed(_msgSender(), withdrawKey, withdrawRequest.requestedAssets);
        return withdrawRequest.requestedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                             CURATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserve allocation cost
    function _processCost(uint256 cost) internal virtual override {
        if (cost > 0) _reserveAllocationCost(cost);
    }

    /// @notice Allocate the idle assets to the logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param assets Unit value array to be deposited to the target vaults
    function allocate(address[] calldata targets, uint256[] calldata assets) external onlyOwner {
        _requireNotShutdown();
        _claimAllocations();
        uint256 _idleAssets = idleAssets();
        uint256 assetsAllocated = _allocateBatch(targets, assets);

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
        (, uint256 assets) = (assetBalance + allocatedAssets() + requestedAssets + claimableAssets).trySub(
            assetsToClaim() + reservedAllocationCost()
        );
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

    /// @dev validate if target is registered
    function _validateTarget(address target) internal view virtual override {
        address _vaultRegistry = vaultRegistry();
        if (_vaultRegistry != address(0)) {
            if (!IVaultRegistry(_vaultRegistry).isApproved(target)) {
                revert MV__InvalidTargetAllocation();
            }
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
