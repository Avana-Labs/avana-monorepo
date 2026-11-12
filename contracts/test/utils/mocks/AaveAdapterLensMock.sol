// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IProxyManager} from "../../../src/proxy/proxy-manager/IProxyManager.sol";

/// @notice The AaveAdapter views the Lens reads, as spec 2.6 defines them (`REQ-ADAPTER-066`, `REQ-PROXY-049`):
/// `proxyOf(wallet, marketId)` (0 before the first pledge), `accountOf(proxy)` (the binding stored at creation; spoke 0
/// for a proxy the Adapter did not create), `walletOf(proxy)`, `borrowNonce(proxy)` and `predictProxy(wallet,
/// marketId)` (the stored proxy, else the ProxyManager's prediction with the market's CDP Spoke). The Lens suites bind
/// accounts with `bind`; the lead swaps in the real AaveAdapter after the merge.
contract AaveAdapterLensMock {
    struct Binding {
        address spoke;
        uint256 marketId;
        address vaultToken;
        uint256 reserveId;
        address wallet;
    }

    mapping(address => mapping(uint256 => address)) public proxyOf;
    mapping(address => Binding) internal _bindings;
    mapping(address => uint256) public borrowNonce;
    mapping(uint256 => address) internal _spokeOf;
    address public proxyManager;

    function setProxyManager(
        address pm
    ) external {
        proxyManager = pm;
    }

    function bind(
        address wallet,
        address proxy,
        address spoke,
        uint256 marketId,
        address vaultToken,
        uint256 reserveId
    ) external {
        proxyOf[wallet][marketId] = proxy;
        _bindings[proxy] = Binding(spoke, marketId, vaultToken, reserveId, wallet);
        _spokeOf[marketId] = spoke;
    }

    function setNonce(
        address proxy,
        uint256 nonce
    ) external {
        borrowNonce[proxy] = nonce;
    }

    function accountOf(
        address proxy
    ) external view returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId) {
        Binding memory b = _bindings[proxy];
        (spoke, marketId, vaultToken, reserveId) = (b.spoke, b.marketId, b.vaultToken, b.reserveId);
    }

    function walletOf(
        address proxy
    ) external view returns (address) {
        return _bindings[proxy].wallet;
    }

    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy) {
        proxy = proxyOf[wallet][marketId];
        if (proxy == address(0)) {
            proxy = IProxyManager(proxyManager).predictProxy(wallet, _spokeOf[marketId], marketId);
        }
    }
}
