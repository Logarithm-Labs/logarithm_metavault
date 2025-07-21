// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import "erc4626-tests/ERC4626.test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MetaVault} from "src/MetaVault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC4626StdTest is ERC4626Test {
    function setUp() public override {
        _underlying_ = address(new ERC20Mock());
        _vault_ = address(
            new ERC1967Proxy(
                address(new MetaVault()),
                abi.encodeWithSelector(
                    MetaVault.initialize.selector, address(0), address(this), _underlying_, "Mock ERC4626", "MERC4626"
                )
            )
        );
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = true;
    }
}
