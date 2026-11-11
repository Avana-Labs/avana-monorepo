// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleTokenMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Token decimals stored at listing and re-checked by every `poke()` (2.10 `REQ-ORACLE-107`). Detection is
/// delayed: reads between a token's change and the next poke still use the stored decimals. A changed or unreadable
/// value fails the market (reason bit 1: Cached, then Expired), which blocks new borrowing, withdraw-with-debt and this
/// market's seizure while repay and debt-free exits read no price; the stored decimals are never replaced. Borrowing
/// also needs a successful verification within `DECIMALS_CHECK_MAX_AGE` (7,200 s, reason bit 19). Feed decimals are not
/// stored: every read compares them with the pinned value, so their change is seen at once.
/// forge-config: default.isolate = false
contract LPOracleDecimalsUnitTest is LPOracleFixture {
    uint256 internal constant MAX_VERIFY_AGE = 7200;

    function setUp() public {
        _deployMarket();
    }

    /// @dev The next block at `t`, with fresh rounds on every feed.
    function _advance(
        uint256 t
    ) internal {
        vm.warp(t);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), t);
    }

    /// @dev A keeper's poke in the next block at `t`, with fresh rounds on every feed.
    function _pokeAt(
        uint256 t
    ) internal returns (PriceState) {
        _advance(t);
        return oracle.poke();
    }

    function _decimalsStatus() internal view returns (bool invalid, uint64 verifiedAt) {
        return oracle.decimalsStatus();
    }

    function _countEvent(
        Vm.Log[] memory logs,
        bytes32 topic
    ) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == topic) ++n;
        }
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-058
    /// @notice `initialize` reads the decimals it stores, so the market starts verified at its listing time; a poke
    /// that reads the same values moves only the verification time and emits no decimals event.
    function test_TEST_294_listingAndPokeVerify() public {
        (bool invalid, uint64 at) = _decimalsStatus();
        assertFalse(invalid);
        assertEq(at, T0, "verified at initialize");
        vm.recordLogs();
        _pokeAt(T0 + 600);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvent(logs, ILPOracleEvents.TokenDecimalsMismatch.selector), 0);
        assertEq(_countEvent(logs, ILPOracleEvents.TokenDecimalsRestored.selector), 0);
        (invalid, at) = _decimalsStatus();
        assertFalse(invalid);
        assertEq(at, T0 + 600, "verified by the poke");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-017, SPEC-ORC-013, REQ-ORACLE-027, SPEC-ORC-017, REQ-ORACLE-100
    /// @notice A token upgraded from 6 to 18 decimals: views before the next poke still price with 6 (delayed
    /// detection); the poke marks the configuration invalid, records the failure at `now` and serves the accepted price
    /// while Cached, with seizure paused and borrowing blocked.
    function test_TEST_294_changedDecimalsFailTheMarketAtTheNextPoke() public {
        uint256 t = T0 + 100;
        vm.warp(t);
        vm.roll(block.number + 1);
        tokenA.setDecimals(18);
        PriceStateView memory before = _state();
        assertEq(uint8(before.state), uint8(PriceState.Live), "delayed detection: no poke yet");
        assertEq(before.answer, int256(SEEDED), "still priced with the stored 6 decimals");
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsMismatch(0, 6, 18, true);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureRecorded(uint64(t), LPOracleCodes.CONFIG_OR_DECIMALS_UNAVAILABLE);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached), "the poke reports Cached");
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(_has(v.reasons, 1), "CONFIG_OR_DECIMALS_UNAVAILABLE");
        assertEq(v.answer, v.acceptedAnswer, "served the accepted price");
        assertEq(oracle.latestAnswer(), v.acceptedAnswer, "latestAnswer serves it too");
        assertEq(v.failureStart, t);
        assertEq(v.cachedUntil, t + 3600);
        assertTrue(v.liquidationPaused, "seizure of this market blocked at this valuation");
        assertFalse(v.borrowAllowed, "borrowing and withdraw-with-debt blocked");
        assertEq(v.freshAnswer, 0, "no fresh price while failed");
        (bool invalid, uint64 at) = _decimalsStatus();
        assertTrue(invalid);
        assertEq(at, T0, "the last successful verification is kept");
        (,, PriceState served) = oracle.getTokenPrices();
        assertEq(uint8(served), uint8(PriceState.Cached), "getTokenPrices reports the same state");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-017, REQ-ORACLE-039
    /// @notice A `decimals()` read that reverts, returns a short word, burns its whole gas or returns a word above
    /// 255 is unreadable (`readable = false`, read 0); a token reporting 0 is a different value. Each fails the market
    /// at the poke, and no view reads token decimals.
    function test_TEST_294_unreadableDecimalsFailTheMarket() public {
        ReadMode[3] memory modes = [ReadMode.Revert, ReadMode.Short, ReadMode.BurnGas];
        for (uint256 k = 0; k < modes.length; ++k) {
            uint256 snap = vm.snapshotState();
            tokenB.setMode(OracleTokenMock.decimals.selector, modes[k]);
            _advance(T0 + 60);
            vm.expectEmit(address(oracle));
            emit ILPOracleEvents.TokenDecimalsMismatch(1, 6, 0, false);
            assertEq(uint8(oracle.poke()), uint8(PriceState.Cached));
            vm.revertToState(snap);
        }
        uint256 snapWide = vm.snapshotState();
        vm.mockCall(address(tokenB), abi.encodeCall(OracleTokenMock.decimals, ()), abi.encode(uint256(256)));
        _advance(T0 + 60);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsMismatch(1, 6, 0, false);
        oracle.poke();
        vm.clearMockedCalls();
        vm.revertToState(snapWide);
        // A token reporting 0 decimals is readable and different from 6.
        tokenA.setDecimals(0);
        assertTrue(_state().borrowAllowed, "views read no token decimals");
        _advance(T0 + 120);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsMismatch(0, 6, 0, true);
        oracle.poke();
    }

    // TEST-294 verifies: REQ-ORACLE-107, SPEC-ORC-013, REQ-ORACLE-027, REQ-ORACLE-085, REQ-ORACLE-030
    /// @notice While the mismatch lasts, later pokes emit no second mismatch event and keep `failedSince`; the market
    /// is Expired from `failedSince + cachedWindow` and serves 1. The outage latch never sets: the failure is not two
    /// stale routes.
    function test_TEST_294_mismatchFollowsTheFailureTimer() public {
        tokenA.setDecimals(18);
        uint256 t = T0 + 60;
        _pokeAt(t);
        vm.recordLogs();
        for (uint256 k = 1; k <= 3; ++k) {
            _pokeAt(t + k * 1000);
            (uint64 failedSince,,,) = oracle.storedTimers();
            assertEq(failedSince, t, "the failure start does not move");
        }
        assertEq(_countEvent(vm.getRecordedLogs(), ILPOracleEvents.TokenDecimalsMismatch.selector), 0, "one event");
        _pokeAt(t + 3599);
        assertEq(uint8(_state().state), uint8(PriceState.Cached));
        _pokeAt(t + 3600);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(v.answer, 1, "Expired serves 1");
        assertTrue(v.liquidationPaused);
        (,, bool latched,) = oracle.storedTimers();
        assertFalse(latched, "no outage latch from a decimals failure");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-027, REQ-ORACLE-032, REQ-ORACLE-058
    /// @notice The token's decimals return to the stored value: the next poke clears the mark (`TokenDecimalsRestored`)
    /// and the failure (`FailureCleared`), the market is Live at the price computed with the stored decimals, and no
    /// grace starts (a configuration failure never opens grace).
    function test_TEST_294_restoredDecimalsClearTheMark() public {
        tokenA.setDecimals(18);
        _pokeAt(T0 + 60);
        tokenA.setDecimals(6);
        assertEq(uint8(_state().state), uint8(PriceState.Cached), "the stored mark holds until a poke");
        uint256 t = T0 + 4000;
        _advance(t);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsRestored(uint64(t));
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureCleared(uint64(T0 + 60), uint64(t));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        PriceStateView memory v = _state();
        assertEq(v.answer, int256(SEEDED), "priced with the stored decimals");
        assertFalse(v.inGrace, "no grace after a configuration failure");
        assertEq(v.recoveredAt, 0);
        (bool invalid, uint64 at) = _decimalsStatus();
        assertFalse(invalid);
        assertEq(at, t);
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-046, REQ-ORACLE-058
    /// @notice New decimals are never adopted: a token left at 18 decimals keeps the market failed through days of
    /// pokes, `checkConfig` reports `CHECK_TOKEN_DECIMALS`, and the stored 6 decimals price the market again only when
    /// the token reports 6.
    function test_TEST_294_newDecimalsAreNeverAdopted() public {
        tokenA.setDecimals(18);
        for (uint256 k = 1; k <= 5; ++k) {
            _pokeAt(T0 + k * 86_400);
            assertGe(uint8(_state().state), uint8(PriceState.Cached), "failed on every day");
            (bool invalid,) = _decimalsStatus();
            assertTrue(invalid);
        }
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_TOKEN_DECIMALS != 0, "listing check refuses");
        tokenA.setDecimals(6);
        _pokeAt(T0 + 6 * 86_400);
        assertEq(_state().answer, int256(SEEDED), "the stored decimals were kept");
        assertEq(oracle.checkConfig(_config()), 0);
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-100, REQ-ORACLE-037
    /// @notice A stopped keeper: with no poke for more than `DECIMALS_CHECK_MAX_AGE` the state, served price and
    /// seizure are unchanged, but `borrowAllowed` is false with reason bit 19; the boundary is inclusive at 7,200 s and
    /// the next poke reopens borrowing.
    function test_TEST_294_verificationMaxAge() public {
        uint256 t = T0 + 1000;
        _pokeAt(t);
        vm.warp(t + MAX_VERIFY_AGE);
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "7,200 s after the verification");
        assertFalse(_has(v.reasons, 19));
        int256 answer = v.answer;
        vm.warp(t + MAX_VERIFY_AGE + 1);
        v = _state();
        assertFalse(v.borrowAllowed, "7,201 s: borrowing blocked");
        assertTrue(_has(v.reasons, 19), "DECIMALS_UNVERIFIED");
        assertEq(uint8(v.state), uint8(PriceState.Live), "the state is unchanged");
        assertEq(v.answer, answer, "the served price is unchanged");
        assertFalse(v.liquidationPaused, "seizure is unchanged");
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, 0, "no timer");
        oracle.poke();
        v = _state();
        assertTrue(v.borrowAllowed, "a poke verifies again");
        assertFalse(_has(v.reasons, 19));
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-016, REQ-ORACLE-100
    /// @notice Per action at the oracle: a stale verification blocks only what `borrowAllowed` gates (borrow,
    /// withdraw-with-debt); a mismatch also pauses this market's seizure (`liquidationPaused`). Neither is read by repay
    /// or a debt-free exit, so those stay open.
    function test_TEST_294_perActionGates() public {
        vm.warp(T0 + MAX_VERIFY_AGE + 1);
        PriceStateView memory stale = _state();
        assertFalse(stale.borrowAllowed, "stale verification: borrow and withdraw-with-debt blocked");
        assertFalse(stale.liquidationPaused, "stale verification: liquidation open");
        tokenA.setDecimals(8);
        _pokeAt(T0 + MAX_VERIFY_AGE + 2);
        PriceStateView memory mismatch = _state();
        assertFalse(mismatch.borrowAllowed, "mismatch: borrow and withdraw-with-debt blocked");
        assertTrue(mismatch.liquidationPaused, "mismatch: liquidation at that valuation blocked");
        assertTrue(_has(mismatch.reasons, 19), "the failed poke kept the old verification time");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-002, SPEC-ORC-020
    /// @notice Feed decimals are pinned in the store and read on every evaluation, not stored by the LPOracle: a
    /// primary feed that changes its decimals is Invalid at the next view with no poke (the alternate quotes), both
    /// routes of a token changed fail the market at once, a second-source feed that changes is unavailable at once,
    /// and each recovers at the next read.
    function test_TEST_294_feedDecimalsAreReadOnEveryEvaluation() public {
        vm.warp(T0 + 60);
        pA.setDecimals(18);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].routeUsed, 2, "primary Invalid at once");
        assertEq(uint8(v.state), uint8(PriceState.Live));
        aA.setDecimals(18);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "no valid route: failed at once");
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
        assertEq(oracle.latestAnswer(), v.acceptedAnswer);
        pA.setDecimals(8);
        aA.setDecimals(8);
        sB.setDecimals(6);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "recovered at the next read");
        assertTrue(v.tokens[1].reasons & (1 << 5) != 0, "second-source decimals changed: unavailable");
        sB.setDecimals(8);
        assertTrue(_state().borrowAllowed);
        (bool invalid,) = _decimalsStatus();
        assertFalse(invalid, "feed decimals never touch the token-decimals mark");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-095, REQ-ORACLE-028
    /// @notice A mismatch found while the routes disagree: the failure clears the stored disagreement start, and the
    /// restore poke starts a new one at its own time if the routes still disagree.
    function test_TEST_294_mismatchDuringDisagreement() public {
        vm.warp(T0 + 60);
        vm.roll(block.number + 1);
        aA.push(97_000_000, T0 + 60);
        oracle.poke();
        (, uint64 disagreeSince,,) = oracle.storedTimers();
        assertEq(disagreeSince, T0 + 60);
        tokenB.setDecimals(18);
        vm.warp(T0 + 120);
        vm.roll(block.number + 1);
        oracle.poke();
        (uint64 failedSince, uint64 since,,) = oracle.storedTimers();
        assertEq(failedSince, T0 + 120);
        assertEq(since, 0, "a failed market clears the disagreement start");
        tokenB.setDecimals(6);
        vm.warp(T0 + 180);
        vm.roll(block.number + 1);
        oracle.poke();
        (failedSince, since,,) = oracle.storedTimers();
        assertEq(failedSince, 0);
        assertEq(since, T0 + 180, "a new disagreement start");
        assertEq(uint8(_state().state), uint8(PriceState.Drifting));
    }
}
