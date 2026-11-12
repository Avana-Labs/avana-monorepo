// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Price formula, decimals, never-revert and failure classes of the LPOracle base (2.10).
contract LPOraclePriceUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    // TEST-036 verifies: SPEC-ORC-008, SPEC-ORC-005, SPEC-UNIT-003, REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-047, REQ-ORACLE-059, Q-028, Q-066, Q-191, INV-055
    // Sources: 5.1 TEST-036
    function test_TEST_036_formula() public {
        assertEq(oracle.vaultDecimals(), 6, "d");
        assertEq(oracle.latestAnswer(), int256(SEEDED), "seeded price8");
        (uint256 accepted, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(accepted, SEEDED);
        assertEq(at, T0);
        // USDC at 0.99987, USDT at 1.00: floor(999,999 * 99,987,000 / 10^6) + floor(999,999 * 10^8 / 10^6) = 99,986,900 + 99,999,900.
        vm.warp(T0 + 60);
        pA.push(99_987_000, T0 + 60);
        aA.push(99_987_000, T0 + 60);
        assertEq(oracle.latestAnswer(), int256(99_986_900 + 99_999_900));
    }

    // TEST-036 verifies: SPEC-ORC-004, REQ-ORACLE-009, Q-177
    function test_TEST_036_stableCeilingCapsValuation() public {
        vm.warp(T0 + 60);
        pA.push(100_300_000, T0 + 60);
        aA.push(100_300_000, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].quote, 100_300_000, "quote uncapped");
        assertEq(v.tokens[0].valuationPrice, ONE, "valuation capped");
        assertEq(v.answer, int256(SEEDED), "ceiling: no premium");
        assertEq(uint8(v.state), uint8(PriceState.Live), "the ceiling alone never makes the market Drifting");
    }

    // TEST-036 verifies: REQ-ORACLE-040, REQ-ORACLE-041, Q-066
    function test_TEST_036_decimalsEight() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "USDC/USDT [-10,10] / USD");
        (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answered) = oracle.latestRoundData();
        assertEq(answer, int256(SEEDED));
        assertEq(updatedAt, T0);
        assertEq(startedAt, T0);
        assertEq(id, uint80(T0));
        assertEq(answered, uint80(T0));
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-061, REQ-ORACLE-085, REQ-ORACLE-087, SPEC-ORC-017, INV-055, Q-128, Q-247
    // Sources: 5.1 TEST-038
    function test_TEST_038_neverFailsNeverZero() public {
        // Both routes of token B fail by Error: Cached at the accepted price, then Expired at 1.
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.answer, int256(SEEDED), "Cached serves the accepted price");
        assertEq(v.servedUpdatedAt, T0, "original timestamp");
        assertEq(v.freshAnswer, 0, "no fresh price when failed");
        vm.warp(T0 + 3600);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(oracle.latestAnswer(), 1, "Expired serves 1");
        (uint256 accepted, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(accepted, SEEDED, "accepted kept");
        assertEq(at, T0);
        uint256[] memory prices;
        (prices,,) = oracle.getTokenPrices();
        assertEq(prices[0], ONE, "accepted vector when failed");
        assertEq(oracle.borrowPriceMaxAge(), 0, "failed: borrow age 0");
        assertEq(oracle.liquidationPriceMaxAge(), 0, "failed: liquidation age 0");
    }

    // TEST-038 verifies: REQ-ORACLE-002, REQ-ORACLE-067, SPEC-ORC-001, Q-056, Q-191
    function test_TEST_038_zeroAnswerIsFailure() public {
        vm.warp(T0 + 60);
        pA.push(0, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].routeUsed, 2, "zero primary: alternate");
        assertEq(uint8(v.state), uint8(PriceState.Live));
        aA.push(-5, T0 + 60);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "both zero or negative: failed");
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
        assertGe(oracle.latestAnswer(), 1);
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-039, REQ-ORACLE-102, SPEC-ORC-023, ATTACK-042, Q-328
    function test_TEST_038_gasStarvedReadStricter() public {
        // A feed that burns its whole explicit gas is a failure of that feed: the alternate quotes.
        pA.setMode(pA.latestRoundData.selector, ReadMode.BurnGas);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].routeUsed, 2, "starved primary fails over");
        assertEq(uint8(v.state), uint8(PriceState.Live));
        // A caller who leaves less than the pre-call bound gets InsufficientGas, never a stricter state.
        (bool ok, bytes memory ret) = address(oracle).staticcall{gas: 120_000}(abi.encodeCall(oracle.latestAnswer, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector);
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-061, Q-056
    function test_TEST_038_malformedAndOversizedReturns() public {
        pA.setMode(pA.latestRoundData.selector, ReadMode.Short);
        assertEq(_state().tokens[0].routeUsed, 2, "short return: Error");
        pA.setMode(pA.latestRoundData.selector, ReadMode.Huge);
        assertEq(_state().tokens[0].routeUsed, 2, "oversized return read bounded: zero answer, Invalid");
        pA.setMode(pA.latestRoundData.selector, ReadMode.Normal);
        pA.setMode(pA.decimals.selector, ReadMode.Revert);
        assertEq(_state().tokens[0].routeUsed, 2, "decimals() revert: Error");
        assertEq(oracle.latestAnswer(), int256(SEEDED));
    }
}
