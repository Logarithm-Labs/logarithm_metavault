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

    /// @dev Emitted when a withdraw request is created against the core vault.
    event WithdrawRequested(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        bytes32 withdrawKey,
        uint256 assets,
        uint256 shares
    );

    event Claimed(address indexed receiver, address indexed owner, bytes32 indexed withdrawKey, uint256 assets);

    event Shutdown();

    event Allocated(address indexed target, uint256 indexed assets, uint256 indexed shares);

    event AllocationWithdrawn(address indexed target, address receiver, uint256 indexed assets, bytes32 withdrawKey);
    event AllocationRedeemed(address indexed target, address receiver, uint256 indexed shares, bytes32 withdrawKey);

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

    /// @notice Shutdown the vault
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
        address[] memory _allocatedVaults = allocatedVaults();
        uint256 len = _allocatedVaults.length;
        for (uint256 i; i < len;) {
            address vault = _allocatedVaults[i];
            uint256 shares = IERC4626(vault).balanceOf(address(this));
            _withdrawAllocation(vault, shares, true);
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

    /// @dev This is limited by the idle assets.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        uint256 assets = super.maxWithdraw(owner);
        uint256 withdrawableAssets = idleAssets();
        return assets > withdrawableAssets ? withdrawableAssets : assets;
    }

    /// @dev This is limited by the idle assets.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        uint256 shares = super.maxRedeem(owner);
        // should be rounded floor so that the derived assets can't exceed idle
        uint256 redeemableShares = _convertToShares(idleAssets(), Math.Rounding.Floor);
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
        claimAllocations();
        super._withdraw(caller, receiver, owner, assets, shares);
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
        _harvestPerformanceFeeShares(assetsToRequest, sharesToRequest, false);

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

    /// @notice Claim withdrawable assets
    function claim(bytes32 withdrawKey) public returns (uint256) {
        if (!isClaimable(withdrawKey)) {
            revert MV__NotClaimable();
        }
        claimAllocations();
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
        claimAllocations();
        uint256 _idleAssets = idleAssets();
        uint256 len = _validateInputParams(targets, assets);
        uint256 assetsAllocated;
        for (uint256 i; i < len;) {
            address target = targets[i];
            _validateTarget(target);
            uint256 assetAmount = assets[i];
            if (assetAmount > 0) {
                IERC20(asset()).approve(target, assetAmount);
                uint256 shares = IERC4626(target).deposit(assetAmount, address(this));
                _getMetaVaultStorage().allocatedVaults.add(target);
                unchecked {
                    assetsAllocated += assetAmount;
                }
                emit Allocated(target, assetAmount, shares);
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
        uint256 len = _validateInputParams(targets, assets);
        for (uint256 i; i < len;) {
            _withdrawAllocation(targets[i], assets[i], false);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Redeem shares from the logarithm vaults
    ///
    /// @param targets Address array of the target vaults that are registered
    /// @param shares Unit value array to be redeemed from the target vaults
    function redeemAllocations(address[] calldata targets, uint256[] calldata shares) external onlyOwner {
        uint256 len = _validateInputParams(targets, shares);
        for (uint256 i; i < len;) {
            _withdrawAllocation(targets[i], shares[i], true);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Withdraw assets from the targets
    function _withdrawAllocation(address target, uint256 amount, bool isRedeem) internal {
        if (amount > 0) {
            MetaVaultStorage storage $ = _getMetaVaultStorage();
            bytes32 withdrawKey;
            if (isRedeem) {
                withdrawKey = ILogarithmVault(target).requestRedeem(amount, address(this), address(this));
                emit AllocationRedeemed(target, address(this), amount, withdrawKey);
            } else {
                withdrawKey = ILogarithmVault(target).requestWithdraw(amount, address(this), address(this));
                emit AllocationWithdrawn(target, address(this), amount, withdrawKey);
            }
            if (withdrawKey != bytes32(0)) {
                $.claimableVaults.add(target);
                $.allocationWithdrawKeys[target].add(withdrawKey);
            }
        }
        if (IERC4626(target).balanceOf(address(this)) == 0) {
            $.allocatedVaults.remove(target);
        }
    }

    /// @notice Claim assets from logarithm vaults
    ///
    /// @dev A decentralized function that can be called by anyone
    function claimAllocations() public {
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

    /// @dev validate params arrays' length
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

    /// @dev validate if target is registered
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
