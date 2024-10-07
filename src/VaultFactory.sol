// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IMetaVault} from "src/interfaces/IMetaVault.sol";
import {IPriorityProvider} from "src/interfaces/IPriorityProvider.sol";

/// @title Factory to create vaults
/// @author Logarithm Labs
/// @notice The factory allows permissionless creation of upgradeable or non-upgradeable proxy contracts and serves as a
/// beacon for the upgradeable ones
contract VaultFactory is UpgradeableBeacon, IPriorityProvider {
    using Clones for address;

    /// @title ProxyConfig
    /// @notice This struct is used to store the configuration of a proxy deployed by the factory
    struct ProxyConfig {
        // If true, proxy is an instance of the BeaconProxy
        bool upgradeable;
        // Address of the implementation contract
        // May be an out-of-date value, if upgradeable (handled by getProxyConfig)
        address implementation;
    }

    /// @notice An address of the whitelist provider which whitelist only logarithm vaults
    address public whitelistProvider;

    /// @notice A lookup for configurations of the proxy contracts deployed by the factory
    mapping(address proxy => ProxyConfig) internal proxyLookup;
    /// @notice An array of addresses of all the proxies deployed by the factory
    address[] public proxyList;

    event ProxyCreated(address indexed proxy, bool indexed upgradeable, address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error VF__BadQuery();

    constructor(address whitelistProvider_, address implementation_, address initialOwner)
        UpgradeableBeacon(implementation_, initialOwner)
    {
        whitelistProvider = whitelistProvider_;
    }

    /// @notice A permissionless function to deploy new proxies for meta vault
    ///
    /// @param upgradeable If true, the proxy will be an instance of the BeaconProxy. If false, a minimal proxy
    /// will be deployed
    ///
    /// @param name Vault name
    ///
    /// @param symbol Vault symbol
    ///
    /// @return The address of the new proxy
    function createVault(bool upgradeable, address underlyingAsset, string calldata name, string calldata symbol)
        external
        returns (address)
    {
        address _implementation = implementation();

        address proxy;

        if (upgradeable) {
            proxy = address(
                new BeaconProxy(
                    address(this),
                    abi.encodeWithSelector(
                        IMetaVault.initialize.selector, whitelistProvider, msg.sender, underlyingAsset, name, symbol
                    )
                )
            );
        } else {
            proxy = _implementation.clone();
            IMetaVault(proxy).initialize(whitelistProvider, msg.sender, underlyingAsset, name, symbol);
        }

        proxyLookup[proxy] = ProxyConfig({upgradeable: upgradeable, implementation: _implementation});

        proxyList.push(proxy);

        emit ProxyCreated(proxy, upgradeable, _implementation);

        return proxy;
    }

    /// @notice Get current proxy configuration
    ///
    /// @param proxy Address of the proxy to query
    ///
    /// @return config The proxy's configuration, including current implementation
    function getProxyConfig(address proxy) external view returns (ProxyConfig memory config) {
        config = proxyLookup[proxy];
        if (config.upgradeable) config.implementation = implementation();
    }

    /// @notice Check if an address is a proxy deployed with this factory
    ///
    /// @param proxy Address to check
    ///
    /// @return True if the address is a proxy
    function isProxy(address proxy) public view returns (bool) {
        return proxyLookup[proxy].implementation != address(0);
    }

    /// @notice Used in the Logarithm vault to decide the withdrawal priority
    ///
    /// @param account Address of withdrawal request owner
    ///
    /// @return True if the owner is the proxy by the factory
    function isPrioritized(address account) external view returns (bool) {
        return isProxy(account);
    }

    /// @notice Fetch the length of the deployed proxies list
    ///
    /// @return The length of the proxy list array
    function getProxyListLength() external view returns (uint256) {
        return proxyList.length;
    }

    /// @notice Get a slice of the deployed proxies array
    ///
    /// @param start Start index of the slice
    ///
    /// @param end End index of the slice
    ///
    /// @return list An array containing the slice of the proxy list
    function getProxyListSlice(uint256 start, uint256 end) external view returns (address[] memory list) {
        if (end == type(uint256).max) end = proxyList.length;
        if (end < start || end > proxyList.length) revert VF__BadQuery();

        list = new address[](end - start);
        for (uint256 i; i < end - start; ++i) {
            list[i] = proxyList[start + i];
        }
    }
}
