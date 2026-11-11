// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleTransitionsUnitTest
/// @notice Every price-state transition of the USDC DebtOracle through `poke()`, each with the exact events it emits
/// (failure, disagreement, acceptance, state and route changes, in emission order) and the exact reason bitmap, served
/// price and served timestamp of the state it lands in: Live to Drifting and back, Live to Cached by invalid answers,
/// Cached to Expired at the exact end of the window, Expired back to Live with no grace, failover to the alternate and
/// back, Drifting straight into Cached, and a view that already reports a state no poke has written.
contract DebtOracleTransitionsUnitTest is DebtOracleFixture {
    uint256 internal constant R_NO_ROUTE = 1 << 0;
    uint256 internal constant R_DISAGREE = 1 << 3;
    uint256 internal constant R_ON_ALTERNATE = 1 << 9;
    uint256 internal constant R_PAUSE = 1 << 12;
    uint256 internal constant R_EXPIRED_DISAGREEMENT = 1 << 14;
    uint256 internal constant R_SECOND_SOURCE = 1 << 19;

    /// @dev USDC/ETH 0.0003333 x ETH/USD 3,090 = 1.029897 USD, 300 bps above the primary's 0.9999.
    int256 internal constant ETH_UP = 309_000_000_000;
    uint256 internal constant ALT_UP = 102_989_700;
    uint256 internal constant A0 = 99_990_000;

    function setUp() public {
        _deployDebtOracle();
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    // TEST-219 verifies: REQ-ORACLE-028, REQ-ORACLE-035, REQ-ORACLE-022, REQ-ORACLE-084, REQ-ORACLE-092, SPEC-ORC-016, SPEC-ORC-018
    // Sources: 2.10 SPEC-ORC-016 example (pause until disagreeSince + disagreementPauseMax, then expired), SPEC-ORC-018
    /// @notice Live to Drifting: the poke records `disagreeSince = now` with both route values and emits the state
    /// change with reasons DISAGREE | PAUSE; Drifting serves `max(p, b, A)` with the alternate's timestamp. At
    /// `disagreeSince + 3,600 - 1` the pause is still active; at `+ 3,600` the reason is EXPIRED and no new state event
    /// is emitted. When the routes agree again the poke clears the episode, returns to Live with reasons 0 and accepts
    /// the fresh primary quote.
    function test_TEST_219_liveDriftingLiveWithExactEvents() public {
        uint256 t1 = T0 + 10;
        vm.warp(t1);
        ethUsd.push(ETH_UP, t1);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtDisagreementRecorded(uint64(t1), A0, ALT_UP);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Live, PriceState.Drifting, R_DISAGREE | R_PAUSE);
        assertEq(uint8(_poke()), uint8(PriceState.Drifting));
        DebtPriceView memory v = _view();
        assertEq(v.reasons, R_DISAGREE | R_PAUSE);
        assertEq(uint256(v.answer), ALT_UP, "max(p, b, A) is the alternate");
        assertEq(v.servedUpdatedAt, T0 - 100, "the alternate's oldest leg");
        assertEq(v.disagreeSince, t1);
        assertTrue(v.disagreementPauseActive);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);

        vm.warp(t1 + 3599);
        v = _view();
        assertTrue(v.disagreementPauseActive, "one second before the bound");
        assertFalse(v.disagreementExpired);
        vm.warp(t1 + 3600);
        vm.recordLogs();
        _poke();
        assertEq(_count(vm.getRecordedLogs(), IDebtOracleEvents.DebtPriceStateChanged.selector), 0, "still Drifting");
        v = _view();
        assertEq(v.reasons, R_DISAGREE | R_EXPIRED_DISAGREEMENT);
        assertFalse(v.disagreementPauseActive);
        assertTrue(v.disagreementExpired);
        assertEq(v.disagreeSince, t1, "the episode keeps its start");

        uint256 t2 = t1 + 4000;
        vm.warp(t2);
        ethUsd.push(ETH_USD, t2);
        pUsd.push(99_995_000, t2);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtDisagreementCleared(uint64(t1), uint64(t2));
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceAccepted(99_995_000, uint64(t2), RouteSlot.Primary);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Drifting, PriceState.Live, 0);
        assertEq(uint8(_poke()), uint8(PriceState.Live));
        assertEq(_view().disagreeSince, 0);
        assertEq(_accepted(), 99_995_000);
    }

    // TEST-219 verifies: REQ-ORACLE-027, REQ-ORACLE-035, REQ-ORACLE-017, REQ-ORACLE-068, REQ-ORACLE-093, SPEC-ORC-013, SPEC-ORC-018
    // Sources: 2.10 SPEC-ORC-013 (an Invalid failure starts at the first failed read), SPEC-ORC-018 (Cached serves A,
    // Expired serves ceil(A x (10^4 + 500) / 10^4))
    /// @notice Both routes invalid (zero answers) at `t`: the poke records `failedSince = t` with reason NO_ROUTE, moves
    /// the route to None and the state to Cached; Cached serves the accepted price with its own timestamp until
    /// `t + 3,599`; at `t + 3,600` the state is Expired and serves 104,989,500; a poke there emits only the state change.
    /// Valid answers at `t + 4,000` clear the failure, accept the new quote and return to Live with no grace window
    /// (no source-timestamp outage was latched).
    function test_TEST_219_liveCachedExpiredLive() public {
        uint256 t = T0 + 30;
        vm.warp(t);
        pUsd.push(0, t);
        aEth.push(0, t);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtFailureRecorded(uint64(t), R_NO_ROUTE);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Live, PriceState.Cached, R_NO_ROUTE);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.Primary, RouteSlot.None);
        assertEq(uint8(_poke()), uint8(PriceState.Cached));
        DebtPriceView memory v = _view();
        assertEq(v.reasons, R_NO_ROUTE, "no second-source flag while failed");
        assertEq(uint256(v.answer), A0);
        assertEq(v.servedUpdatedAt, T0 - 100, "the accepted price keeps its timestamp");
        assertEq(v.failureStart, t);
        assertEq(v.cachedUntil, t + 3600);
        assertEq(v.quote, 0, "no quote while failed");
        assertEq(v.borrowPriceMaxAge, 0, "no age limit on the accepted price");
        assertEq(oracle.liquidationPriceMaxAge(), 0);
        assertEq(v.legFeeds[0], address(0), "no legs reported for the accepted price");

        vm.warp(t + 3599);
        assertEq(uint8(_state()), uint8(PriceState.Cached));
        assertEq(_served(), A0);
        vm.warp(t + 3600);
        assertEq(uint8(_state()), uint8(PriceState.Expired));
        assertEq(_served(), 104_989_500, "ceil(99,990,000 x 1.05)");
        assertEq(_view().stressAnswer, 104_989_500);
        vm.recordLogs();
        _poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only the state change");
        assertEq(logs[0].topics[0], IDebtOracleEvents.DebtPriceStateChanged.selector);

        uint256 back = t + 4000;
        vm.warp(back);
        pUsd.push(USDC_USD, back);
        aEth.push(USDC_ETH, back);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtFailureCleared(uint64(t), uint64(back));
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceAccepted(A0, uint64(back), RouteSlot.Primary);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Expired, PriceState.Live, 0);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.None, RouteSlot.Primary);
        vm.recordLogs();
        assertEq(uint8(_poke()), uint8(PriceState.Live));
        assertEq(_count(vm.getRecordedLogs(), IDebtOracleEvents.DebtGraceStarted.selector), 0, "no grace");
        v = _view();
        assertEq(v.failureStart, 0);
        assertEq(v.recoveredAt, 0);
        assertFalse(v.inGrace);
        assertEq(v.servedUpdatedAt, back);
    }

    // TEST-231 verifies: REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-019, REQ-ORACLE-029, REQ-ORACLE-035, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-006 (failover is automatic and re-evaluated on every read), REQ-ORACLE-029
    /// @notice The primary turns invalid: the next read uses the alternate (reason ON_ALTERNATE, still Live) and the
    /// poke emits only the route change; when both alternate legs publish, the poke accepts the alternate's quote with
    /// source Alternate; when the primary publishes again at the same second the route returns to Primary without a new
    /// acceptance (the quote is not newer than the accepted one).
    function test_TEST_231_failoverAndBackWithExactEvents() public {
        uint256 t = T0 + 20;
        vm.warp(t);
        pUsd.push(0, t);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.reasons, R_ON_ALTERNATE);
        assertEq(v.primaryValue, 0, "invalid primary reports no value");
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.Primary, RouteSlot.Alternate);
        vm.recordLogs();
        _poke();
        assertEq(vm.getRecordedLogs().length, 1, "only the route change");

        uint256 t2 = t + 60;
        vm.warp(t2);
        aEth.push(USDC_ETH, t2);
        ethUsd.push(ETH_USD, t2);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceAccepted(A0, uint64(t2), RouteSlot.Alternate);
        _poke();
        (uint256 price, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(price, A0);
        assertEq(at, t2);

        pUsd.push(99_995_000, t2);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.Alternate, RouteSlot.Primary);
        vm.recordLogs();
        _poke();
        assertEq(vm.getRecordedLogs().length, 1, "no acceptance at an equal timestamp");
        assertEq(_accepted(), A0, "the accepted price is the alternate's");
        assertEq(_served(), 99_995_000, "Live serves the fresh primary quote");
    }

    // TEST-219 verifies: REQ-ORACLE-027, REQ-ORACLE-028, REQ-ORACLE-035, SPEC-ORC-016
    // Sources: 2.10 REQ-ORACLE-028 (no disagreement while failed clears disagreeSince)
    /// @notice A failure during a disagreement: the poke records the failure, clears the disagreement, moves Drifting to
    /// Cached and the route to None, in that order.
    function test_TEST_219_driftingStraightIntoCached() public {
        uint256 t1 = T0 + 10;
        vm.warp(t1);
        ethUsd.push(ETH_UP, t1);
        _poke();
        uint256 t2 = t1 + 50;
        vm.warp(t2);
        pUsd.push(0, t2);
        aEth.push(0, t2);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtFailureRecorded(uint64(t2), R_NO_ROUTE);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtDisagreementCleared(uint64(t1), uint64(t2));
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtPriceStateChanged(PriceState.Drifting, PriceState.Cached, R_NO_ROUTE);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteChanged(RouteSlot.Primary, RouteSlot.None);
        _poke();
        DebtPriceView memory v = _view();
        assertEq(v.disagreeSince, 0);
        assertFalse(v.disagreementPauseActive);
        assertEq(uint256(v.answer), A0, "Cached serves A, not the higher route seen while Drifting");
    }

    // TEST-219 verifies: REQ-ORACLE-042, REQ-ORACLE-093, SPEC-ORC-016, Q-247
    // Sources: 2.10 SPEC-ORC-016 (a view that no poke has seen reads disagreeSince as 0 and s = now)
    /// @notice With no poke, a view reports the state the next poke would write: Drifting with the pause active and
    /// `disagreeSince = 0` at the moment of the disagreement; `latestRoundData` agrees with `getPriceState` field by
    /// field; the poke's return value equals the view's state.
    function test_TEST_219_viewAndPokeAgreeBeforeAnyWrite() public {
        vm.warp(T0 + 10);
        ethUsd.push(ETH_UP, T0 + 10);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(v.disagreeSince, 0, "no poke has seen the episode");
        assertTrue(v.disagreementPauseActive);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(answer, v.answer);
        assertEq(updatedAt, v.servedUpdatedAt);
        assertEq(startedAt, v.servedUpdatedAt);
        assertEq(roundId, uint80(v.servedUpdatedAt));
        assertEq(answeredInRound, roundId);
        assertEq(oracle.latestAnswer(), v.answer);
        assertEq(oracle.borrowPriceMaxAge(), v.borrowPriceMaxAge);
        assertEq(oracle.liquidationPriceMaxAge(), v.liquidationPriceMaxAge);
        assertEq(uint8(_poke()), uint8(v.state));
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-020 (|q - s| x 10^4 <= S x min(q, s), S = 100)
    /// @notice The second source confirms the quote exactly at its tolerance and not one unit beyond: with the quote
    /// at 99,990,000, a source at 98,999,999 is outside and sets the SECOND_SOURCE reason (borrowing closed, Live and
    /// liquidation unaffected); at 99,000,000 it confirms. The source above the quote is checked against the smaller
    /// value too.
    function test_TEST_276_secondSourceToleranceBoundary() public {
        vm.warp(T0 + 5);
        // |99,990,000 - s| x 10^4 <= 100 x s  <=>  s >= 99,990,000 x 10^4 / 10,100 = 99,000,000.
        second.push(98_999_999, T0 + 5);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.reasons, R_SECOND_SOURCE);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused, "the second source gates borrowing only");
        second.push(99_000_000, T0 + 5);
        v = _view();
        assertEq(v.reasons, 0);
        assertTrue(v.borrowAllowed);
        // Above the quote: |s - q| x 10^4 <= 100 x q  <=>  s <= 99,990,000 x 1.01 = 100,989,900.
        second.push(100_989_900, T0 + 5);
        assertTrue(_view().borrowAllowed, "at the upper bound");
        second.push(100_989_901, T0 + 5);
        assertFalse(_view().borrowAllowed, "one unit above it");
    }

    // TEST-231 verifies: REQ-ORACLE-095, REQ-ORACLE-065, REQ-ORACLE-017, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-095 (the route version is stored by a writing call that read it)
    /// @notice A poke whose version read fails stores no version and emits no observation (the asset is failed for that
    /// read); when the read works again with the version unchanged nothing is observed either; a real standby switch is
    /// then observed once as `(1, 2)`.
    function test_TEST_231_failedVersionReadStoresNoVersion() public {
        vm.warp(T0 + 10);
        reg.setMode(reg.priceRouteVersion.selector, HostileConfig.Mode.Revert);
        vm.recordLogs();
        _poke();
        assertEq(_count(vm.getRecordedLogs(), IDebtOracleEvents.DebtRouteVersionObserved.selector), 0);
        assertEq(uint8(_state()), uint8(PriceState.Cached), "a failed configuration read fails the asset");
        reg.setMode(reg.priceRouteVersion.selector, HostileConfig.Mode.Normal);
        vm.recordLogs();
        _poke();
        assertEq(_count(vm.getRecordedLogs(), IDebtOracleEvents.DebtRouteVersionObserved.selector), 0, "still 1");
        reg.useStandby(usdc, RouteSlot.Alternate);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteVersionObserved(1, 2);
        _poke();
        vm.recordLogs();
        _poke();
        assertEq(_count(vm.getRecordedLogs(), IDebtOracleEvents.DebtRouteVersionObserved.selector), 0, "observed once");
    }

    function _count(
        Vm.Log[] memory logs,
        bytes32 topic
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) ++n;
        }
    }
}
