// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The edges of recovery evidence from Chainlink source timestamps (`SPEC-ORC-014`, `REQ-ORACLE-089`): an
/// unusable previous-round lookup on the first or second leg of a route, a previous round not before the current one,
/// an aggregator round of 0, and on the first round of a phase an unreadable previous-phase aggregator that falls back
/// to the recorded round.
/// @dev Timeline (as `test_TEST_042_evidenceWithoutObservingTheOutage`): a poke at `T0` records every leg at `T0`;
/// token A keeps publishing; token B's routes stop at `T0` and both publish again at `BACK = T0 + 95,401`, read by a
/// poke at `BACK + 60`. Each B leg's gap is `[T0 + 88,201, BACK)`, 7,200 s, at least `cachedWindow = 3,600`, so a
/// usable lookup opens grace recovered at `BACK`.
/// forge-config: default.isolate = false
contract LPOracleRecoveryEdgesUnitTest is LPOracleFixture {
    uint256 internal constant BACK = T0 + MAX_AGE + 1 + 7200;
    bytes32 internal constant GRACE = keccak256("GraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployMarket();
    }

    /// @dev Records every leg at `T0`, keeps token A fresh and warps to `BACK + 60`.
    function _outage() internal {
        oracle.poke();
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        vm.warp(BACK + 60);
        pA.push(int256(ONE), BACK + 60);
        aA.push(int256(ONE), BACK + 60);
        sA.push(int256(ONE), BACK + 60);
        sB.push(int256(ONE), BACK + 60);
    }

    /// @dev Pokes once; returns the number of grace windows opened and the stored `recoveredAt`.
    function _graces() internal returns (uint256 n, uint64 recoveredAt) {
        vm.recordLogs();
        oracle.poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == GRACE) ++n;
        }
        (,,, recoveredAt) = oracle.storedTimers();
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice Token B's primary and alternate recover at `BACK` after 7,200-second gaps; the control poke opens grace
    /// at `BACK`. When the primary's `getRoundData` reverts, or the alternate's, that route gives no evidence and no
    /// grace opens: `recoveredAt` stays 0.
    function test_TEST_042_unusableFirstLegLookupGivesNoEvidence() public {
        _outage();
        pB.push(int256(ONE), BACK);
        aB.push(int256(ONE), BACK);
        uint256 snap = vm.snapshotState();
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.GraceStarted(uint64(BACK), uint64(BACK + 1800), false);
        oracle.poke();
        vm.revertToState(snap);
        pB.setMode(pB.getRoundData.selector, ReadMode.Revert);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "primary lookup reverts");
        assertEq(rec, 0);
        vm.revertToState(snap);
        aB.setMode(aB.getRoundData.selector, ReadMode.Revert);
        (n, rec) = _graces();
        assertEq(n, 0, "alternate lookup reverts");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice Token B's alternate is a two-leg route `aB x xB` (both 8-decimal legs at 1.00, so it values 1.00), recorded
    /// by the poke at `T0`. Both its legs and the primary recover at `BACK`: with usable lookups grace opens at `BACK`;
    /// when only the second leg's `getRoundData` reverts, the alternate gives no evidence and no grace opens.
    function test_TEST_042_unusableSecondLegLookupGivesNoEvidence() public {
        OracleFeedMock xB = _feed("xB");
        registry.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None);
        _outage();
        pB.push(int256(ONE), BACK);
        aB.push(int256(ONE), BACK);
        xB.push(int256(ONE), BACK);
        uint256 snap = vm.snapshotState();
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "control: every lookup usable");
        assertEq(rec, BACK);
        vm.revertToState(snap);
        xB.setMode(xB.getRoundData.selector, ReadMode.Revert);
        vm.expectCall(address(aB), abi.encodeWithSelector(aB.getRoundData.selector), 1);
        (n, rec) = _graces();
        assertEq(n, 0, "second leg's lookup reverts");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice Token B's alternate is the two-leg route `aB x xB`. With no poke after `T0`, `xB` publishes at
    /// `T0 + 88,250` (gap `[T0 + 88,201, T0 + 88,250)`) and `aB` at `T0 + 20,000` and `T0 + 115,401` (last gap
    /// `[T0 + 108,201, T0 + 115,401)`): the gaps are disjoint, so the alternate's interval is the first leg's, the one
    /// with the later end. With the primary's gap `[T0 + 88,201, T0 + 115,401)` both routes were stale together for
    /// 7,200 s and grace opens at `T0 + 115,401`; the second leg's gap alone would have given 49 s and no grace.
    function test_TEST_042_disjointLegGapsKeepTheLaterOne() public {
        OracleFeedMock xB = _feed("xB");
        registry.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None);
        oracle.poke();
        uint256 back = T0 + 115_401;
        aB.push(int256(ONE), T0 + 20_000);
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        xB.push(int256(ONE), T0 + 88_250);
        vm.warp(back + 60);
        pA.push(int256(ONE), back + 60);
        aA.push(int256(ONE), back + 60);
        sA.push(int256(ONE), back + 60);
        sB.push(int256(ONE), back + 60);
        aB.push(int256(ONE), back);
        pB.push(int256(ONE), back);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.GraceStarted(uint64(back), uint64(back + 1800), false);
        oracle.poke();
        (,,, uint64 rec) = oracle.storedTimers();
        assertEq(rec, back);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-089, Q-272
    /// @notice A previous round reporting the current round's own time (`prev >= updatedAt`) is unusable, and so is an
    /// aggregator round of 0 (`roundId = 5 << 64`, no previous round to look up): no grace opens in either case.
    function test_TEST_042_previousRoundNotBeforeOrRoundZeroIsUnusable() public {
        _outage();
        aB.push(int256(ONE), BACK);
        uint256 snap = vm.snapshotState();
        pB.push(int256(ONE), BACK);
        pB.setHistory(pB.roundId() - 1, BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "previous round at the current round's time");
        assertEq(rec, 0);
        vm.revertToState(snap);
        pB.setRound(uint80(uint256(5) << 64), int256(ONE), BACK, BACK);
        vm.expectCall(address(pB), abi.encodeWithSelector(pB.getRoundData.selector), 0);
        (n, rec) = _graces();
        assertEq(n, 0, "aggregator round 0");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, ATTACK-150, Q-272
    /// @notice Token B's primary moves to phase 5 at `BACK`. When phase 4's aggregator last published at `BACK - 100`,
    /// the gap starts at `BACK + 88,101`, after the round: no gap and no grace. When the proxy names no phase-4
    /// aggregator, when that aggregator's `latestRoundData` reverts, or when it reports a time of `2^64`, the gap starts
    /// at the recorded `T0` instead, and grace opens at `BACK`.
    function test_TEST_042_unreadablePreviousPhaseFallsBackToSeen() public {
        _outage();
        aB.push(int256(ONE), BACK);
        OracleFeedMock phase4 = new OracleFeedMock(8, 1, 1e12);
        phase4.setRound(7, int256(ONE), BACK - 100, BACK - 100);
        pB.setPhaseAggregator(4, address(phase4));
        pB.setRound(uint80((uint256(5) << 64) | 1), int256(ONE), BACK, BACK);
        uint256 snap = vm.snapshotState();
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "control: phase 4's last round bounds the gap");
        assertEq(rec, 0);
        vm.revertToState(snap);
        pB.setPhaseAggregator(4, address(0));
        (n, rec) = _graces();
        assertEq(n, 1, "no phase-4 aggregator");
        assertEq(rec, BACK);
        vm.revertToState(snap);
        phase4.setMode(phase4.latestRoundData.selector, ReadMode.Revert);
        (n, rec) = _graces();
        assertEq(n, 1, "phase-4 aggregator reverts");
        assertEq(rec, BACK);
        vm.revertToState(snap);
        phase4.setRound(7, int256(ONE), 1 << 64, 1 << 64);
        (n, rec) = _graces();
        assertEq(n, 1, "phase-4 time of 2^64");
        assertEq(rec, BACK);
    }
}
