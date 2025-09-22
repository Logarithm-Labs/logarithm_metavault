// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

contract SharePrice is Script {
    address[] VAULTS = [
        0x9c6864105AEC23388C89600046213a44C384c831,
        0x3128a0F7f0ea68E7B7c9B00AFa7E41045828e858,
        0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183,
        0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca,
        0x616a4E1db48e22028f6bbf20444Cd3b8e3273738
    ];

    uint256 constant BLOCKS_PER_DAY = 24 * 60 * 60 / 2; // 2 seconds per block

    function run() public {
        // get the historical total assets and shares of the vaults
        // for the past 90 days, every 24 hours
        uint256 blockNumber = 35880642;
        for (uint256 d = 0; d < 90; d++) {
            blockNumber -= BLOCKS_PER_DAY;
            vm.createSelectFork("base", blockNumber);
            for (uint256 i = 0; i < VAULTS.length; i++) {
                address vault = VAULTS[i];
                string memory vaultSymbol = IERC4626(vault).symbol();
                uint256 sharePrice = IERC4626(vault).convertToAssets(10 ** IERC4626(vault).decimals());
                console.log("%s: %s: %s", vaultSymbol, block.timestamp, sharePrice);
            }
        }
    }
}
