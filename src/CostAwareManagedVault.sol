// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ManagedVault} from "@managed_basis/vault/ManagedVault.sol";

/// @title CostAwareManagedVault
/// @author Logarithm Labs
/// @notice Base contract for vaults that need to charge a cost for deposits and withdrawals
/// @dev This contract is used to charge a cost for deposits and withdrawals
/// @dev The cost is charged in the form of a percentage of the total assets
abstract contract CostAwareManagedVault is ManagedVault {
    using Math for uint256;

    uint256 private constant _BASIS_POINT_SCALE = 1e4; // 100%
    uint256 private constant _MAX_ENTRY_COST_BPS = 100; // 1%

    event EntryCostUpdated(address indexed caller, uint256 newCost);

    error MVC__EntryCostExceedMaxLimit();

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.ManagedVaultWithCost
    struct ManagedVaultWithCostStorage {
        uint256 entryCostBps;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedVaultWithCost")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MANAGED_VAULT_WITH_COST_STORAGE_LOCATION =
        0x43d1391ea5b1f9854179c6ec1827b969ede7cdf416fcafb3966f660ba465bc00;

    function _getManagedVaultWithCostStorage() private pure returns (ManagedVaultWithCostStorage storage $) {
        assembly {
            $.slot := MANAGED_VAULT_WITH_COST_STORAGE_LOCATION
        }
    }

    function _setEntryCost(uint256 costBps) internal {
        if (costBps > _MAX_ENTRY_COST_BPS) {
            revert MVC__EntryCostExceedMaxLimit();
        }
        _getManagedVaultWithCostStorage().entryCostBps = costBps;
        emit EntryCostUpdated(_msgSender(), costBps);
    }

    /*//////////////////////////////////////////////////////////////
                            COST PROCESSING
    //////////////////////////////////////////////////////////////*/

    /// @dev Process the cost
    function _processCost(uint256 cost) internal virtual;

    /*//////////////////////////////////////////////////////////////
                            ADMIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the entry cost
    /// @param costBps The entry cost in basis points
    function setEntryCost(uint256 costBps) external onlyOwner {
        _setEntryCost(costBps);
    }

    /*//////////////////////////////////////////////////////////////
                              VAULT LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        (uint256 shares,) = _previewDepositWithCost(assets);
        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        (uint256 assets,) = _previewMintWithCost(shares);
        return assets;
    }

    function _previewDepositWithCost(uint256 assets) private view returns (uint256 shares, uint256 cost) {
        cost = _costOnTotal(assets, entryCostBps());
        assets -= cost;

        shares = _convertToShares(assets, Math.Rounding.Floor);
        return (shares, cost);
    }

    function _previewMintWithCost(uint256 shares) private view returns (uint256 assets, uint256 cost) {
        assets = _convertToAssets(shares, Math.Rounding.Ceil);
        cost = _costOnRaw(assets, entryCostBps());
        assets += cost;
        return (assets, cost);
    }

    /// @inheritdoc ERC4626Upgradeable
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        (uint256 shares, uint256 cost) = _previewDepositWithCost(assets);

        _deposit(_msgSender(), receiver, assets, shares);

        _processCost(cost);

        return shares;
    }

    /// @inheritdoc ERC4626Upgradeable
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        (uint256 assets, uint256 cost) = _previewMintWithCost(shares);

        _deposit(_msgSender(), receiver, assets, shares);

        _processCost(cost);

        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calculates the cost that should be added to an amount `assets` that does not include cost.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _costOnRaw(uint256 assets, uint256 costBps) private pure returns (uint256) {
        return assets.mulDiv(costBps, _BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    /// @dev Calculates the cost part of an amount `assets` that already includes cost.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _costOnTotal(uint256 assets, uint256 costBps) private pure returns (uint256) {
        return assets.mulDiv(costBps, costBps + _BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

    function entryCostBps() public view returns (uint256) {
        return _getManagedVaultWithCostStorage().entryCostBps;
    }
}
