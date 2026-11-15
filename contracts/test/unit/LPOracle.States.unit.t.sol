// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {TokenPriceView} from "../../src/types/TokenPriceView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

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

    // TEST-040 verifies: REQ-ORACLE-017, SPEC-ORC-013, REQ-ORACLE-068
    /// @notice The mirror of `failureStartFromSourceTimestamps`: token B's primary is updated later (at T0 + 1,000) and
    /// goes stale at T0 + 1,000 + 88,201, after its alternate (stale from T0 + 88,201). Both routes have failed from the
    /// later of the two, the primary's, so that is the failure start and the cached window runs an hour from it.
    function test_TEST_040_failureStartFromTheLaterPrimary() public {
        pB.push(int256(ONE), T0 + 1000);
        uint256 staleAt = T0 + 1000 + MAX_AGE + 1;
        vm.warp(staleAt + 10);
        pA.push(int256(ONE), staleAt + 10);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.failureStart, staleAt, "failureStart is the primary's later stale start");
        assertEq(v.cachedUntil, staleAt + 3600);
        assertTrue(_has(v.reasons, 8), "SOURCE_TIMESTAMP_FAILURE");
    }

    // TEST-040 verifies: REQ-ORACLE-018, REQ-ORACLE-071, REQ-ORACLE-072, REQ-ORACLE-103, Q-119, Q-330
    /// @dev The core's reaction to each module answer (the base's test module supplies them); the concentrated-liquidity
    /// module's own reads are checked on real pools in LPOracleCL.Module.unit.t.sol (REQ-ORACLE-014, REQ-ORACLE-104).
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

    // TEST-040 verifies: REQ-ORACLE-017, REQ-ORACLE-095, REQ-ORACLE-099, REQ-ORACLE-042
    /// @notice A failed configuration read quotes no token, reports no route reading and no sequencer, and a poke of
    /// it observes no route version.
    function test_TEST_040_failedConfigurationReadReportsNoRouteAndKeepsVersions() public {
        registry.bumpVersion(address(tokenA));
        vm.warp(T0 + 60);
        vm.roll(block.number + 1);
        oracle.poke();
        assertEq(oracle.storedRouteVersion(0), 1, "control: version 1 stored");
        store.setMode(store.getOracleInputs.selector, ReadMode.Revert);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.tokens[0].routeUsed, 0, "no route in use");
        assertEq(v.tokens[0].quote, 0, "no quote");
        assertEq(v.tokens[0].reasons, 0, "no token reason");
        assertEq(v.tokens[0].primaryAge, type(uint64).max, "no reading");
        assertFalse(v.sequencerReady, "no sequencer read without a configuration");
        vm.roll(block.number + 1);
        oracle.poke();
        assertEq(oracle.storedRouteVersion(0), 1, "a failed read observes no version");
    }

    // TEST-040 verifies: REQ-ORACLE-042, REQ-ORACLE-021, SPEC-ORC-012, SPEC-ORC-015
    /// @notice The report of a Live market gives each route's value and age, their deviation, the second source's
    /// deviation, the legs in use with their age limits, the accepted timestamp, no reason bit and no grace end.
    function test_TEST_040_reportReadingsOfEachRoute() public {
        uint256 t = T0 + 600;
        vm.warp(t);
        pA.push(100_000_000, t - 100);
        aA.push(99_000_000, t - 200);
        sA.push(99_500_000, t - 50);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.reasons, 0, "agreeing routes, confirmed sources: no reason bit");
        assertEq(v.graceEndsAt, 0, "no grace window");
        assertEq(v.acceptedUpdatedAt, T0, "the seeded timestamp");
        TokenPriceView memory a = v.tokens[0];
        assertEq(a.token, address(tokenA));
        assertEq(v.tokens[1].token, address(tokenB));
        assertEq(a.updatedAt, t - 100, "the quote route's timestamp");
        assertEq(a.primaryValue, 100_000_000);
        assertEq(a.primaryAge, 100);
        assertEq(a.alternateValue, 99_000_000);
        assertEq(a.alternateAge, 200);
        assertEq(a.deviationBps, 101, "floor(10^6 * 10^4 / 99,000,000)");
        assertEq(a.secondSourceValue, 99_500_000);
        assertEq(a.secondSourceDeviationBps, 50, "floor(500,000 * 10^4 / 99,500,000)");
        assertEq(a.legFeeds[0], address(pA));
        assertEq(a.legUpdatedAt[0], t - 100);
        assertEq(a.legBorrowPriceMaxAge[0], MAX_AGE);
        assertEq(a.legLiquidationPriceMaxAge[0], MAX_AGE);
    }

    // TEST-040 verifies: REQ-ORACLE-042, REQ-ORACLE-095, REQ-ORACLE-028, REQ-ORACLE-005
    /// @notice Token reason bits (disagreement, standby, no route), the route version read and the stored
    /// disagreement start appear in the report.
    function test_TEST_040_tokenReasonBitsAndRouteVersion() public {
        uint256 t = T0 + 60;
        vm.warp(t);
        vm.roll(block.number + 1);
        aB.push(97_000_000, t);
        registry.setRoutes(address(tokenB), _one(address(pB)), _one(address(aB)), RouteSlot.Primary);
        registry.bumpVersion(address(tokenB));
        oracle.poke();
        PriceStateView memory v = _state();
        assertTrue(v.tokens[1].reasons & (1 << 1) != 0, "TOKEN_DISAGREE");
        assertTrue(v.tokens[1].reasons & (1 << 3) != 0, "TOKEN_ON_STANDBY");
        assertEq(v.tokens[1].routeVersion, 1, "the route version read");
        assertEq(v.disagreeSince, t, "the disagreement start the poke stored");
        pA.setMode(pA.latestRoundData.selector, ReadMode.Revert);
        aA.setMode(aA.latestRoundData.selector, ReadMode.Revert);
        assertTrue(_state().tokens[0].reasons & (1 << 0) != 0, "TOKEN_NO_ROUTE");
    }

    function _assertNoReading(
        string memory what
    ) internal view {
        TokenPriceView memory a = _state().tokens[0];
        assertEq(a.routeUsed, 2, what);
        assertEq(a.primaryValue, 0, what);
        assertEq(a.primaryAge, type(uint64).max, what);
    }

    // TEST-040 verifies: REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-042
    /// @notice A primary whose round reverts, whose round is 128 bytes, or whose `decimals()` reverts is Error: the
    /// alternate quotes and the primary is reported as `(0, type(uint64).max)`.
    function test_TEST_040_unreadableRouteReportsNoReading() public {
        uint256 t = T0 + 60;
        vm.warp(t);
        pA.setMode(pA.latestRoundData.selector, ReadMode.Revert);
        _assertNoReading("reverting round");
        pA.setMode(pA.latestRoundData.selector, ReadMode.Normal);
        vm.mockCall(
            address(pA), abi.encodeCall(OracleFeedMock.latestRoundData, ()), abi.encode(uint256(5), int256(ONE), t, t)
        );
        _assertNoReading("128-byte round");
        vm.clearMockedCalls();
        pA.setMode(pA.decimals.selector, ReadMode.Revert);
        _assertNoReading("decodable round, reverting decimals()");
    }

    // TEST-040 verifies: REQ-ORACLE-001, REQ-ORACLE-003
    /// @notice A round whose roundId or answeredInRound word exceeds 80 bits is a failed read.
    function test_TEST_040_roundIdsBeyond80BitsAreUnreadable() public {
        uint256 t = T0 + 60;
        vm.warp(t);
        bytes memory call = abi.encodeCall(OracleFeedMock.latestRoundData, ());
        vm.mockCall(address(pA), call, abi.encode(uint256(1) << 128, int256(ONE), t, t, uint256(1)));
        assertEq(_state().tokens[0].routeUsed, 2, "roundId 2^128");
        vm.mockCall(address(pA), call, abi.encode(uint256(1), int256(ONE), t, t, uint256(1) << 128));
        assertEq(_state().tokens[0].routeUsed, 2, "answeredInRound 2^128");
        vm.mockCall(address(pA), call, abi.encode(uint256(1) << 80, int256(ONE), t, t, uint256(1)));
        assertEq(_state().tokens[0].routeUsed, 2, "roundId 2^80");
        vm.clearMockedCalls();
        assertEq(_state().tokens[0].routeUsed, 1, "control");
    }

    // TEST-040 verifies: REQ-ORACLE-002, REQ-ORACLE-003, SPEC-ORC-019
    /// @notice More leg validity edges: an answer above `maxAnswer`, an `updatedAt` beyond 64 bits (the future), an
    /// `updatedAt` of 1 (stale) and an answer below a `minAnswer` above 1 each make the primary unusable.
    function test_TEST_040_legValidityEdges() public {
        uint256 t = T0 + 100;
        vm.warp(t);
        pA.push(2e12, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer above maxAnswer");
        pA.setRound(20, int256(ONE), t, (uint256(1) << 64) + t);
        assertEq(_state().tokens[0].routeUsed, 2, "updatedAt beyond 64 bits is in the future");
        pA.setRound(21, int256(ONE), 1, 1);
        assertEq(_state().tokens[0].routeUsed, 2, "a round at timestamp 1 is stale");
        FeedDef memory d = store.getFeed(address(pA));
        d.minAnswer = 1e6;
        store.setFeed(address(pA), d);
        pA.push(5e5, t);
        assertEq(_state().tokens[0].routeUsed, 2, "answer below minAnswer = 10^6");
        pA.push(2e6, t);
        assertEq(_state().tokens[0].routeUsed, 1, "control: above minAnswer");
    }

    // TEST-040 verifies: REQ-ORACLE-004, SPEC-ORC-002, REQ-ORACLE-042
    /// @notice A two-leg route in use: its value is the product of its legs, its timestamp the older leg, both legs
    /// appear in the report, and an Invalid second leg makes the route Invalid.
    function test_TEST_040_twoLegRouteInTheReport() public {
        OracleFeedMock xB = _feed("xB");
        registry.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None);
        uint256 t = T0 + 300;
        vm.warp(t);
        pB.push(0, t);
        aB.push(50_000_000, t - 100);
        xB.push(200_000_000, t - 200);
        TokenPriceView memory b = _state().tokens[1];
        assertEq(b.routeUsed, 2, "the two-leg alternate quotes");
        assertEq(b.alternateValue, 100_000_000, "0.5 x 2.0");
        assertEq(b.alternateAge, 200, "the route's timestamp is its older leg");
        assertEq(b.legFeeds[0], address(aB));
        assertEq(b.legFeeds[1], address(xB));
        assertEq(b.legUpdatedAt[1], t - 200);
        xB.push(1e12, t);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "second leg at maxAnswer: no valid route");
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
    }

    // TEST-040 verifies: REQ-ORACLE-004, SPEC-ORC-013, REQ-ORACLE-017
    /// @notice Two Invalid routes with non-zero values (answers at `maxAnswer`) are Invalid, not Stale: no
    /// source-timestamp failure, and the failure starts now.
    function test_TEST_040_twoInvalidRoutesAreNotStale() public {
        vm.warp(T0 + 60);
        pA.push(1e12, T0 + 60);
        aA.push(1e12, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
        assertFalse(_has(v.reasons, 8), "no SOURCE_TIMESTAMP_FAILURE");
        assertEq(v.failureStart, T0 + 60);
    }
}
