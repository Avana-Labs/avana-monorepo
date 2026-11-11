// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {ProxyCallTarget} from "../utils/mocks/ProxyMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title PositionProxyHalmosTest
/// @notice Symbolic checks of the PositionProxy for every caller, target and calldata: only the Adapter makes it act,
/// its binding and code never change, it calls only the named target as itself with no ETH, and the callee's return and
/// revert data pass through unchanged.
/// @dev The Adapter, wallet and Spoke are fixed concrete addresses; callers, targets and call words are symbolic.
/// Calldata is a symbolic selector and one symbolic word, which reaches the target's fallback or any of its functions.
contract PositionProxyHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant WALLET = address(0xCA201);
    address internal constant SPOKE = address(0x5B0CE);
    uint256 internal constant MARKET_ID = 3;

    PositionProxy internal proxy;
    ProxyCallTarget internal target;
    ProxyCallTarget internal bystander;

    function setUp() public {
        proxy = new PositionProxy(ADAPTER, WALLET, SPOKE, MARKET_ID);
        target = new ProxyCallTarget();
        bystander = new ProxyCallTarget();
    }

    // PROP-010 verifies: REQ-PROXY-002, REQ-PROXY-003, REQ-PROXY-004, REQ-PROXY-092, Q-306
    /// @notice The constructor succeeds exactly for a non-zero binding and stores it unchanged.
    function check_PROP_010_constructorFixesNonZeroBinding(
        address a,
        address w,
        address s,
        uint256 m
    ) public {
        bool valid = a != address(0) && w != address(0) && s != address(0) && m != 0;
        try new PositionProxy(a, w, s, m) returns (PositionProxy p) {
            assert(valid);
            assert(p.ADAPTER() == a && p.WALLET() == w && p.SPOKE() == s && p.MARKET_ID() == m);
        } catch (bytes memory reason) {
            assert(!valid);
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IPositionProxy.ZeroAddress.selector)));
        }
    }

    // PROP-010 verifies: REQ-PROXY-005, REQ-PROXY-007, REQ-PROXY-086, INV-016, INV-065, Q-064, Q-107
    /// @notice No call by anyone, to any target, changes the binding or the code.
    function check_PROP_010_bindingAndCodeNeverChange(
        address caller,
        bool toTarget,
        address otherTarget,
        bytes4 selector,
        bytes32 word
    ) public {
        // A symbolic word as the offset of a dynamic argument is outside Halmos's calldata model; the two target
        // functions with a `bytes` argument are covered with concrete data by the unit suite.
        vm.assume(selector != ProxyCallTarget.echo.selector && selector != ProxyCallTarget.failWithRaw.selector);
        bytes32 codeHash = address(proxy).codehash;
        address to = toTarget ? address(target) : otherTarget;
        vm.prank(caller);
        (bool ok,) = address(proxy).call(abi.encodeCall(IPositionProxy.execute, (to, abi.encodePacked(selector, word))));
        ok;
        assert(proxy.ADAPTER() == ADAPTER);
        assert(proxy.WALLET() == WALLET);
        assert(proxy.SPOKE() == SPOKE);
        assert(proxy.MARKET_ID() == MARKET_ID);
        assert(address(proxy).codehash == codeHash);
    }

    // PROP-056 verifies: INV-016, INV-063, Q-223, Q-225
    /// @notice Every caller but the Adapter, the bound wallet included, is refused with `OnlyAdapter` before any call.
    function check_PROP_056_executeOnlyFromAdapter(
        address caller,
        bool toTarget,
        address otherTarget,
        bytes4 selector,
        bytes32 word
    ) public {
        vm.assume(caller != ADAPTER);
        address to = toTarget ? address(target) : otherTarget;
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeCall(IPositionProxy.execute, (to, abi.encodePacked(selector, word))));
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IPositionProxy.OnlyAdapter.selector)));
        assert(target.calls() == 0);
    }

    // PROP-010 verifies: REQ-PROXY-007, REQ-PROXY-091, Q-107
    /// @notice From the Adapter, the proxy itself, the zero address and any codeless address are refused with
    /// `InvalidTarget(target)`.
    function check_PROP_010_invalidTargetRefused(
        address to,
        bytes32 word
    ) public {
        vm.assume(to == address(proxy) || to == address(0) || to.code.length == 0);
        vm.prank(ADAPTER);
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeCall(IPositionProxy.execute, (to, abi.encode(word))));
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, to)));
    }

    // PROP-010 verifies: REQ-PROXY-007, REQ-PROXY-010, INV-016, Q-107, Q-225
    /// @notice From the Adapter, the call reaches the named target only, as the proxy, with no ETH and the exact
    /// calldata; any other contract sees nothing.
    function check_PROP_010_callsOnlyTheNamedTarget(
        bytes4 selector,
        bytes32 word
    ) public {
        vm.assume(selector != ProxyCallTarget.failWithError.selector);
        vm.assume(selector != ProxyCallTarget.failWithString.selector);
        vm.assume(selector != ProxyCallTarget.failWithRaw.selector);
        vm.assume(selector != ProxyCallTarget.failEmpty.selector);
        vm.assume(selector != ProxyCallTarget.ping.selector && selector != ProxyCallTarget.echo.selector);
        // The four getters record nothing; every other selector reaches a recording function or the fallback.
        vm.assume(selector != bytes4(keccak256("lastCaller()")) && selector != bytes4(keccak256("lastValue()")));
        vm.assume(selector != bytes4(keccak256("lastData()")) && selector != bytes4(keccak256("calls()")));
        bytes memory data = abi.encodePacked(selector, word);
        vm.prank(ADAPTER);
        (bool ok,) = address(proxy).call(abi.encodeCall(IPositionProxy.execute, (address(target), data)));
        assert(ok);
        assert(target.lastCaller() == address(proxy));
        assert(target.lastValue() == 0);
        assert(keccak256(target.lastData()) == keccak256(data));
        assert(target.calls() == 1);
        assert(bystander.calls() == 0);
    }

    // PROP-010 verifies: REQ-PROXY-007, REQ-PROXY-012, REQ-PROXY-098
    /// @notice Return data comes back unchanged; a revert with data passes that data through, an empty revert becomes
    /// `CallFailed(target)`.
    function check_PROP_010_returnAndRevertDataPassThrough(
        uint256 x,
        uint256 code,
        bool empty
    ) public {
        vm.assume(x < type(uint256).max);
        vm.prank(ADAPTER);
        bytes memory result = proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.ping, (x)));
        assert(abi.decode(result, (uint256)) == x + 1);

        bytes memory failing = empty
            ? abi.encodeCall(ProxyCallTarget.failEmpty, ())
            : abi.encodeCall(ProxyCallTarget.failWithError, (code));
        vm.prank(ADAPTER);
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeCall(IPositionProxy.execute, (address(target), failing)));
        assert(!ok);
        bytes memory expected = empty
            ? abi.encodeWithSelector(IPositionProxy.CallFailed.selector, address(target))
            : abi.encodeWithSelector(ProxyCallTarget.TargetError.selector, code);
        assert(keccak256(ret) == keccak256(expected));
    }
}
