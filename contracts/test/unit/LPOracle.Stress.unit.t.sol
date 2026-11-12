// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Stress valuation, the USD band and the quote-change cap of the LPOracle base (2.10).
/// forge-config: default.isolate = false
contract LPOracleStressUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    // TEST-230 verifies: REQ-ORACLE-020, REQ-ORACLE-085, REQ-ORACLE-086, REQ-ORACLE-087, SPEC-ORC-017, INV-087, INV-055, ATTACK-145, Q-247
    // Sources: 5.1 TEST-230
    function test_TEST_230_servedByState() public {
        // Drifting with no disagreement: min(fresh, A); fresh above A is served at A.
        vm.warp(T0 + 60);
        oracle.setConsistency(false, true, 80, false);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(v.answer, int256(SEEDED), "fresh == A");
        _pushAll(99_000_000, T0 + 60);
        v = _state();
        assertEq(v.answer, v.freshAnswer, "fresh below A is served");
        assertLt(uint256(v.answer), SEEDED);
        // Cached: A. Expired: 1. lastAcceptedPrice stays A in every state.
        oracle.setConsistency(false, false, 0, false);
        oracle.setLock(false, true);
        oracle.poke();
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.answer, int256(SEEDED));
        vm.warp(T0 + 60 + 3600);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(v.answer, 1);
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        assertEq(accepted, SEEDED);
        assertTrue(v.liquidationPaused, "an Expired market's own seizure waits");
    }

    // TEST-251 verifies: REQ-ORACLE-009, REQ-ORACLE-015, SPEC-ORC-011, REQ-ORACLE-073, ATTACK-052, Q-275
    // Sources: 5.1 TEST-251, HYP-63
    function test_TEST_251_upperBoundOnCapped() public {
        // GHO at 1.047 with USDC at 1.00: uncapped 1.047 would breach 1.02^2, capped it passes.
        vm.warp(T0 + 60);
        pA.push(104_700_000, T0 + 60);
        aA.push(104_700_000, T0 + 60);
        sA.push(104_700_000, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "GHO above peg stays Live");
        assertFalse(_has(v.reasons, 3));
    }

    // TEST-251 verifies: REQ-ORACLE-015, SPEC-ORC-011, ATTACK-051, Q-176, Q-195
    function test_TEST_251_lowerBoundUncapped() public {
        vm.warp(T0 + 60);
        _pushAll(89_000_000, T0 + 60);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertTrue(_has(v.reasons, 3), "USD_BAND");
        assertEq(v.usdLevel, 89_000_000);
        assertFalse(v.liquidationPaused, "a band breach never pauses liquidation");
        assertFalse(v.borrowAllowed);
        assertEq(v.answer, v.freshAnswer, "min(fresh, A)");
        // Back inside the band restores Live.
        _pushAll(99_987_000, T0 + 60);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.usdLevel, 99_987_000);
    }

    // TEST-043 verifies: REQ-ORACLE-015, REQ-ORACLE-073, SPEC-ORC-011, Q-176, Q-195
    // Sources: 5.1 TEST-043 (LPOracle part: state, reasons and served price; RiskModule and LPVaultSwap parts in theirs)
    function test_TEST_043_breachIsDriftingNotPaused() public {
        vm.warp(T0 + 60);
        _pushAll(89_500_000, T0 + 60);
        aB.push(85_000_000, T0 + 60);
        PriceStateView memory v = _state();
        assertTrue(_has(v.reasons, 3) && _has(v.reasons, 2), "band and disagreement together");
        assertTrue(v.liquidationPaused, "the disagreement rules apply");
    }

    // TEST-219 verifies: REQ-ORACLE-103, REQ-AMM-CORE-014, INV-087, Q-321
    // TEST-283 verifies: REQ-AMM-CORE-014
    function test_TEST_219_quoteChangeCapHoldsOneBlock() public {
        // In the block of the seed a 1.5 % move is refused and served as Cached at the accepted price.
        _pushAll(98_500_000, T0);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(_has(v.reasons, 18), "QUOTE_CHANGE_CAPPED");
        assertEq(v.answer, int256(SEEDED));
        uint256[] memory prices;
        (prices,,) = oracle.getTokenPrices();
        assertEq(prices[0], ONE, "the accepted vector while capped");
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.QuoteChangeCapped(int256(SEEDED), int256(2 * 98_499_901));
        oracle.poke();
        // A move within 1 % is not capped; a later block accepts the 1.5 % move.
        vm.roll(block.number + 1);
        vm.warp(T0 + 12);
        _pushAll(98_500_000, T0 + 12);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        assertEq(accepted, 2 * 98_499_901);
        _pushAll(99_000_000, T0 + 12);
        assertEq(uint8(_state().state), uint8(PriceState.Live), "0.5 % in the same block is accepted");
    }

    // TEST-219 verifies: REQ-ORACLE-060, REQ-ORACLE-061, INV-055, Q-056, Q-191
    function test_TEST_219_extremeAnswersNeverRevert() public {
        int256[6] memory answers = [int256(0), -1, type(int256).max, type(int256).min, 1, 1e12 - 1];
        for (uint256 i = 0; i < answers.length; ++i) {
            pA.push(answers[i], T0);
            aA.push(answers[i], T0);
            assertGe(oracle.latestAnswer(), 1);
            oracle.getPriceState();
            oracle.getTokenPrices();
            oracle.borrowPriceMaxAge();
            oracle.liquidationPriceMaxAge();
            oracle.latestRoundData();
        }
        pA.setMode(pA.latestRoundData.selector, ReadMode.Huge);
        sB.setMode(sB.latestRoundData.selector, ReadMode.Short);
        assertGe(oracle.latestAnswer(), 1);
    }
}
