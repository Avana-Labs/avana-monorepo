// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPOracleCLTimersTest
/// @notice The stored timers of the real concentrated-liquidity LPOracle on real Uniswap v3 pools: the disagreement
/// start and pause, its expiry for seizure and its end by agreement or a standby switch; `poke()` against
/// `getPriceState()` in every state and a poke from inside the pool's lock that writes nothing; the hourly checkpoint;
/// the one-block quote-change cap and the price vector `getTokenPrices()` serves; the grace start after an outage.
contract LPOracleCLTimersTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;
    uint256 internal constant LOW = 97_500_000;

    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    /// @dev The stable market with token1's alternate at 97.5 cents against $1.00 on its primary: 250 bps > 150 bps.
    function _disagreeing() internal {
        _stable();
        a1Feed.push(int256(LOW), T1);
    }

    function _token0(
        uint256 price,
        uint256 at
    ) internal {
        p0Feed.push(int256(price), at);
        a0Feed.push(int256(price), at);
        s0Feed.push(int256(price), at);
    }

    function _next(
        uint256 at
    ) internal {
        vm.warp(at);
        vm.roll(block.number + 1);
    }

    function _oracleLogs(
        Vm.Log[] memory logs
    ) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(oracle)) ++n;
        }
    }

    // ─── TEST-159: the stored disagreement start ───

    // TEST-159 verifies: REQ-ORACLE-028, REQ-ORACLE-022, INV-059
    /// @notice A view measures the pause from now and stores nothing; the first poke that sees the disagreement stores
    /// its time and emits `DisagreementRecorded` with both routes' values; a later poke keeps the stored time; the
    /// pause ends at the stored time plus `disagreementPauseMax` with no call in between, leaving the market Expired
    /// for its own seizure while the routes disagree.
    function test_TEST_159_firstObservationStoredAndKept() public {
        _disagreeing();
        PriceStateView memory v = _state();
        assertEq(v.disagreeSince, 0, "no poke has seen it yet");
        assertTrue(v.disagreementPauseActive, "a view measures the pause from now");
        uint256[] memory primary = new uint256[](2);
        uint256[] memory alternate = new uint256[](2);
        (primary[0], primary[1], alternate[0], alternate[1]) = (ONE, ONE, ONE, LOW);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.DisagreementRecorded(uint64(T1), primary, alternate);
        oracle.poke();
        assertEq(_state().disagreeSince, T1, "stored at the first observation");
        _next(T1 + 900);
        oracle.poke();
        assertEq(_state().disagreeSince, T1, "a later poke never moves it");
        vm.warp(T1 + 3599);
        assertTrue(_state().disagreementPauseActive, "inside disagreementPauseMax");
        vm.warp(T1 + 3600);
        v = _state();
        assertFalse(v.disagreementPauseActive, "the pause ends with no call in between");
        assertTrue(v.disagreementExpired, "Expired for its own seizure");
        assertTrue(v.liquidationPaused, "seizure stays blocked");
        assertTrue(_has(v.reasons, 11), "DISAGREEMENT_EXPIRED");
    }

    // TEST-159 verifies: REQ-ORACLE-028, REQ-ORACLE-023, REQ-ORACLE-024
    /// @notice Agreement clears the stored start with `DisagreementCleared`; a gas-starved poke reverts and stores
    /// nothing, so the next view still measures from now.
    function test_TEST_159_agreementClearsAndAStarvedPokeStoresNothing() public {
        _disagreeing();
        (bool ok,) = address(oracle).call{gas: POKE_FLOOR - 1}(abi.encodeCall(oracle.poke, ()));
        assertFalse(ok, "below pokeMinGas");
        assertEq(_state().disagreeSince, 0, "nothing stored");
        oracle.poke();
        _next(T1 + 120);
        a1Feed.push(int256(ONE), T1 + 120);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.DisagreementCleared(uint64(T1), uint64(T1 + 120));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "agreement: Live");
        assertEq(_state().disagreeSince, 0, "cleared");
    }

    // ─── TEST-044 / TEST-157: the pause and its expiry ───

    // TEST-044 verifies: REQ-ORACLE-022, REQ-ORACLE-084, SPEC-ORC-016, SPEC-ORC-017
    /// @notice From the first stored observation seizure of the market is paused and borrowing is blocked; the market
    /// is valued at its lower route (token1 at 97.5 cents), never above the fresh or accepted price, served by the
    /// lower route's legs. After `disagreementPauseMax` with the routes still apart the market stays Drifting (not
    /// Cached) and is Expired for its own seizure until the routes agree.
    function test_TEST_044_pauseFromFirstObservationThenExpiredForSeizure() public {
        _disagreeing();
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(v.disagreementPauseActive && v.liquidationPaused, "seizure paused");
        assertTrue(_has(v.reasons, 9), "DISAGREEMENT_PAUSE");
        assertFalse(v.borrowAllowed, "borrowing blocked");
        assertLt(uint256(v.answer), uint256(v.freshAnswer), "valued at the lower route");
        assertLe(uint256(v.answer), uint256(v.acceptedAnswer), "never above the accepted price");
        assertEq(v.tokens[1].legFeeds[0], address(a1Feed), "the lower route's legs serve");
        _next(T1 + 3600);
        oracle.poke();
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "still Drifting, not Cached");
        assertTrue(v.disagreementExpired && v.liquidationPaused, "Expired for its own seizure");
        assertFalse(v.borrowAllowed, "borrowing still blocked");
        a1Feed.push(int256(ONE), T1 + 3600);
        oracle.poke();
        v = _state();
        assertFalse(v.liquidationPaused || v.disagreementExpired, "agreement resumes seizure");
        assertTrue(v.borrowAllowed, "and borrowing");
    }

    // TEST-157 verifies: REQ-ORACLE-084, REQ-ORACLE-094, REQ-ORACLE-007
    /// @notice Persistent disagreement past `disagreementPauseMax`: Expired for seizure with borrowing blocked; a
    /// guardian's standby switch of the wrong route's slot in the MarketRegistry, read on the next evaluation, ends
    /// it with no LPOracle write: the standby agrees with the primary and seizure resumes.
    function test_TEST_157_persistentDisagreementEndsWithAStandbySwitch() public {
        _disagreeing();
        oracle.poke();
        _next(T1 + 3600);
        oracle.poke();
        PriceStateView memory v = _state();
        assertTrue(v.disagreementExpired, "Expired for seizure");
        assertFalse(v.borrowAllowed, "borrow and withdraw-with-debt refused");
        OracleFeedMock standby = _feed("standby", ONE);
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(address(standby)), RouteSlot.Alternate);
        registry.bumpVersion(address(token1));
        v = _state();
        assertFalse(_has(v.reasons, 2), "the standby agrees");
        assertFalse(v.disagreementExpired || v.liquidationPaused, "seizure resumes on the next evaluation");
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
    }

    // ─── TEST-042: poke against the report, and the checkpoint ───

    function _pokeMatches(
        string memory label
    ) internal {
        uint256 snap = vm.snapshotState();
        PriceStateView memory v = _state();
        assertEq(uint8(oracle.poke()), uint8(v.state), label);
        PriceStateView memory after_ = _state();
        assertEq(uint8(after_.state), uint8(v.state), "the stored timers keep the state");
        assertEq(after_.answer, oracle.latestAnswer(), "answer == latestAnswer() after the poke");
        vm.revertToState(snap);
    }

    // TEST-042 verifies: REQ-ORACLE-026, REQ-ORACLE-016
    /// @notice In every state `poke()` returns the state `getPriceState()` reports in the same block: Live, Drifting
    /// by disagreement, by the band and by an unavailable TWAP read, Cached by a failed token and by the quote-change
    /// cap, and Expired from source timestamps.
    function test_TEST_042_pokeReturnsTheReportedStateInEveryState() public {
        _stable();
        _pokeMatches("Live");
        a1Feed.push(int256(LOW), T1);
        _pokeMatches("Drifting by disagreement");
        a1Feed.push(int256(ONE), T1);
        _setPrices(89_000_000, 89_000_000);
        _pokeMatches("Drifting by the band");
        _setPrices(ONE, ONE);
        vm.mockCallRevert(address(pool), abi.encodeWithSignature("observe(uint32[])"), "observe");
        _pokeMatches("Drifting by an unavailable consistency read");
        vm.clearMockedCalls();
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        _pokeMatches("Cached by a failed token");
        vm.clearMockedCalls();
        oracle.poke();
        _setPrices(98_000_000, 98_000_000);
        _pokeMatches("Cached by the quote-change cap");
        uint256 staleAt = T1 + MAX_AGE + 1;
        _next(staleAt + 3600);
        _token0(ONE, staleAt + 3600);
        s1Feed.push(int256(ONE), staleAt + 3600);
        assertEq(uint8(_state().state), uint8(PriceState.Expired));
        _pokeMatches("Expired from source timestamps");
    }

    // TEST-042 verifies: REQ-ORACLE-088
    /// @notice `initialize` seeds the checkpoint at the listing price and time; a poke inside the hour leaves it; the
    /// first poke an hour or more later copies the accepted price, after accepting the newer price of that same poke;
    /// in a failed market it copies the last accepted price, never the fresh or served one.
    function test_TEST_042_checkpointCopiesTheAcceptedPriceHourly() public {
        _stable();
        (uint256 seeded, uint64 seededAt) = oracle.lastAcceptedPrice();
        (uint256 cp, uint64 at) = oracle.priceCheckpoint();
        assertEq(cp, seeded, "seeded price");
        assertEq(at, seededAt, "seeded at initialize");
        assertEq(at, T0);
        _next(T0 + 3599);
        _setPrices(99_900_000, 99_900_000);
        oracle.poke();
        (, at) = oracle.priceCheckpoint();
        assertEq(at, T0, "not before CHECKPOINT_INTERVAL");
        _next(T0 + 3600);
        _setPrices(99_800_000, 99_800_000);
        oracle.poke();
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        assertEq(acceptedAt, T0 + 3600, "this poke accepted the newer rounds");
        (cp, at) = oracle.priceCheckpoint();
        assertEq(cp, accepted, "the price accepted in the same poke");
        assertEq(at, T0 + 3600);
        // A failed market an hour later: the checkpoint copies the accepted price, not a fresh or served one.
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        _next(T0 + 7200);
        _token0(99_000_000, T0 + 7200);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached), "failed");
        (cp, at) = oracle.priceCheckpoint();
        assertEq(cp, accepted, "the last accepted price");
        assertEq(at, T0 + 7200, "at the block time");
    }

    // ─── TEST-306: a poke inside the pool's lock ───

    // TEST-306 verifies: REQ-ORACLE-026, REQ-ORACLE-103
    /// @notice A market Live with no stored disagreement start, poked from inside a real flash callback of its pool
    /// while token1's routes disagree, returns the failed state and writes nothing: no event, no disagreement start, no
    /// accepted price, no checkpoint and no token-decimals verification. The next poke outside the callback stores
    /// the start at its own time.
    function test_TEST_306_pokeInsideThePoolLockWritesNothing() public {
        _stable();
        oracle.poke();
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        (uint256 cp, uint64 cpAt) = oracle.priceCheckpoint();
        (, uint64 verifiedAt) = oracle.decimalsStatus();
        _next(T0 + 3600);
        _setPrices(ONE, ONE);
        a1Feed.push(int256(LOW), T0 + 3600);
        vm.recordLogs();
        actor.flash(pool, 1e6, 0, address(oracle), abi.encodeWithSignature("poke()"));
        assertEq(_oracleLogs(vm.getRecordedLogs()), 0, "no event");
        assertTrue(actor.lastOk(), "poke inside the lock completes");
        assertEq(abi.decode(actor.lastResult(), (uint8)), uint8(PriceState.Cached), "returns the failed state");
        assertEq(_state().disagreeSince, 0, "no disagreement start");
        (uint256 a2, uint64 at2) = oracle.lastAcceptedPrice();
        assertEq(a2, accepted);
        assertEq(at2, acceptedAt, "no accepted price");
        (uint256 cp2, uint64 cpAt2) = oracle.priceCheckpoint();
        assertEq(cp2, cp);
        assertEq(cpAt2, cpAt, "no checkpoint, though an hour has passed");
        (, uint64 v2) = oracle.decimalsStatus();
        assertEq(v2, verifiedAt, "no decimals verification");
        oracle.poke();
        assertEq(_state().disagreeSince, T0 + 3600, "the next poke outside stores the start");
    }

    // ─── TEST-283 / TEST-038: the quote-change cap and the served price vector ───

    // TEST-283 verifies: REQ-ORACLE-103, REQ-AMM-CORE-014
    /// @notice The per-block quote-change cap on the concentrated-liquidity LPOracle: a poke stores an accepted price;
    /// in the same block a quote 2 % lower (every route of both tokens at $0.98) is not accepted: every evaluation of
    /// the block is Cached with `QUOTE_CHANGE_CAPPED`, serves the accepted price with borrowing refused, and the poke
    /// emits `QuoteChangeCapped` and stores nothing. A move within 1 % is accepted in the same block, and the next
    /// block accepts the larger move.
    function test_TEST_283_quoteMovedPastTheCapInOneBlockIsNotAccepted() public {
        _stable();
        oracle.poke();
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        assertEq(acceptedAt, T1, "accepted in this block");
        // Newer rounds in the same block: one second later, `block.number` unchanged.
        vm.warp(T1 + 1);
        _setPrices(98_000_000, 98_000_000);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "capped: Cached");
        assertTrue(_has(v.reasons, 18), "QUOTE_CHANGE_CAPPED");
        assertEq(uint256(v.answer), accepted, "serves the accepted price");
        assertFalse(v.borrowAllowed, "the price read for new borrowing is refused");
        vm.recordLogs();
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool capped;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == ILPOracleEvents.QuoteChangeCapped.selector) {
                capped = true;
            }
        }
        assertTrue(capped, "QuoteChangeCapped emitted");
        (uint256 a2, uint64 at2) = oracle.lastAcceptedPrice();
        assertEq(a2, accepted, "nothing stored");
        assertEq(at2, acceptedAt);
        _setPrices(99_500_000, 99_500_000);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "within 1 %: accepted in the same block");
        (a2,) = oracle.lastAcceptedPrice();
        assertLt(a2, accepted, "the smaller move is accepted");
        vm.roll(block.number + 1);
        _setPrices(97_000_000, 97_000_000);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "the next block accepts the larger move");
    }

    // TEST-038 verifies: REQ-ORACLE-044, SPEC-ORC-017
    /// @notice `getTokenPrices()` returns the valuation price vector of the fresh evaluation, its served timestamp and
    /// the state while the market is not failed; the accepted vector while the quote-change cap holds the market
    /// Cached and while a token's routes fail; the served price is never above the price of the vector returned.
    function test_TEST_038_tokenPricesFollowTheServedState() public {
        _stable();
        (uint256[] memory prices, uint64 at, PriceState s) = oracle.getTokenPrices();
        PriceStateView memory v = _state();
        assertEq(uint8(s), uint8(PriceState.Live));
        assertEq(prices[0], v.tokens[0].valuationPrice, "token0: fresh valuation price");
        assertEq(prices[1], v.tokens[1].valuationPrice, "token1: fresh valuation price");
        assertEq(at, v.servedUpdatedAt, "served timestamp");
        oracle.poke();
        uint256[] memory acceptedVector = new uint256[](2);
        (acceptedVector[0], acceptedVector[1]) = (prices[0], prices[1]);
        _setPrices(98_000_000, 98_000_000);
        (prices,, s) = oracle.getTokenPrices();
        assertEq(uint8(s), uint8(PriceState.Cached), "quote-capped");
        assertEq(prices[0], acceptedVector[0], "the accepted vector while capped");
        assertEq(prices[1], acceptedVector[1]);
        vm.roll(block.number + 1);
        (prices,, s) = oracle.getTokenPrices();
        assertEq(uint8(s), uint8(PriceState.Live), "a later block");
        assertEq(prices[0], 98_000_000, "the fresh vector again");
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        (prices,, s) = oracle.getTokenPrices();
        assertEq(uint8(s), uint8(PriceState.Cached), "failed");
        assertEq(prices[0], acceptedVector[0], "the accepted vector while failed");
        assertEq(prices[1], acceptedVector[1]);
        assertEq(uint256(oracle.latestAnswer()), uint256(_state().acceptedAnswer), "served the accepted price");
    }

    // ─── TEST-252: grace start after an outage ───

    /// @dev Token1 stale on both routes since `T1 + MAX_AGE + 1`, observed Expired by a poke an hour later.
    function _latchedOutage() internal returns (uint256 t) {
        _stable();
        t = T1 + MAX_AGE + 1 + 3600;
        vm.warp(t);
        vm.roll(block.number + 1);
        _token0(ONE, t);
        s1Feed.push(int256(ONE), t);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Expired), "the outage is observed Expired");
    }

    // TEST-252 verifies: REQ-ORACLE-032, REQ-ORACLE-030
    /// @notice Token1 recovers through two new feeds no poke recorded, rounds at `t + 50` (primary) and `t + 20`
    /// (alternate), with token0's newest round at `t + 40`: the grace window starts at the newest leg in use of the
    /// fresh price, `t + 50`, not at the poke (`t + 70`) and never after `block.timestamp`.
    function test_TEST_252_graceStartsAtTheNewestLegInUse() public {
        uint256 t = _latchedOutage();
        OracleFeedMock np = _feed("newPrimary", ONE);
        OracleFeedMock na = _feed("newAlternate", ONE);
        np.push(int256(ONE), t + 50);
        na.push(int256(ONE), t + 20);
        registry.setRoutes(address(token1), _one(address(np)), _one(address(na)), RouteSlot.None);
        vm.warp(t + 70);
        vm.roll(block.number + 1);
        _token0(ONE, t + 40);
        s1Feed.push(int256(ONE), t + 40);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.recoveredAt, t + 50, "the newest leg in use");
        assertLe(v.recoveredAt, block.timestamp, "never after now");
        assertEq(v.graceEndsAt, t + 50 + 1800, "graceDuration from the recovery");
        assertTrue(v.inGrace, "in grace");
    }

    // TEST-252 verifies: REQ-ORACLE-032, REQ-ORACLE-095
    /// @notice While latched, a guardian switches token1's primary slot to a standby whose round predates the switch:
    /// the poke that observes the switch starts grace at its own `block.timestamp`, not at the older round.
    function test_TEST_252_graceAtNowOnAStandbySwitchWhileLatched() public {
        uint256 t = _latchedOutage();
        OracleFeedMock standby = _feed("standby", ONE);
        standby.push(int256(ONE), t - 3000);
        registry.setRoutes(address(token1), _one(address(standby)), _one(address(a1Feed)), RouteSlot.Primary);
        registry.bumpVersion(address(token1));
        vm.warp(t + 12);
        vm.roll(block.number + 1);
        _token0(ONE, t + 12);
        s1Feed.push(int256(ONE), t + 12);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.recoveredAt, t + 12, "grace starts at the poke that observes the switch");
        assertTrue(v.inGrace, "in grace");
    }
}
