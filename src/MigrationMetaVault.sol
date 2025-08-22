// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MetaVault} from "./MetaVault.sol";
import {VaultAdapter} from "./library/VaultAdapter.sol";

contract MigrationMetaVault is MetaVault {
    using SafeERC20 for IERC20;

    event Migrated(
        address indexed owner, address indexed targetVault, uint256 targetShares, uint256 assets, uint256 shares
    );

    error MigrationExceededMaxShares();
    error MigrationZeroShares();

    /// @notice Migrate shares from target vault to meta vault
    function migrate(address targetVault, uint256 targetShares, address receiver) public virtual returns (uint256) {
        if (targetShares == 0) {
            revert MigrationZeroShares();
        }
        _validateTarget(targetVault);
        uint256 maxShares = VaultAdapter.shareBalanceOf(targetVault, _msgSender());
        if (targetShares > maxShares) {
            revert MigrationExceededMaxShares();
        }

        (uint256 assets, uint256 shares) = convertTargetShares(targetVault, targetShares);
        _migrate(receiver, _msgSender(), targetVault, targetShares, assets, shares);
        _withdrawTargetIdleAssets(targetVault);

        return shares;
    }

    /// @notice Convert target shares to assets and shares
    function convertTargetShares(address targetVault, uint256 targetShares)
        public
        view
        returns (uint256 assets, uint256 shares)
    {
        assets = VaultAdapter.tryPreviewAssets(targetVault, targetShares);
        // don't use preview functions to avoid entry cost
        shares = convertToShares(assets);
    }

    /// @dev Migrate shares from target vault to meta vault
    function _migrate(
        address receiver,
        address owner,
        address targetVault,
        uint256 targetShares,
        uint256 assets,
        uint256 shares
    ) internal virtual {
        IERC20(targetVault).safeTransferFrom(owner, address(this), targetShares);
        _addAllocatedTarget(targetVault);
        _updateHwmDeposit(assets);
        _mint(receiver, shares);

        emit Migrated(owner, targetVault, targetShares, assets, shares);
    }

    /// @dev Withdraw idle assets from target vault to avoid duplicated consideration with multiple migrations
    function _withdrawTargetIdleAssets(address targetVault) internal virtual {
        uint256 immediateAssets = VaultAdapter.maxWithdraw(targetVault, address(this));
        if (immediateAssets > 0) {
            _withdrawAllocation(targetVault, immediateAssets, address(this));
        }
    }
}
