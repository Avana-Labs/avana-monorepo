// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Oracle fuzz of the LPOracle base (5.1 `TEST-219`): answers across and beyond the pinned bounds, timestamps
/// zero, future and past every age bound, reverting and malformed reads, pool-module failures and the disagreement
/// window across `disagreementPauseMax` +/- 1 s.
/// forge-config: default.isolate = false
contract LPOracleOracleFuzzTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    /// @dev One leg's round from fuzzed inputs: the answer class and the age class.
    function _round(
        OracleFeedMock f,
        uint8 answerClass,
        uint256 raw,
        uint8 ageClass,
        uint256 age
    ) internal {
        int256 answer;
        if (answerClass % 6 == 0) answer = 0;
        else if (answerClass % 6 == 1) answer = 1;
        else if (answerClass % 6 == 2) answer = 1e12;
        else if (answerClass % 6 == 3) answer = -int256(bound(raw, 1, 1e20));
        else if (answerClass % 6 == 4) answer = int256(bound(raw, 1e6, 2e8));
        else answer = int256(bound(raw, 2, 1e12 - 1));
        uint256 at;
        if (ageClass % 4 == 0) at = 0;
        else if (ageClass % 4 == 1) at = block.timestamp + 1 + bound(age, 0, 1e6);
        else at = block.timestamp - bound(age, 0, ageClass % 4 == 2 ? MAX_AGE : 1e6);
        f.setRound(uint80(bound(raw, 2, type(uint64).max)), answer, at, at);
        if (answerClass % 7 == 6) f.setMode(f.latestRoundData.selector, ReadMode.Revert);
    }

    // TEST-219 verifies: REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-061, REQ-ORACLE-085, REQ-ORACLE-086, SPEC-ORC-017, INV-055, INV-087, ATTACK-055, ATTACK-145, Q-056, Q-191, Q-247
    // Sources: 5.1 TEST-219, HYP-11, HYP-42
    function testFuzz_TEST_219_servedBoundsEveryState(
        uint8[4] memory answerClass,
        uint256[4] memory raw,
        uint8[4] memory ageClass,
        uint256[4] memory age,
        uint32 dt,
        uint8 module,
        bool pokeFirst
    ) public {
        vm.warp(T0 + bound(dt, 0, 400_000));
        OracleFeedMock[4] memory feeds = [pA, aA, pB, aB];
        for (uint256 i = 0; i < 4; ++i) {
            _round(feeds[i], answerClass[i], raw[i], ageClass[i], age[i]);
        }
        if (module % 5 == 1) oracle.setLock(false, true);
        else if (module % 5 == 2) oracle.setConsistency(false, true, 99, false);
        else if (module % 5 == 3) oracle.setCompositionFails(true);
        else if (module % 5 == 4) oracle.setConsistency(true, false, 0, true);
        if (pokeFirst) oracle.poke();
        PriceStateView memory v = oracle.getPriceState();
        int256 answer = oracle.latestAnswer();
        assertEq(answer, v.answer, "latestAnswer == getPriceState().answer");
        assertGe(answer, 1, "served below 1");
        uint256 served = uint256(answer);
        uint256 accepted = uint256(v.acceptedAnswer);
        if (v.state != PriceState.Live) assertLe(served, accepted, "not Live: above the accepted price");
        if (v.state == PriceState.Expired) assertEq(served, 1);
        if (v.state == PriceState.Cached) assertEq(served, accepted);
        if (v.freshAnswer != 0 && v.state != PriceState.Cached) {
            assertLe(served, uint256(v.freshAnswer), "not failed: above the fresh price");
        }
        if (v.state == PriceState.Cached || v.state == PriceState.Expired) assertTrue(v.liquidationPaused);
        if (v.borrowAllowed) assertEq(uint8(v.state), uint8(PriceState.Live));
        (, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        assertLe(acceptedAt, block.timestamp, "accepted timestamp is a source timestamp");
    }

    // TEST-219 verifies: SPEC-ORC-016, REQ-ORACLE-022, REQ-ORACLE-084, INV-059, Q-162, Q-208
    function testFuzz_TEST_219_disagreementAcrossPauseMax(
        uint32 offset
    ) public {
        uint256 t1 = T0 + 600;
        vm.warp(t1);
        _pushAll(int256(ONE), t1);
        aB.push(97_500_000, t1);
        oracle.poke();
        uint256 dt = bound(offset, 3598, 3602);
        vm.warp(t1 + dt);
        PriceStateView memory v = oracle.getPriceState();
        assertEq(v.disagreementPauseActive, dt < 3600, "pause until disagreeSince + disagreementPauseMax");
        assertEq(v.disagreementExpired, dt >= 3600);
        assertTrue(v.liquidationPaused);
        assertLe(uint256(v.answer), uint256(v.freshAnswer));
    }
}
