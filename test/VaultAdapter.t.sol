// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Test} from "forge-std/Test.sol";

import {VaultAdapter} from "src/library/VaultAdapter.sol";

contract MockLogarithmVault {

    uint256 public exitCost;
    uint256 public entryCost;

    constructor(uint256 _exitCost, uint256 _entryCost) {
        exitCost = _exitCost;
        entryCost = _entryCost;
    }

}

contract VaultAdapterTest is Test {

    address owner = makeAddr("owner");

    ERC20Mock asset;
    MockLogarithmVault logVaultOne;
    MockLogarithmVault logVaultTwo;
    MockLogarithmVault logVaultThree;
    MockLogarithmVault logVaultFour;

    function setUp() public {
        vm.startPrank(owner);
        asset = new ERC20Mock();
        logVaultOne = new MockLogarithmVault(0.001 ether, 0.001 ether);
        logVaultTwo = new MockLogarithmVault(0.002 ether, 0.002 ether);
        logVaultThree = new MockLogarithmVault(0.003 ether, 0.003 ether);
        logVaultFour = new MockLogarithmVault(0.004 ether, 0.004 ether);
    }

    function test_insertionSortTargetsByExitCost_ascending() public view {
        address[] memory targets = new address[](4);
        targets[0] = address(logVaultFour);
        targets[1] = address(logVaultTwo);
        targets[2] = address(logVaultThree);
        targets[3] = address(logVaultOne);

        VaultAdapter.insertionSortTargetsByExitCost(targets, 4, true);

        assertEq(targets[0], address(logVaultOne));
        assertEq(targets[1], address(logVaultTwo));
        assertEq(targets[2], address(logVaultThree));
        assertEq(targets[3], address(logVaultFour));
    }

    function test_insertionSortTargetsByExitCost_descending() public view {
        address[] memory targets = new address[](4);
        targets[0] = address(logVaultFour);
        targets[1] = address(logVaultTwo);
        targets[2] = address(logVaultThree);
        targets[3] = address(logVaultOne);

        VaultAdapter.insertionSortTargetsByExitCost(targets, 4, false);

        assertEq(targets[0], address(logVaultFour));
        assertEq(targets[1], address(logVaultThree));
        assertEq(targets[2], address(logVaultTwo));
        assertEq(targets[3], address(logVaultOne));
    }

    function test_cost_total_to_raw() public pure {
        uint256 totalAssets = 1 ether;
        uint256 costBpsOrRate = 0.01 ether;
        uint256 costOnTotal = VaultAdapter.costOnTotal(totalAssets, costBpsOrRate);
        uint256 effectiveAssets = totalAssets - costOnTotal;
        uint256 costOnRaw = VaultAdapter.costOnRaw(effectiveAssets, costBpsOrRate);
        assertEq(costOnRaw, costOnTotal);
    }

    function test_cost_raw_to_total() public pure {
        uint256 rawAssets = 1 ether;
        uint256 costBpsOrRate = 0.001 ether;
        uint256 costOnRaw = VaultAdapter.costOnRaw(rawAssets, costBpsOrRate);
        uint256 totalAssets = rawAssets + costOnRaw;
        uint256 costOnTotal = VaultAdapter.costOnTotal(totalAssets, costBpsOrRate);
        assertEq(costOnTotal, costOnRaw);
    }

    function test_cost_total_to_raw_bps() public pure {
        uint256 totalAssets = 1 ether;
        uint256 costBpsOrRate = 100;
        uint256 costOnTotal = VaultAdapter.costOnTotal(totalAssets, costBpsOrRate);
        uint256 effectiveAssets = totalAssets - costOnTotal;
        uint256 costOnRaw = VaultAdapter.costOnRaw(effectiveAssets, costBpsOrRate);
        assertEq(costOnRaw, costOnTotal);
    }

    function test_cost_raw_to_total_bps() public pure {
        uint256 rawAssets = 1 ether;
        uint256 costBpsOrRate = 100;
        uint256 costOnRaw = VaultAdapter.costOnRaw(rawAssets, costBpsOrRate);
        uint256 totalAssets = rawAssets + costOnRaw;
        uint256 costOnTotal = VaultAdapter.costOnTotal(totalAssets, costBpsOrRate);
        assertEq(costOnTotal, costOnRaw);
    }

}
