// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ILogarithmVault} from "./interfaces/ILogarithmVault.sol";

library VaultAdapter {
    /// @notice Request to withdraw assets from a target vault. Falls back to synchronous withdraw if async is unsupported.
    /// @return withdrawKey bytes32(0) if fulfilled synchronously; non-zero for async requests.
    function tryRequestWithdraw(address target, uint256 assets, address receiver, address owner)
        internal
        returns (bytes32 withdrawKey)
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
    /// @return withdrawKey bytes32(0) if fulfilled synchronously; non-zero for async requests.
    function tryRequestRedeem(address target, uint256 shares, address receiver, address owner)
        internal
        returns (bytes32 withdrawKey)
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
    function tryClaim(address target, bytes32 withdrawKey) internal returns (uint256 assets) {
        return ILogarithmVault(target).claim(withdrawKey);
    }

    /// @notice Preview assets for a given amount of shares on a target vault.
    /// @dev Tries previewRedeem first; falls back to convertToAssets.
    function tryPreviewAssets(address target, uint256 shares) internal view returns (uint256 assets) {
        try IERC4626(target).previewRedeem(shares) returns (uint256 previewAssets) {
            return previewAssets;
        } catch {
            return IERC4626(target).convertToAssets(shares);
        }
    }

    /// @notice Returns the current share balance held by holder for the target vault.
    function shareBalanceOf(address target, address holder) internal view returns (uint256) {
        return IERC4626(target).balanceOf(holder);
    }

    /// @notice Returns the asset token address for the target vault.
    function asset(address target) internal view returns (address) {
        return IERC4626(target).asset();
    }
}
