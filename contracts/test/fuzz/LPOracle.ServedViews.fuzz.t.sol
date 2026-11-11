// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice The served-price views skip the second sources (`REQ-ORACLE-100`): whatever the second sources do (agree,
/// disagree, go stale, revert, return malformed or oversized data, burn their gas), in every market state, every
/// served view returns exactly what `getPriceState()`, which evaluates them, reports in the same block.
/// forge-config: default.isolate = false
contract LPOracleServedViewsFuzzTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    /// @dev A second source's behaviour from fuzzed inputs.
    function _second(
        OracleFeedMock f,
        uint8 mode,
        uint256 answer,
        uint256 age
    ) internal {
        f.push(int256(bound(answer, 1, 1e12 - 1)), block.timestamp - bound(age, 0, 2 * MAX_AGE));
        ReadMode m = ReadMode(mode % 5);
        f.setMode(f.latestRoundData.selector, m);
        if (mode % 7 == 6) f.setMode(f.decimals.selector, ReadMode.Revert);
    }

    // TEST-219 verifies: REQ-ORACLE-100, REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-043, REQ-ORACLE-044, REQ-ORACLE-061, SPEC-ORC-015, SPEC-ORC-017, SPEC-ORC-020
    // Sources: 5.1 TEST-219
    function testFuzz_TEST_219_servedViewsIndependentOfSecondSources(
        uint8[2] memory mode,
        uint256[2] memory answer,
        uint256[2] memory age,
        uint8 market,
        uint32 dt
    ) public {
        vm.warp(T0 + bound(dt, 0, 7200));
        // Market states: Live; USDC on its alternate; a disagreement (Drifting); USDT failed (Cached).
        if (market % 4 == 1) {
            pA.push(int256(ONE), block.timestamp - MAX_AGE - 1);
        } else if (market % 4 == 2) {
            aB.push(97e6, block.timestamp);
        } else if (market % 4 == 3) {
            pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
            aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        }
        _second(sA, mode[0], answer[0], age[0]);
        _second(sB, mode[1], answer[1], age[1]);
        PriceStateView memory v = oracle.getPriceState();
        assertEq(oracle.latestAnswer(), v.answer, "latestAnswer");
        (uint80 roundId, int256 a, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(a, v.answer, "latestRoundData answer");
        assertEq(updatedAt, v.servedUpdatedAt, "updatedAt");
        assertEq(startedAt, v.servedUpdatedAt, "startedAt");
        assertEq(roundId, uint80(v.servedUpdatedAt), "roundId");
        assertEq(answeredInRound, roundId, "answeredInRound");
        (uint256[] memory prices, uint64 servedAt, PriceState state) = oracle.getTokenPrices();
        assertEq(servedAt, v.servedUpdatedAt, "getTokenPrices updatedAt");
        assertEq(uint8(state), uint8(v.state), "state");
        assertEq(prices.length, 2, "prices");
        if (state == PriceState.Live || state == PriceState.Drifting) {
            assertEq(prices[0], v.tokens[0].valuationPrice, "price 0");
            assertEq(prices[1], v.tokens[1].valuationPrice, "price 1");
        }
        assertEq(oracle.borrowPriceMaxAge(), v.borrowPriceMaxAge, "borrow age");
        assertEq(oracle.liquidationPriceMaxAge(), v.liquidationPriceMaxAge, "liquidation age");
        // A borrow still needs both second sources: the report alone carries the gate.
        if (v.borrowAllowed) assertFalse(_has(v.reasons, 16), "borrowAllowed with a disagreeing second source");
    }

    // TEST-219 verifies: REQ-ORACLE-061, REQ-ORACLE-039, REQ-ORACLE-100
    /// @notice A served view needs no more gas than `getPriceState()`: with the gas at which the report completes, the
    /// served price completes too, and below it the only revert is `InsufficientGas`.
    function testFuzz_TEST_219_servedViewNeedsNoMoreGasThanReport(
        uint256 gas
    ) public {
        sA.setMode(sA.latestRoundData.selector, ReadMode.BurnGas);
        gas = bound(gas, 50_000, 2_000_000);
        (bool reportOk,) = address(oracle).staticcall{gas: gas}(abi.encodeCall(oracle.getPriceState, ()));
        (bool servedOk, bytes memory ret) =
            address(oracle).staticcall{gas: gas}(abi.encodeCall(oracle.latestAnswer, ()));
        if (reportOk) assertTrue(servedOk, "served view reverted where the report did not");
        if (!servedOk && ret.length >= 4) assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector, "revert");
    }
}
