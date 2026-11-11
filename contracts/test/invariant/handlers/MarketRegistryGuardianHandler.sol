// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryEvents} from "../../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistrySafetyEvents} from "../../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title MarketRegistryGuardianHandler
/// @notice Guardian handler of the TEST-101 suite: `freeze`, `pause`, `unfreeze`, `unpause`, `freezeAll` and
/// `pauseAll` on three recorded Hubs (and one unrecorded address) by the Emergency Guardian (both guardian roles), a
/// freeze-only guardian, a pause-only guardian, the timelock as `APPLICATION_ADMIN` and an unauthorised address, plus
/// time warps. Each call is checked against a model of REQ-MREG-001, REQ-MREG-004 and REQ-MREG-024: the call succeeds
/// exactly when the caller holds the right role and the model admits the transition, the resulting state and reason
/// equal the model's, every changed Hub emits exactly one `PauseStateChanged(hub, previous, current, caller)` and every
/// changed reason one `PauseReasonChanged`, and a refused call changes nothing. Ghosts count every departure.
contract MarketRegistryGuardianHandler is CommonBase, StdUtils {
    uint8 internal constant OP_FREEZE = 0;
    uint8 internal constant OP_PAUSE = 1;
    uint8 internal constant OP_UNFREEZE = 2;
    uint8 internal constant OP_UNPAUSE = 3;
    uint8 internal constant OP_FREEZE_ALL = 4;
    uint8 internal constant OP_PAUSE_ALL = 5;

    uint256 public constant HUBS = 3;
    uint256 public constant ACTORS = 5;

    MarketRegistry public immutable REGISTRY;
    address public immutable UNRECORDED;
    address[HUBS] internal _hubs;
    /// @dev 0 Emergency Guardian (both roles), 1 freeze-only, 2 pause-only, 3 timelock (APPLICATION_ADMIN), 4 stranger.
    address[ACTORS] internal _actors;

    uint256 public calls;
    uint256 public successes;
    uint256 public outcomeMismatch;
    uint256 public stateMismatch;
    uint256 public refusedButChanged;
    uint256 public eventMismatch;
    uint256 public freezeOnlyLoosened;
    uint256 public strangerSucceeded;
    uint256 public timeChangedState;
    mapping(uint8 op => uint256) public successesByOp;

    struct Snap {
        PauseState[HUBS] state;
        PauseReason[HUBS] reason;
    }

    constructor(
        MarketRegistry registry,
        address[HUBS] memory hubs,
        address[ACTORS] memory actors,
        address unrecorded
    ) {
        REGISTRY = registry;
        _hubs = hubs;
        _actors = actors;
        UNRECORDED = unrecorded;
    }

    function hubAt(
        uint256 i
    ) external view returns (address) {
        return _hubs[i];
    }

    // ─── Actions ───

    function freeze(
        uint256 hubSeed,
        uint256 actorSeed
    ) external {
        _single(OP_FREEZE, hubSeed, actorSeed, PauseReason.None);
    }

    function pause(
        uint256 hubSeed,
        uint256 actorSeed,
        uint256 reasonSeed
    ) external {
        _single(OP_PAUSE, hubSeed, actorSeed, PauseReason(bound(reasonSeed, 0, 2)));
    }

    function unfreeze(
        uint256 hubSeed,
        uint256 actorSeed
    ) external {
        _single(OP_UNFREEZE, hubSeed, actorSeed, PauseReason.None);
    }

    function unpause(
        uint256 hubSeed,
        uint256 actorSeed
    ) external {
        _single(OP_UNPAUSE, hubSeed, actorSeed, PauseReason.None);
    }

    function freezeAll(
        uint256 actorSeed
    ) external {
        _all(OP_FREEZE_ALL, actorSeed, PauseReason.None);
    }

    function pauseAll(
        uint256 actorSeed,
        uint256 reasonSeed
    ) external {
        _all(OP_PAUSE_ALL, actorSeed, PauseReason(bound(reasonSeed, 0, 2)));
    }

    /// @dev No state has an on-chain expiry (REQ-MREG-003): a warp of up to ten years changes nothing.
    function warp(
        uint256 secondsSeed
    ) external {
        Snap memory before = _snap();
        vm.warp(block.timestamp + bound(secondsSeed, 1, 3650 days));
        Snap memory afterWarp = _snap();
        if (!_same(before, afterWarp)) ++timeChangedState;
    }

    // ─── Model ───

    /// @dev Whether `actor` may call `op` (REQ-MREG-004): freeze and freezeAll need the freeze guardian or the admin;
    /// every other call the pause guardian or the admin.
    function _authorized(
        uint256 actor,
        uint8 op
    ) internal pure returns (bool) {
        if (actor == 3 || actor == 0) return true;
        if (op == OP_FREEZE || op == OP_FREEZE_ALL) return actor == 1;
        return actor == 2;
    }

    /// @dev The model's next (state, reason) of one Hub, and whether the transition is admitted.
    function _next(
        uint8 op,
        PauseState st,
        PauseReason rs,
        PauseReason reason
    ) internal pure returns (bool ok, PauseState nst, PauseReason nrs) {
        (nst, nrs) = (st, rs);
        if (op == OP_FREEZE || op == OP_FREEZE_ALL) {
            if (st != PauseState.None) return (false, st, rs);
            return (true, PauseState.Frozen, PauseReason.None);
        }
        if (op == OP_PAUSE || op == OP_PAUSE_ALL) {
            if (reason == PauseReason.None) return (false, st, rs);
            if (st == PauseState.Paused && rs == reason) return (false, st, rs);
            return (true, PauseState.Paused, reason);
        }
        if (op == OP_UNFREEZE) {
            if (st != PauseState.Frozen) return (false, st, rs);
            return (true, PauseState.None, PauseReason.None);
        }
        if (st != PauseState.Paused) return (false, st, rs);
        return (true, PauseState.None, PauseReason.None);
    }

    function _single(
        uint8 op,
        uint256 hubSeed,
        uint256 actorSeed,
        PauseReason reason
    ) internal {
        uint256 hi = bound(hubSeed, 0, HUBS);
        address hub = hi == HUBS ? UNRECORDED : _hubs[hi];
        uint256 actor = bound(actorSeed, 0, ACTORS - 1);
        Snap memory before = _snap();
        Snap memory expected = _copy(before);
        bool expectOk = _authorized(actor, op);
        if (expectOk && hi == HUBS) expectOk = false;
        if (expectOk) {
            (bool ok, PauseState nst, PauseReason nrs) = _next(op, before.state[hi], before.reason[hi], reason);
            expectOk = ok;
            (expected.state[hi], expected.reason[hi]) = (nst, nrs);
        }
        bytes memory data;
        if (op == OP_FREEZE) data = abi.encodeCall(REGISTRY.freeze, (hub));
        else if (op == OP_PAUSE) data = abi.encodeCall(REGISTRY.pause, (hub, reason));
        else if (op == OP_UNFREEZE) data = abi.encodeCall(REGISTRY.unfreeze, (hub));
        else data = abi.encodeCall(REGISTRY.unpause, (hub));
        _run(op, actor, data, before, expectOk ? expected : before, expectOk);
    }

    function _all(
        uint8 op,
        uint256 actorSeed,
        PauseReason reason
    ) internal {
        uint256 actor = bound(actorSeed, 0, ACTORS - 1);
        Snap memory before = _snap();
        Snap memory expected = _copy(before);
        bool anyChange = false;
        for (uint256 i = 0; i < HUBS; ++i) {
            (bool ok, PauseState nst, PauseReason nrs) = _next(op, before.state[i], before.reason[i], reason);
            if (ok) {
                (expected.state[i], expected.reason[i]) = (nst, nrs);
                anyChange = true;
            }
        }
        bool expectOk = _authorized(actor, op) && anyChange;
        bytes memory data =
            op == OP_FREEZE_ALL ? abi.encodeCall(REGISTRY.freezeAll, ()) : abi.encodeCall(REGISTRY.pauseAll, (reason));
        _run(op, actor, data, before, expectOk ? expected : before, expectOk);
    }

    function _run(
        uint8 op,
        uint256 actor,
        bytes memory data,
        Snap memory before,
        Snap memory expected,
        bool expectOk
    ) internal {
        ++calls;
        address caller = _actors[actor];
        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = address(REGISTRY).call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory afterCall = _snap();
        if (ok != expectOk) ++outcomeMismatch;
        if (!_same(afterCall, expected)) ++stateMismatch;
        if (!ok && !_same(afterCall, before)) ++refusedButChanged;
        if (ok && actor == 4) ++strangerSucceeded;
        if (ok && actor == 1) {
            for (uint256 i = 0; i < HUBS; ++i) {
                if (before.state[i] != PauseState.None && afterCall.state[i] == PauseState.None) ++freezeOnlyLoosened;
            }
        }
        if (ok) {
            ++successes;
            ++successesByOp[op];
            if (!_eventsMatch(logs, before, afterCall, caller)) ++eventMismatch;
        } else if (logs.length != 0) {
            ++eventMismatch;
        }
    }

    /// @dev Exactly one `PauseStateChanged` per Hub whose state changed and one `PauseReasonChanged` per Hub whose
    /// reason changed, with the exact previous, current and caller, and no other log.
    function _eventsMatch(
        Vm.Log[] memory logs,
        Snap memory before,
        Snap memory afterCall,
        address caller
    ) internal view returns (bool) {
        uint256 expectedLogs = 0;
        for (uint256 i = 0; i < HUBS; ++i) {
            bool stateChanged = before.state[i] != afterCall.state[i];
            bool reasonChanged = before.reason[i] != afterCall.reason[i];
            if (stateChanged) ++expectedLogs;
            if (reasonChanged) ++expectedLogs;
            uint256 stateLogs = 0;
            uint256 reasonLogs = 0;
            for (uint256 k = 0; k < logs.length; ++k) {
                Vm.Log memory g = logs[k];
                if (g.emitter != address(REGISTRY) || g.topics.length < 2) continue;
                if (g.topics[1] != bytes32(uint256(uint160(_hubs[i])))) continue;
                if (g.topics[0] == IMarketRegistryEvents.PauseStateChanged.selector) {
                    bool exact = g.topics[2] == bytes32(uint256(before.state[i]))
                        && g.topics[3] == bytes32(uint256(afterCall.state[i]))
                        && abi.decode(g.data, (address)) == caller;
                    if (!exact) return false;
                    ++stateLogs;
                } else if (g.topics[0] == IMarketRegistrySafetyEvents.PauseReasonChanged.selector) {
                    (PauseReason prev, PauseReason cur) = abi.decode(g.data, (PauseReason, PauseReason));
                    bool exact = prev == before.reason[i] && cur == afterCall.reason[i]
                        && g.topics[2] == bytes32(uint256(uint160(caller)));
                    if (!exact) return false;
                    ++reasonLogs;
                }
            }
            if (stateLogs != (stateChanged ? 1 : 0) || reasonLogs != (reasonChanged ? 1 : 0)) return false;
        }
        return logs.length == expectedLogs;
    }

    function _snap() internal view returns (Snap memory s) {
        for (uint256 i = 0; i < HUBS; ++i) {
            s.state[i] = REGISTRY.pauseState(_hubs[i]);
            s.reason[i] = REGISTRY.pauseReason(_hubs[i]);
        }
    }

    function _copy(
        Snap memory a
    ) internal pure returns (Snap memory b) {
        for (uint256 i = 0; i < HUBS; ++i) {
            (b.state[i], b.reason[i]) = (a.state[i], a.reason[i]);
        }
    }

    function _same(
        Snap memory a,
        Snap memory b
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < HUBS; ++i) {
            if (a.state[i] != b.state[i] || a.reason[i] != b.reason[i]) return false;
        }
        return true;
    }
}
