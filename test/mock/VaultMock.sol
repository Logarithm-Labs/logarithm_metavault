// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract VaultMock {

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function name() public pure returns (string memory) {
        return "VaultMock";
    }

    function symbol() public pure returns (string memory) {
        return "VM";
    }

    function asset() public pure returns (address) {
        return address(0);
    }

}
