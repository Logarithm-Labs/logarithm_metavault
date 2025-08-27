// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILogarithmVault} from "../interfaces/ILogarithmVault.sol";

library VaultAdapter {
    using Math for uint256;

    uint256 private constant _BASIS_POINT_SCALE = 1e4; // 100%

    /// @notice Deposit assets into a target vault.
    function deposit(address target, uint256 assets, address receiver) internal returns (uint256) {
        return IERC4626(target).deposit(assets, receiver);
    }

    /// @notice Request to withdraw assets from a target vault. Falls back to synchronous withdraw if async is unsupported.
    /// @return bytes32(0) if fulfilled synchronously; non-zero for async requests.
    function tryRequestWithdraw(address target, uint256 assets, address receiver, address owner)
        internal
        returns (bytes32)
    {
        // Prefer async interface if supported
        try ILogarithmVault(target).requestWithdraw(assets, receiver, owner) returns (bytes32 key) {
            return key;
        } catch {
            // Fallback to standard ERC4626 withdraw
            IERC4626(target).withdraw(assets, receiver, owner);
            return bytes32(0);
        }
    }

    /// @notice Request to redeem shares from a target vault. Falls back to synchronous redeem if async is unsupported.
    /// @return bytes32(0) if fulfilled synchronously; non-zero for async requests.
    function tryRequestRedeem(address target, uint256 shares, address receiver, address owner)
        internal
        returns (bytes32)
    {
        // Prefer async interface if supported
        try ILogarithmVault(target).requestRedeem(shares, receiver, owner) returns (bytes32 key) {
            return key;
        } catch {
            // Fallback to standard ERC4626 redeem
            IERC4626(target).redeem(shares, receiver, owner);
            return bytes32(0);
        }
    }

    /// @notice Returns whether a given withdraw key is claimable on a target vault.
    /// @dev Returns false if async interface is not implemented.
    function tryIsClaimable(address target, bytes32 withdrawKey) internal view returns (bool) {
        try ILogarithmVault(target).isClaimable(withdrawKey) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    /// @notice Returns whether a given withdraw key is claimed on a target vault.
    /// @dev Returns false if async interface is not implemented.
    function tryIsClaimed(address target, bytes32 withdrawKey) internal view returns (bool) {
        try ILogarithmVault(target).withdrawRequests(withdrawKey) returns (
            ILogarithmVault.WithdrawRequest memory request
        ) {
            return request.isClaimed;
        } catch {
            return false;
        }
    }

    /// @notice Claims assets for a given withdraw key on a target vault.
    /// @dev Reverts if async interface is not implemented. Callers should check tryIsClaimable first.
    function tryClaim(address target, bytes32 withdrawKey) internal returns (uint256) {
        try ILogarithmVault(target).claim(withdrawKey) returns (uint256 assets) {
            return assets;
        } catch {
            return 0;
        }
    }

    /// @notice Preview assets for a given amount of shares on a target vault.
    /// @dev Tries previewRedeem first; falls back to convertToAssets.
    function tryPreviewAssets(address target, uint256 shares) internal view returns (uint256) {
        try IERC4626(target).previewRedeem(shares) returns (uint256 previewAssets) {
            return previewAssets;
        } catch {
            return IERC4626(target).convertToAssets(shares);
        }
    }

    /// @notice Convert assets to shares on a target vault.
    function convertToShares(address target, uint256 assets) internal view returns (uint256) {
        return IERC4626(target).convertToShares(assets);
    }

    /// @notice Preview shares for a given amount of assets on a target vault.
    /// @dev Tries previewAssets first; falls back to convertToShares.
    function tryPreviewShares(address target, uint256 assets) internal view returns (uint256) {
        try IERC4626(target).previewWithdraw(assets) returns (uint256 previewShares) {
            return previewShares;
        } catch {
            return IERC4626(target).convertToShares(assets);
        }
    }

    /// @notice Convert shares to assets on a target vault.
    function convertToAssets(address target, uint256 shares) internal view returns (uint256) {
        return IERC4626(target).convertToAssets(shares);
    }

    /// @notice Returns the current share balance held by holder for the target vault.
    function shareBalanceOf(address target, address holder) internal view returns (uint256) {
        return IERC4626(target).balanceOf(holder);
    }

    /// @notice Returns the asset token address for the target vault.
    function asset(address target) internal view returns (address) {
        return IERC4626(target).asset();
    }

    function tryMaxRequestWithdraw(address target, address holder) internal view returns (uint256) {
        try ILogarithmVault(target).maxRequestWithdraw(holder) returns (uint256 assets) {
            return assets;
        } catch {
            return 0;
        }
    }

    function tryMaxRequestRedeem(address target, address holder) internal view returns (uint256) {
        try ILogarithmVault(target).maxRequestRedeem(holder) returns (uint256 shares) {
            return shares;
        } catch {
            return 0;
        }
    }

    function maxWithdraw(address target, address holder) internal view returns (uint256) {
        return IERC4626(target).maxWithdraw(holder);
    }

    function maxRedeem(address target, address holder) internal view returns (uint256) {
        return IERC4626(target).maxRedeem(holder);
    }

    /// @notice Returns the idle assets available in a target vault.
    /// @dev Returns 0 if the target doesn't support idle assets (e.g., standard ERC4626 vaults).
    function tryIdleAssets(address target) internal view returns (uint256) {
        try ILogarithmVault(target).idleAssets() returns (uint256 idleAssets) {
            return idleAssets;
        } catch {
            // For non-LogarithmVaults, return 0 (no idle assets concept)
            return 0;
        }
    }

    /// @notice Returns the entry cost for a target vault.
    /// @dev Returns 0 if the target doesn't support entry costs (e.g., standard ERC4626 vaults).
    function tryEntryCost(address target) internal view returns (uint256) {
        try ILogarithmVault(target).entryCost() returns (uint256 entryCost) {
            return entryCost;
        } catch {
            // For non-LogarithmVaults, return 0 (highest priority)
            return 0;
        }
    }

    /// @notice Returns the exit cost for a target vault.
    /// @dev Returns 0 if the target doesn't support exit costs (e.g., standard ERC4626 vaults).
    function tryExitCost(address target) internal view returns (uint256) {
        try ILogarithmVault(target).exitCost() returns (uint256 exitCost) {
            return exitCost;
        } catch {
            // For non-LogarithmVaults, return 0 (no exit cost concept)
            return 0;
        }
    }

    function tryExitCostOnRaw(address target, uint256 assets) internal view returns (uint256) {
        uint256 exitCost = tryExitCost(target);
        if (exitCost == 0) return 0;
        return costOnRaw(assets, exitCost);
    }

    function tryExitCostOnTotal(address target, uint256 assets) internal view returns (uint256) {
        uint256 exitCost = tryExitCost(target);
        if (exitCost == 0) return 0;
        return costOnTotal(assets, exitCost);
    }

    /// @dev Calculates the cost that should be added to an amount `assets` that does not include cost.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function costOnRaw(uint256 assets, uint256 costBpsOrRate) internal pure returns (uint256) {
        uint256 denominator = costBpsOrRate > _BASIS_POINT_SCALE ? 1 ether : _BASIS_POINT_SCALE;
        return assets.mulDiv(costBpsOrRate, denominator, Math.Rounding.Ceil);
    }

    /// @dev Calculates the cost part of an amount `assets` that already includes cost.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function costOnTotal(uint256 assets, uint256 costBpsOrRate) internal pure returns (uint256) {
        uint256 denominator =
            costBpsOrRate > _BASIS_POINT_SCALE ? costBpsOrRate + 1 ether : costBpsOrRate + _BASIS_POINT_SCALE;
        return assets.mulDiv(costBpsOrRate, denominator, Math.Rounding.Ceil);
    }

    /// @dev Calculates the remaining shares after redeeming for idle assets.
    function tryPreviewRemainingSharesAfterIdleAssets(address target, address holder) internal view returns (uint256) {
        uint256 shares = shareBalanceOf(target, holder);
        uint256 idleAssets = tryIdleAssets(target);
        if (idleAssets == 0) return shares;
        uint256 idleShares = tryPreviewShares(target, idleAssets);
        return shares > idleShares ? shares - idleShares : 0;
    }

    /// @dev Insertion sort for targets by exit cost
    /// @param targets Array of target vault addresses
    /// @param length The length of the array to sort
    function insertionSortTargetsByExitCost(address[] memory targets, uint256 length, bool ascending) internal view {
        if (length <= 1) return;

        for (uint256 i = 1; i < length;) {
            address key = targets[i];
            uint256 keyExitCost = VaultAdapter.tryExitCost(key);
            uint256 j;

            unchecked {
                j = i - 1;
            }

            while (
                j != type(uint256).max
                    && (
                        ascending
                            ? VaultAdapter.tryExitCost(targets[j]) > keyExitCost
                            : VaultAdapter.tryExitCost(targets[j]) < keyExitCost
                    )
            ) {
                unchecked {
                    targets[j + 1] = targets[j];
                    --j;
                }
            }

            unchecked {
                targets[j + 1] = key;
                ++i;
            }
        }
    }
}
