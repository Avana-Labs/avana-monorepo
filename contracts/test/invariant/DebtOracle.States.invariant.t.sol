// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {DebtOracleHandler} from "./handlers/DebtOracleHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title DebtOracleStatesInvariantTest
/// @notice State-consistency invariants of the USDC DebtOracle under the TEST-105 handler (feed moves, bounds, odd
/// timestamps, hostile reads, time, standby switches and restores, pokes). After every call the report is internally
/// consistent with SPEC-ORC-018 and the gates of REQ-ORACLE-093: the served price is the formula of its state (the
/// quote when Live, `max(p, b, A)` when Drifting, `A` when Cached, the stress price when Expired); the route used is
/// None exactly when failed; the failure window and the Cached/Expired split agree; Drifting is exactly a
/// disagreement with the pause or the expiry reported; the gates follow the state; the grace window is reported per
/// REQ-ORACLE-034; and `latestRoundData`, `latestAnswer` and the age getters equal the report.
contract DebtOracleStatesInvariantTest is DebtOracleFixture, HandlerReach {
    uint256 internal constant R_DISAGREE = 1 << 3;
    uint256 internal constant R_ALT_PAST_BORROW = 1 << 15;
    uint256 internal constant R_SECOND_SOURCE = 1 << 19;

    DebtOracleHandler internal handler;

    function setUp() public {
        _deployDebtOracle();
        MockAggregator[4] memory feeds = [pUsd, aEth, ethUsd, standby];
        int256[4] memory honest = [USDC_USD, USDC_ETH, ETH_USD, int256(99_995_000)];
        handler = new DebtOracleHandler(oracle, reg, usdc, feeds, honest);
        targetContract(address(handler));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(6, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](6), new string[](6), new int16[][](6));
        (actions[0], names[0]) = (DebtOracleHandler.breakFeed.selector, "breakFeed");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        (actions[1], names[1]) = (DebtOracleHandler.move.selector, "move");
        kinds[1] = new int16[](3);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        kinds[1][2] = 256;
        (actions[2], names[2]) = (DebtOracleHandler.oddTimestamp.selector, "oddTimestamp");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 256;
        (actions[3], names[3]) = (DebtOracleHandler.poke.selector, "poke");
        kinds[3] = new int16[](0);
        (actions[4], names[4]) = (DebtOracleHandler.switchStandby.selector, "switchStandby");
        kinds[4] = new int16[](1);
        kinds[4][0] = 1;
        (actions[5], names[5]) = (DebtOracleHandler.warp.selector, "warp");
        kinds[5] = new int16[](1);
        kinds[5][0] = 256;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-105 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-092, INV-087
    // Sources: 2.10 SPEC-ORC-018 (served debt price by state)
    function invariant_TEST_105_servedIsTheFormulaOfItsState() public view {
        DebtPriceView memory v = oracle.getPriceState();
        uint256 served = uint256(v.answer);
        uint256 a = v.acceptedAnswer;
        if (v.state == PriceState.Live) {
            assertEq(served, v.quote, "Live serves the quote");
            assertEq(v.quote, v.routeUsed == RouteSlot.Primary ? v.primaryValue : v.alternateValue, "quote's route");
        } else if (v.state == PriceState.Drifting) {
            assertEq(served, _driftingServed(v.primaryValue, v.alternateValue, a), "Drifting serves max(counted, A)");
        } else if (v.state == PriceState.Cached) {
            assertEq(served, a, "Cached serves A");
        } else {
            uint256 d = v.debtStressRiseBps < 100 ? 100 : v.debtStressRiseBps;
            assertEq(served, (a * (10_000 + d) + 9999) / 10_000, "Expired serves the stress price");
        }
        assertEq(
            v.stressAnswer, (a * (10_000 + (v.debtStressRiseBps < 100 ? 100 : v.debtStressRiseBps)) + 9999) / 10_000
        );
        assertGe(served, 1);
    }

    // TEST-105 verifies: REQ-ORACLE-017, SPEC-ORC-013, REQ-ORACLE-092, REQ-ORACLE-068
    // Sources: 2.10 SPEC-ORC-013 (Cached iff now < failureStart + cachedWindow)
    function invariant_TEST_105_failureWindowMatchesTheState() public view {
        DebtPriceView memory v = oracle.getPriceState();
        bool failed = v.state == PriceState.Cached || v.state == PriceState.Expired;
        assertEq(v.routeUsed == RouteSlot.None, failed, "no route exactly when failed");
        if (failed) {
            assertGt(v.failureStart, 0);
            assertLe(v.failureStart, block.timestamp, "a failure never starts in the future");
            assertEq(v.cachedUntil, v.failureStart + 3600);
            assertEq(v.state == PriceState.Cached, block.timestamp < v.cachedUntil, "Cached inside the window");
            assertEq(v.quote, 0);
            assertEq(v.servedUpdatedAt, v.acceptedUpdatedAt, "the accepted price keeps its timestamp");
            assertEq(v.borrowPriceMaxAge, 0);
            assertEq(v.liquidationPriceMaxAge, 0);
        } else {
            assertEq(v.failureStart, 0);
            assertEq(v.cachedUntil, 0);
        }
    }

    // TEST-105 verifies: REQ-ORACLE-022, SPEC-ORC-016, REQ-ORACLE-084, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-016 (D implies pauseActive or disagreementExpired, never both)
    function invariant_TEST_105_driftingIsExactlyADisagreement() public view {
        DebtPriceView memory v = oracle.getPriceState();
        bool drifting = v.state == PriceState.Drifting;
        assertEq(v.reasons & R_DISAGREE != 0, drifting, "the DISAGREE reason exactly while Drifting");
        if (drifting) {
            assertTrue(v.disagreementPauseActive != v.disagreementExpired, "pause xor expired");
        } else {
            assertFalse(v.disagreementPauseActive);
            assertFalse(v.disagreementExpired);
        }
    }

    // TEST-105 verifies: REQ-ORACLE-093, REQ-ORACLE-090, REQ-ORACLE-100, REQ-ORACLE-034
    // Sources: 2.10 REQ-ORACLE-093 (liquidationPaused and borrowAllowed), REQ-ORACLE-034 (inGrace)
    function invariant_TEST_105_gatesFollowTheState() public view {
        DebtPriceView memory v = oracle.getPriceState();
        bool altPast = v.reasons & R_ALT_PAST_BORROW != 0;
        assertEq(v.liquidationPaused, v.state != PriceState.Live || altPast, "liquidationPaused (no sequencer)");
        if (v.borrowAllowed) {
            assertEq(uint8(v.state), uint8(PriceState.Live));
            assertEq(v.reasons & R_SECOND_SOURCE, 0, "confirmed by the second source");
            assertLe(v.servedAge, v.borrowPriceMaxAge, "within the borrow age");
        }
        bool grace = v.recoveredAt != 0 && v.recoveredAt <= block.timestamp && block.timestamp < v.graceEndsAt;
        assertEq(v.inGrace, grace, "inGrace");
        if (v.recoveredAt != 0) assertEq(v.graceEndsAt, v.recoveredAt + 1800);
        assertEq(v.servedAge, block.timestamp - v.servedUpdatedAt);
    }

    // TEST-105 verifies: REQ-ORACLE-093, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-087
    // Sources: 2.10 REQ-ORACLE-042 (the same code in the same block)
    function invariant_TEST_105_gettersEqualTheReport() public view {
        DebtPriceView memory v = oracle.getPriceState();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(answer, v.answer);
        assertEq(oracle.latestAnswer(), v.answer);
        assertEq(updatedAt, v.servedUpdatedAt);
        assertEq(startedAt, v.servedUpdatedAt);
        assertEq(roundId, uint80(v.servedUpdatedAt));
        assertEq(answeredInRound, roundId);
        assertEq(oracle.borrowPriceMaxAge(), v.borrowPriceMaxAge);
        assertEq(oracle.liquidationPriceMaxAge(), v.liquidationPriceMaxAge);
        (uint256 price, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(price, v.acceptedAnswer);
        assertEq(at, v.acceptedUpdatedAt);
    }
}
