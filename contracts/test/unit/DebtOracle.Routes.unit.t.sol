// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleRoutesUnitTest
/// @notice Legs, routes, failover, agreement, the disagreement windows, standby switches and route versions, and every
/// failure of a feed or configuration read: the DebtOracle never reverts and fails closed.
contract DebtOracleRoutesUnitTest is DebtOracleFixture {
    uint256 internal constant BIT_NO_ROUTE = 1 << 0;
    uint256 internal constant BIT_CONFIG = 1 << 2;
    uint256 internal constant BIT_DISAGREE = 1 << 3;
    uint256 internal constant BIT_ALTERNATE = 1 << 9;
    uint256 internal constant BIT_PAUSE = 1 << 12;
    uint256 internal constant BIT_EXPIRED = 1 << 14;
    uint256 internal constant BIT_STANDBY = 1 << 16;
    uint256 internal constant BIT_SEQ_DOWN = 1 << 17;
    uint256 internal constant BIT_SECOND = 1 << 19;

    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 60);
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    function _assertFailedOver(
        uint256 value
    ) internal view {
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live), "alternate keeps Live");
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertTrue(v.reasons & BIT_ALTERNATE != 0);
        assertEq(uint256(v.answer), value);
        assertEq(v.quote, value);
    }

    // ─── Failover (REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-067) ───

    // TEST-231 verifies: REQ-ORACLE-092, REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-067, REQ-ORACLE-019, Q-248
    // Sources: 5.1 TEST-231 (the DebtOracle fails over from its primary to its backup feed)
    function test_TEST_231_failsOverToAlternateAndBack() public {
        pUsd.push(0, block.timestamp);
        _assertFailedOver(99_990_000);
        _poke();
        pUsd.push(99_995_000, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(uint256(v.answer), 99_995_000);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.Alternate, RouteSlot.Primary);
        _poke();
    }

    // TEST-219 verifies: REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-067, REQ-ORACLE-092, REQ-ORACLE-061
    // Sources: 5.1 TEST-219 (answers 0, minAnswer, maxAnswer, negative, a decimals mismatch, updatedAt 0 and future)
    function test_TEST_219_invalidPrimaryAnswersFailOver() public {
        int256[5] memory bad = [int256(0), int256(-1), int256(1e12), int256(1e13), type(int256).min];
        for (uint256 i = 0; i < bad.length; ++i) {
            pUsd.push(bad[i], block.timestamp);
            _assertFailedOver(99_990_000);
        }
        pUsd.push(USDC_USD, 0);
        _assertFailedOver(99_990_000);
        pUsd.push(USDC_USD, block.timestamp + 1);
        _assertFailedOver(99_990_000);
        pUsd.push(USDC_USD, block.timestamp);
        pUsd.setDecimals(18);
        _assertFailedOver(99_990_000);
        pUsd.setDecimalsWord(256);
        _assertFailedOver(99_990_000);
    }

    // TEST-219 verifies: REQ-ORACLE-001, REQ-ORACLE-039, REQ-ORACLE-061, REQ-ORACLE-102, REQ-ORACLE-092
    // Sources: 5.1 TEST-219 (a reverting feed and an out-of-gas read)
    function test_TEST_219_hostileFeedReadsFailOverWithBoundedGas() public {
        MockAggregator.Mode[5] memory modes = [
            MockAggregator.Mode.Revert,
            MockAggregator.Mode.Short,
            MockAggregator.Mode.Bomb,
            MockAggregator.Mode.Burn,
            MockAggregator.Mode.Dirty
        ];
        for (uint256 i = 0; i < modes.length; ++i) {
            pUsd.setMode(pUsd.latestRoundData.selector, modes[i]);
            uint256 before = gasleft();
            _assertFailedOver(99_990_000);
            assertLt(before - gasleft(), 1_500_000, "a hostile feed cannot make the read expensive");
        }
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Normal);
        pUsd.setMode(pUsd.decimals.selector, MockAggregator.Mode.Bomb);
        _assertFailedOver(99_990_000);
    }

    // TEST-219 verifies: REQ-ORACLE-002, REQ-ORACLE-004, SPEC-ORC-001, SPEC-ORC-002, REQ-ORACLE-092
    function test_TEST_219_routeValueBounds() public {
        // A one-leg route normalising to 0 is Invalid.
        store.setFeed(address(pUsd), 18, 0, 1e30, 86_400, 1800);
        pUsd.setDecimals(18);
        pUsd.push(1, block.timestamp);
        _assertFailedOver(99_990_000);
        // A route value above MAX_ROUTE_ANSWER is Invalid even inside the pinned bounds.
        store.setFeed(address(pUsd), 8, 0, 1e30, 86_400, 1800);
        pUsd.setDecimals(8);
        pUsd.push(1e18 + 1, block.timestamp);
        _assertFailedOver(99_990_000);
        pUsd.push(1e18, block.timestamp);
        assertEq(uint8(_view().routeUsed), uint8(RouteSlot.Primary));
        // A two-leg route worth 0 is Invalid: the asset has no route.
        pUsd.push(0, block.timestamp);
        aEth.push(1, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(v.reasons & BIT_NO_ROUTE != 0);
        assertEq(uint256(v.answer), 99_990_000);
    }

    // TEST-276 verifies: REQ-ORACLE-092, SPEC-ORC-002, REQ-ORACLE-005
    function test_TEST_276_twoLegAlternateUsesOldestLegTimestamp() public {
        pUsd.push(0, block.timestamp);
        aEth.push(USDC_ETH, T0 + 10);
        ethUsd.push(ETH_USD, T0 + 30);
        DebtPriceView memory v = _view();
        assertEq(v.servedUpdatedAt, T0 + 10);
        assertEq(v.legFeeds[0], address(aEth));
        assertEq(v.legFeeds[1], address(ethUsd));
        assertEq(v.legUpdatedAt[1], T0 + 30);
    }

    // ─── Agreement and the disagreement windows ───

    // TEST-219 verifies: REQ-ORACLE-008, SPEC-ORC-003, REQ-ORACLE-092, REQ-ORACLE-070, INV-059
    // Sources: 5.1 TEST-219 (route divergence just inside and just outside feedAgreementToleranceBps)
    function test_TEST_219_agreementJustInsideAndOutside() public {
        // b = 99,990,000 with T = 225: p agrees iff |p - b| * 1e4 <= 225 * min(p, b).
        pUsd.push(102_239_775, block.timestamp);
        assertEq(uint8(_view().state), uint8(PriceState.Live));
        pUsd.push(102_239_776, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertTrue(v.reasons & BIT_DISAGREE != 0);
        assertEq(v.deviationBps, 225);
        assertEq(uint256(v.answer), 102_239_776);
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
    }

    /// @notice Review DO-01: while the routes disagree, the served timestamp, the age limits, the leg report and
    /// `latestRoundData().updatedAt` follow the route whose value is served. Primary 0.9999 from `T0 - 100`, alternate
    /// 1.03 published now: the alternate is served with its own timestamp, legs and limits (the hourly ETH/USD leg binds
    /// at 5,400 s). With both routes below the accepted price, the accepted price is served with its own timestamp and
    /// no route limits.
    // TEST-219 verifies: REQ-ORACLE-093, SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-090, REQ-ORACLE-092
    function test_TEST_219_disagreementTimestampsFollowServedRoute() public {
        vm.warp(T0 + 50_000);
        aEth.push(343_333_333_333_334, block.timestamp);
        ethUsd.republish(block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(uint256(v.answer), 103_000_000, "served = max(p, b, A) = b");
        assertEq(v.servedUpdatedAt, block.timestamp, "the alternate's timestamp");
        assertEq(v.legFeeds[0], address(aEth));
        assertEq(v.legFeeds[1], address(ethUsd));
        assertEq(v.borrowPriceMaxAge, 5400);
        assertEq(v.liquidationPriceMaxAge, 5400);
        assertEq(oracle.borrowPriceMaxAge(), 5400);
        (,, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, block.timestamp);
        assertEq(startedAt, block.timestamp);
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary), "the quote stays the primary");
        assertTrue(v.liquidationPaused && !v.borrowAllowed);

        // Both routes below A = 99,990,000 and disagreeing: A is served with the accepted timestamp, no route limits.
        pUsd.push(97_000_000, block.timestamp);
        aEth.push(331_666_666_666_667, block.timestamp);
        v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(uint256(v.answer), 99_990_000);
        assertEq(v.servedUpdatedAt, T0 - 100, "the accepted timestamp");
        assertEq(v.legFeeds[0], address(0));
        assertEq(v.borrowPriceMaxAge, 0);
        assertEq(v.liquidationPriceMaxAge, 0);
        (,,, updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, T0 - 100);

        // The primary above both: the primary is served with its own timestamp and legs.
        pUsd.push(103_500_000, block.timestamp - 10);
        v = _view();
        assertEq(uint256(v.answer), 103_500_000);
        assertEq(v.servedUpdatedAt, block.timestamp - 10);
        assertEq(v.legFeeds[0], address(pUsd));
        assertEq(v.legFeeds[1], address(0));
    }

    // TEST-219 verifies: REQ-ORACLE-022, REQ-ORACLE-023, REQ-ORACLE-028, REQ-ORACLE-084, SPEC-ORC-016, REQ-ORACLE-092, INV-059
    // Sources: 5.1 TEST-219 (divergence held across disagreementPauseMax ± 1 s)
    function test_TEST_219_disagreementPauseThenExpiry() public {
        pUsd.push(97_000_000, block.timestamp);
        uint64 since = uint64(block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtDisagreementRecorded(since, 97_000_000, 99_990_000);
        _poke();
        vm.warp(since + 3599);
        DebtPriceView memory v = _view();
        assertTrue(v.disagreementPauseActive);
        assertTrue(v.reasons & BIT_PAUSE != 0);
        assertEq(v.disagreeSince, since);
        assertTrue(v.liquidationPaused);
        _poke();
        vm.warp(since + 3600);
        v = _view();
        assertFalse(v.disagreementPauseActive);
        assertTrue(v.disagreementExpired);
        assertTrue(v.reasons & BIT_EXPIRED != 0);
        assertTrue(v.liquidationPaused);
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        // The stored start never moves while the disagreement lasts; agreement clears it.
        _poke();
        assertEq(_view().disagreeSince, since);
        pUsd.push(99_990_000, block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtDisagreementCleared(since, uint64(block.timestamp));
        _poke();
        assertEq(_view().disagreeSince, 0);
    }

    // TEST-219 verifies: SPEC-ORC-016, REQ-ORACLE-022, REQ-ORACLE-092
    function test_TEST_219_zeroPauseMaxExpiresAtOnceInAView() public {
        store.setTimers(3600, 0, 1800);
        pUsd.push(97_000_000, block.timestamp);
        DebtPriceView memory v = _view();
        assertFalse(v.disagreementPauseActive);
        assertTrue(v.disagreementExpired);
        assertTrue(v.liquidationPaused);
    }

    // ─── Standby switch and route versions (REQ-ORACLE-094, REQ-ORACLE-095) ───

    // TEST-231 verifies: REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-092, REQ-ORACLE-084, ATTACK-140, Q-248
    // Sources: 5.1 TEST-231 (a switch restarts the stored disagreement start and keeps the failure timer)
    function test_TEST_231_standbySwitchRestartsDisagreementTimer() public {
        pUsd.push(97_000_000, block.timestamp);
        _poke();
        uint64 first = _view().disagreeSince;
        vm.warp(block.timestamp + 1000);
        reg.useStandby(usdc, RouteSlot.Alternate);
        standby.push(99_000_000, block.timestamp);
        store.setTolerance(usdc, 100);
        // The view already measures the new routes' disagreement from now.
        DebtPriceView memory v = _view();
        assertEq(v.disagreeSince, 0);
        assertTrue(v.reasons & BIT_STANDBY != 0);
        assertEq(uint8(v.replaced), uint8(RouteSlot.Alternate));
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtRouteVersionObserved(1, 2);
        _poke();
        v = _view();
        assertEq(v.disagreeSince, uint64(block.timestamp));
        assertGt(v.disagreeSince, first);
        assertEq(v.routeVersion, 2);
        // A standby that agrees ends the disagreement on the next poke.
        standby.push(97_100_000, block.timestamp);
        _poke();
        assertEq(uint8(_view().state), uint8(PriceState.Live));
        assertEq(_view().disagreeSince, 0);
    }

    // TEST-231 verifies: REQ-ORACLE-095, REQ-ORACLE-027, REQ-ORACLE-092, SPEC-ORC-013, Q-248
    function test_TEST_231_switchToStaleStandbyKeepsFailureTimer() public {
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Revert);
        aEth.setMode(aEth.latestRoundData.selector, MockAggregator.Mode.Revert);
        _poke();
        uint64 failedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + 2000);
        reg.useStandby(usdc, RouteSlot.Primary);
        standby.setMode(standby.latestRoundData.selector, MockAggregator.Mode.Revert);
        _poke();
        DebtPriceView memory v = _view();
        assertEq(v.failureStart, failedAt);
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        vm.warp(failedAt + 3600);
        assertEq(uint8(_view().state), uint8(PriceState.Expired), "a switch never delays Expired");
        // A valid standby makes the asset Live at once, from the routes in force alone.
        standby.setMode(standby.latestRoundData.selector, MockAggregator.Mode.Normal);
        standby.push(99_990_000, block.timestamp);
        assertEq(uint8(_view().state), uint8(PriceState.Live));
    }

    // TEST-231 verifies: REQ-ORACLE-092, REQ-ORACLE-017, REQ-ORACLE-068, SPEC-ORC-013
    // Sources: 5.1 TEST-231 (the DebtOracle reaches Expired when every route fails)
    function test_TEST_231_everyRouteFailingReachesExpired() public {
        pUsd.setAll(MockAggregator.Mode.Revert);
        aEth.setAll(MockAggregator.Mode.Revert);
        ethUsd.setAll(MockAggregator.Mode.Revert);
        _poke();
        assertEq(uint8(_view().state), uint8(PriceState.Cached));
        vm.warp(block.timestamp + 3600);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(uint256(v.answer), 104_989_500);
        assertTrue(v.reasons & BIT_NO_ROUTE != 0);
        assertEq(v.primaryAge, type(uint64).max);
        assertEq(v.primaryValue, 0);
    }

    // ─── Configuration failures (REQ-ORACLE-017, REQ-ORACLE-069, REQ-ORACLE-092) ───

    function _assertConfigFailed() internal view {
        DebtPriceView memory v = _view();
        assertTrue(v.reasons & BIT_CONFIG != 0, "config bit");
        assertTrue(uint8(v.state) >= uint8(PriceState.Cached), "failed");
        assertGe(uint256(v.answer), 99_990_000);
        assertEq(v.borrowPriceMaxAge, 0);
        assertEq(v.liquidationPriceMaxAge, 0);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        assertEq(v.reasons & (BIT_DISAGREE | BIT_EXPIRED | BIT_SECOND), 0, "bits 3, 14, 19 are 0 when failed");
    }

    // TEST-219 verifies: REQ-ORACLE-017, REQ-ORACLE-069, REQ-ORACLE-092, REQ-ORACLE-094, REQ-ORACLE-061, REQ-ORACLE-083
    // Sources: 5.1 TEST-219 (configuration behaviour: revert, malformed data, out of gas)
    function test_TEST_219_registryReadFailuresFailTheAsset() public {
        bytes4[3] memory sels = [reg.getToken.selector, reg.activePriceRoutes.selector, reg.priceRouteVersion.selector];
        HostileConfig.Mode[4] memory modes = [
            HostileConfig.Mode.Revert, HostileConfig.Mode.Short, HostileConfig.Mode.Burn, HostileConfig.Mode.Oversized
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            for (uint256 j = 0; j < modes.length; ++j) {
                reg.setMode(sels[i], modes[j]);
                _assertConfigFailed();
                _poke();
            }
            reg.setMode(sels[i], HostileConfig.Mode.Normal);
        }
        reg.setListed(usdc, false);
        _assertConfigFailed();
    }

    // TEST-219 verifies: REQ-ORACLE-017, REQ-ORACLE-069, REQ-ORACLE-092, REQ-ORACLE-083
    function test_TEST_219_storeReadFailuresFailTheAsset() public {
        bytes4[4] memory sels = [
            store.getFeed.selector,
            store.feedAgreementToleranceBps.selector,
            store.disagreementPauseMax.selector,
            store.graceDuration.selector
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            store.setMode(sels[i], HostileConfig.Mode.Revert);
            _assertConfigFailed();
            assertEq(uint8(_view().state), uint8(PriceState.Cached));
            store.setMode(sels[i], HostileConfig.Mode.Oversized);
            _assertConfigFailed();
            store.setMode(sels[i], HostileConfig.Mode.Normal);
        }
        store.clearFeed(address(ethUsd));
        _assertConfigFailed();
    }

    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-018, REQ-ORACLE-017
    function test_TEST_219_unreadableWindowAndStressRiseFailClosed() public {
        store.setTimers(1800, 3600, 1800);
        _poke();
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Revert);
        _poke();
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "the window the last poke read applies");
        assertEq(v.cachedUntil, uint64(block.timestamp + 1800));
        assertEq(uint256(v.answer), 99_990_000);
        vm.warp(block.timestamp + 1800);
        v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(uint256(v.answer), 104_989_500);
        store.setMode(store.debtStressRiseBps.selector, HostileConfig.Mode.Revert);
        // The last good delta (500, read by the last poke) applies, not 100: ceil(99,990,000 * 10,500 / 10,000).
        assertEq(_served(), 104_989_500);
        assertEq(_view().debtStressRiseBps, 500);
    }

    /// @notice A failed `debtStressRiseBps` read keeps the value the last writing call read, as `lastCachedWindow`
    /// does for the window: a poke that reads 200 bps makes 200 the fallback; a later value seen only by views is not
    /// stored; a failed read during the poke leaves the stored value.
    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-018, REQ-ORACLE-017
    function test_TEST_219_failedStressRiseReadKeepsLastGoodValue() public {
        store.setStressRise(usdc, 200);
        _poke();
        store.setStressRise(usdc, 300);
        store.setMode(store.debtStressRiseBps.selector, HostileConfig.Mode.Revert);
        _poke();
        vm.warp(T0 + 200_000);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(v.debtStressRiseBps, 200, "the value the last successful poke read");
        assertEq(uint256(v.answer), 101_989_800, "ceil(99,990,000 x 10,200 / 10,000)");
        store.setMode(store.debtStressRiseBps.selector, HostileConfig.Mode.Normal);
        assertEq(_served(), 102_989_700, "a good read serves the store's 300 bps");
    }

    // TEST-219 verifies: REQ-ORACLE-017, REQ-ORACLE-094, REQ-ORACLE-092
    function test_TEST_219_malformedRoutesFailTheAsset() public {
        reg.setRoutes(usdc, new address[](3), _route1(address(standby)));
        _assertConfigFailed();
        reg.setRoutes(usdc, _route1(address(pUsd)), new address[](0));
        _assertConfigFailed();
    }

    // TEST-276 verifies: REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-092
    // Sources: 5.1 TEST-276 (liquidation does not require the second source)
    function test_TEST_276_sequencerAndSecondSourceReadFailuresOnlyBlockBorrowing() public {
        assertTrue(_view().borrowAllowed);
        store.setMode(store.sequencer.selector, HostileConfig.Mode.Revert);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertTrue(v.reasons & BIT_SEQ_DOWN != 0);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
        store.setMode(store.sequencer.selector, HostileConfig.Mode.Normal);
        store.setMode(store.secondSource.selector, HostileConfig.Mode.Burn);
        v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertTrue(v.reasons & BIT_SECOND != 0);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
    }
}
