// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {TokenPriceView} from "../../src/types/TokenPriceView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice An invalid or failed second source leaves its token unconfirmed and changes nothing else (2.10
/// `REQ-ORACLE-100`): the primary price that `latestAnswer()`, `getPriceState()` and `poke()` compute is the same, the
/// state follows the primary routes' freshness, Cached and Expired rules, and no failure, disagreement or grace timer
/// starts, resets or extends. Each comparison reads both evaluations at the same state: the second evaluation only
/// replaces the configuration words the store returns, which changes no chain state.
/// forge-config: default.isolate = false
contract LPOracleSecondSourceWordsUnitTest is LPOracleFixture {
    uint256 internal constant HEAD = OracleInputsLayout.HEAD_WORDS;
    uint256 internal constant STRIDE = OracleInputsLayout.TOKEN_WORDS + OracleInputsLayout.SECOND_WORDS;
    uint256 internal constant SECOND = OracleInputsLayout.TOKEN_WORDS;
    uint32 internal constant TOKEN_SECOND_DISAGREE = 1 << 4;
    uint32 internal constant TOKEN_SECOND_UNAVAILABLE = 1 << 5;
    uint256 internal constant T1 = T0 + 60;

    function setUp() public {
        _deployMarket();
        vm.roll(block.number + 1);
        vm.warp(T1);
        _pushAll(99_500_000, T1);
    }

    // TEST-040 verifies: REQ-ORACLE-042, REQ-ORACLE-100
    function test_TEST_040_malformedSecondSourceWordChangesNoServedValue() public {
        address[] memory list = _two(address(tokenA), address(tokenB));
        uint256[] memory w = store.getOracleInputs(address(oracle), list, true);
        w[OracleInputsLayout.HEAD_WORDS + OracleInputsLayout.TOKEN_WORDS] = 3; // token A second-source kind 3
        vm.mockCall(address(store), abi.encodeCall(store.getOracleInputs, (address(oracle), list, true)), abi.encode(w));
        PriceStateView memory v = oracle.getPriceState();
        assertEq(v.answer, oracle.latestAnswer(), "REQ-ORACLE-042: answer == latestAnswer()");
        (,, PriceState served) = oracle.getTokenPrices();
        assertEq(uint8(v.state), uint8(served), "REQ-ORACLE-100: a second source changes no state");
        assertFalse(v.borrowAllowed, "the second source is unconfirmed: no borrow");
        oracle.poke();
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, 0, "REQ-ORACLE-100: a second source starts no timer");
    }

    // ─── Helpers ───

    /// @dev The configuration words the store serves with second sources.
    function _words() internal view returns (uint256[] memory) {
        return store.getOracleInputs(address(oracle), _two(address(tokenA), address(tokenB)), true);
    }

    /// @dev Serves `w` for the read with second sources; the read without them is untouched.
    function _serve(
        uint256[] memory w
    ) internal {
        address[] memory list = _two(address(tokenA), address(tokenB));
        vm.mockCall(address(store), abi.encodeCall(store.getOracleInputs, (address(oracle), list, true)), abi.encode(w));
    }

    /// @dev Second-source word `word` of token `token` set to `value`.
    function _malform(
        uint256 token,
        uint256 word,
        uint256 value
    ) internal {
        uint256[] memory w = _words();
        w[HEAD + token * STRIDE + SECOND + word] = value;
        _serve(w);
    }

    /// @dev Every field of two reports of the same state, except what a second source reaches: `borrowAllowed`, market
    /// bit 16 and the token bits 4 and 5 with the token's second-source value and deviation.
    function _assertSameExceptConfirmation(
        PriceStateView memory a,
        PriceStateView memory b
    ) internal pure {
        uint256 sourceBits = 1 << 16;
        assertEq(uint8(a.state), uint8(b.state), "state");
        assertEq(a.reasons & ~sourceBits, b.reasons & ~sourceBits, "market reasons");
        assertEq(a.answer, b.answer, "answer");
        assertEq(a.servedUpdatedAt, b.servedUpdatedAt, "servedUpdatedAt");
        assertEq(a.servedAge, b.servedAge, "servedAge");
        assertEq(a.consistencyDeviationBps, b.consistencyDeviationBps, "consistency");
        assertEq(a.usdLevel, b.usdLevel, "usdLevel");
        assertEq(a.sequencerReady, b.sequencerReady, "sequencerReady");
        assertEq(a.failureStart, b.failureStart, "failureStart");
        assertEq(a.cachedUntil, b.cachedUntil, "cachedUntil");
        assertEq(a.disagreeSince, b.disagreeSince, "disagreeSince");
        assertEq(a.disagreementPauseActive, b.disagreementPauseActive, "pause");
        assertEq(a.disagreementExpired, b.disagreementExpired, "expired");
        assertEq(a.liquidationPaused, b.liquidationPaused, "liquidationPaused");
        assertEq(a.recoveredAt, b.recoveredAt, "recoveredAt");
        assertEq(a.graceEndsAt, b.graceEndsAt, "graceEndsAt");
        assertEq(a.inGrace, b.inGrace, "inGrace");
        assertEq(a.borrowPriceMaxAge, b.borrowPriceMaxAge, "borrow age");
        assertEq(a.liquidationPriceMaxAge, b.liquidationPriceMaxAge, "liquidation age");
        assertEq(a.freshAnswer, b.freshAnswer, "fresh");
        assertEq(a.acceptedAnswer, b.acceptedAnswer, "accepted");
        assertEq(a.acceptedUpdatedAt, b.acceptedUpdatedAt, "acceptedUpdatedAt");
        assertEq(a.tokens.length, b.tokens.length, "tokens");
        for (uint256 i = 0; i < a.tokens.length; ++i) {
            TokenPriceView memory x = a.tokens[i];
            TokenPriceView memory y = b.tokens[i];
            uint32 tokenBits = TOKEN_SECOND_DISAGREE | TOKEN_SECOND_UNAVAILABLE;
            assertEq(x.reasons & ~tokenBits, y.reasons & ~tokenBits, "token reasons");
            assertEq(x.routeUsed, y.routeUsed, "route used");
            assertEq(x.quote, y.quote, "quote");
            assertEq(x.valuationPrice, y.valuationPrice, "valuation price");
            assertEq(x.updatedAt, y.updatedAt, "token updatedAt");
            assertEq(x.primaryValue, y.primaryValue, "primary");
            assertEq(x.alternateValue, y.alternateValue, "alternate");
            assertEq(x.legFeeds[0], y.legFeeds[0], "leg feed");
            assertEq(x.legUpdatedAt[0], y.legUpdatedAt[0], "leg updatedAt");
        }
    }

    /// @dev The served views and the report of one state, read with the configuration the store serves now.
    function _read()
        internal
        view
        returns (PriceStateView memory v, int256 answer, uint256 updatedAt, uint256[] memory prices, PriceState state)
    {
        v = oracle.getPriceState();
        answer = oracle.latestAnswer();
        (,,, updatedAt,) = oracle.latestRoundData();
        uint64 servedAt;
        (prices, servedAt, state) = oracle.getTokenPrices();
        assertEq(servedAt, updatedAt, "getTokenPrices and latestRoundData share the served timestamp");
    }

    /// @dev Reads the current state with a valid configuration and with token A's second-source kind out of range, and
    /// checks that only the confirmation differs and that every served view equals the report's answer.
    function _compareAtThisState() internal returns (PriceStateView memory valid, PriceStateView memory malformed) {
        vm.clearMockedCalls();
        int256 answerValid;
        uint256 atValid;
        uint256[] memory pricesValid;
        PriceState stateValid;
        (valid, answerValid, atValid, pricesValid, stateValid) = _read();
        _malform(0, 0, 3);
        int256 answer;
        uint256 at;
        uint256[] memory prices;
        PriceState state;
        (malformed, answer, at, prices, state) = _read();
        vm.clearMockedCalls();
        _assertSameExceptConfirmation(valid, malformed);
        assertEq(answer, answerValid, "latestAnswer is unchanged");
        assertEq(malformed.answer, answer, "REQ-ORACLE-042: getPriceState().answer == latestAnswer()");
        assertEq(at, atValid, "latestRoundData timestamp is unchanged");
        assertEq(uint8(state), uint8(stateValid), "getTokenPrices state is unchanged");
        assertEq(uint8(state), uint8(malformed.state), "getTokenPrices state == getPriceState().state");
        assertEq(prices.length, pricesValid.length);
        for (uint256 i = 0; i < prices.length; ++i) {
            assertEq(prices[i], pricesValid[i], "valuation prices are unchanged");
        }
        assertFalse(malformed.borrowAllowed, "an unconfirmed token blocks borrowing");
    }

    /// @dev No timer, latch or grace event in `logs`.
    function _assertNoTimerEvent(
        Vm.Log[] memory logs
    ) internal view {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(oracle)) continue;
            bytes32 t = logs[i].topics[0];
            assertTrue(t != ILPOracleEvents.FailureRecorded.selector, "FailureRecorded");
            assertTrue(t != ILPOracleEvents.FailureCleared.selector, "FailureCleared");
            assertTrue(t != ILPOracleEvents.DisagreementRecorded.selector, "DisagreementRecorded");
            assertTrue(t != ILPOracleEvents.DisagreementCleared.selector, "DisagreementCleared");
            assertTrue(t != ILPOracleEvents.OutageExpiredLatched.selector, "OutageExpiredLatched");
            assertTrue(t != ILPOracleEvents.GraceStarted.selector, "GraceStarted");
            assertTrue(t != ILPOracleEvents.PriceStateChanged.selector, "PriceStateChanged");
        }
    }

    // ─── Every malformed word ───

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, REQ-ORACLE-042, REQ-ORACLE-016
    /// @notice Each second-source word one past its type (kind 3, a 161-bit source, a 33-bit maximum age or window, a
    /// 17-bit tolerance, 9-bit decimals) unconfirms that token only (token bit 5, market bit 16): the state stays Live,
    /// the other token stays confirmed and the served price is the report's answer.
    function test_TEST_276_everyMalformedSecondSourceWordUnconfirmsOnlyItsToken() public {
        uint256[6] memory word = [uint256(0), 1, 3, 4, 5, 6];
        uint256[6] memory value = [uint256(3), 1 << 160, 1 << 32, 1 << 32, 1 << 16, 1 << 8];
        int256 answer = oracle.latestAnswer();
        for (uint256 k = 0; k < word.length; ++k) {
            for (uint256 token = 0; token < 2; ++token) {
                vm.clearMockedCalls();
                _malform(token, word[k], value[k]);
                PriceStateView memory v = _state();
                assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
                assertEq(v.answer, answer, "served price unchanged");
                assertEq(v.answer, oracle.latestAnswer(), "answer == latestAnswer()");
                assertTrue(_has(v.reasons, 16), "SECOND_SOURCE_DISAGREE");
                assertFalse(_has(v.reasons, 1), "no failed configuration");
                assertTrue(v.tokens[token].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "this token unavailable");
                assertEq(v.tokens[token].secondSourceValue, 0, "no value from an unset source");
                assertEq(v.tokens[token].secondSourceDeviationBps, type(uint256).max, "no deviation");
                assertEq(v.tokens[1 - token].reasons & (TOKEN_SECOND_DISAGREE | TOKEN_SECOND_UNAVAILABLE), 0);
                assertFalse(v.borrowAllowed, "borrowing blocked");
                assertFalse(v.liquidationPaused, "liquidation open");
            }
        }
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020
    /// @notice The range check is exact: each word at its type's maximum is read as given (a tolerance of 65,535 bps
    /// confirms, a maximum age of 2^32 - 1 seconds accepts the round), one more unconfirms the token.
    function test_TEST_276_secondSourceWordBoundaries() public {
        _malform(0, 5, type(uint16).max);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE, 0, "tolerance 65,535 is a tolerance");
        assertFalse(_has(v.reasons, 16));
        vm.clearMockedCalls();
        _malform(0, 3, type(uint32).max);
        v = _state();
        assertEq(v.tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE, 0, "maximum age 2^32 - 1 is an age");
        assertTrue(v.borrowAllowed);
        vm.clearMockedCalls();
        _malform(0, 3, uint256(type(uint32).max) + 1);
        assertTrue(_state().tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "2^32 is out of range");
        vm.clearMockedCalls();
        // The kind None (0) is a valid word: a token with no second source is unconfirmed, as a malformed one.
        _malform(0, 0, 0);
        v = _state();
        assertTrue(v.tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "kind None: unavailable");
        assertEq(uint8(v.state), uint8(PriceState.Live));
    }

    // ─── Stale primary ───

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ORACLE-005, REQ-ORACLE-019, REQ-ORACLE-042, REQ-ORACLE-029
    /// @notice With token A's primary stale and its alternate fresh, token A is quoted on the alternate and the market
    /// stays Live; an invalid second source on token A changes none of it, so `latestAnswer`, `getPriceState` and
    /// `poke` price the market the same, and `poke` accepts the alternate-quoted price.
    function test_TEST_276_invalidSecondSourceWithStalePrimary() public {
        uint256 t = T1 + MAX_AGE + 1;
        vm.warp(t);
        aA.push(99_500_000, t);
        pB.push(99_500_000, t);
        aB.push(99_500_000, t);
        sA.push(99_500_000, t);
        sB.push(99_500_000, t);
        // A keeper's poke verifies the token decimals (REQ-ORACLE-107), so borrowAllowed reflects the sources only.
        oracle.poke();
        (PriceStateView memory valid, PriceStateView memory malformed) = _compareAtThisState();
        assertEq(uint8(valid.state), uint8(PriceState.Live), "stale primary, fresh alternate: Live");
        assertEq(malformed.tokens[0].routeUsed, 2, "token A on its alternate");
        assertTrue(_has(malformed.reasons, 7), "ANY_TOKEN_ON_ALTERNATE");
        assertTrue(valid.borrowAllowed, "valid second sources confirm the alternate quote");
        // New rounds on the alternate and token B; the next poke runs with token A's second source malformed.
        uint256 t2 = t + 12;
        vm.warp(t2);
        vm.roll(block.number + 1);
        aA.push(99_400_000, t2);
        pB.push(99_500_000, t2);
        aB.push(99_500_000, t2);
        _malform(0, 0, 3);
        vm.recordLogs();
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "poke reports Live");
        _assertNoTimerEvent(vm.getRecordedLogs());
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        assertEq(int256(accepted), oracle.latestAnswer(), "the alternate-quoted price is accepted");
        assertEq(int256(accepted), _state().answer, "and is the report's answer");
        assertEq(acceptedAt, t2, "at its source timestamp");
        (uint64 failedSince, uint64 disagreeSince, bool latched, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(failedSince, 0);
        assertEq(disagreeSince, 0);
        assertFalse(latched);
        assertEq(recoveredAt, 0);
    }

    // TEST-042 verifies: REQ-ORACLE-100, REQ-ORACLE-027, SPEC-ORC-013, REQ-ORACLE-017, REQ-ORACLE-030
    /// @notice Both routes of token A stale: the market fails from `staleAt = updatedAt + feedMaxAge + 1` and is Cached
    /// for `cachedWindow`, then Expired. An invalid second source on either token neither starts nor moves that
    /// timer: each poke stores the same `failedSince`, and the Expired boundary is the same second.
    function test_TEST_042_invalidSecondSourceKeepsTheFailureTimer() public {
        uint256 staleAt = T1 + MAX_AGE + 1;
        uint256 t = staleAt + 100;
        vm.warp(t);
        pB.push(99_500_000, t);
        aB.push(99_500_000, t);
        sB.push(99_500_000, t);
        (PriceStateView memory valid,) = _compareAtThisState();
        assertEq(uint8(valid.state), uint8(PriceState.Cached), "both routes stale: Cached");
        assertEq(valid.failureStart, staleAt, "failure starts at staleAt (S_ts)");
        assertEq(valid.cachedUntil, staleAt + 3600);
        _malform(1, 0, 3);
        for (uint256 k = 0; k < 4; ++k) {
            vm.warp(t + k * 600);
            vm.roll(block.number + 1);
            oracle.poke();
            (uint64 failedSince,,,) = oracle.storedTimers();
            assertEq(failedSince, staleAt, "the stored start is staleAt on every poke");
        }
        vm.warp(staleAt + 3599);
        assertEq(uint8(_state().state), uint8(PriceState.Cached), "Cached one second before the bound");
        vm.warp(staleAt + 3600);
        (PriceStateView memory expiredValid, PriceStateView memory expiredMalformed) = _compareAtThisState();
        assertEq(uint8(expiredValid.state), uint8(PriceState.Expired), "Expired at failureStart + cachedWindow");
        assertEq(expiredMalformed.answer, 1, "served 1 once Expired");
        // Second sources are not evaluated while the market is failed: bit 16 is 0 in both reports.
        assertFalse(_has(expiredValid.reasons, 16));
        assertFalse(_has(expiredMalformed.reasons, 16));
    }

    // ─── Repeated pokes and recovery ───

    // TEST-042 verifies: REQ-ORACLE-100, REQ-ORACLE-027, REQ-ORACLE-028, REQ-ORACLE-029, REQ-ORACLE-032
    /// @notice While a second source stays invalid, every poke accepts the new Live price and records no failure,
    /// disagreement, latch or grace; once the configuration is valid again the token is confirmed at once, with no
    /// write, and borrowing reopens.
    function test_TEST_042_repeatedPokesAndRecovery() public {
        _malform(0, 1, 1 << 160);
        vm.recordLogs();
        for (uint256 k = 1; k <= 5; ++k) {
            uint256 t = T1 + k * 900;
            vm.warp(t);
            vm.roll(block.number + 1);
            int256 answer = int256(99_500_000 + k * 10_000);
            _pushAll(answer, t);
            assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
            (, uint64 acceptedAt) = oracle.lastAcceptedPrice();
            assertEq(acceptedAt, t, "each poke accepts the newer price");
            assertEq(int256(oracle.latestAnswer()), _state().answer, "same answer");
        }
        _assertNoTimerEvent(vm.getRecordedLogs());
        (uint64 failedSince, uint64 disagreeSince, bool latched, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(failedSince + disagreeSince + recoveredAt, 0, "no timer stored");
        assertFalse(latched);
        assertFalse(_state().borrowAllowed, "still unconfirmed");
        vm.clearMockedCalls();
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "a valid configuration confirms at once");
        assertFalse(_has(v.reasons, 16));
        assertFalse(v.inGrace, "no grace: nothing was failed");
        vm.recordLogs();
        oracle.poke();
        _assertNoTimerEvent(vm.getRecordedLogs());
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, REQ-ORACLE-039, REQ-ORACLE-102
    /// @notice A second source that reverts, returns a short or oversized buffer, burns its whole gas, is stale or
    /// reports another decimals value is unavailable (token bit 5) and moves no timer; a poke at each stays Live.
    function test_TEST_276_failedSecondSourceReadsMoveNoTimer() public {
        ReadMode[4] memory modes = [ReadMode.Revert, ReadMode.Short, ReadMode.BurnGas, ReadMode.Huge];
        for (uint256 k = 0; k < modes.length; ++k) {
            sA.setMode(sA.latestRoundData.selector, modes[k]);
            PriceStateView memory v = _state();
            assertTrue(v.tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "unavailable");
            assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "poke stays Live");
            sA.setMode(sA.latestRoundData.selector, ReadMode.Normal);
        }
        sA.setDecimals(18);
        assertTrue(_state().tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "decimals mismatch: unavailable");
        sA.setDecimals(8);
        vm.warp(T1 + MAX_AGE + 1);
        _pushAll(99_500_000, T1 + MAX_AGE + 1);
        sA.push(99_500_000, T1);
        assertTrue(_state().tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE != 0, "stale: unavailable");
        oracle.poke();
        (uint64 failedSince, uint64 disagreeSince,, uint64 recoveredAt) = oracle.storedTimers();
        assertEq(failedSince + disagreeSince + recoveredAt, 0, "no timer from a failed second source");
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020
    /// @notice A second source that disagrees beyond its tolerance gives token bit 4, not 5; the boundary is inclusive:
    /// `|q - s| * 10^4 <= S * min(q, s)` confirms.
    function test_TEST_276_disagreeingSecondSourceBoundary() public {
        // q = 99,500,000, S = 100 bps: s = 98,514,852 gives 985,148 * 10^4 <= 100 * 98,514,852 (confirmed); one unit
        // lower gives 9,851,490,000 > 9,851,485,100.
        sA.push(98_514_852, T1);
        assertEq(_state().tokens[0].reasons & TOKEN_SECOND_DISAGREE, 0, "inside the tolerance");
        sA.push(98_514_851, T1);
        PriceStateView memory v = _state();
        assertTrue(v.tokens[0].reasons & TOKEN_SECOND_DISAGREE != 0, "outside: disagrees");
        assertEq(v.tokens[0].reasons & TOKEN_SECOND_UNAVAILABLE, 0, "a readable source is not unavailable");
        assertEq(v.tokens[0].secondSourceValue, 98_514_851);
        assertEq(uint8(v.state), uint8(PriceState.Live));
        // Above the quote, symmetric: s = 100,495,000 gives 995,000 * 10^4 <= 100 * 99,500,000.
        sA.push(100_495_000, T1);
        assertEq(_state().tokens[0].reasons & TOKEN_SECOND_DISAGREE, 0);
        sA.push(100_495_001, T1);
        assertTrue(_state().tokens[0].reasons & TOKEN_SECOND_DISAGREE != 0);
    }

    // ─── Same snapshot in every state ───

    // TEST-040 verifies: REQ-ORACLE-100, REQ-ORACLE-042, REQ-ORACLE-018, REQ-ORACLE-022, REQ-ORACLE-086
    /// @notice Drifting by a route disagreement: the lower-route price, the pause window and `liquidationPaused` are
    /// the same with and without a valid second source.
    function test_TEST_040_sameSnapshotWhileDrifting() public {
        aA.push(97_000_000, T1);
        (PriceStateView memory valid,) = _compareAtThisState();
        assertEq(uint8(valid.state), uint8(PriceState.Drifting));
        assertTrue(valid.disagreementPauseActive);
        assertTrue(valid.liquidationPaused);
        oracle.poke();
        vm.warp(T1 + 3600);
        (valid,) = _compareAtThisState();
        assertTrue(valid.disagreementExpired, "past disagreementPauseMax");
    }

    // TEST-040 verifies: REQ-ORACLE-100, REQ-ORACLE-042, REQ-ORACLE-015, REQ-ORACLE-103
    /// @notice Drifting by a USD-band breach and Cached by the quote-change cap: identical with an invalid second source.
    function test_TEST_040_sameSnapshotBandAndQuoteCap() public {
        _pushAll(89_000_000, T1);
        (PriceStateView memory valid,) = _compareAtThisState();
        assertEq(uint8(valid.state), uint8(PriceState.Drifting), "below the band");
        assertTrue(_has(valid.reasons, 3));
        _pushAll(99_500_000, T1);
        oracle.poke();
        _pushAll(98_000_000, T1);
        (valid,) = _compareAtThisState();
        assertEq(uint8(valid.state), uint8(PriceState.Cached), "the quote-change cap holds the block");
        assertTrue(_has(valid.reasons, 18));
    }

    // TEST-042 verifies: REQ-ORACLE-100, REQ-ORACLE-026, REQ-ORACLE-027, REQ-ORACLE-029, REQ-ORACLE-031
    /// @notice A poke from the same snapshot with and without a valid second source returns the same state and writes
    /// the same accepted price, timers and `seen` rounds.
    function test_TEST_042_pokeFromTheSameSnapshot() public {
        uint256 t = T1 + MAX_AGE + 1;
        vm.warp(t);
        pB.push(99_600_000, t);
        aB.push(99_600_000, t);
        aA.push(99_500_000, t);
        uint256 snap = vm.snapshotState();
        PriceState valid = oracle.poke();
        (uint256 a1, uint64 at1) = oracle.lastAcceptedPrice();
        (uint64 f1, uint64 d1,, uint64 r1) = oracle.storedTimers();
        (, uint80 round1,) = oracle.storedSeen(0, 1, 0);
        vm.revertToState(snap);
        _malform(0, 0, 3);
        _malform(1, 6, 1 << 8);
        PriceState malformed = oracle.poke();
        (uint256 a2, uint64 at2) = oracle.lastAcceptedPrice();
        (uint64 f2, uint64 d2,, uint64 r2) = oracle.storedTimers();
        (, uint80 round2,) = oracle.storedSeen(0, 1, 0);
        assertEq(uint8(valid), uint8(malformed), "same state");
        assertEq(a1, a2, "same accepted price");
        assertEq(at1, at2, "same accepted timestamp");
        assertEq(f1, f2, "same failedSince");
        assertEq(d1, d2, "same disagreeSince");
        assertEq(r1, r2, "same recoveredAt");
        assertEq(round1, round2, "same seen round");
    }
}
