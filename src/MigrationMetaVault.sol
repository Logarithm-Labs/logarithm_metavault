// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {MetaVault} from "./MetaVault.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract MigrationMetaVault is MetaVault {
    error MigrationExceededMaxShares();
    error MigrationZeroShares();

    function migrate(address targetVault, uint256 targetShares, address receiver) public virtual returns (uint256) {
        if (targetShares == 0) {
            revert MigrationZeroShares();
        }
        _validateTarget(targetVault);
        uint256 maxShares = IERC4626(targetVault).balanceOf(_msgSender());
        if (targetShares > maxShares) {
            revert MigrationExceededMaxShares();
        }

        uint256 assets = IERC4626(targetVault).previewRedeem(targetShares);
        uint256 shares = previewDeposit(assets);
        IERC4626(targetVault).transferFrom(_msgSender(), address(this), targetShares);
        _updateHwmDeposit(assets);
        _mint(receiver, shares);

        return shares;
    }
}
