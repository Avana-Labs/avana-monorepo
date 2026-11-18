// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleBase} from "../../src/oracle/lp-oracle/ILPOracleBase.sol";
import {RouteSlot} from "../../src/types/OracleTypes.sol";
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
        emit ILPOracleBase.GraceStarted(uint64(BACK), uint64(BACK + 1800), false);
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
        emit ILPOracleBase.GraceStarted(uint64(back), uint64(back + 1800), false);
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

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice Evidence needs a both-stale interval of at least `cachedWindow` (3,600 s): token B's routes recovering
    /// after gaps of 3,599 s open no grace; after gaps of exactly 3,600 s grace opens at their end.
    function test_TEST_042_evidenceNeedsTheWholeCachedWindow() public {
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            uint256 back = T0 + MAX_AGE + 1 + 3599 + k;
            oracle.poke();
            pA.push(int256(ONE), T0 + 80_000);
            aA.push(int256(ONE), T0 + 80_000);
            vm.warp(back + 60);
            pA.push(int256(ONE), back + 60);
            aA.push(int256(ONE), back + 60);
            sA.push(int256(ONE), back + 60);
            sB.push(int256(ONE), back + 60);
            pB.push(int256(ONE), back);
            aB.push(int256(ONE), back);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, k, k == 0 ? "3,599 s: no evidence" : "3,600 s: grace opens");
            assertEq(rec, k == 0 ? 0 : back, "recoveredAt");
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice Every token is searched for evidence, the first one included: the same outage on token A (index 0)
    /// while token B keeps publishing opens grace at `BACK`.
    function test_TEST_042_evidenceOnTheFirstToken() public {
        oracle.poke();
        pB.push(int256(ONE), T0 + 80_000);
        aB.push(int256(ONE), T0 + 80_000);
        vm.warp(BACK + 60);
        pB.push(int256(ONE), BACK + 60);
        aB.push(int256(ONE), BACK + 60);
        sA.push(int256(ONE), BACK + 60);
        sB.push(int256(ONE), BACK + 60);
        pA.push(int256(ONE), BACK);
        aA.push(int256(ONE), BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "grace opens");
        assertEq(rec, BACK, "recoveredAt");
    }

    // ─── Recovery evidence: intervals, routes and previous rounds (mutation-gate triage, run 43492416937) ───

    /// @dev Token B's alternate becomes the two-leg route `aB x xB` (both 8-decimal legs at 1.00); returns `xB`.
    function _twoLegAlternate() internal returns (OracleFeedMock xB) {
        xB = _feed("xB");
        registry.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None);
    }

    /// @dev Keeps token A and both second sources fresh up to `at`, then warps to `at`.
    function _freshAAt(
        uint256 at
    ) internal {
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        vm.warp(at);
        pA.push(int256(ONE), at);
        aA.push(int256(ONE), at);
        sA.push(int256(ONE), at);
        sB.push(int256(ONE), at);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice Overlapping leg gaps of a two-leg route join into one interval: one leg is stale over
    /// `[T0 + 88,201, T0 + 95,401)` and the other over `[T0 + 93,201, T0 + 100,000)`, so the alternate was stale over
    /// `[T0 + 88,201, T0 + 100,000)`; with the primary's gap `[T0 + 88,201, T0 + 96,000)` both routes were stale
    /// together for 7,799 s and grace opens at `T0 + 96,000`. Either gap alone would give less than `cachedWindow` or
    /// another end. Checked with the legs in both orders.
    function test_TEST_042_overlappingLegGapsJoin() public {
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            OracleFeedMock xB = _twoLegAlternate();
            oracle.poke();
            (OracleFeedMock early, OracleFeedMock late) = k == 0 ? (aB, xB) : (xB, aB);
            late.push(int256(ONE), T0 + 5000);
            early.push(int256(ONE), T0 + 95_401);
            late.push(int256(ONE), T0 + 100_000);
            pB.push(int256(ONE), T0 + 96_000);
            _freshAAt(T0 + 100_060);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 1, "grace opens");
            assertEq(rec, T0 + 96_000, "recoveredAt = the primary's end");
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice Disjoint leg gaps are not joined: the alternate's interval is the gap with the later end
    /// (`[T0 + 108,201, T0 + 115,401)`, on either leg), so with the primary stale over `[T0 + 88,201, T0 + 110,000)`
    /// the routes were stale together for only 1,799 s and no grace opens (their union would give 21,799 s). The same
    /// holds for gaps that only touch (`[T0 + 88,201, T0 + 95,401)` and `[T0 + 95,401, T0 + 102,000)`, primary to
    /// `T0 + 98,000`: 2,599 s).
    function test_TEST_042_disjointLegGapsAreNotJoined() public {
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            OracleFeedMock xB = _twoLegAlternate();
            oracle.poke();
            (OracleFeedMock early, OracleFeedMock late) = k == 0 ? (aB, xB) : (xB, aB);
            early.push(int256(ONE), T0 + 88_250);
            late.push(int256(ONE), T0 + 20_000);
            late.push(int256(ONE), T0 + 115_401);
            pB.push(int256(ONE), T0 + 110_000);
            _freshAAt(T0 + 115_461);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 0, "the later gap alone overlaps the primary's for 1,799 s");
            assertEq(rec, 0);
            vm.revertToState(snap);
        }
        OracleFeedMock x = _twoLegAlternate();
        oracle.poke();
        aB.push(int256(ONE), T0 + 95_401);
        x.push(int256(ONE), T0 + 7200);
        x.push(int256(ONE), T0 + 102_000);
        pB.push(int256(ONE), T0 + 98_000);
        _freshAAt(T0 + 102_060);
        (uint256 m, uint64 r) = _graces();
        assertEq(m, 0, "touching gaps keep the later one");
        assertEq(r, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice The both-stale interval is the intersection `[max start, min end)`: a primary stale over
    /// `[T0 + 108,201, T0 + 115,401)` and an alternate over `[T0 + 88,201, T0 + 110,000)` were stale together for
    /// 1,799 s, so no grace opens; and a primary stale over `[T0 + 88,201, T0 + 88,300)` with an alternate over
    /// `[T0 + 108,201, T0 + 115,401)` were never stale together (no grace, and the poke does not revert).
    function test_TEST_042_bothStaleIsTheIntersection() public {
        uint256 snap = vm.snapshotState();
        oracle.poke();
        pB.push(int256(ONE), T0 + 20_000);
        pB.push(int256(ONE), T0 + 115_401);
        aB.push(int256(ONE), T0 + 110_000);
        _freshAAt(T0 + 115_461);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "1,799 s together");
        assertEq(rec, 0);
        vm.revertToState(snap);
        oracle.poke();
        pB.push(int256(ONE), T0 + 88_300);
        aB.push(int256(ONE), T0 + 20_000);
        aB.push(int256(ONE), T0 + 115_401);
        _freshAAt(T0 + 115_461);
        (n, rec) = _graces();
        assertEq(n, 0, "never stale together");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice With evidence on both tokens, `recoveredAt` is the latest end over the tokens, whichever token comes
    /// first: token A recovers at `T0 + 115,401` and token B at `T0 + 100,000`, so grace opens at `T0 + 115,401`.
    function test_TEST_042_latestEndOverEveryToken() public {
        oracle.poke();
        pA.push(int256(ONE), T0 + 115_401);
        aA.push(int256(ONE), T0 + 115_401);
        pB.push(int256(ONE), T0 + 100_000);
        aB.push(int256(ONE), T0 + 100_000);
        vm.warp(T0 + 115_461);
        sA.push(int256(ONE), T0 + 115_461);
        sB.push(int256(ONE), T0 + 115_461);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "grace opens");
        assertEq(rec, T0 + 115_401, "the later of the two ends");
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice A route that is still Stale at the poke is stale over `[staleFrom, now)`: token B's alternate never
    /// publishes again, its primary recovers at `BACK` after the usual gap, and grace opens at `BACK`. When the
    /// alternate's last round is later (`T0 + 20,000`, so `staleFrom = T0 + 108,201`) and the primary recovers at
    /// `T0 + 109,900`, the routes were stale together for 1,699 s and no grace opens.
    function test_TEST_042_staleRouteSpansFromStaleFromToNow() public {
        uint256 snap = vm.snapshotState();
        _outage();
        pB.push(int256(ONE), BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "Stale alternate: grace at BACK");
        assertEq(rec, BACK);
        vm.revertToState(snap);
        oracle.poke();
        aB.push(int256(ONE), T0 + 20_000);
        pB.push(int256(ONE), T0 + 109_900);
        _freshAAt(T0 + 110_000);
        (n, rec) = _graces();
        assertEq(n, 0, "1,699 s together");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice An Invalid route gives the token no evidence, even when its leg has a gap: token B's alternate returns
    /// at `BACK` with an answer above its `maxAnswer`, so no grace opens although both B feeds were silent for the
    /// same 7,200 s.
    function test_TEST_042_invalidRouteGivesNoEvidence() public {
        _outage();
        pB.push(int256(ONE), BACK);
        aB.push(2e12, BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "Invalid alternate");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice Two-leg alternate `aB x xB`: when only the first leg's `getRoundData` reverts, the route gives no
    /// evidence (no grace), even though the second leg has a usable gap. When the first leg has no gap at all (its
    /// round is within `feedMaxAge` of the recorded one) no lookup is made for it, so its reverting `getRoundData` does
    /// not matter and grace opens from the second leg's gap.
    function test_TEST_042_firstLegLookupOfATwoLegRoute() public {
        uint256 snap = vm.snapshotState();
        OracleFeedMock xB = _twoLegAlternate();
        _outage();
        aB.push(int256(ONE), BACK);
        xB.push(int256(ONE), BACK);
        pB.push(int256(ONE), BACK);
        aB.setMode(aB.getRoundData.selector, ReadMode.Revert);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "first leg's lookup reverts");
        assertEq(rec, 0);
        vm.revertToState(snap);
        xB = _twoLegAlternate();
        _outage();
        aB.push(int256(ONE), T0 + 80_000);
        xB.push(int256(ONE), BACK);
        pB.push(int256(ONE), BACK);
        aB.setMode(aB.getRoundData.selector, ReadMode.Revert);
        (n, rec) = _graces();
        assertEq(n, 1, "no gap on the first leg: no lookup");
        assertEq(rec, BACK);
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, Q-272
    /// @notice The first round of phase 0 or 1 has no previous phase to read: the gap starts at the recorded round and
    /// grace opens at `BACK`, even when the proxy names a phase-0 aggregator (which is not read).
    function test_TEST_042_firstRoundOfPhaseZeroOrOne() public {
        uint256 snap = vm.snapshotState();
        _outage();
        aB.push(int256(ONE), BACK);
        pB.setRound(1, int256(ONE), BACK, BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "phase 0, round 1");
        assertEq(rec, BACK);
        vm.revertToState(snap);
        _outage();
        aB.push(int256(ONE), BACK);
        OracleFeedMock phase0 = new OracleFeedMock(8, 1, 1e12);
        phase0.setRound(7, int256(ONE), BACK - 100, BACK - 100);
        pB.setPhaseAggregator(0, address(phase0));
        pB.setRound(uint80((uint256(1) << 64) | 1), int256(ONE), BACK, BACK);
        (n, rec) = _graces();
        assertEq(n, 1, "phase 1, round 1: phase 0 is never read");
        assertEq(rec, BACK);
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, ATTACK-150, Q-272
    /// @notice A previous-phase time not before the current round (`BACK + 100`, or `BACK` itself), or one beyond 32
    /// bits (`2^40`), is unusable: the gap starts at the recorded round and grace opens at `BACK`.
    function test_TEST_042_previousPhaseTimeNotBeforeTheRound() public {
        uint256[3] memory times = [BACK + 100, BACK, uint256(1) << 40];
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < times.length; ++k) {
            _outage();
            aB.push(int256(ONE), BACK);
            OracleFeedMock phase4 = new OracleFeedMock(8, 1, 1e12);
            phase4.setRound(7, int256(ONE), times[k], times[k]);
            pB.setPhaseAggregator(4, address(phase4));
            pB.setRound(uint80((uint256(5) << 64) | 1), int256(ONE), BACK, BACK);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 1, "falls back to the recorded round");
            assertEq(rec, BACK);
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, ATTACK-150, Q-272
    /// @notice A previous phase that gives no usable time (no aggregator, or one reporting time 0) falls back to the
    /// recorded round, never to time 0: with the primary recorded at `T0 + 5,000` and switching to phase 5 at
    /// `T0 + 96,201` its gap is 3,000 s, so no grace opens (a gap from time 0 would overlap the alternate's 8,000 s).
    function test_TEST_042_previousPhaseWithoutATimeUsesTheRecordedRound() public {
        uint256 back2 = T0 + 96_201;
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            oracle.poke();
            vm.warp(T0 + 5000);
            pA.push(int256(ONE), T0 + 5000);
            aA.push(int256(ONE), T0 + 5000);
            pB.push(int256(ONE), T0 + 5000);
            sA.push(int256(ONE), T0 + 5000);
            sB.push(int256(ONE), T0 + 5000);
            oracle.poke();
            if (k == 1) {
                OracleFeedMock phase4 = new OracleFeedMock(8, 1, 1e12);
                phase4.setRound(7, int256(ONE), 0, 0);
                pB.setPhaseAggregator(4, address(phase4));
            }
            pB.setRound(uint80((uint256(5) << 64) | 1), int256(ONE), back2, back2);
            aB.push(int256(ONE), back2);
            vm.warp(back2 + 60);
            pA.push(int256(ONE), back2 + 60);
            aA.push(int256(ONE), back2 + 60);
            sA.push(int256(ONE), back2 + 60);
            sB.push(int256(ONE), back2 + 60);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 0, k == 0 ? "no phase-4 aggregator" : "phase-4 time 0");
            assertEq(rec, 0);
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, Q-272
    /// @notice A leg recorded with time 0 (a decoded round reporting `updatedAt = 0`) has no recorded time to fall
    /// back to: when it later returns on the first round of a phase with no readable previous phase, its route gives
    /// no evidence and no grace opens; the poke does not revert.
    function test_TEST_042_recordedTimeZeroIsNoFallback() public {
        oracle.poke();
        vm.warp(T0 + 1000);
        pB.setRound(7, int256(ONE), 0, 0);
        oracle.poke();
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        vm.warp(BACK + 60);
        pA.push(int256(ONE), BACK + 60);
        aA.push(int256(ONE), BACK + 60);
        sA.push(int256(ONE), BACK + 60);
        sB.push(int256(ONE), BACK + 60);
        aB.push(int256(ONE), BACK);
        pB.setRound(uint80((uint256(5) << 64) | 1), int256(ONE), BACK, BACK);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "no usable previous time");
        assertEq(rec, 0);
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    /// @notice Intervals that only touch give no end time: token A recovers at `T0 + 100,000` after an 11,799-second
    /// gap, while token B's primary is stale over `[T0 + 88,201, T0 + 110,000)` and its alternate (which also published
    /// at `T0 + 21,799`) over `[T0 + 110,000, T0 + 115,000)`. B's intersection `[T0 + 110,000, T0 + 110,000)` is empty,
    /// so `recoveredAt` is A's end, `T0 + 100,000`, not B's `T0 + 110,000`.
    function test_TEST_042_touchingIntervalsGiveNoEndTime() public {
        oracle.poke();
        aB.push(int256(ONE), T0 + 21_799);
        pA.push(int256(ONE), T0 + 100_000);
        aA.push(int256(ONE), T0 + 100_000);
        pB.push(int256(ONE), T0 + 110_000);
        aB.push(int256(ONE), T0 + 115_000);
        vm.warp(T0 + 115_060);
        sA.push(int256(ONE), T0 + 115_060);
        sB.push(int256(ONE), T0 + 115_060);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "grace opens from token A");
        assertEq(rec, T0 + 100_000, "token B's empty intersection adds no end");
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-032, Q-129, Q-272
    /// @notice A leg whose previous round is within `feedMaxAge` of its new round has no gap, even though its recorded
    /// round is older than that: on the two-leg alternate `aB x xB`, `xB` publishes at `T0 + 10,000` and again at
    /// `T0 + 98,201` (gap start `T0 + 98,201`, equal to the round) or `T0 + 98,000` (start after the round). The route's
    /// interval is then `aB`'s gap `[T0 + 88,201, BACK)`, and with the primary's equal gap grace opens at `BACK`.
    function test_TEST_042_legGapStartingAtOrAfterItsRoundIsEmpty() public {
        uint256[2] memory ends = [T0 + 98_201, T0 + 98_000];
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            OracleFeedMock xB = _twoLegAlternate();
            oracle.poke();
            xB.push(int256(ONE), T0 + 10_000);
            pB.push(int256(ONE), BACK);
            aB.push(int256(ONE), BACK);
            xB.push(int256(ONE), ends[k]);
            _freshAAt(T0 + 98_261);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 1, k == 0 ? "start equal to the round: no gap on xB" : "start after the round: no gap on xB");
            assertEq(rec, BACK, "recoveredAt = aB's and the primary's end");
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-089, Q-129, Q-272
    /// @notice On the two-leg alternate `aB x xB`, both legs and the primary recover at `BACK` after the usual gap, so
    /// grace opens at `BACK`. When `aB`'s previous round reports the current round's time, a later time, or time 0
    /// (without reverting), that lookup is unusable and the whole route gives no evidence, although `xB`'s gap alone
    /// would match the primary's.
    function test_TEST_042_unusablePreviousTimeOnTheFirstLeg() public {
        uint256 snap = vm.snapshotState();
        OracleFeedMock xB = _twoLegAlternate();
        _outage();
        pB.push(int256(ONE), BACK);
        aB.push(int256(ONE), BACK);
        xB.push(int256(ONE), BACK);
        uint80 prevId = aB.roundId() - 1;
        uint256 afterSetup = vm.snapshotState();
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "control: every lookup usable");
        assertEq(rec, BACK);
        uint256[2] memory times = [BACK, BACK + 1];
        for (uint256 k = 0; k < 2; ++k) {
            vm.revertToState(afterSetup);
            aB.setHistory(prevId, times[k]);
            (n, rec) = _graces();
            assertEq(n, 0, k == 0 ? "previous round at the round's time" : "previous round after the round");
            assertEq(rec, 0);
        }
        vm.revertToState(afterSetup);
        vm.mockCall(
            address(aB),
            abi.encodeWithSelector(aB.getRoundData.selector, prevId),
            abi.encode(prevId, int256(ONE), uint256(0), uint256(0), prevId)
        );
        (n, rec) = _graces();
        assertEq(n, 0, "previous round at time 0");
        assertEq(rec, 0);
        vm.clearMockedCalls();
        vm.revertToState(snap);
    }
}
