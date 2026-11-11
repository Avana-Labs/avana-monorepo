// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleTimersUnitTest
/// @notice `poke()`: the failure start (`SPEC-ORC-013`), the outage latch, recovery evidence and the phase rule
/// (`SPEC-ORC-014`, `REQ-ORACLE-089`), the grace window (`REQ-ORACLE-032` to `REQ-ORACLE-034`), the accepted price
/// (`REQ-ORACLE-029`), events, and a worst-case poke at `pokeMinGas`.
contract DebtOracleTimersUnitTest is DebtOracleFixture {
    uint256 internal constant STALE_AT = T0 + 88_101;
    bytes32 internal constant GRACE_TOPIC = keccak256("DebtGraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployDebtOracle();
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    function _pokeCountingGrace() internal returns (uint256 starts) {
        vm.recordLogs();
        _poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == GRACE_TOPIC) ++starts;
        }
    }

    // ─── Failure start (SPEC-ORC-013, REQ-ORACLE-027) ───

    // TEST-219 verifies: SPEC-ORC-013, REQ-ORACLE-027, REQ-ORACLE-017, REQ-ORACLE-092, REQ-ORACLE-068
    // Sources: SPEC-ORC-013 (the Cached window starts at the first failed read, whenever poke runs)
    function test_TEST_219_failureStartFromSourceTimestamps() public {
        // Primary stale from T0 + 88,101; alternate from T0 + 5,301 (its ETH/USD leg); both stale from T0 + 88,101.
        vm.warp(T0 + 90_000);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.failureStart, STALE_AT);
        assertEq(v.cachedUntil, STALE_AT + 3600);
        assertTrue(v.reasons & (1 << 11) != 0);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtFailureRecorded(uint64(STALE_AT), v.reasons);
        _poke();
        vm.warp(STALE_AT + 3599);
        assertEq(uint8(_view().state), uint8(PriceState.Cached));
        vm.warp(STALE_AT + 3600);
        assertEq(uint8(_view().state), uint8(PriceState.Expired));
    }

    // TEST-219 verifies: SPEC-ORC-013, REQ-ORACLE-027, REQ-ORACLE-092
    // Sources: SPEC-ORC-013 precision example (a late reading reports Expired earlier, never later)
    function test_TEST_219_unobservedRecoveryKeepsEarlierFailureStart() public {
        vm.warp(T0 + 1000);
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Revert);
        aEth.setMode(aEth.latestRoundData.selector, MockAggregator.Mode.Revert);
        _poke();
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Normal);
        vm.warp(T0 + 5000);
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Revert);
        vm.warp(T0 + 5100);
        DebtPriceView memory v = _view();
        assertEq(v.failureStart, T0 + 1000);
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        // Recovery clears the failure timer.
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Normal);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtFailureCleared(uint64(T0 + 1000), uint64(T0 + 5100));
        _poke();
    }

    // ─── Latch and grace (REQ-ORACLE-030, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-065) ───

    // TEST-219 verifies: REQ-ORACLE-030, REQ-ORACLE-065, REQ-ORACLE-092, REQ-ORACLE-033
    // Sources: 5.1 TEST-105 and TEST-042 (the latch moves only on source timestamps, never on a caught error)
    function test_TEST_219_caughtErrorsNeverLatchOrStartGrace() public {
        vm.warp(T0 + 10);
        pUsd.setAll(MockAggregator.Mode.Revert);
        aEth.setAll(MockAggregator.Mode.Revert);
        _poke();
        vm.warp(T0 + 10 + 7200);
        assertEq(uint8(_view().state), uint8(PriceState.Expired));
        _poke();
        pUsd.setAll(MockAggregator.Mode.Normal);
        aEth.setAll(MockAggregator.Mode.Normal);
        _refreshAll();
        assertEq(_pokeCountingGrace(), 0);
        assertEq(_view().recoveredAt, 0);
    }

    // TEST-219 verifies: REQ-ORACLE-030, REQ-ORACLE-032, SPEC-ORC-014, REQ-ORACLE-034, REQ-ORACLE-092, Q-264
    // Sources: 5.1 TEST-219 (a grace window opens after each Expired recovery)
    function test_TEST_219_latchThenRecoveryByEvidence() public {
        vm.warp(STALE_AT + 3600);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtOutageExpiredLatched(uint64(STALE_AT), uint64(STALE_AT + 3600));
        _poke();
        uint256 back = T0 + 92_000;
        vm.warp(back);
        _refreshAll();
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtGraceStarted(uint64(back), uint64(back + 1800), false);
        _poke();
        DebtPriceView memory v = _view();
        assertTrue(v.inGrace);
        assertEq(v.recoveredAt, back);
        assertEq(v.graceEndsAt, back + 1800);
        assertTrue(v.reasons & (1 << 13) != 0);
        // One grace per outage.
        vm.warp(back + 100);
        _refreshAll();
        assertEq(_pokeCountingGrace(), 0);
        vm.warp(back + 1800);
        assertFalse(_view().inGrace);
    }

    // TEST-219 verifies: REQ-ORACLE-032, REQ-ORACLE-092, Q-264
    // Sources: REQ-ORACLE-032 (c): the latch set and no interval determinable
    function test_TEST_219_latchWithoutEvidenceStartsAtNewestLeg() public {
        vm.warp(STALE_AT + 3600);
        _poke();
        uint256 back = T0 + 92_000;
        vm.warp(back);
        pUsd.setMode(pUsd.getRoundData.selector, MockAggregator.Mode.Revert);
        pUsd.push(USDC_USD, back - 20);
        _refresh(aEth);
        _refresh(ethUsd);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtGraceStarted(uint64(back - 20), uint64(back - 20 + 1800), true);
        _poke();
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-031, REQ-ORACLE-092, ATTACK-145
    // Sources: SPEC-ORC-014 (an outage that starts and ends between two pokes still opens grace)
    function test_TEST_219_outageBetweenPokesOpensGrace() public {
        uint256 back = T0 + 200_000;
        vm.warp(back);
        _refreshAll();
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtGraceStarted(uint64(back), uint64(back + 1800), false);
        _poke();
        // A short gap (below the cached window) gives no evidence.
        vm.warp(back + 88_200 + 1000);
        _refreshAll();
        assertEq(_pokeCountingGrace(), 0);
    }

    // TEST-231 verifies: REQ-ORACLE-032, REQ-ORACLE-095, REQ-ORACLE-065, REQ-ORACLE-092, Q-248
    // Sources: REQ-ORACLE-032 (a): a standby switch observed while latched starts grace at the poke
    function test_TEST_231_switchWhileLatchedStartsGraceAtPoke() public {
        vm.warp(STALE_AT + 3600);
        _poke();
        vm.warp(STALE_AT + 4000);
        reg.useStandby(usdc, RouteSlot.Primary);
        standby.push(99_990_000, block.timestamp - 30);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtGraceStarted(uint64(block.timestamp), uint64(block.timestamp + 1800), true);
        _poke();
    }

    // ─── Phase rule (REQ-ORACLE-089) ───

    /// @dev Primary recovers on the first round of phase 2 at `T0 + 92,000`; the alternate stays stale. The stored
    /// round is from `T0 - 100`, so its gap alone lasts 3,899 s >= 3,600.
    function _phaseRecovery(
        MockAggregator previous
    ) internal returns (uint256 starts) {
        vm.warp(T0 + 92_010);
        pUsd.pushNewPhase(USDC_USD, T0 + 92_000, address(previous));
        assertEq(pUsd.roundId(), (uint80(2) << 64) | 1);
        return _pokeCountingGrace();
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-092, ATTACK-150, Q-272
    // Sources: 5.1 TEST-220 (unit part with a mock proxy)
    function test_TEST_220_previousPhaseRoundBoundsTheGap() public {
        // The previous phase's last round at T0 + 1,000 shortens the gap to 2,799 s: no evidence.
        MockAggregator previous = new MockAggregator(8, USDC_USD, T0 + 1000);
        assertEq(_phaseRecovery(previous), 0);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-092, Q-272
    function test_TEST_220_revertingPreviousPhaseFallsBackToSeen() public {
        MockAggregator previous = new MockAggregator(8, USDC_USD, T0 + 1000);
        previous.setMode(previous.latestRoundData.selector, MockAggregator.Mode.Revert);
        assertEq(_phaseRecovery(previous), 1);
        assertEq(_view().recoveredAt, T0 + 92_000);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, Q-272
    function test_TEST_220_zeroTimestampPreviousPhaseFallsBackToSeen() public {
        MockAggregator previous = new MockAggregator(8, USDC_USD, T0 + 1000);
        previous.setCurrent(USDC_USD, 0);
        assertEq(_phaseRecovery(previous), 1);
        assertEq(_view().recoveredAt, T0 + 92_000);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075
    function test_TEST_220_zeroPreviousAggregatorFallsBackToSeen() public {
        assertEq(_phaseRecovery(MockAggregator(address(0))), 1);
    }

    // ─── Accepted price and events (REQ-ORACLE-029, REQ-ORACLE-035) ───

    // TEST-219 verifies: REQ-ORACLE-029, REQ-ORACLE-066, REQ-ORACLE-021, REQ-ORACLE-092
    function test_TEST_219_acceptedOnlyWhenLiveAndNewer() public {
        vm.warp(T0 + 10);
        vm.recordLogs();
        _poke();
        assertEq(vm.getRecordedLogs().length, 0, "re-reading the same rounds stores nothing");
        (, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(at, T0 - 100);
        pUsd.push(97_000_000, T0 + 10);
        _poke();
        (, at) = oracle.lastAcceptedPrice();
        assertEq(at, T0 - 100, "a Drifting quote is not accepted");
        pUsd.push(99_980_000, T0 + 10);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtPriceAccepted(99_980_000, uint64(T0 + 10), RouteSlot.Primary);
        _poke();
    }

    // TEST-219 verifies: REQ-ORACLE-035, REQ-ORACLE-092
    function test_TEST_219_stateChangeEvents() public {
        vm.warp(T0 + 100_000);
        vm.expectEmit(true, true, true, false);
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Live, PriceState.Cached, 0);
        _poke();
        _refreshAll();
        vm.expectEmit(true, true, true, false);
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Cached, PriceState.Live, 0);
        _poke();
    }

    // ─── Worst-case poke at pokeMinGas (SPEC-ORC-023) ───

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-038, REQ-ORACLE-102, REQ-ORACLE-092, SPEC-ORC-023
    // Sources: SPEC-ORC-023 (POKE_MIN_GAS_FLOOR covers the worst-case poke)
    function test_TEST_042_worstCasePokeCompletesAtMinimumGas() public {
        MockAggregator pA = new MockAggregator(18, USDC_ETH, T0 - 100);
        MockAggregator pB = new MockAggregator(8, ETH_USD, T0 - 100);
        store.setFeed(address(pA), 18, 0, 1e18, 86_400, 1800);
        store.setFeed(address(pB), 8, 0, 1e12, 3600, 1800);
        reg.setRoutes(usdc, _route2(address(pA), address(pB)), _route2(address(aEth), address(ethUsd)));
        MockAggregator seq = new MockAggregator(0, 0, T0 - 50_000);
        store.setSequencer(address(seq), 3600);
        _poke();
        // Every leg recovers after a long gap; the first primary leg starts a new phase.
        uint256 back = T0 + 200_000;
        vm.warp(back);
        MockAggregator previous = new MockAggregator(18, USDC_ETH, T0 - 50);
        pA.pushNewPhase(USDC_ETH, back, address(previous));
        _refresh(pB);
        _refresh(aEth);
        _refresh(ethUsd);
        _refresh(second);
        // The proxy forwards 63/64 of its gas to the implementation, so this call reaches poke() with just above
        // pokeMinGas, the minimum a caller can give it.
        uint256 before = gasleft();
        oracle.poke{gas: (uint256(MIN_GAS) * 64) / 63 + 10_000}();
        uint256 used = before - gasleft();
        emit log_named_uint("worst-case DebtOracle poke gas", used);
        assertTrue(_view().inGrace);
    }
}
