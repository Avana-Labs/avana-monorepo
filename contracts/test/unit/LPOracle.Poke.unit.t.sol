// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice `poke()`: gas floor, failure timer, outage latch, recovery evidence, grace window, checkpoint and events.
/// forge-config: default.isolate = false
contract LPOraclePokeUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    /// @dev Both routes of token B stop publishing at T0; every other feed keeps publishing at `at`.
    function _keepOthersFresh(
        uint256 at
    ) internal {
        pA.push(int256(ONE), at);
        aA.push(int256(ONE), at);
        sA.push(int256(ONE), at);
        sB.push(int256(ONE), at);
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-074, REQ-ORACLE-038, ATTACK-042, Q-154
    // Sources: 5.1 TEST-042, HYP-37
    function test_TEST_042_pokeMinGas() public {
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        (bool ok, bytes memory ret) = address(oracle).call{gas: POKE_FLOOR - 1}(abi.encodeCall(oracle.poke, ()));
        assertFalse(ok, "below pokeMinGas");
        assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector);
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, 0, "a reverted poke stores nothing");
        oracle.poke();
        (failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, T0, "failedSince = now for a failure by Error");
    }

    // TEST-042 verifies: REQ-ORACLE-030, REQ-ORACLE-065, INV-031, ATTACK-042, Q-129, Q-154
    function test_TEST_042_expiredOnlyFromTimestamps() public {
        // An Error-only failure never latches, however long it lasts.
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        oracle.poke();
        vm.warp(T0 + 10_000);
        _keepOthersFresh(T0 + 10_000);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Expired));
        (,, bool latched,) = oracle.storedTimers();
        assertFalse(latched, "a caught error never latches");
        // Both routes Stale for cachedWindow: latched.
        pB.setMode(pB.latestRoundData.selector, ReadMode.Normal);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Normal);
        uint256 t = T0 + MAX_AGE + 1 + 3600;
        vm.warp(t);
        _keepOthersFresh(t);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.OutageExpiredLatched(1, uint64(T0 + MAX_AGE + 1), uint64(t));
        oracle.poke();
        (,, latched,) = oracle.storedTimers();
        assertTrue(latched);
    }

    // TEST-042 verifies: REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-034, SPEC-ORC-014, INV-031, Q-129, Q-154, Q-264
    function test_TEST_042_recoveredAtFirstFreshRound() public {
        uint256 t = T0 + MAX_AGE + 1 + 3600;
        vm.warp(t);
        _keepOthersFresh(t);
        oracle.poke();
        // Token B recovers: its primary publishes at t + 100; the poke at t + 160 starts grace at t + 100.
        vm.warp(t + 160);
        _keepOthersFresh(t + 150);
        pB.push(int256(ONE), t + 100);
        aB.push(int256(ONE), t + 100);
        oracle.poke();
        (uint64 failedSince,, bool latched, uint64 recoveredAt) = oracle.storedTimers();
        assertFalse(latched, "latch cleared by the grace window");
        assertEq(failedSince, 0);
        // The evidence of SPEC-ORC-014: both routes' gaps end at t + 100.
        assertEq(recoveredAt, t + 100, "recoveredAt is the first fresh round");
        PriceStateView memory v = _state();
        assertTrue(v.inGrace);
        assertEq(v.graceEndsAt, t + 100 + 1800);
        assertTrue(_has(v.reasons, 10), "IN_GRACE");
        vm.warp(t + 100 + 1800);
        assertFalse(_state().inGrace, "grace ends");
    }

    // TEST-042 verifies: REQ-ORACLE-033, REQ-ORACLE-065, Q-154
    function test_TEST_042_oneGraceWindowPerOutage() public {
        test_TEST_042_recoveredAtFirstFreshRound();
        (,,, uint64 first) = oracle.storedTimers();
        // Later pokes over the same rounds never start another window.
        vm.warp(block.timestamp + 600);
        _keepOthersFresh(block.timestamp);
        oracle.poke();
        (,,, uint64 again) = oracle.storedTimers();
        assertEq(again, first, "no second window for the same outage");
    }

    // TEST-042 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, Q-129, Q-272
    function test_TEST_042_evidenceWithoutObservingTheOutage() public {
        // No poke saw the outage: Chainlink's own round history shows both routes stale for longer than cachedWindow.
        oracle.poke();
        // Token A keeps publishing within its heartbeat; only token B's two routes stop.
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        uint256 back = T0 + MAX_AGE + 1 + 7200;
        vm.warp(back + 60);
        _keepOthersFresh(back + 60);
        pB.push(int256(ONE), back);
        aB.push(int256(ONE), back);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.GraceStarted(uint64(back), uint64(back + 1800), false);
        oracle.poke();
        (,,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(recoveredAt, back);
    }

    // TEST-042 verifies: REQ-ORACLE-089, REQ-ORACLE-075, SPEC-ORC-014, ATTACK-150, Q-272
    function test_TEST_042_phaseRolloverUsesPreviousPhase() public {
        oracle.poke();
        // Token A keeps publishing within its heartbeat; only token B's two routes stop.
        pA.push(int256(ONE), T0 + 80_000);
        aA.push(int256(ONE), T0 + 80_000);
        uint256 back = T0 + MAX_AGE + 1 + 7200;
        vm.warp(back + 60);
        _keepOthersFresh(back + 60);
        // pB moves to phase 5: its first round's previous round is the last round of phase 4 (at T0).
        OracleFeedMock phase4 = new OracleFeedMock(8, 1, 1e12);
        phase4.setRound(7, int256(ONE), T0, T0);
        pB.setPhaseAggregator(4, address(phase4));
        pB.setRound(uint80((uint256(5) << 64) | 1), int256(ONE), back, back);
        aB.push(int256(ONE), back);
        oracle.poke();
        (,,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(recoveredAt, back, "phase rollover hides no outage");
    }

    // TEST-252 verifies: REQ-ORACLE-032, REQ-ORACLE-095, REQ-ORACLE-065, Q-248, Q-264
    // Sources: 5.1 TEST-252
    function test_TEST_252_graceAtNowOnStandbySwitchWhileLatched() public {
        uint256 t = T0 + MAX_AGE + 1 + 3600;
        vm.warp(t);
        _keepOthersFresh(t);
        oracle.poke();
        // A guardian switches token B's primary slot to a standby with a round older than the switch.
        OracleFeedMock standby = _feed("standby");
        standby.push(int256(ONE), t - 3000);
        registry.setRoutes(address(tokenB), _one(address(standby)), _one(address(aB)), RouteSlot.Primary);
        registry.bumpVersion(address(tokenB));
        vm.warp(t + 12);
        _keepOthersFresh(t + 12);
        oracle.poke();
        (,, bool latched, uint64 recoveredAt) = oracle.storedTimers();
        assertFalse(latched);
        assertEq(recoveredAt, t + 12, "grace starts at the poke that observes the switch");
        assertEq(oracle.storedRouteVersion(1), 1);
    }

    // TEST-252 verifies: REQ-ORACLE-032, Q-264
    function test_TEST_252_graceAtNewestLegWhenNoInterval() public {
        uint256 t = T0 + MAX_AGE + 1 + 3600;
        vm.warp(t);
        _keepOthersFresh(t);
        oracle.poke();
        // Token B recovers through two brand-new feeds that no poke recorded: no interval, so case (c).
        OracleFeedMock np = _feed("newPrimary");
        OracleFeedMock na = _feed("newAlternate");
        np.push(int256(ONE), t + 50);
        na.push(int256(ONE), t + 20);
        registry.setRoutes(address(tokenB), _one(address(np)), _one(address(na)), RouteSlot.None);
        vm.warp(t + 70);
        pA.push(int256(ONE), t + 40);
        aA.push(int256(ONE), t + 40);
        oracle.poke();
        (,,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(recoveredAt, t + 50, "the newest leg in use, never after now");
    }

    // TEST-042 verifies: REQ-ORACLE-088, REQ-ORACLE-059, Q-241
    function test_TEST_042_checkpointHourly() public {
        (uint256 price8, uint64 at) = oracle.priceCheckpoint();
        assertEq(price8, SEEDED);
        assertEq(at, T0);
        vm.warp(T0 + 1000);
        _pushAll(99_990_000, T0 + 1000);
        oracle.poke();
        (, at) = oracle.priceCheckpoint();
        assertEq(at, T0, "not before an hour");
        vm.warp(T0 + 3600);
        oracle.poke();
        (price8, at) = oracle.priceCheckpoint();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        assertEq(price8, accepted, "copies the accepted price");
        assertEq(at, T0 + 3600);
    }

    // TEST-042 verifies: REQ-ORACLE-029, REQ-ORACLE-035, REQ-ORACLE-031, REQ-ORACLE-027, Q-076, Q-182
    function test_TEST_042_acceptedAndEvents() public {
        vm.warp(T0 + 60);
        _pushAll(99_990_000, T0 + 60);
        vm.roll(block.number + 1);
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (99_990_000, 99_990_000);
        uint256 expected = 2 * 99_989_900;
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.PriceAccepted(int256(expected), uint64(T0 + 60), prices);
        oracle.poke();
        (address feed, uint80 roundId, uint64 seenAt) = oracle.storedSeen(0, 0, 0);
        assertEq(feed, address(pA));
        assertEq(roundId, pA.roundId());
        assertEq(seenAt, T0 + 60);
        // A failure records and clears its timer with events; the route change is reported.
        pA.setMode(pA.latestRoundData.selector, ReadMode.Revert);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.RouteChanged(0, 1, 2);
        oracle.poke();
        pA.setMode(pA.latestRoundData.selector, ReadMode.Normal);
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureRecorded(uint64(T0 + 60), 1 << 0);
        oracle.poke();
        pB.setMode(pB.latestRoundData.selector, ReadMode.Normal);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Normal);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureCleared(uint64(T0 + 60), uint64(T0 + 60));
        oracle.poke();
    }

    // TEST-042 verifies: REQ-ORACLE-029, REQ-RISK-026, REQ-RISK-059, Q-182
    // A fast leg's new round moves the accepted price while the slow leg's round (the oldest input) is unchanged, so
    // the borrow bound follows a rally within one fast round; the timestamp stays the oldest leg's.
    function test_TEST_042_acceptedFollowsFastLegAtSameOldestTimestamp() public {
        (uint256 seeded, uint64 seededAt) = oracle.lastAcceptedPrice();
        // Token A dips, then rallies back, on new rounds; token B (the oldest input) publishes nothing.
        _pushTokenA(99_900_000, T0 + 1800);
        oracle.poke();
        (uint256 dipped,) = oracle.lastAcceptedPrice();
        assertLt(dipped, seeded, "dip accepted");
        _pushTokenA(int256(ONE), T0 + 3600);
        oracle.poke();
        assertEq(uint8(_state().state), uint8(PriceState.Live), "Live");
        (uint256 accepted, uint64 at) = oracle.lastAcceptedPrice();
        assertGt(accepted, dipped, "rally accepted before the slow leg publishes");
        assertEq(int256(accepted), _state().freshAnswer, "accepted = fresh");
        assertEq(at, seededAt, "timestamp stays the oldest leg's");
        // Re-reading the same rounds writes nothing.
        vm.roll(block.number + 1);
        vm.recordLogs();
        oracle.poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != ILPOracleEvents.PriceAccepted.selector, "no PriceAccepted for the same rounds"
            );
        }
    }

    function _pushTokenA(
        int256 answer,
        uint256 at
    ) private {
        vm.warp(at);
        vm.roll(block.number + 1);
        pA.push(answer, at);
        aA.push(answer, at);
        sA.push(answer, at);
    }
}
