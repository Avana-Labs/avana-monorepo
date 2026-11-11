// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../src/proxy/proxy-manager/IProxyManager.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {FreezeRegistryMock} from "../utils/mocks/ProxyMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title ProxyManagerHalmosTest
/// @notice Symbolic checks of the ProxyManager for every caller, triple and freeze state: `deployProxy` succeeds only
/// for the Adapter, a non-zero triple without a proxy and a wallet that is not frozen, deploys at exactly
/// `predictProxy` with the triple bound, refuses a second deployment of the triple, and every refusal carries the
/// error of the first failing check.
/// @dev The Adapter is a fixed concrete address and the MarketRegistry is the freeze-only mock; the caller, the
/// triple and the freeze flag are symbolic.
contract ProxyManagerHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);

    FreezeRegistryMock internal registry;
    ProxyManager internal manager;

    function setUp() public {
        registry = new FreezeRegistryMock();
        manager = new ProxyManager(ADAPTER, address(registry));
    }

    // PROP-064 verifies: REQ-PROXY-051, REQ-PROXY-052, REQ-PROXY-097, REQ-PROXY-099, REQ-PROXY-102, INV-012, INV-064, Q-225, Q-242
    /// @notice A success is the Adapter's call for a non-zero triple of a wallet not frozen, at `predictProxy`, with the
    /// triple and the Adapter bound in the new proxy; a refusal names the first failing check; `predictProxy` answers
    /// exactly for non-zero triples.
    function check_PROP_064_deployOnlyAdapterAtPredicted(
        address caller,
        address wallet,
        address spoke,
        uint256 marketId,
        bool frozen
    ) public {
        registry.setFrozen(wallet, frozen);
        bool zero = wallet == address(0) || spoke == address(0) || marketId == 0;
        (bool predictOk, bytes memory predictRet) =
            address(manager).staticcall(abi.encodeCall(IProxyManager.predictProxy, (wallet, spoke, marketId)));
        // `predictProxy` answers exactly for the triples `deployProxy` can deploy.
        assert(predictOk == !zero);
        address predicted = predictOk ? abi.decode(predictRet, (address)) : address(0);
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(manager).call(abi.encodeCall(IProxyManager.deployProxy, (wallet, spoke, marketId)));
        if (ok) {
            assert(caller == ADAPTER && !zero && !frozen);
            address proxy = abi.decode(ret, (address));
            assert(proxy == predicted && proxy != address(0));
            assert(IPositionProxy(proxy).ADAPTER() == ADAPTER);
            assert(IPositionProxy(proxy).WALLET() == wallet);
            assert(IPositionProxy(proxy).SPOKE() == spoke);
            assert(IPositionProxy(proxy).MARKET_ID() == marketId);
        } else if (caller != ADAPTER) {
            assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IProxyManager.OnlyAdapter.selector)));
        } else if (zero) {
            assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IProxyManager.ZeroAddress.selector)));
        } else {
            // Nothing is deployed yet, so the only remaining refusal is the freeze.
            assert(frozen);
            assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IProxyManager.AddressIsFrozen.selector, wallet)));
        }
    }

    // PROP-064 verifies: REQ-PROXY-051, REQ-PROXY-053, REQ-PROXY-100, INV-064, Q-225
    /// @notice After one deployment of a triple, a second deployment of it reverts `ProxyExists`, frozen or not, and the
    /// first proxy keeps its binding.
    function check_PROP_064_atMostOneProxyPerTriple(
        address wallet,
        address spoke,
        uint256 marketId,
        bool frozenLater
    ) public {
        vm.assume(wallet != address(0) && spoke != address(0) && marketId != 0);
        vm.prank(ADAPTER);
        address first = manager.deployProxy(wallet, spoke, marketId);
        registry.setFrozen(wallet, frozenLater);
        vm.prank(ADAPTER);
        (bool ok, bytes memory ret) =
            address(manager).call(abi.encodeCall(IProxyManager.deployProxy, (wallet, spoke, marketId)));
        assert(!ok);
        assert(
            keccak256(ret)
                == keccak256(abi.encodeWithSelector(IProxyManager.ProxyExists.selector, wallet, spoke, marketId))
        );
        assert(IPositionProxy(first).WALLET() == wallet && IPositionProxy(first).MARKET_ID() == marketId);
    }

    // PROP-076 verifies: INV-064, INV-012, REQ-PROXY-052, REQ-PROXY-053, REQ-PROXY-055
    /// @notice Two deployments of different triples give two different proxies, each bound to its own triple.
    function check_PROP_076_distinctTriplesDistinctProxies(
        address w1,
        address s1,
        uint256 m1,
        address w2,
        address s2,
        uint256 m2
    ) public {
        vm.assume(w1 != address(0) && s1 != address(0) && m1 != 0);
        vm.assume(w2 != address(0) && s2 != address(0) && m2 != 0);
        vm.assume(w1 != w2 || s1 != s2 || m1 != m2);
        vm.prank(ADAPTER);
        address p1 = manager.deployProxy(w1, s1, m1);
        vm.prank(ADAPTER);
        address p2 = manager.deployProxy(w2, s2, m2);
        assert(p1 != p2);
        assert(IPositionProxy(p1).WALLET() == w1 && IPositionProxy(p1).SPOKE() == s1);
        assert(IPositionProxy(p1).MARKET_ID() == m1);
        assert(IPositionProxy(p2).WALLET() == w2 && IPositionProxy(p2).SPOKE() == s2);
        assert(IPositionProxy(p2).MARKET_ID() == m2);
    }
}
