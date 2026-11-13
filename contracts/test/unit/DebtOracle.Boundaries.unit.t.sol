// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleBoundariesUnitTest
/// @notice The exact edges of every validity rule of the USDC DebtOracle, each one unit inside and one unit outside:
/// the pinned answer bounds (both exclusive), the pinned decimals, `updatedAt` at 0, now and now + 1, the age limit
/// of each alternate leg, the leg normalisation at 6, 8 and 18 decimals and a one-leg value that floors to 0, the
/// route bound `MAX_ROUTE_ANSWER = 10^12`, the stress rise read below 100 bps, and the sequencer answers that are
/// neither up nor down.
contract DebtOracleBoundariesUnitTest is DebtOracleFixture {
    uint256 internal constant R_NO_ROUTE = 1 << 0;
    uint256 internal constant R_ON_ALTERNATE = 1 << 9;
    uint256 internal constant R_SEQUENCER_DOWN = 1 << 17;

    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    function _routeUsed() internal view returns (RouteSlot) {
        return _view().routeUsed;
    }

    // TEST-219 verifies: REQ-ORACLE-002, REQ-ORACLE-006, REQ-ORACLE-067, REQ-ORACLE-092
    // Sources: 5.1 TEST-219 (answers minAnswer +- 1, maxAnswer +- 1)
    /// @notice With the primary pinned to `(99,000,000, 101,000,000)`, both bounds exclusive: 99,000,000 and
    /// 101,000,000 are invalid (the alternate serves), 99,000,001 and 100,999,999 are valid (the primary serves).
    function test_TEST_219_pinnedAnswerBoundsAreExclusive() public {
        store.setFeed(address(pUsd), 8, 99_000_000, 101_000_000, 86_400, 1800);
        int256[4] memory answers = [int256(99_000_000), 99_000_001, 100_999_999, 101_000_000];
        bool[4] memory valid = [false, true, true, false];
        for (uint256 i = 0; i < 4; ++i) {
            pUsd.push(answers[i], block.timestamp);
            DebtPriceView memory v = _view();
            assertEq(uint8(v.routeUsed), uint8(valid[i] ? RouteSlot.Primary : RouteSlot.Alternate), "route by bound");
            assertEq(uint8(v.state), uint8(PriceState.Live), "failover keeps Live");
            assertEq(v.reasons & R_ON_ALTERNATE != 0, !valid[i]);
            if (valid[i]) assertEq(v.primaryValue, uint256(answers[i]));
        }
    }

    // TEST-219 verifies: REQ-ORACLE-002, REQ-ORACLE-067, REQ-ORACLE-092
    // Sources: 5.1 TEST-219 (a decimals mismatch; updatedAt 0 and in the future)
    /// @notice A primary reporting 9 decimals against 8 pinned is invalid; a `decimals()` word above 255 does not
    /// decode (an error leg); an `updatedAt` of 0 or one second in the future is invalid; exactly now is valid.
    function test_TEST_219_decimalsAndTimestampEdges() public {
        pUsd.setDecimals(9);
        assertEq(uint8(_routeUsed()), uint8(RouteSlot.Alternate), "decimals mismatch");
        pUsd.setDecimals(8);
        pUsd.setDecimalsWord(256);
        assertEq(uint8(_routeUsed()), uint8(RouteSlot.Alternate), "decimals word above uint8");
        pUsd.setDecimalsWord(8);
        assertEq(uint8(_routeUsed()), uint8(RouteSlot.Primary), "a clean 8 decodes");
        pUsd.push(USDC_USD, 0);
        assertEq(uint8(_routeUsed()), uint8(RouteSlot.Alternate), "updatedAt 0");
        pUsd.push(USDC_USD, block.timestamp + 1);
        assertEq(uint8(_routeUsed()), uint8(RouteSlot.Alternate), "updatedAt in the future");
        pUsd.push(USDC_USD, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary), "updatedAt now");
        assertEq(v.primaryAge, 0);
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-002, REQ-ORACLE-067
    // Sources: 2.10 REQ-ORACLE-092 (1) (a leg updatedAt of 2^64 or more is a failed decode: Error)
    /// @notice A primary round stamped `2^64` does not decode (an error leg: no value reported, age unknown); stamped
    /// `2^64 - 1` it decodes but lies in the future (an invalid leg whose value is still reported); either way the
    /// alternate serves.
    function test_TEST_219_updatedAtAt64Bits() public {
        pUsd.push(USDC_USD, uint256(type(uint64).max) + 1);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.primaryValue, 0, "an error leg reports no value");
        assertEq(v.primaryAge, type(uint64).max);
        pUsd.push(USDC_USD, type(uint64).max);
        v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.primaryValue, 99_990_000, "an invalid leg still reports its value");
        assertEq(v.primaryAge, type(uint64).max, "a future timestamp has no age");
    }

    // TEST-276 verifies: SPEC-ORC-019, SPEC-ORC-013, REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-019 (feedMaxAge = heartbeat + margin per leg; ETH/USD 3,600 + 1,800 = 5,400)
    /// @notice With the primary invalid, the alternate's ETH/USD leg is fresh at exactly 5,400 s and stale at 5,401 s:
    /// the asset is Live on the alternate, then failed with NO_ROUTE only (one route Invalid, so no source-timestamp
    /// failure) and a failure start at the current time; the stale route reports its value and age.
    function test_TEST_276_alternateLegAgeBoundary() public {
        pUsd.push(0, block.timestamp);
        uint256 published = block.timestamp;
        ethUsd.push(ETH_USD, published);
        aEth.push(USDC_ETH, published);
        vm.warp(published + 5400);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.alternateAge, 5400);
        vm.warp(published + 5401);
        v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.reasons, R_NO_ROUTE, "no source-timestamp failure with an invalid primary");
        assertEq(v.failureStart, published + 5401, "the failure starts now");
        assertEq(v.alternateValue, 99_990_000, "a stale route still reports its value");
        assertEq(v.alternateAge, 5401);
        assertEq(uint256(v.answer), 99_990_000, "Cached serves the accepted price");
    }

    // TEST-219 verifies: SPEC-ORC-001, SPEC-ORC-002, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-001 (n = a x 10^(8 - f) for f <= 8, floor(a / 10^(f - 8)) above)
    /// @notice A primary pinned at 6 decimals answering 999,900 and one pinned at 18 decimals answering 0.9999 x 10^18
    /// both value USDC at 99,990,000; an 18-decimal answer of `10^10 - 1` floors to 0 and the one-leg route is invalid.
    function test_TEST_219_legNormalisationAcrossDecimals() public {
        store.setFeed(address(pUsd), 6, 0, 1e12, 86_400, 1800);
        pUsd.setDecimals(6);
        pUsd.push(999_900, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(v.primaryValue, 99_990_000, "6 decimals scaled up");
        store.setFeed(address(pUsd), 18, 0, 1e30, 86_400, 1800);
        pUsd.setDecimals(18);
        pUsd.push(999_900_000_000_000_000, block.timestamp);
        v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(v.primaryValue, 99_990_000, "18 decimals scaled down");
        pUsd.push(9_999_999_999, block.timestamp);
        v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate), "a value that floors to 0 is invalid");
        assertEq(v.primaryValue, 0);
    }

    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-002, REQ-ORACLE-008
    // Sources: 2.10 REQ-ORACLE-092 (2): a route value above MAX_ROUTE_ANSWER = 10^12 is Invalid
    /// @notice An alternate of 0.5 x 2,000,000 = exactly 10^12 is valid (and disagrees with the primary, so the asset
    /// drifts and serves it); one unit above, 10^12 + 1, is invalid, so nothing disagrees and the primary serves Live.
    function test_TEST_219_routeValueBoundAtTenToThe18() public {
        store.setFeed(address(ethUsd), 8, 0, 1e20, 3600, 1800);
        aEth.push(500_000_000_000_000_000, block.timestamp);
        ethUsd.push(2_000_000_000_000_000_000, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(v.alternateValue, 1e18);
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "valid at the bound, and far from the primary");
        assertEq(uint256(v.answer), 1e18, "Drifting serves the higher route");
        ethUsd.push(2_000_000_000_000_000_002, block.timestamp);
        v = _view();
        assertEq(v.alternateValue, 1e18 + 1, "the value is reported");
        assertEq(uint8(v.state), uint8(PriceState.Live), "but the route is invalid");
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(uint256(v.answer), 99_990_000);
    }

    // TEST-230 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087
    // Sources: 2.10 SPEC-ORC-018 (a value below 100 is read as 100; the rise rounds up)
    /// @notice Expired serves `ceil(A x (10^4 + max(delta, 100)) / 10^4)`: delta 0 and 99 serve A x 1.01, delta 100
    /// the same, delta 101 serves A x 1.0101; the report keeps the stored value (capped at 5,000) and its stress answer
    /// equals the served price.
    function test_TEST_230_stressRiseFloorOf100Bps() public {
        _expire();
        uint16[4] memory deltas = [uint16(0), 99, 100, 101];
        uint256[4] memory served = [uint256(100_989_900), 100_989_900, 100_989_900, 100_999_899];
        for (uint256 i = 0; i < 4; ++i) {
            store.setStressRise(usdc, deltas[i]);
            DebtPriceView memory v = _view();
            assertEq(uint8(v.state), uint8(PriceState.Expired));
            assertEq(uint256(v.answer), served[i], "stress price");
            assertEq(v.stressAnswer, served[i]);
            assertEq(v.debtStressRiseBps, deltas[i], "reported as read");
            assertGt(uint256(v.answer), v.acceptedAnswer, "Expired is always above A");
        }
    }

    // TEST-276 verifies: SPEC-ORC-021, REQ-ORACLE-099, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-021 (up = answer 0, startedAt != 0 and <= now; any other answer or a failed read is unknown)
    /// @notice An up answer with `startedAt = 0`, with `startedAt` one second in the future, a reverting sequencer
    /// read and a failing `sequencer()` configuration read are each unknown: borrowing closes, the SEQUENCER_DOWN reason
    /// is set, liquidation stays open and the price is unaffected. `startedAt = now - 3,600` is ready; `now - 3,599`
    /// is in grace until exactly `startedAt + 3,600`.
    function test_TEST_276_sequencerUnknownAndGraceEdges() public {
        MockAggregator seq = new MockAggregator(0, 0, block.timestamp - 3600);
        store.setSequencer(address(seq), 3600);
        DebtPriceView memory v = _view();
        assertTrue(v.borrowAllowed, "ready at startedAt + grace");
        assertEq(v.reasons, 0);
        seq.setStartedAt(block.timestamp - 3599);
        v = _view();
        assertFalse(v.borrowAllowed, "grace one second before");
        assertTrue(v.inGrace);
        assertEq(v.graceEndsAt, block.timestamp + 1);
        assertFalse(v.liquidationPaused);

        seq.setStartedAt(0);
        _assertUnknown("startedAt 0");
        seq.setStartedAt(block.timestamp + 1);
        _assertUnknown("startedAt in the future");
        seq.setStartedAt(block.timestamp - 7200);
        seq.setMode(seq.latestRoundData.selector, MockAggregator.Mode.Revert);
        _assertUnknown("a reverting feed");
        seq.setMode(seq.latestRoundData.selector, MockAggregator.Mode.Normal);
        assertTrue(_view().borrowAllowed, "back to ready");
        store.setMode(store.sequencer.selector, HostileConfig.Mode.Revert);
        _assertUnknown("a failing configuration read");
        store.setMode(store.sequencer.selector, HostileConfig.Mode.Oversized);
        _assertUnknown("an oversized configuration word");
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-017, REQ-ORACLE-069, SPEC-ORC-013
    // Sources: 2.10 SPEC-ORC-013 (a failed configuration read uses lastCachedWindow, the window the last writing call
    // read)
    /// @notice A poke that reads a 100-second window stores it; a later window of 5,000 seconds seen only by views is not
    /// stored; when the window read itself fails the asset is failed (CONFIG_UNAVAILABLE) and Expired after the stored
    /// 100 seconds, not 5,000.
    function test_TEST_219_failedWindowReadUsesTheLastPokedWindow() public {
        store.setTimers(100, 3600, 1800);
        _poke();
        store.setTimers(5000, 3600, 1800);
        assertEq(uint8(_state()), uint8(PriceState.Live), "a view sees the new window but stores nothing");
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Revert);
        uint256 failedAt = block.timestamp;
        _poke();
        DebtPriceView memory v = _view();
        assertEq(v.reasons, 1 << 2, "CONFIG_UNAVAILABLE only");
        assertEq(v.cachedUntil, failedAt + 100, "the stored window");
        vm.warp(failedAt + 99);
        assertEq(uint8(_state()), uint8(PriceState.Cached));
        vm.warp(failedAt + 100);
        assertEq(uint8(_state()), uint8(PriceState.Expired));
    }

    function _assertUnknown(
        string memory what
    ) internal view {
        DebtPriceView memory v = _view();
        assertFalse(v.borrowAllowed, what);
        assertEq(v.reasons & R_SEQUENCER_DOWN, R_SEQUENCER_DOWN, what);
        assertFalse(v.liquidationPaused, what);
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(uint256(v.answer), 99_990_000, what);
    }

    /// @dev Both routes invalid from now; a poke records the failure, and the window passes.
    function _expire() internal {
        pUsd.push(0, block.timestamp);
        aEth.push(0, block.timestamp);
        _poke();
        vm.warp(block.timestamp + 3600);
    }
}
