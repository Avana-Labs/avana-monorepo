// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {ProxyCallTarget, ProxyReentrantTarget, ProxyTestToken, TokenPuller} from "../utils/mocks/ProxyMocks.sol";

/// @title PositionProxyUnitTest
/// @notice The PositionProxy on its own (2.5): binding fixed in the constructor, `execute` only for the AaveAdapter,
/// target checks, calls made as the proxy with no ETH, return and revert data passed through unchanged, and a runtime
/// code with exactly `execute` and the four views and no `delegatecall`, `selfdestruct`, storage or ETH entry point.
/// @dev The Adapter is a plain address here: the proxy checks only `msg.sender`. The Adapter's account steps (exact
/// approvals reset to 0, balance deltas, collateral enable and cleanup) join TEST-010, TEST-027, TEST-029 and TEST-018
/// with the AaveAdapter; this suite shows the proxy forwards those calls as itself.
contract PositionProxyUnitTest is AvanaTest {
    using BytecodeInspector for bytes;

    uint256 internal constant MARKET_ID = 3;

    address internal adapter;
    address internal wallet;
    address internal spoke;
    PositionProxy internal proxy;
    ProxyCallTarget internal target;

    function setUp() public {
        adapter = makeAddr("AaveAdapter");
        wallet = makeAddr("Carol");
        spoke = makeAddr("CdpSpoke");
        proxy = new PositionProxy(adapter, wallet, spoke, MARKET_ID);
        target = new ProxyCallTarget();
        vm.label(address(proxy), "PositionProxy");
        vm.label(address(target), "Target");
    }

    // ─── Binding (constructor immutables) ───

    // TEST-025 verifies: REQ-PROXY-002, REQ-PROXY-004, REQ-PROXY-090, INV-016, Q-306
    // Sources: 5.1 TEST-025 (proxy side), 2.5
    function test_TEST_025_bindingFixedAtConstruction() public view {
        assertEq(proxy.ADAPTER(), adapter, "ADAPTER");
        assertEq(proxy.WALLET(), wallet, "WALLET");
        assertEq(proxy.SPOKE(), spoke, "SPOKE");
        assertEq(proxy.MARKET_ID(), MARKET_ID, "MARKET_ID");
    }

    /// @notice The Adapter is a CREATE3-predicted address, so it needs no code when proxies are created.
    // TEST-025 verifies: REQ-PROXY-003, REQ-PROXY-085
    function testFuzz_TEST_025_anyNonZeroBindingIsAccepted(
        address a,
        address w,
        address s,
        uint256 m
    ) public {
        vm.assume(a != address(0) && w != address(0) && s != address(0) && m != 0);
        PositionProxy p = new PositionProxy(a, w, s, m);
        assertEq(p.ADAPTER(), a);
        assertEq(p.WALLET(), w);
        assertEq(p.SPOKE(), s);
        assertEq(p.MARKET_ID(), m);
    }

    // TEST-187 verifies: REQ-PROXY-003, REQ-PROXY-092
    function testFuzz_TEST_187_constructorRefusesZeroBinding(
        address a,
        address w,
        address s,
        uint256 m
    ) public {
        vm.assume(a != address(0) && w != address(0) && s != address(0) && m != 0);
        vm.expectRevert(IPositionProxy.ZeroAddress.selector);
        new PositionProxy(address(0), w, s, m);
        vm.expectRevert(IPositionProxy.ZeroAddress.selector);
        new PositionProxy(a, address(0), s, m);
        vm.expectRevert(IPositionProxy.ZeroAddress.selector);
        new PositionProxy(a, w, address(0), m);
        vm.expectRevert(IPositionProxy.ZeroAddress.selector);
        new PositionProxy(a, w, s, 0);
    }

    /// @notice No call to the proxy, by anyone, changes its binding or its code.
    // TEST-025 verifies: REQ-PROXY-005, REQ-PROXY-086, INV-016, INV-065, ATTACK-123, ATTACK-168
    function test_TEST_025_bindingAndCodeNeverChange() public {
        bytes32 codeHash = address(proxy).codehash;
        vm.startPrank(adapter);
        proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.ping, (1)));
        proxy.execute(address(target), hex"deadbeef");
        vm.stopPrank();
        vm.prank(wallet);
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("initialize(address,address)", wallet, spoke));
        assertFalse(ok, "no initializer");
        assertEq(address(proxy).codehash, codeHash, "code changed");
        test_TEST_025_bindingFixedAtConstruction();
    }

    // ─── Access: Adapter only ───

    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-040, REQ-PROXY-091, INV-016, INV-063, ATTACK-030, Q-223, Q-306
    // Sources: 5.1 TEST-187, TEST-271 (proxy side)
    function testFuzz_TEST_187_executeOnlyFromAdapter(
        address caller,
        bytes calldata data
    ) public {
        vm.assume(caller != adapter);
        vm.prank(caller);
        vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
        proxy.execute(address(target), data);
        assertEq(target.calls(), 0, "a call went through");
    }

    /// @notice The bound wallet, the Spoke, the ProxyManager, LPVaultSwap, the timelock and another proxy are refused
    /// like any other address.
    // TEST-271 verifies: REQ-PROXY-007, REQ-PROXY-091, INV-063, ATTACK-022, ATTACK-030
    function test_TEST_271_namedCallersRefused() public {
        PositionProxy other = new PositionProxy(adapter, wallet, spoke, MARKET_ID + 1);
        address[6] memory callers = [
            wallet, spoke, makeAddr("ProxyManager"), makeAddr("LPVaultSwap"), makeAddr("AvanaTimelock"), address(other)
        ];
        bytes memory data = abi.encodeCall(ProxyCallTarget.ping, (7));
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
            proxy.execute(address(target), data);
        }
        assertEq(target.calls(), 0);
    }

    /// @notice The caller check comes first: a non-Adapter caller with an invalid target gets `OnlyAdapter`.
    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-091
    function test_TEST_187_callerCheckedBeforeTarget() public {
        vm.prank(wallet);
        vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
        proxy.execute(address(0), "");
    }

    /// @notice A callee that calls back into the proxy is refused: inside `execute` the callee is `msg.sender`.
    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-014, INV-063
    function test_TEST_187_calleeCannotReenter() public {
        ProxyReentrantTarget hostile = new ProxyReentrantTarget();
        bytes memory inner = abi.encodeCall(ProxyCallTarget.ping, (1));
        vm.prank(adapter);
        vm.expectRevert(IPositionProxy.OnlyAdapter.selector);
        proxy.execute(address(hostile), abi.encodeCall(ProxyReentrantTarget.reenter, (address(target), inner)));
        assertEq(target.calls(), 0);
    }

    // ─── Targets ───

    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-091
    function test_TEST_187_invalidTargetsRefused() public {
        address codeless = makeAddr("codeless");
        address[3] memory bad = [address(proxy), address(0), codeless];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, bad[i]));
            proxy.execute(bad[i], abi.encodeCall(ProxyCallTarget.ping, (1)));
        }
    }

    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-091, INV-063
    // Sources: PositionProxy review 2026-11-10 (I-1)
    /// @notice The Adapter and the ProxyManager that created the proxy are refused as targets even when they hold code,
    /// so no Adapter call path can make the proxy a caller of either; the same call to another contract succeeds.
    function test_TEST_187_adapterAndProxyManagerRefusedAsTargets() public {
        vm.etch(adapter, address(target).code);
        address[2] memory bad = [adapter, address(this)];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(adapter);
            vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, bad[i]));
            proxy.execute(bad[i], abi.encodeCall(ProxyCallTarget.ping, (1)));
        }
        vm.prank(adapter);
        proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.ping, (1)));
        assertEq(target.lastCaller(), address(proxy), "other targets still reachable");
    }

    // TEST-187 verifies: REQ-PROXY-007, REQ-PROXY-091
    function testFuzz_TEST_187_codelessTargetRefused(
        address codeless
    ) public {
        vm.assume(codeless.code.length == 0);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, codeless));
        proxy.execute(codeless, "");
    }

    // ─── Calls made as the proxy ───

    // TEST-032 verifies: REQ-PROXY-007, REQ-PROXY-010, INV-016, Q-306
    // Sources: 5.1 TEST-032 (proxy entry point)
    function test_TEST_032_executeCallsTargetAsProxyWithNoValue() public {
        bytes memory data = abi.encodeCall(ProxyCallTarget.ping, (41));
        vm.prank(adapter);
        bytes memory result = proxy.execute(address(target), data);
        assertEq(abi.decode(result, (uint256)), 42, "return data");
        assertEq(target.lastCaller(), address(proxy), "caller is the proxy");
        assertEq(target.lastValue(), 0, "no ETH");
        assertEq(target.lastData(), data, "calldata unchanged");
        assertEq(target.calls(), 1, "one call");
    }

    // TEST-032 verifies: REQ-PROXY-007, REQ-PROXY-012
    function testFuzz_TEST_032_returnDataPassesThrough(
        bytes calldata payload
    ) public {
        vm.prank(adapter);
        bytes memory result = proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.echo, (payload)));
        assertEq(abi.decode(result, (bytes)), payload);
    }

    /// @notice Calldata the target has no function for reaches its fallback unchanged; the proxy adds no selector rule.
    // TEST-032 verifies: REQ-PROXY-007
    function testFuzz_TEST_032_noSelectorRule(
        bytes calldata data
    ) public {
        vm.assume(data.length < 4 || _isUnknownSelector(bytes4(data[:4])));
        vm.prank(adapter);
        proxy.execute(address(target), data);
        assertEq(target.lastData(), data);
        assertEq(target.lastCaller(), address(proxy));
    }

    /// @notice The Adapter's supply step shape: exact approval, the Spoke pulls, approval back to 0, all as the proxy.
    // TEST-032 verifies: REQ-PROXY-007, REQ-PROXY-042, REQ-PROXY-088, SPEC-PROXY-005
    function test_TEST_032_proxyMovesOnlyItsOwnTokens() public {
        ProxyTestToken token = new ProxyTestToken();
        TokenPuller puller = new TokenPuller();
        uint256 units = 4_815_162_342;
        token.mint(address(proxy), units);
        vm.startPrank(adapter);
        proxy.execute(address(token), abi.encodeCall(token.approve, (address(puller), units)));
        assertEq(token.allowance(address(proxy), address(puller)), units, "exact approval");
        proxy.execute(address(puller), abi.encodeCall(TokenPuller.pull, (token, units)));
        proxy.execute(address(token), abi.encodeCall(token.approve, (address(puller), 0)));
        vm.stopPrank();
        assertEq(token.balanceOf(address(proxy)), 0, "proxy emptied by exactly units");
        assertEq(token.balanceOf(address(puller)), units, "Spoke received units");
        assertEq(token.allowance(address(proxy), address(puller)), 0, "allowance back to 0");
    }

    // ─── Revert data ───

    // TEST-187 verifies: REQ-PROXY-012, REQ-PROXY-096, REQ-PROXY-098
    function testFuzz_TEST_187_customErrorPropagatesUnchanged(
        uint256 code
    ) public {
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ProxyCallTarget.TargetError.selector, code));
        proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.failWithError, (code)));
    }

    // TEST-187 verifies: REQ-PROXY-012, REQ-PROXY-096, REQ-PROXY-098
    function test_TEST_187_stringRevertPropagatesUnchanged() public {
        vm.prank(adapter);
        vm.expectRevert(bytes("target refused"));
        proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.failWithString, ()));
    }

    // TEST-187 verifies: REQ-PROXY-012, REQ-PROXY-098
    function testFuzz_TEST_187_rawRevertDataPropagatesUnchanged(
        bytes calldata raw
    ) public {
        vm.assume(raw.length > 0);
        vm.prank(adapter);
        (bool ok, bytes memory ret) = address(proxy)
            .call(
                abi.encodeCall(
                    IPositionProxy.execute, (address(target), abi.encodeCall(ProxyCallTarget.failWithRaw, (raw)))
                )
            );
        assertFalse(ok);
        assertEq(ret, raw, "revert data changed");
    }

    // TEST-187 verifies: REQ-PROXY-012, REQ-PROXY-098
    function test_TEST_187_emptyRevertBecomesCallFailed() public {
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(IPositionProxy.CallFailed.selector, address(target)));
        proxy.execute(address(target), abi.encodeCall(ProxyCallTarget.failEmpty, ()));
    }

    // ─── Code surface ───

    /// @notice Runtime selectors are exactly `execute` and the four views; no forbidden selector appears anywhere.
    // TEST-172 verifies: REQ-PROXY-001, REQ-PROXY-007, REQ-PROXY-008, REQ-PROXY-101, REQ-PROXY-103, INV-016, ATTACK-022, ATTACK-030, ATTACK-156
    // Sources: 5.1 TEST-172, TEST-026, TEST-031, TEST-206 (PositionProxy inventory)
    function test_TEST_172_selectorInventory() public view {
        bytes memory code = address(proxy).code;
        bytes4[] memory found = code.dispatcherSelectors(0, code.length);
        bytes4[5] memory expected = [
            IPositionProxy.execute.selector,
            IPositionProxy.ADAPTER.selector,
            IPositionProxy.WALLET.selector,
            IPositionProxy.SPOKE.selector,
            IPositionProxy.MARKET_ID.selector
        ];
        assertEq(found.length, expected.length, "selector count");
        for (uint256 i = 0; i < expected.length; ++i) {
            assertTrue(_has(found, expected[i]), "expected selector missing");
        }
        bytes4[13] memory forbidden = [
            bytes4(keccak256("multicall(bytes[])")),
            bytes4(keccak256("isValidSignature(bytes32,bytes)")),
            bytes4(keccak256("setUserPositionManager(address,bool)")),
            bytes4(keccak256("renouncePositionManagerRole(address)")),
            bytes4(keccak256("updateUserRiskPremium(address)")),
            bytes4(keccak256("updateUserDynamicConfig(address)")),
            IAaveV4Spoke.liquidationCall.selector,
            bytes4(keccak256("setApprovalForAll(address,bool)")),
            bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")),
            bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("upgradeToAndCall(address,bytes)")),
            bytes4(keccak256("grantRole(bytes32,address)"))
        ];
        for (uint256 i = 0; i < forbidden.length; ++i) {
            assertFalse(code.pushesSelector(0, code.length, forbidden[i]), "forbidden selector present");
        }
    }

    /// @notice No `delegatecall`, `callcode`, `selfdestruct`, `tx.origin`, contract creation or storage access exists
    /// in the runtime code.
    // TEST-172 verifies: REQ-PROXY-001, REQ-PROXY-002, REQ-PROXY-006, REQ-PROXY-011, REQ-PROXY-014, INV-016, INV-065, ATTACK-123, ATTACK-156
    function test_TEST_172_noForbiddenOpcodes() public view {
        bytes memory code = address(proxy).code;
        uint8[10] memory ops = [0xf4, 0xf2, 0xff, 0x32, 0xf0, 0xf5, 0x54, 0x55, 0x5c, 0x5d];
        for (uint256 i = 0; i < ops.length; ++i) {
            assertFalse(code.hasOpcode(0, code.length, ops[i]), "forbidden opcode present");
        }
        assertTrue(code.hasOpcode(0, code.length, 0xf1), "CALL present (sanity of the scan)");
    }

    /// @notice ETH is refused on every path: no `receive`, no payable `fallback`, `execute` is non-payable; a call that
    /// matches no selector reverts.
    // TEST-172 verifies: REQ-PROXY-007, REQ-PROXY-103
    function test_TEST_172_noEthAndNoFallback() public {
        vm.deal(adapter, 1 ether);
        vm.prank(adapter);
        (bool sent,) = address(proxy).call{value: 1}("");
        assertFalse(sent, "plain ETH accepted");
        vm.prank(adapter);
        (bool paid,) = address(proxy).call{value: 1}(
            abi.encodeCall(IPositionProxy.execute, (address(target), abi.encodeCall(ProxyCallTarget.ping, (1))))
        );
        assertFalse(paid, "execute accepted ETH");
        vm.prank(adapter);
        (bool unknown,) = address(proxy).call(abi.encodeWithSignature("upgradeTo(address)", address(target)));
        assertFalse(unknown, "unknown selector accepted");
        assertEq(address(proxy).balance, 0);
    }

    function _has(
        bytes4[] memory list,
        bytes4 s
    ) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == s) return true;
        }
        return false;
    }

    function _isUnknownSelector(
        bytes4 s
    ) private pure returns (bool) {
        return s != ProxyCallTarget.ping.selector && s != ProxyCallTarget.echo.selector
            && s != ProxyCallTarget.failWithError.selector && s != ProxyCallTarget.failWithString.selector
            && s != ProxyCallTarget.failWithRaw.selector && s != ProxyCallTarget.failEmpty.selector
            && s != bytes4(keccak256("lastCaller()")) && s != bytes4(keccak256("lastValue()"))
            && s != bytes4(keccak256("lastData()")) && s != bytes4(keccak256("calls()"));
    }
}
