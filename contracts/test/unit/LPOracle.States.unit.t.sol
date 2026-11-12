// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Leg validity, failover, agreement, failure start and the Drifting causes of the LPOracle base (2.10).
contract LPOracleStatesUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    // TEST-040 verifies: REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-007, REQ-ORACLE-019, REQ-ORACLE-067, Q-079, Q-130, REQ-ORACLE-079
    // Sources: 5.1 TEST-040, SIM-02C
    function test_TEST_040_failoverKeepsLive() public {
        vm.warp(T0 + MAX_AGE + 1);
        aA.push(int256(ONE), T0 + MAX_AGE + 1);
        aB.push(int256(ONE), T0 + MAX_AGE + 1);
        sA.push(int256(ONE), T0 + MAX_AGE + 1);
        sB.push(int256(ONE), T0 + MAX_AGE + 1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "stale primary, fresh alternate: Live");
        assertEq(v.tokens[0].routeUsed, 2);
        assertTrue(_has(v.reasons, 7), "ANY_TOKEN_ON_ALTERNATE");
        assertTrue(v.tokens[0].reasons & (1 << 2) != 0, "ON_ALTERNATE");
        // The primary is used again on the next read once it is valid again; no transaction is needed.
        pA.push(int256(ONE), T0 + MAX_AGE + 1);
        v = _state();
        assertEq(v.tokens[0].routeUsed, 1, "primary back");
        assertFalse(_has(v.reasons, 7) && v.tokens[0].routeUsed == 2);
    }

    // TEST-040 verifies: REQ-ORACLE-008, SPEC-ORC-003, Q-112, Q-130
    function test_TEST_040_agreementOnlyWhenBothReport() public {
        vm.warp(T0 + 60);
        aA.push(97_500_000, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "both valid, outside 150 bps: Drifting");
        assertTrue(_has(v.reasons, 2), "ANY_TOKEN_DISAGREE");
        assertEq(v.tokens[0].routeUsed, 1, "the quote stays the primary");
        // Only the disagreeing alternate valid? No: with the primary invalid, no agreement check runs.
        pA.push(0, T0 + 60);
        v = _state();
        assertEq(v.tokens[0].routeUsed, 2);
        assertFalse(_has(v.reasons, 2), "one valid route: no agreement check");
        // Exactly at the tolerance: |p - b| * 10^4 == T * min(p, b) agrees (T = 150, b = 98,522,167 rounds the edge).
        pA.push(100_000_000, T0 + 60);
        aA.push(98_600_000, T0 + 60);
        assertFalse(_has(_state().reasons, 2), "1,400,000 * 10^4 <= 150 * 98,600,000");
        aA.push(98_500_000, T0 + 60);
        assertTrue(_has(_state().reasons, 2), "1,500,000 * 10^4 > 150 * 98,500,000");
    }

    // TEST-040 verifies: REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-067, SPEC-ORC-019, Q-056, Q-119, Q-191, Q-322
    function test_TEST_040_legValidity() public {
        uint256 t = T0 + 100;
        vm.warp(t);
        // Each failed condition makes the primary leg Invalid and the alternate quote.
        pA.setDecimals(18);
        assertEq(_state().tokens[0].routeUsed, 2, "decimals mismatch");
        pA.setDecimals(8);
        pA.push(1, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer == minAnswer");
        pA.push(1e12, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer == maxAnswer");
        pA.setRound(9, int256(ONE), t, 0);
        assertEq(_state().tokens[0].routeUsed, 2, "updatedAt == 0");
        pA.setRound(10, int256(ONE), t, t + 1);
        assertEq(_state().tokens[0].routeUsed, 2, "updatedAt in the future");
        // Age: valid at exactly feedMaxAge, Stale one second later.
        pA.setRound(11, int256(ONE), t - MAX_AGE, t - MAX_AGE);
        assertEq(_state().tokens[0].routeUsed, 1, "age == heartbeat + margin is fresh");
        pA.setRound(12, int256(ONE), t - MAX_AGE - 1, t - MAX_AGE - 1);
        assertEq(_state().tokens[0].routeUsed, 2, "age 88,201 is stale");
    }

    // TEST-040 verifies: REQ-ORACLE-021, REQ-ORACLE-066, SPEC-ORC-012, INV-056, Q-182
    function test_TEST_040_sameRoundNeverRefreshes() public {
        vm.warp(T0 + 5000);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.servedUpdatedAt, T0, "re-reading the same rounds keeps their timestamp");
        assertEq(v.servedAge, 5000);
        (, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(at, T0, "caching the same rounds never refreshes the accepted timestamp");
        // The oldest input serves: token B's rounds are older.
        pA.push(int256(ONE), T0 + 4000);
        aA.push(int256(ONE), T0 + 4000);
        assertEq(_state().servedUpdatedAt, T0);
    }

    // TEST-040 verifies: REQ-ORACLE-017, SPEC-ORC-013, REQ-ORACLE-068, Q-079, Q-154, Q-183
    function test_TEST_040_failureStartFromSourceTimestamps() public {
        // Token B: primary stale from T0 + 88,201; alternate updated later, stale from T0 + 1,000 + 88,201.
        aB.push(int256(ONE), T0 + 1000);
        uint256 staleAt = T0 + 1000 + MAX_AGE + 1;
        vm.warp(staleAt + 10);
        pA.push(int256(ONE), staleAt + 10);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.failureStart, staleAt, "failureStart is the first second both routes failed");
        assertEq(v.cachedUntil, staleAt + 3600);
        assertTrue(_has(v.reasons, 8), "SOURCE_TIMESTAMP_FAILURE");
        vm.warp(staleAt + 3600);
        assertEq(
            uint8(_state().state), uint8(PriceState.Expired), "Expired at failureStart + cachedWindow, poked or not"
        );
    }

    // TEST-040 verifies: REQ-ORACLE-018, REQ-ORACLE-014, REQ-ORACLE-071, REQ-ORACLE-072, REQ-ORACLE-104, REQ-ORACLE-103, Q-119, Q-330
    function test_TEST_040_driftingCausesFromThePricingModule() public {
        oracle.setConsistency(true, false, type(uint256).max, false);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertTrue(_has(v.reasons, 5), "CONSISTENCY_UNAVAILABLE");
        assertEq(v.consistencyDeviationBps, type(uint256).max);
        oracle.setConsistency(false, true, 73, false);
        v = _state();
        assertTrue(_has(v.reasons, 4), "CONSISTENCY_DEVIATION");
        assertEq(v.consistencyDeviationBps, 73);
        oracle.setConsistency(false, false, 3, true);
        assertTrue(_has(_state().reasons, 6), "PRICE_CLAMPED");
        oracle.setConsistency(false, false, 0, false);
        // A held pool lock fails the market (bit 17); a failed lock read or composition is bit 1.
        oracle.setLock(false, true);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(_has(v.reasons, 17), "POOL_REENTRANCY_LOCKED");
        oracle.setLock(true, false);
        assertTrue(_has(_state().reasons, 1));
        oracle.setLock(false, false);
        oracle.setCompositionFails(true);
        v = _state();
        assertTrue(_has(v.reasons, 1), "malformed module read");
        assertEq(uint8(v.state), uint8(PriceState.Cached));
    }

    // TEST-040 verifies: REQ-ORACLE-017, REQ-ORACLE-069, REQ-ORACLE-083, REQ-ORACLE-043, Q-240, Q-248
    function test_TEST_040_configurationFailuresFailTheMarket() public {
        store.setMode(store.getOracleInputs.selector, ReadMode.Revert);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "config read fails: failed");
        assertTrue(_has(v.reasons, 1));
        assertEq(v.borrowPriceMaxAge, 0);
        assertEq(v.cachedUntil, T0 + 3600, "the window read by the last writing call");
        store.setMode(store.getOracleInputs.selector, ReadMode.Short);
        assertTrue(_has(_state().reasons, 1), "malformed config");
        store.setMode(store.getOracleInputs.selector, ReadMode.Normal);
        registry.setMode(registry.activePriceRoutes.selector, ReadMode.Revert);
        assertTrue(_has(_state().reasons, 1), "route read fails");
        registry.setMode(registry.activePriceRoutes.selector, ReadMode.Normal);
        registry.setRoutes(address(tokenA), new address[](0), _one(address(aA)), RouteSlot.None);
        assertTrue(_has(_state().reasons, 1), "route with no leg");
        registry.setRoutes(address(tokenA), _one(address(pA)), _one(address(aA)), RouteSlot.None);
        store.setMode(store.getFeed.selector, ReadMode.Revert);
        assertTrue(_has(_state().reasons, 1), "feed definition read fails");
        store.setMode(store.getFeed.selector, ReadMode.Normal);
        assertEq(uint8(_state().state), uint8(PriceState.Live));
        // Token decimals are the values stored at initialize: evaluation does not read them again.
        tokenB.setDecimals(18);
        assertEq(uint8(_state().state), uint8(PriceState.Live), "token decimals are fixed at listing");
        tokenB.setMode(tokenB.decimals.selector, ReadMode.Revert);
        assertEq(oracle.latestAnswer(), int256(SEEDED), "no token read on the price path");
        tokenB.setMode(tokenB.decimals.selector, ReadMode.Normal);
        tokenB.setDecimals(6);
    }
}
