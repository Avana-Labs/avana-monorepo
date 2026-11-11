// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The outage latch, the grace window and the sequencer on an L2 market (2.10 `REQ-ORACLE-030` to
/// `REQ-ORACLE-034`, `REQ-ORACLE-065`, `REQ-ORACLE-099`): the latch at its exact second, the grace window's bounds, no
/// grace after a failure that was not two stale routes, and a sequencer that never moves the state, the price or a
/// timer.
/// forge-config: default.isolate = false
contract LPOracleGraceUnitTest is LPOracleFixture {
    uint256 internal constant STALE_AT = T0 + MAX_AGE + 1;

    function setUp() public {
        _deployMarket(true);
        seqFeed.setRound(1, 0, T0 - 7200, T0 - 7200);
    }

    /// @dev Token B's two routes stop at T0; every other feed publishes at `at`.
    function _othersAt(
        uint256 at
    ) internal {
        pA.push(int256(ONE), at);
        aA.push(int256(ONE), at);
        sA.push(int256(ONE), at);
        sB.push(int256(ONE), at);
    }

    function _pokeAt(
        uint256 t
    ) internal returns (PriceState) {
        vm.warp(t);
        vm.roll(block.number + 1);
        _othersAt(t);
        return oracle.poke();
    }

    function _latched() internal view returns (bool latched) {
        (,, latched,) = oracle.storedTimers();
    }

    // TEST-042 verifies: REQ-ORACLE-030, SPEC-ORC-013, REQ-ORACLE-065
    /// @notice The latch sets on the first poke at or after `staleAt + cachedWindow` of a token whose two routes are
    /// stale, never one second earlier, and records that token, its `staleAt` and the observation time.
    function test_TEST_042_latchAtTheExactSecond() public {
        _pokeAt(STALE_AT + 3599);
        assertFalse(_latched(), "one second before staleAt + cachedWindow");
        assertEq(uint8(_state().state), uint8(PriceState.Cached));
        vm.warp(STALE_AT + 3600);
        vm.roll(block.number + 1);
        _othersAt(STALE_AT + 3600);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.OutageExpiredLatched(1, uint64(STALE_AT), uint64(STALE_AT + 3600));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Expired));
        assertTrue(_latched());
    }

    // TEST-042 verifies: REQ-ORACLE-032, REQ-ORACLE-034, REQ-ORACLE-033
    /// @notice After a latched outage the first fresh round opens one grace window from its source timestamp:
    /// `inGrace` holds from `recoveredAt` to `recoveredAt + graceDuration - 1` with reason bit 10, and not after.
    function test_TEST_042_graceWindowBounds() public {
        _pokeAt(STALE_AT + 3600);
        uint256 back = STALE_AT + 5000;
        vm.warp(back + 30);
        vm.roll(block.number + 1);
        _othersAt(back + 30);
        pB.push(int256(ONE), back);
        aB.push(int256(ONE), back);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.GraceStarted(uint64(back), uint64(back + 1800), true);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        assertFalse(_latched(), "the latch is consumed");
        PriceStateView memory v = _state();
        assertTrue(v.inGrace);
        assertEq(v.recoveredAt, back);
        assertEq(v.graceEndsAt, back + 1800);
        assertTrue(_has(v.reasons, 10), "IN_GRACE");
        vm.warp(back + 1799);
        assertTrue(_state().inGrace, "last second of grace");
        vm.warp(back + 1800);
        v = _state();
        assertFalse(v.inGrace, "grace over");
        assertFalse(_has(v.reasons, 10));
    }

    // TEST-042 verifies: REQ-ORACLE-065, REQ-ORACLE-030, REQ-ORACLE-017, REQ-ORACLE-027
    /// @notice A failed configuration read held past `cachedWindow` reaches Expired but never latches, so its end
    /// clears the failure and opens no grace window.
    function test_TEST_042_configurationFailureOpensNoGrace() public {
        vm.mockCallRevert(address(store), abi.encodeWithSelector(store.getOracleInputs.selector), "down");
        _pokeAt(T0 + 60);
        _pokeAt(T0 + 60 + 3600);
        assertEq(uint8(_state().state), uint8(PriceState.Expired));
        assertFalse(_latched());
        vm.clearMockedCalls();
        vm.warp(T0 + 7300);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T0 + 7300);
        vm.recordLogs();
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ILPOracleEvents.GraceStarted.selector, "no grace");
        }
        (uint64 failedSince,,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(failedSince, 0, "failure cleared");
        assertEq(recoveredAt, 0, "no recovery time");
        assertFalse(_state().inGrace);
    }

    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021, REQ-ORACLE-016, REQ-ORACLE-029
    /// @notice The sequencer status changes only `liquidationPaused`, `borrowAllowed`, `inGrace` and bits 14 and 15:
    /// at the same state with the uptime feed down or up, the state, served price, timestamp and failure start are
    /// equal, and a poke while it is down still accepts the new Live price and records no failure.
    function test_TEST_276_sequencerNeverMovesStateOrTimers() public {
        vm.warp(T0 + 60);
        vm.roll(block.number + 1);
        _pushAll(99_900_000, T0 + 60);
        PriceStateView memory up = _state();
        seqFeed.setRound(2, 1, T0 + 50, T0 + 50);
        PriceStateView memory down = _state();
        assertEq(uint8(down.state), uint8(up.state), "state");
        assertEq(down.answer, up.answer, "served price");
        assertEq(down.servedUpdatedAt, up.servedUpdatedAt, "served timestamp");
        assertEq(down.failureStart, up.failureStart, "failure start");
        assertTrue(down.liquidationPaused, "down: seizure paused");
        assertFalse(down.borrowAllowed);
        assertTrue(_has(down.reasons, 14));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        (uint256 accepted, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(int256(accepted), up.answer, "accepted while the sequencer is down");
        assertEq(at, T0 + 60);
        (uint64 failedSince, uint64 disagreeSince,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(failedSince + disagreeSince + recoveredAt, 0, "no timer");
    }

    // TEST-276 verifies: REQ-ORACLE-099, REQ-ORACLE-034, SPEC-ORC-021
    /// @notice A sequencer restart inside a price grace window: `graceEndsAt` is the later of the two ends, `inGrace`
    /// holds until it, and borrowing stays closed until the sequencer's grace period has passed.
    function test_TEST_276_graceEndsAtTheLaterOfBothWindows() public {
        _pokeAt(STALE_AT + 3600);
        uint256 back = STALE_AT + 5000;
        vm.warp(back);
        vm.roll(block.number + 1);
        _othersAt(back);
        pB.push(int256(ONE), back);
        aB.push(int256(ONE), back);
        oracle.poke();
        seqFeed.setRound(3, 0, back + 600, back + 600);
        vm.warp(back + 700);
        PriceStateView memory v = _state();
        assertEq(v.graceEndsAt, back + 600 + 3600, "the sequencer window ends later");
        assertTrue(v.inGrace);
        assertTrue(_has(v.reasons, 15), "SEQUENCER_GRACE");
        assertFalse(v.borrowAllowed);
        vm.warp(back + 1800);
        v = _state();
        assertTrue(v.inGrace, "price grace over, sequencer grace on");
        assertTrue(_has(v.reasons, 10), "IN_GRACE reports either window");
        assertTrue(_has(v.reasons, 15), "SEQUENCER_GRACE");
        assertEq(v.graceEndsAt, back + 4200);
        vm.warp(back + 4200);
        _othersAt(back + 4200);
        pB.push(int256(ONE), back + 4200);
        aB.push(int256(ONE), back + 4200);
        oracle.poke();
        v = _state();
        assertFalse(v.inGrace, "both windows over");
        assertTrue(v.sequencerReady);
        assertTrue(v.borrowAllowed, "borrowing reopens");
    }
}
