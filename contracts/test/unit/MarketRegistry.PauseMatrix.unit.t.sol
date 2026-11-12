// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The full transition table of the per-Hub pause state: every starting state (None, Frozen,
/// Paused(General), Paused(MintPathSuspect)) against every call (`freeze`, `pause` with each reason, `unfreeze`,
/// `unpause`) and every caller class, with the exact result, error and events; and `freezeAll` / `pauseAll` over
/// Hubs in mixed states.
contract MarketRegistryPauseMatrixUnitTest is MarketRegistryFixture {
    uint8 internal constant S_NONE = 0;
    uint8 internal constant S_FROZEN = 1;
    uint8 internal constant S_PAUSED_GENERAL = 2;
    uint8 internal constant S_PAUSED_MINT = 3;

    uint8 internal constant OP_FREEZE = 0;
    uint8 internal constant OP_PAUSE_GENERAL = 1;
    uint8 internal constant OP_PAUSE_MINT = 2;
    uint8 internal constant OP_PAUSE_NONE = 3;
    uint8 internal constant OP_UNFREEZE = 4;
    uint8 internal constant OP_UNPAUSE = 5;

    address internal freezeOnly = makeAddr("freezeOnlyGuardian");
    address internal pauseOnly = makeAddr("pauseOnlyGuardian");
    address internal hubB = makeAddr("correlatedLpHub");
    address internal hubC = makeAddr("volatileLpHub");
    address internal hubD = makeAddr("secondStableLpHub");

    function setUp() public {
        _setUpWorld();
        vm.startPrank(address(timelock));
        registry.recordHub(hubB, RiskTier.Correlated);
        registry.recordHub(hubC, RiskTier.Volatile);
        registry.recordHub(hubD, RiskTier.Stable);
        registry.grantRole(FREEZE_GUARDIAN, freezeOnly);
        registry.grantRole(PAUSE_GUARDIAN, pauseOnly);
        vm.stopPrank();
    }

    // ─── Helpers ───

    function _stateOf(
        uint8 s
    ) internal pure returns (PauseState st, PauseReason rs) {
        if (s == S_NONE) return (PauseState.None, PauseReason.None);
        if (s == S_FROZEN) return (PauseState.Frozen, PauseReason.None);
        if (s == S_PAUSED_GENERAL) return (PauseState.Paused, PauseReason.General);
        return (PauseState.Paused, PauseReason.MintPathSuspect);
    }

    /// @dev Puts `h` in starting state `s` through the timelock.
    function _enter(
        address h,
        uint8 s
    ) internal {
        vm.startPrank(address(timelock));
        if (s == S_FROZEN) registry.freeze(h);
        if (s == S_PAUSED_GENERAL) registry.pause(h, PauseReason.General);
        if (s == S_PAUSED_MINT) registry.pause(h, PauseReason.MintPathSuspect);
        vm.stopPrank();
    }

    function _data(
        uint8 op,
        address h
    ) internal view returns (bytes memory) {
        if (op == OP_FREEZE) return abi.encodeCall(registry.freeze, (h));
        if (op == OP_PAUSE_GENERAL) return abi.encodeCall(registry.pause, (h, PauseReason.General));
        if (op == OP_PAUSE_MINT) return abi.encodeCall(registry.pause, (h, PauseReason.MintPathSuspect));
        if (op == OP_PAUSE_NONE) return abi.encodeCall(registry.pause, (h, PauseReason.None));
        if (op == OP_UNFREEZE) return abi.encodeCall(registry.unfreeze, (h));
        return abi.encodeCall(registry.unpause, (h));
    }

    /// @dev REQ-MREG-001 and REQ-MREG-024: the error of `op` from state `s`, or empty with the resulting state.
    function _expected(
        uint8 s,
        uint8 op
    ) internal pure returns (bytes memory err, uint8 next) {
        next = s;
        if (op == OP_FREEZE) {
            if (s == S_NONE) return ("", S_FROZEN);
            if (s == S_FROZEN) return (abi.encodeWithSelector(IMarketRegistryErrors.AlreadyFrozen.selector), s);
            return (abi.encodeWithSelector(IMarketRegistryErrors.AlreadyPaused.selector), s);
        }
        if (op == OP_PAUSE_NONE) return (abi.encodeWithSelector(IMarketRegistryErrors.InvalidPauseReason.selector), s);
        if (op == OP_PAUSE_GENERAL) {
            if (s == S_PAUSED_GENERAL) {
                return (abi.encodeWithSelector(IMarketRegistryErrors.InvalidPauseReason.selector), s);
            }
            return ("", S_PAUSED_GENERAL);
        }
        if (op == OP_PAUSE_MINT) {
            if (s == S_PAUSED_MINT) {
                return (abi.encodeWithSelector(IMarketRegistryErrors.InvalidPauseReason.selector), s);
            }
            return ("", S_PAUSED_MINT);
        }
        if (op == OP_UNFREEZE) {
            if (s == S_FROZEN) return ("", S_NONE);
            if (s == S_NONE) return (abi.encodeWithSelector(IMarketRegistryErrors.NotFrozen.selector), s);
            return (abi.encodeWithSelector(IMarketRegistryErrors.CannotUnfreezeWhilePaused.selector), s);
        }
        if (s == S_PAUSED_GENERAL || s == S_PAUSED_MINT) return ("", S_NONE);
        return (abi.encodeWithSelector(IMarketRegistryErrors.NotPaused.selector), s);
    }

    function _authorized(
        address caller,
        uint8 op
    ) internal view returns (bool) {
        if (caller == address(timelock) || caller == emergencyGuardian) return true;
        return op == OP_FREEZE ? caller == freezeOnly : caller == pauseOnly;
    }

    /// @dev The exact logs of one transition of `h` by `caller`.
    function _checkLogs(
        Vm.Log[] memory logs,
        address h,
        uint8 from,
        uint8 to,
        address caller
    ) internal view {
        (PauseState s0, PauseReason r0) = _stateOf(from);
        (PauseState s1, PauseReason r1) = _stateOf(to);
        uint256 n = (s0 != s1 ? 1 : 0) + (r0 != r1 ? 1 : 0);
        assertEq(logs.length, n, "log count");
        uint256 k = 0;
        if (s0 != s1) {
            Vm.Log memory g = logs[k++];
            assertEq(g.emitter, address(registry));
            assertEq(g.topics[0], IMarketRegistryEvents.PauseStateChanged.selector);
            assertEq(g.topics[1], bytes32(uint256(uint160(h))));
            assertEq(g.topics[2], bytes32(uint256(s0)));
            assertEq(g.topics[3], bytes32(uint256(s1)));
            assertEq(abi.decode(g.data, (address)), caller);
        }
        if (r0 != r1) {
            Vm.Log memory g = logs[k++];
            assertEq(g.topics[0], IMarketRegistrySafetyEvents.PauseReasonChanged.selector);
            assertEq(g.topics[1], bytes32(uint256(uint160(h))));
            assertEq(g.topics[2], bytes32(uint256(uint160(caller))));
            (PauseReason p, PauseReason c) = abi.decode(g.data, (PauseReason, PauseReason));
            assertEq(uint8(p), uint8(r0));
            assertEq(uint8(c), uint8(r1));
        }
    }

    function _assertState(
        address h,
        uint8 s
    ) internal view {
        (PauseState st, PauseReason rs) = _stateOf(s);
        assertEq(uint8(registry.pauseState(h)), uint8(st), "state");
        assertEq(uint8(registry.pauseReason(h)), uint8(rs), "reason");
    }

    function _cell(
        uint8 s,
        uint8 op,
        address caller
    ) internal {
        uint256 snap = vm.snapshotState();
        address h = address(hub);
        _enter(h, s);
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(_data(op, h));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!_authorized(caller, op)) {
            assertFalse(ok, "unauthorised call admitted");
            assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, caller));
            assertEq(logs.length, 0);
            _assertState(h, s);
        } else {
            (bytes memory err, uint8 next) = _expected(s, op);
            if (err.length != 0) {
                assertFalse(ok, "illegal transition admitted");
                assertEq(ret, err, "transition error");
                assertEq(logs.length, 0);
                _assertState(h, s);
            } else {
                assertTrue(ok, "legal transition refused");
                _assertState(h, next);
                _checkLogs(logs, h, s, next, caller);
            }
        }
        // The other Hubs never move (REQ-MREG-001: one state per Hub).
        _assertState(hubB, S_NONE);
        _assertState(hubC, S_NONE);
        vm.revertToState(snap);
    }

    // ─── Single-Hub table ───

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, REQ-MREG-024, INV-049, Q-227, Q-252, SPEC-GOV-004, REQ-ACCESS-062, REQ-ACCESS-063, REQ-ACCESS-085, REQ-ACCESS-086, REQ-ACCESS-122, REQ-ACCESS-123, REQ-ACCESS-124
    // Sources: 5.1 TEST-065, QNT-T13
    function test_TEST_065_fullTransitionTableEveryCaller() public {
        address[5] memory callers = [emergencyGuardian, freezeOnly, pauseOnly, address(timelock), attacker];
        for (uint8 s = 0; s < 4; ++s) {
            for (uint8 op = 0; op < 6; ++op) {
                for (uint256 c = 0; c < callers.length; ++c) {
                    _cell(s, op, callers[c]);
                }
            }
        }
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-024, INV-049
    function testFuzz_TEST_065_randomWalkMatchesTheTable(
        uint8[16] calldata ops
    ) public {
        uint8 s = S_NONE;
        address h = address(hub);
        for (uint256 i = 0; i < ops.length; ++i) {
            uint8 op = ops[i] % 6;
            (bytes memory err, uint8 next) = _expected(s, op);
            vm.recordLogs();
            vm.prank(emergencyGuardian);
            (bool ok, bytes memory ret) = address(registry).call(_data(op, h));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (err.length != 0) {
                assertFalse(ok);
                assertEq(ret, err);
                assertEq(logs.length, 0);
            } else {
                assertTrue(ok);
                _checkLogs(logs, h, s, next, emergencyGuardian);
                s = next;
            }
            _assertState(h, s);
        }
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-024
    // Every call on an address that is no recorded Hub reverts `InvalidHub(hub)`; `pause(None)` is refused first with
    // `InvalidPauseReason`, since the reason is checked before the Hub.
    function test_TEST_065_unrecordedHubRefusedByEveryCall() public {
        address h = makeAddr("notAHub");
        bytes memory invalidHub = abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, h);
        for (uint8 op = 0; op < 6; ++op) {
            vm.prank(address(timelock));
            (bool ok, bytes memory ret) = address(registry).call(_data(op, h));
            assertFalse(ok);
            if (op == OP_PAUSE_NONE) {
                assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.InvalidPauseReason.selector));
            } else {
                assertEq(ret, invalidHub);
            }
        }
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.None));
        assertEq(uint8(registry.pauseReason(h)), uint8(PauseReason.None));
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-CONFIG-083
    // A Hub recorded later starts in None and takes part in the machine at once.
    function test_TEST_065_newlyRecordedHubStartsNone() public {
        address late = makeAddr("lateHub");
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, late));
        registry.freeze(late);
        vm.prank(address(timelock));
        registry.recordHub(late, RiskTier.Volatile);
        _assertState(late, S_NONE);
        vm.prank(emergencyGuardian);
        registry.freeze(late);
        _assertState(late, S_FROZEN);
    }

    // ─── freezeAll and pauseAll ───

    /// @dev Hub (Stable) None, hubB Frozen, hubC Paused(General), hubD Paused(MintPathSuspect).
    function _mixed() internal {
        _enter(hubB, S_FROZEN);
        _enter(hubC, S_PAUSED_GENERAL);
        _enter(hubD, S_PAUSED_MINT);
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-CONFIG-082, INV-049, REQ-ACCESS-172, REQ-ACCESS-085
    function test_TEST_065_freezeAllMovesOnlyHubsInNone() public {
        _mixed();
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PauseStateChanged(address(hub), PauseState.None, PauseState.Frozen, aaveGuardian);
        vm.recordLogs();
        vm.prank(aaveGuardian);
        registry.freezeAll();
        assertEq(vm.getRecordedLogs().length, 1);
        _assertState(address(hub), S_FROZEN);
        _assertState(hubB, S_FROZEN);
        _assertState(hubC, S_PAUSED_GENERAL);
        _assertState(hubD, S_PAUSED_MINT);
        // Nothing left in None: the second call changes no Hub.
        vm.prank(aaveGuardian);
        vm.expectRevert(IMarketRegistryErrors.AlreadyFrozen.selector);
        registry.freezeAll();
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-024, REQ-CONFIG-082, INV-049, REQ-ACCESS-172, REQ-ACCESS-162
    function test_TEST_065_pauseAllGeneralOverMixedStates() public {
        _mixed();
        address g = emergencyGuardian;
        // Hub: None -> Paused(General): state and reason events.
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PauseStateChanged(address(hub), PauseState.None, PauseState.Paused, g);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.PauseReasonChanged(address(hub), PauseReason.None, PauseReason.General, g);
        // hubB: Frozen -> Paused(General).
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PauseStateChanged(hubB, PauseState.Frozen, PauseState.Paused, g);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.PauseReasonChanged(hubB, PauseReason.None, PauseReason.General, g);
        // hubC already Paused(General): skipped. hubD: reason only.
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.PauseReasonChanged(hubD, PauseReason.MintPathSuspect, PauseReason.General, g);
        vm.recordLogs();
        vm.prank(g);
        registry.pauseAll(PauseReason.General);
        assertEq(vm.getRecordedLogs().length, 5);
        _assertState(address(hub), S_PAUSED_GENERAL);
        _assertState(hubB, S_PAUSED_GENERAL);
        _assertState(hubC, S_PAUSED_GENERAL);
        _assertState(hubD, S_PAUSED_GENERAL);
        vm.prank(g);
        vm.expectRevert(IMarketRegistryErrors.AlreadyPaused.selector);
        registry.pauseAll(PauseReason.General);
    }

    // TEST-065 verifies: REQ-MREG-024, REQ-CONFIG-082
    function test_TEST_065_pauseAllMintPathSuspectOverMixedStates() public {
        _mixed();
        vm.recordLogs();
        vm.prank(address(timelock));
        registry.pauseAll(PauseReason.MintPathSuspect);
        // Hub and hubB: state and reason each; hubC: reason only; hubD: skipped.
        assertEq(vm.getRecordedLogs().length, 5);
        _assertState(address(hub), S_PAUSED_MINT);
        _assertState(hubB, S_PAUSED_MINT);
        _assertState(hubC, S_PAUSED_MINT);
        _assertState(hubD, S_PAUSED_MINT);
    }

    // TEST-065 verifies: REQ-MREG-024, REQ-CONFIG-082, REQ-ACCESS-162
    function test_TEST_065_pauseAllNoneIsRefusedWhateverTheStates() public {
        _mixed();
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidPauseReason.selector);
        registry.pauseAll(PauseReason.None);
        _assertState(address(hub), S_NONE);
        _assertState(hubB, S_FROZEN);
    }

    // TEST-065 verifies: REQ-MREG-004, REQ-CONFIG-082, REQ-ACCESS-172
    function test_TEST_065_allCallsNeedTheirRole() public {
        vm.prank(pauseOnly);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, pauseOnly));
        registry.freezeAll();
        vm.prank(freezeOnly);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezeOnly));
        registry.pauseAll(PauseReason.General);
        vm.prank(freezeOnly);
        registry.freezeAll();
        vm.prank(pauseOnly);
        registry.pauseAll(PauseReason.General);
        _assertState(hubD, S_PAUSED_GENERAL);
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-CONFIG-082
    // With no recorded Hub there is nothing to change: both batch calls revert.
    function test_TEST_065_batchCallsWithNoHubRevert() public {
        _deployRegistry();
        assertEq(registry.getHubs().length, 0);
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.AlreadyFrozen.selector);
        registry.freezeAll();
        vm.expectRevert(IMarketRegistryErrors.AlreadyPaused.selector);
        registry.pauseAll(PauseReason.General);
        vm.stopPrank();
    }

    // TEST-065 verifies: REQ-MREG-001, REQ-MREG-024, INV-049, SPEC-GOV-004, REQ-ACCESS-172
    // freezeAll and pauseAll change exactly the Hubs a per-Hub call would, for every combination of starting states.
    function testFuzz_TEST_065_batchEqualsPerHubCalls(
        uint8[4] calldata starts,
        bool pauseBatch,
        bool mintReason
    ) public {
        address[4] memory hs = [address(hub), hubB, hubC, hubD];
        uint8[4] memory s;
        for (uint256 i = 0; i < 4; ++i) {
            s[i] = starts[i] % 4;
            _enter(hs[i], s[i]);
        }
        uint8 op = pauseBatch ? (mintReason ? OP_PAUSE_MINT : OP_PAUSE_GENERAL) : OP_FREEZE;
        bool any = false;
        uint8[4] memory want;
        for (uint256 i = 0; i < 4; ++i) {
            (bytes memory err, uint8 next) = _expected(s[i], op);
            want[i] = err.length == 0 ? next : s[i];
            any = any || err.length == 0;
        }
        vm.prank(emergencyGuardian);
        if (!pauseBatch) {
            if (!any) vm.expectRevert(IMarketRegistryErrors.AlreadyFrozen.selector);
            registry.freezeAll();
        } else {
            if (!any) vm.expectRevert(IMarketRegistryErrors.AlreadyPaused.selector);
            registry.pauseAll(mintReason ? PauseReason.MintPathSuspect : PauseReason.General);
        }
        for (uint256 i = 0; i < 4; ++i) {
            _assertState(hs[i], want[i]);
        }
    }

    // TEST-065 verifies: REQ-MREG-003, INV-049
    // ATTACK-132: no call other than the four transitions and the two batch calls moves a Hub's state; a Paused
    // Hub stays Paused across market listing, activation, breaker trips and address freezes.
    function test_TEST_065_otherWritesNeverTouchThePauseState() public {
        _enter(address(hub), S_PAUSED_MINT);
        (uint256 id,,) = _activeMarket();
        vm.startPrank(emergencyGuardian);
        registry.tripMarketBreaker(id);
        registry.freezeAddress(bob);
        vm.stopPrank();
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        vm.warp(block.timestamp + 30 days);
        registry.stepWindDown(id);
        _assertState(address(hub), S_PAUSED_MINT);
        _assertState(hubB, S_NONE);
    }
}
