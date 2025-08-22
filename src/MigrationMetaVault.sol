// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {MetaVault} from "./MetaVault.sol";
import {VaultAdapter} from "./library/VaultAdapter.sol";

contract MigrationMetaVault is MetaVault {
    using SafeERC20 for IERC20;

    error MigrationExceededMaxShares();
    error MigrationZeroShares();

    function migrate(address targetVault, uint256 targetShares, address receiver) public virtual returns (uint256) {
        if (targetShares == 0) {
            revert MigrationZeroShares();
        }
        _validateTarget(targetVault);
        uint256 maxShares = VaultAdapter.shareBalanceOf(targetVault, _msgSender());
        if (targetShares > maxShares) {
            revert MigrationExceededMaxShares();
        }

        uint256 assets = VaultAdapter.tryPreviewAssets(targetVault, targetShares);
        uint256 shares = convertToShares(assets);
        IERC20(targetVault).safeTransferFrom(_msgSender(), address(this), targetShares);
        _updateHwmDeposit(assets);
        _mint(receiver, shares);

        return shares;
    }
}
