// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPOracleCLDecimalsTest
/// @notice Token decimals verified by `poke()` on the real concentrated-liquidity LPOracle (2.10 `REQ-ORACLE-107`): the
/// tokens' `decimals()` answers are replaced with `vm.mockCall` (a USDC upgraded to 18 decimals, an unreadable or
/// oversized answer), so the market stays the real USDC/USDT market on a real Uniswap v3 pool.
contract LPOracleCLDecimalsTest is LPOracleCLFixture {
    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;

    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    function _decimals(
        address token,
        bytes memory answer
    ) internal {
        vm.mockCall(token, abi.encodeWithSignature("decimals()"), answer);
    }

    function _pokeAt(
        uint256 t
    ) internal returns (PriceState) {
        vm.warp(t);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
        return oracle.poke();
    }

    function _count(
        Vm.Log[] memory logs,
        bytes32 topic
    ) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(oracle) && logs[i].topics[0] == topic) ++n;
        }
    }

    // TEST-294 verifies: REQ-ORACLE-107
    /// @notice `initialize` verified the decimals at listing; a token changing from 6 to 18 decimals is still priced
    /// with 6 until the next poke, which emits `TokenDecimalsMismatch(0, 6, 18, true)` and `FailureRecorded(now, bit 1)`:
    /// the market is Cached at the accepted price with seizure paused and borrowing blocked, keeping the last
    /// successful verification time.
    function test_TEST_294_changedDecimalsFailTheMarketAtTheNextPoke() public {
        _stable();
        (bool invalid, uint64 at) = oracle.decimalsStatus();
        assertFalse(invalid);
        assertEq(at, T0, "verified at initialize");
        int256 before = oracle.latestAnswer();
        _decimals(address(token0), abi.encode(uint256(18)));
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "delayed detection: no poke yet");
        assertEq(v.answer, before, "still priced with the stored 6 decimals");
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsMismatch(0, 6, 18, true);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureRecorded(uint64(T1), LPOracleCodes.CONFIG_OR_DECIMALS_UNAVAILABLE);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached), "the poke reports Cached");
        v = _state();
        assertTrue(_has(v.reasons, 1), "CONFIG_OR_DECIMALS_UNAVAILABLE");
        assertEq(v.answer, v.acceptedAnswer, "served the accepted price");
        assertEq(v.failureStart, T1);
        assertEq(v.cachedUntil, T1 + 3600);
        assertTrue(v.liquidationPaused, "seizure paused");
        assertFalse(v.borrowAllowed, "borrowing blocked");
        (invalid, at) = oracle.decimalsStatus();
        assertTrue(invalid);
        assertEq(at, T0, "the last successful verification is kept");
    }

    // TEST-294 verifies: REQ-ORACLE-107
    /// @notice A `decimals()` that reverts, returns a short word or a word above 255 is unreadable
    /// (`TokenDecimalsMismatch(token, 6, 0, false)`); each fails the market at the poke.
    function test_TEST_294_unreadableDecimalsFailTheMarket() public {
        _stable();
        bytes[2] memory answers = [abi.encodePacked(uint16(6)), abi.encode(uint256(256))];
        for (uint256 k = 0; k <= answers.length; ++k) {
            uint256 snap = vm.snapshotState();
            if (k == answers.length) {
                vm.mockCallRevert(address(token1), abi.encodeWithSignature("decimals()"), "no decimals");
            } else {
                _decimals(address(token1), answers[k]);
            }
            vm.warp(T1 + 60);
            vm.roll(block.number + 1);
            _setPrices(ONE, ONE);
            vm.expectEmit(address(oracle));
            emit ILPOracleEvents.TokenDecimalsMismatch(1, 6, 0, false);
            assertEq(uint8(oracle.poke()), uint8(PriceState.Cached), "unreadable decimals fail the market");
            vm.clearMockedCalls();
            vm.revertToState(snap);
        }
    }

    // TEST-294 verifies: REQ-ORACLE-107
    /// @notice While the mismatch lasts, later pokes emit no second mismatch event and keep the failure start; the
    /// market is Expired from `failedSince + cachedWindow`. New decimals are never adopted (`checkConfig` reports
    /// `CHECK_TOKEN_DECIMALS`); when the token reports 6 again the next poke emits `TokenDecimalsRestored` and
    /// `FailureCleared`, the market is Live at the price of the stored decimals and no grace starts.
    function test_TEST_294_mismatchFollowsTheTimerAndRestores() public {
        _stable();
        int256 before = oracle.latestAnswer();
        _decimals(address(token0), abi.encode(uint256(18)));
        _pokeAt(T1 + 60);
        vm.recordLogs();
        for (uint256 k = 1; k <= 3; ++k) {
            _pokeAt(T1 + 60 + k * 1000);
            assertEq(_state().failureStart, T1 + 60, "the failure start does not move");
        }
        assertEq(_count(vm.getRecordedLogs(), ILPOracleEvents.TokenDecimalsMismatch.selector), 0, "one event only");
        _pokeAt(T1 + 60 + 3600);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Expired), "Expired from failedSince + cachedWindow");
        assertEq(v.answer, 1);
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_TOKEN_DECIMALS != 0, "never adopted");
        vm.clearMockedCalls();
        uint256 t = T1 + 60 + 4000;
        vm.warp(t);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.TokenDecimalsRestored(uint64(t));
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.FailureCleared(uint64(T1 + 60), uint64(t));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live), "restored");
        v = _state();
        assertEq(v.answer, before, "priced with the stored decimals");
        assertFalse(v.inGrace, "no grace after a configuration failure");
        (bool invalid, uint64 at) = oracle.decimalsStatus();
        assertFalse(invalid);
        assertEq(at, t);
    }

    // TEST-294 verifies: REQ-ORACLE-107
    /// @notice With no poke for more than `DECIMALS_CHECK_MAX_AGE` (7,200 s, inclusive) `borrowAllowed` is false with
    /// reason bit 19 while the state, served price and seizure are unchanged; feed decimals are read on every
    /// evaluation, so a primary feed reporting other decimals is left for the alternate with no poke.
    function test_TEST_294_verificationAgeAndFeedDecimals() public {
        _stable();
        uint256 t = T1 + 1000;
        _pokeAt(t);
        vm.warp(t + 7200);
        _setPrices(ONE, ONE);
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "7,200 s after the verification");
        int256 answer = v.answer;
        vm.warp(t + 7201);
        _setPrices(ONE, ONE);
        v = _state();
        assertFalse(v.borrowAllowed, "7,201 s: borrowing blocked");
        assertTrue(_has(v.reasons, 19), "DECIMALS_UNVERIFIED");
        assertEq(uint8(v.state), uint8(PriceState.Live), "state unchanged");
        assertEq(v.answer, answer, "served price unchanged");
        assertFalse(v.liquidationPaused, "seizure unchanged");
        p0Feed.setDecimals(18);
        assertEq(_state().tokens[0].routeUsed, 2, "a feed's decimals are read on every evaluation");
        p0Feed.setDecimals(8);
        oracle.poke();
        assertTrue(_state().borrowAllowed, "a poke verifies again");
    }
}
