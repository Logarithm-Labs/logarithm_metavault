// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VaultAdapter} from "./VaultAdapter.sol";

/// @title AllocationManager
/// @notice Generalized allocation/deallocation/claim helper for managing positions across heterogeneous vaults
/// @dev Supports both standard ERC4626 and semi-async vaults implementing ISemiAsyncRedeemVault
abstract contract AllocationManager {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AAM__InvalidInputLength();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Allocated(address indexed target, uint256 assets, uint256 shares);
    event AllocationWithdrawn(address indexed target, address indexed receiver, uint256 assets, bytes32 withdrawKey);
    event AllocationRedeemed(address indexed target, address indexed receiver, uint256 shares, bytes32 withdrawKey);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct AllocationStorage {
        EnumerableSet.AddressSet allocatedTargets;
        EnumerableSet.AddressSet claimableTargets;
        mapping(address target => EnumerableSet.Bytes32Set) withdrawKeysByTarget;
        // Track requested asset amounts per target/key for accounting
        mapping(address target => mapping(bytes32 key => uint256 assets)) requestedAssetsByKey;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.AllocationManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ALLOCATION_STORAGE_LOCATION =
        0xfebea8c17ed7d235908df1841c550752fa884affd713fb9d9fb47bc0b16bc700;

    function _getAllocationStorage() private pure returns (AllocationStorage storage $) {
        assembly {
            $.slot := ALLOCATION_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                               ABSTRACTS
    //////////////////////////////////////////////////////////////*/

    function _allocationAsset() internal view virtual returns (address);

    /*//////////////////////////////////////////////////////////////
                               ALLOCATE
    //////////////////////////////////////////////////////////////*/

    function _allocate(address target, uint256 assets) internal virtual {
        if (assets == 0) return;
        IERC20(_allocationAsset()).forceApprove(target, assets);
        uint256 shares = VaultAdapter.deposit(target, assets, address(this));
        _getAllocationStorage().allocatedTargets.add(target);
        emit Allocated(target, assets, shares);
    }

    function _allocateBatch(address[] memory targets, uint256[] memory assets) internal virtual {
        uint256 len = targets.length;
        if (assets.length != len) revert AAM__InvalidInputLength();
        for (uint256 i; i < len;) {
            _allocate(targets[i], assets[i]);
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         DE-ALLOCATE (WITHDRAW/REDEEM)
    //////////////////////////////////////////////////////////////*/

    function _withdrawAllocation(address target, uint256 assets, address receiver) internal virtual {
        if (assets == 0) return;
        uint256 beforeBal = IERC20(_allocationAsset()).balanceOf(receiver);
        bytes32 key = VaultAdapter.tryRequestWithdraw(target, assets, receiver, address(this));
        uint256 afterBal = IERC20(_allocationAsset()).balanceOf(receiver);
        uint256 immediate = afterBal > beforeBal ? (afterBal - beforeBal) : 0;
        uint256 pending = assets > immediate ? (assets - immediate) : 0;
        emit AllocationWithdrawn(target, receiver, assets, key);
        if (key != bytes32(0)) {
            AllocationStorage storage $ = _getAllocationStorage();
            $.claimableTargets.add(target);
            $.withdrawKeysByTarget[target].add(key);
            if (pending > 0) {
                $.requestedAssetsByKey[target][key] = pending;
            }
        }
        _maybePruneAllocated(target);
    }

    function _redeemAllocation(address target, uint256 shares, address receiver) internal virtual {
        if (shares == 0) return;
        uint256 previewAssets = VaultAdapter.tryPreviewAssets(target, shares);
        uint256 beforeBal = IERC20(_allocationAsset()).balanceOf(receiver);
        bytes32 key = VaultAdapter.tryRequestRedeem(target, shares, receiver, address(this));
        uint256 afterBal = IERC20(_allocationAsset()).balanceOf(receiver);
        uint256 immediate = afterBal > beforeBal ? (afterBal - beforeBal) : 0;
        uint256 pending = previewAssets > immediate ? (previewAssets - immediate) : 0;
        emit AllocationRedeemed(target, receiver, shares, key);
        if (key != bytes32(0)) {
            AllocationStorage storage $ = _getAllocationStorage();
            $.claimableTargets.add(target);
            $.withdrawKeysByTarget[target].add(key);
            if (pending > 0) {
                $.requestedAssetsByKey[target][key] = pending;
            }
        }
        _maybePruneAllocated(target);
    }

    function _withdrawAllocationBatch(address[] memory targets, uint256[] memory assets, address receiver)
        internal
        virtual
    {
        uint256 len = targets.length;
        if (assets.length != len) revert AAM__InvalidInputLength();
        for (uint256 i; i < len;) {
            _withdrawAllocation(targets[i], assets[i], receiver);
            unchecked {
                ++i;
            }
        }
    }

    function _redeemAllocationBatch(address[] memory targets, uint256[] memory shares, address receiver)
        internal
        virtual
    {
        uint256 len = targets.length;
        if (shares.length != len) revert AAM__InvalidInputLength();
        for (uint256 i; i < len;) {
            _redeemAllocation(targets[i], shares[i], receiver);
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CLAIM
    //////////////////////////////////////////////////////////////*/

    function _claimAllocations() internal virtual {
        AllocationStorage storage $ = _getAllocationStorage();
        address[] memory targets = $.claimableTargets.values();
        uint256 len = targets.length;
        for (uint256 i; i < len;) {
            address target = targets[i];
            bytes32[] memory keys = $.withdrawKeysByTarget[target].values();
            uint256 keyLen = keys.length;
            bool allDone = true;
            for (uint256 j; j < keyLen;) {
                bytes32 key = keys[j];
                bool isClaimable = VaultAdapter.tryIsClaimable(target, key);
                if (isClaimable) {
                    // claim to this contract
                    VaultAdapter.tryClaim(target, key);
                    _removeWithdrawKey(target, key);
                } else if (VaultAdapter.tryIsClaimed(target, key)) {
                    _removeWithdrawKey(target, key);
                } else {
                    // Check whether the request was claimed externally (defensive)
                    // If the target doesn't expose state, we keep the key until claimable
                    allDone = false;
                }
                unchecked {
                    ++j;
                }
            }
            if (allDone) {
                $.claimableTargets.remove(target);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    function allocatedTargets() public view returns (address[] memory) {
        return _getAllocationStorage().allocatedTargets.values();
    }

    function claimableTargets() public view returns (address[] memory) {
        return _getAllocationStorage().claimableTargets.values();
    }

    function withdrawKeysFor(address target) public view returns (bytes32[] memory) {
        return _getAllocationStorage().withdrawKeysByTarget[target].values();
    }

    function allocatedAssets() public view returns (uint256 assets) {
        address[] memory targets = allocatedTargets();
        uint256 len = targets.length;
        for (uint256 i; i < len;) {
            address target = targets[i];
            assets += allocatedAssetsFor(target);
            unchecked {
                ++i;
            }
        }
    }

    function allocatedAssetsFor(address target) public view returns (uint256 assets) {
        uint256 shares = VaultAdapter.shareBalanceOf(target, address(this));
        if (shares > 0) {
            assets = VaultAdapter.tryPreviewAssets(target, shares);
        }
        return assets;
    }

    /// @notice Totals across outstanding withdraw keys tracked by this manager
    /// @return pendingRequested sum of requested-but-not-yet-claimable assets
    /// @return claimable sum of requested-and-claimable assets
    function allocationPendingAndClaimable() public view returns (uint256 pendingRequested, uint256 claimable) {
        AllocationStorage storage $ = _getAllocationStorage();
        address[] memory targets = $.claimableTargets.values();
        uint256 len = targets.length;
        for (uint256 i; i < len;) {
            address target = targets[i];
            bytes32[] memory keys = $.withdrawKeysByTarget[target].values();
            uint256 keyLen = keys.length;
            for (uint256 j; j < keyLen;) {
                bytes32 key = keys[j];
                unchecked {
                    ++j;
                }
                if (VaultAdapter.tryIsClaimed(target, key)) {
                    continue;
                }
                uint256 amt = $.requestedAssetsByKey[target][key];
                bool ok = VaultAdapter.tryIsClaimable(target, key);
                if (ok) {
                    claimable += amt;
                } else {
                    pendingRequested += amt;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _removeWithdrawKey(address target, bytes32 key) private {
        AllocationStorage storage $ = _getAllocationStorage();
        $.withdrawKeysByTarget[target].remove(key);
        delete $.requestedAssetsByKey[target][key];
    }

    function _maybePruneAllocated(address target) private {
        if (VaultAdapter.shareBalanceOf(target, address(this)) == 0) {
            _getAllocationStorage().allocatedTargets.remove(target);
        }
    }
}
