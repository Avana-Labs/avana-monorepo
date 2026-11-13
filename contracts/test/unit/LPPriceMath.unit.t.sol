// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {LPPriceMathHarness} from "../utils/harness/LPPriceMathHarness.sol";

/// @title LPPriceMathUnitTest
/// @notice Golden vectors of every LPPriceMath formula: the worked examples of 2.10 (`SPEC-ORC-001` … `SPEC-ORC-023`),
/// recomputed in SymPy `sym08` (`SYM-121` … `SYM-172`, `SYM-190`, `SYM-191`) and the Z3 `units-oracle` models
/// (`MATH-UO-58` … `MATH-UO-66` for the input bounds), plus the boundaries of each formula: 0 and 1, signed and oversize
/// answers, decimals at and beyond 8, malformed vectors, sentinels, saturation and state precedence.
/// @dev Library half of TEST-036, TEST-038, TEST-039, TEST-042, TEST-070, TEST-139, TEST-167, TEST-217, TEST-230,
/// TEST-250, TEST-251, TEST-275 and TEST-276; the LPOracle and DebtOracle halves join those rows with the oracles.
contract LPPriceMathUnitTest is AvanaTest {
    uint256 internal constant MAX_ROUTE = 1e18;
    uint256 internal constant SAT = type(uint256).max;

    LPPriceMathHarness internal m;

    function setUp() public {
        m = new LPPriceMathHarness();
    }

    // ─── SPEC-ORC-001 leg normalisation ───

    // TEST-038 verifies: SPEC-ORC-001, REQ-ORACLE-002, ATTACK-055, Q-191
    // Sources: 5.1 TEST-038 (normalised 0 is a failure), SYM-121, MATH-UO-15
    function test_TEST_038_normalizeAnswerSpecExample() public view {
        assertEq(m.normalizeAnswer(99_987_000, 8), 99_987_000, "8 decimals");
        assertEq(m.normalizeAnswer(999_870_000_000_000_000, 18), 99_987_000, "18 decimals");
        assertEq(m.normalizeAnswer(999_870, 6), 99_987_000, "6 decimals");
        assertEq(m.normalizeAnswer(1, 0), 1e8, "0 decimals");
    }

    // TEST-038 verifies: SPEC-ORC-001, REQ-ORACLE-002, ATTACK-055, Q-191
    // Sources: MATH-UO-15b (a feed with more than 8 decimals and a tiny answer floors to 0), MATH-UO-58e
    function test_TEST_038_normalizeAnswerTinyAnswerIsZero() public view {
        int256 maxAnswer = int256(uint256(type(uint128).max));
        assertEq(m.normalizeAnswer(9_999_999_999, 18), 0, "below one unit floors to 0");
        assertEq(m.normalizeAnswer(10_000_000_000, 18), 1, "exactly one unit");
        assertEq(m.normalizeAnswer(maxAnswer, 46), uint256(type(uint128).max) / 1e38, "f = 46: 10^38 < 2^128");
        assertEq(m.normalizeAnswer(maxAnswer, 47), 0, "f = 47: 10^39 > 2^128, always 0");
        assertEq(m.normalizeAnswer(maxAnswer, 255), 0, "f = 255");
        assertEq(m.normalizeAnswer(0, 8), 0, "zero stays zero");
    }

    // TEST-038 verifies: SPEC-ORC-001, REQ-ORACLE-002, REQ-ORACLE-061, ATTACK-055
    // Sources: MATH-UO-58a, MATH-UO-58d (a negative answer read unsigned is a huge price)
    function test_TEST_038_normalizeAnswerSignedAndOversizeFailClosed() public view {
        assertEq(m.normalizeAnswer(-1, 18), 0, "negative, 18 decimals");
        assertEq(m.normalizeAnswer(-1, 6), 0, "negative, 6 decimals: no overflow revert");
        assertEq(m.normalizeAnswer(type(int256).min, 0), 0, "int256 min");
        assertEq(m.normalizeAnswer(type(int256).max, 0), 0, "int256 max");
        assertEq(m.normalizeAnswer(int256(2 ** 128), 8), 0, "2^128 is outside the bound");
        int256 top = int256(2 ** 128 - 1);
        assertEq(m.normalizeAnswer(top, 0), (2 ** 128 - 1) * 1e8, "2^128 - 1 at 0 decimals fits");
    }

    // ─── SPEC-ORC-002 route value and timestamp ───

    // TEST-070 verifies: SPEC-ORC-002, REQ-ORACLE-012, Q-119
    // Sources: SYM-122, MATH-UO-48
    function test_TEST_070_routeValueSpecExample() public view {
        assertEq(m.routeValue2(333_300_000_000_000, 18, 300_000_000_000, 8), 99_990_000, "USDT/ETH x ETH/USD");
        assertEq(m.routeTimestamp(1_762_650_000, 1_762_649_000), 1_762_649_000, "oldest leg");
        assertEq(m.routeTimestamp(1_762_649_000, 1_762_650_000), 1_762_649_000, "oldest leg, other order");
        assertEq(m.routeValue1(99_987_000, 8), 99_987_000, "one leg = normalised answer");
        assertEq(m.routeValue1(-99_987_000, 8), 0, "one leg, negative");
    }

    // TEST-070 verifies: SPEC-ORC-002, REQ-ORACLE-012, REQ-ORACLE-049
    // Sources: MATH-UO-58b, MATH-UO-58c
    function test_TEST_070_routeValueRoundsDownAndRefusesShortDecimals() public view {
        int256 top = int256(2 ** 128 - 1);
        // 3 * 7 / 10 = 2.1 floors to 2.
        assertEq(m.routeValue2(3, 5, 7, 4), 2, "floor");
        // fA + fB < 8 is not listable: the route is invalid (0).
        assertEq(m.routeValue2(1e8, 3, 1e8, 4), 0, "fA + fB < 8");
        assertEq(m.routeValue2(12, 4, 34, 4), 408, "fA + fB = 8");
        // The largest product: both answers 2^128 - 1 at fA + fB = 8 still fits 256 bits.
        assertEq(m.routeValue2(top, 0, top, 8), uint256(2 ** 128 - 1) ** 2, "largest product");
        // Exponent above 77: every product below 2^256 floors to 0.
        assertEq(m.routeValue2(top, 255, top, 255), 0, "huge exponent");
        assertEq(m.routeValue2(10 ** 38, 40, 10 ** 38, 46), 0, "exponent 78");
    }

    // TEST-070 verifies: SPEC-ORC-002, REQ-ORACLE-002, REQ-ORACLE-061, ATTACK-055
    // Sources: MATH-UO-58c (the old bound aA, aB < 2^255 let mulDiv revert)
    function test_TEST_070_routeValueInvalidLegsGiveZero() public view {
        assertEq(m.routeValue2(-1, 18, 300_000_000_000, 8), 0, "negative leg A");
        assertEq(m.routeValue2(333_300_000_000_000, 18, -1, 8), 0, "negative leg B");
        assertEq(m.routeValue2(0, 18, 300_000_000_000, 8), 0, "zero leg");
        int256 big = int256(2 ** 200);
        assertEq(m.routeValue2(big, 4, big, 4), 0, "2^200 x 2^200 at fA + fB = 8: invalid, no revert");
    }

    // ─── SPEC-ORC-019 feed age limit ───

    // TEST-250 verifies: SPEC-ORC-019, REQ-ORACLE-054, Q-322
    // Sources: SYM-166, SYM-135, MATH-UO-50c
    function test_TEST_250_feedMaxAgeLaunchFeeds() public view {
        assertEq(m.feedMaxAge(82_800, 1800), 84_600, "Ethereum USDC/USD");
        assertEq(m.feedMaxAge(86_400, 1800), 88_200, "USDT/USD, GHO/USD, Base stables");
        assertEq(m.feedMaxAge(3600, 1800), 5400, "ETH/USD");
        assertEq(m.feedMaxAge(type(uint32).max, type(uint32).max), uint64(type(uint32).max) * 2, "no overflow");
        assertEq(1_762_560_000 + uint256(m.feedMaxAge(86_400, 1800)), 1_762_648_200, "last valid second");
    }

    // ─── SPEC-ORC-003 agreement ───

    // TEST-039 verifies: SPEC-ORC-003, REQ-ORACLE-008, ATTACK-054, Q-184
    // Sources: SYM-123, MATH-UO-24
    function test_TEST_039_routesAgreeSpecExample() public view {
        assertTrue(m.routesAgree(100_010_000, 99_900_000, 225), "agrees");
        assertFalse(m.routesAgree(100_010_000, 97_500_000, 225), "disagrees");
        assertTrue(m.routesAgree(99_900_000, 100_010_000, 225), "symmetric agree");
        assertFalse(m.routesAgree(97_500_000, 100_010_000, 225), "symmetric disagree");
    }

    // TEST-039 verifies: SPEC-ORC-003, ATTACK-054, Q-184
    // Sources: MATH-UO-24a (floor division would admit T + 1 bps)
    function test_TEST_039_routesAgreeExactAtTheEdge() public view {
        assertTrue(m.routesAgree(100_000_000 + 225 * 10_000, 100_000_000, 225), "at the edge");
        assertFalse(m.routesAgree(100_000_000 + 225 * 10_000 + 1, 100_000_000, 225), "one unit past");
        assertEq(m.deviationBps(100_000_000 + 225 * 10_000 + 1, 100_000_000), 225, "floored deviation reads 225");
        assertTrue(m.routesAgree(5, 5, 0), "equal values agree at T = 0");
        assertFalse(m.routesAgree(5, 6, 0), "different values never agree at T = 0");
    }

    // TEST-039 verifies: SPEC-ORC-003, SPEC-ORC-020, REQ-ORACLE-008
    // Sources: MATH-UO-60c (outside [1, MAX_ROUTE_ANSWER] the test fails closed)
    function test_TEST_039_agreementOutsideTheBoundsFailsClosed() public view {
        assertFalse(m.routesAgree(0, 0, 10_000), "two zeros never agree");
        assertFalse(m.routesAgree(MAX_ROUTE + 1, MAX_ROUTE + 1, 10_000), "above MAX_ROUTE_ANSWER");
        assertFalse(m.routesAgree(1, 2 ** 243, 100), "no overflow revert");
        assertTrue(m.routesAgree(MAX_ROUTE, MAX_ROUTE - 1, 1), "at the bound");
        assertFalse(m.secondSourceAgrees(true, 0, 0, 10_000), "second source of 0");
        assertFalse(m.secondSourceAgrees(true, MAX_ROUTE + 1, MAX_ROUTE + 1, 10_000), "second source oversize");
    }

    // TEST-039 verifies: REQ-ORACLE-042
    // Sources: MATH-UO-60a, MATH-UO-60b
    function test_TEST_039_deviationBpsReportsUnreadableAndSaturates() public view {
        assertEq(m.deviationBps(0, 1e8), SAT, "unreadable");
        assertEq(m.deviationBps(100_010_000, 97_500_000), 257, "floor(2,510,000e4 / 97,500,000)");
        assertEq(m.deviationBps(1e8, 1e8), 0, "equal");
        assertEq(m.deviationBps(1, SAT), SAT, "|x - y| * 1e4 needs 257 bits: saturated, no revert");
        uint256 gap = 2 ** 240 - 1e8;
        assertEq(m.deviationBps(1e8, 2 ** 240), gap * 1e4 / 1e8, "large but representable");
        assertEq(m.deviationBps(1e8, 2 ** 250), SAT, "(2^250 - 1e8) * 1e4 needs 257 bits");
    }

    // ─── SPEC-ORC-020 second source ───

    // TEST-276 verifies: SPEC-ORC-020, REQ-ORACLE-100, Q-323
    // Sources: SYM-169, MATH-UO-54c
    function test_TEST_276_secondSourceSpecExample() public view {
        assertTrue(m.secondSourceAgrees(true, 100_020_000, 99_400_000, 100), "confirmed");
        assertFalse(m.secondSourceAgrees(true, 100_020_000, 98_900_000, 100), "not confirmed");
        assertFalse(m.secondSourceAgrees(false, 100_020_000, 100_020_000, 100), "invalid source never confirms");
        assertTrue(m.secondSourceAgrees(true, 99_400_000, 100_020_000, 100), "symmetric");
    }

    // ─── SPEC-ORC-004 stable ceiling ───

    // TEST-167 verifies: SPEC-ORC-004, REQ-ORACLE-009, Q-177
    // Sources: SYM-124, MATH-UO-19
    function test_TEST_167_valuationPriceSpecExample() public view {
        assertEq(m.valuationPrice(100_300_000, true), 1e8, "GHO above peg capped");
        assertEq(m.valuationPrice(99_987_000, true), 99_987_000, "USDC below peg unchanged");
        assertEq(m.valuationPrice(1e8, true), 1e8, "at the ceiling");
        assertEq(m.valuationPrice(300_000_000_000, false), 300_000_000_000, "non-stable never capped");
        assertEq(LPPriceMath.STABLE_CEILING_USD, 1e8, "stableCeilingUsd = $1.00");
    }

    // ─── SPEC-ORC-008 vault-token price ───

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-103, INV-055
    // Sources: SYM-127, MATH-UO-51c, AMM-A3f
    function test_TEST_036_lpPriceSpecExampleNarrowRange() public view {
        assertEq(_price(_u2(5_648_563, 4_348_479), _u2(99_987_000, 1e8), _d2(6, 6)), 999_630_568, "[-10, 10]");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055
    // Sources: SYM-127 (DAI/USDC full range, 200 units below the closed form)
    function test_TEST_036_lpPriceSpecExampleFullRange() public view {
        uint256 p = _price(_u2(1e18, 999_999), _u2(1e8, 1e8), _d2(18, 6));
        assertEq(p, 199_999_799, "99,999,999 + 99,999,800");
        assertEq(199_999_999 - p, 200, "200 units below isqrt(4e16) - 1");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-103
    // Sources: SYM-125 (depegged USDC/USDT on [-100, 100], clamped composition)
    function test_TEST_036_lpPriceSpecExampleOneTokenHolding() public view {
        assertEq(_price(_u2(0, 9_999_541), _u2(1e8, 95_200_000), _d2(6, 6)), 951_956_208, "clamped holding");
    }

    // TEST-230 verifies: SPEC-ORC-008, SPEC-ORC-017
    // Sources: SYM-133 (lower-route composition of the disagreement example)
    function test_TEST_230_lpPriceLowerRouteExample() public view {
        assertEq(_price(_u2(987_420, 1_012_739), _u2(1e8, 97_500_000), _d2(6, 6)), 197_483_855, "lower");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-060, INV-055
    function test_TEST_036_lpPriceFloorsAtOneAndDropsOneRawUnit() public view {
        assertEq(_price(_u2(0, 0), _u2(1e8, 1e8), _d2(6, 6)), 1, "empty holding is 1");
        assertEq(_price(_u2(1, 1), _u2(1e8, 1e8), _d2(6, 6)), 1, "one raw unit each is taken off");
        assertEq(_price(_u2(2, 0), _u2(1e8, 1e8), _d2(6, 6)), 100, "a' = 1: 1e-6 tokens = 100 units");
        assertEq(
            _price(_u2(2 ** 128 - 1, 2), _u2(MAX_ROUTE, 1e8), _d2(77, 0)), 1e8, "d = 77: the first term floors to 0"
        );
        uint256[] memory three = new uint256[](3);
        (three[0], three[1], three[2]) = (1e6 + 1, 1e18 + 1, 1e8 + 1);
        uint256[] memory prices = new uint256[](3);
        (prices[0], prices[1], prices[2]) = (1e8, 1e8, 1e8);
        uint8[] memory decs = new uint8[](3);
        (decs[0], decs[1], decs[2]) = (6, 18, 8);
        assertEq(_price(three, prices, decs), 3e8, "three tokens, $1 each");
    }

    // TEST-036 verifies: SPEC-ORC-008, REQ-ORACLE-103, REQ-ORACLE-061
    // Sources: MATH-UO-64 (inputs outside the bounds are a malformed module read, never a revert or a dropped token)
    function test_TEST_036_lpPriceRejectsMalformedCompositions() public view {
        uint256[] memory a3 = new uint256[](3);
        (a3[0], a3[1], a3[2]) = (1e6, 1e6, 1e6);
        _assertInvalid(a3, _u2(1e8, 1e8), _d2(6, 6), "more amounts than prices");
        uint256[] memory a1 = new uint256[](1);
        a1[0] = 1e6 + 1;
        _assertInvalid(a1, _u2(1e8, 1e8), _d2(6, 6), "fewer amounts: no token dropped");
        _assertInvalid(new uint256[](0), new uint256[](0), new uint8[](0), "empty composition");
        _assertInvalid(a1, a1, new uint8[](1), "one token");
        _assertInvalid(new uint256[](9), new uint256[](9), new uint8[](9), "nine tokens");
        _assertInvalid(_u2(1e6, 1e6), _u2(1e8, 1e8), new uint8[](3), "decimals length");
        _assertInvalid(_u2(2 ** 128, 1), _u2(1e8, 1e8), _d2(6, 6), "amount 2^128");
        _assertInvalid(_u2(1e6, 1e6), _u2(0, 1e8), _d2(6, 6), "price 0");
        _assertInvalid(_u2(1e6, 1e6), _u2(1e8, MAX_ROUTE + 1), _d2(6, 6), "price above MAX_ROUTE_ANSWER");
        _assertInvalid(_u2(1e6, 1e6), _u2(MAX_ROUTE + 1, 1e8), _d2(6, 6), "first price above MAX_ROUTE_ANSWER");
        (bool valid,) = m.lpPrice(_u2(1e6, 1e6), _u2(MAX_ROUTE, MAX_ROUTE), _d2(6, 6));
        assertTrue(valid, "prices at MAX_ROUTE_ANSWER = 10^18 are valid");
        _assertInvalid(_u2(1e6, 1e6), _u2(1e8, 1e8), _d2(78, 6), "78 decimals");
    }

    // TEST-070 verifies: SPEC-ORC-001, SPEC-ORC-002, SPEC-ORC-003, SPEC-ORC-008, SPEC-ORC-018, ATTACK-055, Q-191
    // Sources: MATH-UO-14d, MATH-UO-24c, MATH-UO-43c, MATH-UO-64, MATH-UO-75a (no overflow at the extremes of the
    // listing bounds: each term below 2^188, eight below 2^191, the int256 cast safe)
    function test_TEST_070_noOverflowAtListingExtremes() public view {
        uint256 maxAmount = 2 ** 128 - 1;
        uint256[] memory a = new uint256[](8);
        uint256[] memory v = new uint256[](8);
        uint8[] memory d = new uint8[](8);
        for (uint256 i = 0; i < 8; ++i) {
            (a[i], v[i], d[i]) = (maxAmount, MAX_ROUTE, 0);
        }
        uint256 p = _price(a, v, d);
        assertEq(p, 8 * (maxAmount - 1) * MAX_ROUTE, "eight tokens at the extremes");
        assertLt(p, 2 ** 191, "below 2^191");
        assertGe(p, 2 ** 190, "the 2^191 bound is tight: eight terms of nearly 2^188");
        assertLt((maxAmount - 1) * MAX_ROUTE, 2 ** 188, "each term below 2^188");
        assertTrue(m.routesAgree(MAX_ROUTE, MAX_ROUTE - 1, 1), "agreement at the bound");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, MAX_ROUTE, 5000), MAX_ROUTE * 3 / 2, "1.5 x MAX");
    }

    // ─── SPEC-ORC-005 vault-token decimals ───

    // TEST-139 verifies: SPEC-ORC-005, REQ-ORACLE-047, Q-325
    // Sources: SYM-167, MATH-UO-51c (compositions of the concentrated-liquidity module at each d)
    function test_TEST_139_vaultDecimalsSpecExamples() public {
        for (uint8 d = 6; d <= 12; ++d) {
            m.setCompositionTable(d, _u2(10 ** d * 1e6, d == 6 ? 0 : 10 ** (d - 6) - 1));
        }
        (bool found, uint8 dec) = m.vaultDecimalsFromTable(_u2(1e8, 1e8), _d2(18, 6));
        assertTrue(found, "found");
        assertEq(dec, 12, "DAI/USDC full range");

        m.setCompositionTable(6, _u2(564, 434));
        m.setCompositionTable(7, _u2(5648, 4348));
        m.setCompositionTable(8, _u2(56_485, 43_484));
        m.setCompositionTable(9, _u2(564_856, 434_847));
        m.setCompositionTable(10, _u2(5_648_563, 4_348_479));
        (found, dec) = m.vaultDecimalsFromTable(_u2(99_987_000, 1e8), _d2(6, 6));
        assertTrue(found, "found");
        assertEq(dec, 10, "USDC/USDT [-10, 10]");
        assertEq(_price(_u2(564_856, 434_847), _u2(99_987_000, 1e8), _d2(6, 6)), 99_962_756, "d = 9 below $1");

        m.setCompositionTable(6, _u2(0, 9999));
        m.setCompositionTable(7, _u2(0, 99_995));
        m.setCompositionTable(8, _u2(0, 999_954));
        m.setCompositionTable(9, _u2(0, 9_999_541));
        (found, dec) = m.vaultDecimalsFromTable(_u2(1e8, 95_200_000), _d2(6, 6));
        assertTrue(found, "found");
        assertEq(dec, 9, "USDC/USDT [-100, 100] depegged");
    }

    // TEST-139 verifies: SPEC-ORC-005, REQ-ORACLE-047, REQ-ORACLE-103
    function test_TEST_139_vaultDecimalsNotFoundAndBounds() public {
        m.setLinearComposition(_u2(1, 1));
        (bool found, uint8 dec) = m.vaultDecimalsLinear(_u2(1e8, 1e8), _d2(18, 18));
        assertFalse(found, "not found");
        assertEq(dec, 0, "d = 0 when not found");
        m.setLinearComposition(_u2(2e30, 2e30));
        (found, dec) = m.vaultDecimalsLinear(_u2(1e8, 1e8), _d2(18, 18));
        assertTrue(found, "found");
        assertEq(dec, 6, "lower bound 6");
        m.setLinearComposition(_u2(1e18 + 1e17, 0));
        (found, dec) = m.vaultDecimalsLinear(_u2(1e8, 1e8), _d2(18, 18));
        assertTrue(found, "found");
        assertEq(dec, 18, "upper bound 18");
        // A composition of the wrong length at a candidate is malformed: not found, even if a later d would pass.
        m.setCompositionTable(6, new uint256[](3));
        m.setCompositionTable(7, _u2(1e18, 1e18));
        (found, dec) = m.vaultDecimalsFromTable(_u2(1e8, 1e8), _d2(6, 6));
        assertFalse(found, "malformed composition");
        assertEq(dec, 0, "d = 0");
    }

    // ─── SPEC-ORC-011 USD band and level ───

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-009, REQ-ORACLE-015, Q-275
    // Sources: SYM-129, MATH-UO-53d
    function test_TEST_251_usdBandSpecExamples() public view {
        uint256 low = 90_000_000;
        uint256 high = 102_000_000;
        assertTrue(_band(_u2(104_700_000, 1e8), _u2(1e8, 1e8), low, high), "GHO premium in band");
        assertFalse(_band(_u2(104_700_000, 1e8), _u2(104_700_000, 1e8), low, high), "uncapped breaches");
        assertEq(m.fixedPointProduct(_u2(99_987_000, 100_010_000)), 99_996_998, "two-token level");
        assertTrue(_band(_u2(99_987_000, 100_010_000), _u2(99_987_000, 1e8), low, high), "in band");
        assertEq(m.fixedPointProduct(_u2(89_000_000, 89_000_000)), 79_210_000, "both at 0.89");
        assertFalse(_band(_u2(89_000_000, 89_000_000), _u2(89_000_000, 89_000_000), low, high), "below band");
        assertEq(m.fixedPointPower(low, 2), 81_000_000, "low^2");
        assertEq(m.fixedPointPower(high, 2), 104_040_000, "high^2");
        uint256[] memory three = _u3(99_990_000, 1e8, 99_980_000);
        assertEq(m.fixedPointProduct(three), 99_970_002, "three-token level");
        assertEq(m.fixedPointPower(low, 3), 72_900_000, "low^3");
        assertTrue(_band(three, three, low, high), "three tokens in band");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-015
    // Sources: MATH-UO-62 (sticky saturation)
    function test_TEST_251_usdBandSentinelsAndSaturation() public view {
        assertTrue(_band(_u2(1, 1), _u2(MAX_ROUTE, MAX_ROUTE), 0, SAT), "non-stable market");
        assertEq(m.fixedPointPower(SAT, 8), SAT, "saturates, never reverts");
        assertEq(m.fixedPointPower(0, 8), 0, "zero");
        assertEq(m.fixedPointPower(7, 0), 1e8, "empty power is one");
        assertEq(m.fixedPointProduct(new uint256[](0)), 1e8, "empty product is one");
        assertEq(m.fixedPointProduct(_u3(2 ** 200, 2 ** 200, 1)), SAT, "x 1 after saturation stays saturated");
        assertEq(m.fixedPointProduct(_u3(2 ** 200, 2 ** 200, 0)), SAT, "x 0 after saturation stays saturated");
        assertEq(m.fixedPointProduct(_u2(SAT, 1e8)), SAT, "a saturated factor");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-103
    function test_TEST_251_usdBandRejectsMalformedInputs() public view {
        _assertBandInvalid(_u3(1e8, 1e8, 1e8), _u2(1e8, 1e8), "unequal lengths");
        _assertBandInvalid(new uint256[](1), new uint256[](1), "one token");
        _assertBandInvalid(new uint256[](0), new uint256[](0), "empty");
        _assertBandInvalid(new uint256[](9), new uint256[](9), "nine tokens");
        _assertBandInvalid(_u2(0, 1e8), _u2(0, 1e8), "a zero quote");
        _assertBandInvalid(_u2(MAX_ROUTE + 1, 1e8), _u2(1e8, 1e8), "a quote above MAX_ROUTE_ANSWER");
        _assertBandInvalid(_u2(1e8, 1e8), _u2(1e8, MAX_ROUTE + 1), "a price above MAX_ROUTE_ANSWER");
    }

    // TEST-251 verifies: SPEC-ORC-011
    // Sources: MATH-UO-63 (the fixed-point product depends on the order of its factors)
    function test_TEST_251_usdBandTokenOrderAtTheEdge() public view {
        uint256[] memory poolOrder = _u3(95_243_313, 98_905_925, 97_089_205);
        uint256[] memory reversed = _u3(97_089_205, 98_905_925, 95_243_313);
        assertEq(m.fixedPointProduct(poolOrder), 91_459_272, "pool order");
        assertEq(m.fixedPointProduct(reversed), 91_459_273, "reversed");
        assertFalse(_band(poolOrder, poolOrder, 97_067_963, SAT), "out of band in pool order");
        assertTrue(_band(reversed, reversed, 97_067_963, SAT), "in band reversed: order is part of the rule");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-042
    // Sources: SYM-190, MATH-UO-61g
    function test_TEST_251_usdLevelSpecExamples() public view {
        assertEq(m.usdLevel(_u2(99_987_000, 100_010_000)), 99_998_499, "two tokens");
        assertEq(m.fixedPointPower(99_998_499, 2), 99_996_998, "its power is the product");
        assertEq(m.fixedPointPower(99_998_500, 2), 99_997_000, "one more exceeds it");
        assertEq(m.usdLevel(_u2(89_000_000, 89_000_000)), 89_000_000, "both at 0.89");
        assertEq(m.usdLevel(_u3(99_990_000, 1e8, 99_980_000)), 99_990_000, "three tokens");
        assertEq(m.usdLevel(_u2(1, 1)), 9999, "tiny quotes: 9,999^(x)2 = 0 = product, 10,000^(x)2 = 1");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-042
    // Sources: MATH-UO-61e, MATH-UO-61f (the real root sits below usdBandLow while the band passes)
    function test_TEST_251_usdLevelAgreesWithTheBand() public view {
        uint256[] memory q = _u2(81_000_001, 1e8);
        assertTrue(_band(q, q, 90_000_001, 102_000_000), "in band at low = 90,000,001");
        assertEq(m.usdLevel(q), 90_000_001, "level = low: the reported level is never below an in-band low");
        assertFalse(_band(q, q, 90_000_002, 102_000_000), "out of band one unit higher");
        assertEq(m.usdLevel(new uint256[](1)), 0, "malformed: 0");
        assertEq(m.usdLevel(_u2(0, 1e8)), 0, "zero quote: 0");
        assertEq(m.usdLevel(_u2(MAX_ROUTE + 1, 1e8)), 0, "oversize quote: 0");
    }

    // TEST-251 verifies: SPEC-ORC-011, REQ-ORACLE-042, REQ-ORACLE-103
    // Sources: MATH-UO-75i (at MAX_ROUTE_ANSWER = 10^18 six factors are exact, seven or eight saturate), MATH-UO-75j
    // (a saturated product reports usdLevel = type(uint256).max, and the level and the band test still agree)
    function test_TEST_251_usdLevelAtTheRouteBound() public view {
        uint256[] memory six = _filled(6, MAX_ROUTE);
        assertEq(m.fixedPointProduct(six), 1e68, "six factors of 10^18 are exact: 10^68");
        assertEq(m.usdLevel(six), MAX_ROUTE, "six tokens at the bound: level 10^18");
        assertGt(m.fixedPointPower(MAX_ROUTE + 1, 6), 1e68, "one more exceeds the product");
        for (uint256 n = 7; n <= 8; ++n) {
            uint256[] memory q = _filled(n, MAX_ROUTE);
            assertEq(m.fixedPointProduct(q), SAT, "seven or eight factors of 10^18 saturate");
            assertEq(m.usdLevel(q), SAT, "a saturated product reports the saturated level");
            assertTrue(_band(q, q, MAX_ROUTE, SAT), "the lower band test passes at every level");
            assertTrue(_band(q, q, SAT, SAT), "even usdBandLow = type(uint256).max: usdBandLow <= usdLevel");
            q[n - 1] = MAX_ROUTE + 1;
            assertEq(m.usdLevel(q), 0, "an oversize quote is malformed before the product");
        }
    }

    // ─── SPEC-ORC-012 served timestamp, SPEC-ORC-015 age limits ───

    // TEST-038 verifies: SPEC-ORC-012, REQ-ORACLE-021, REQ-ORACLE-066
    // Sources: SPEC-ORC-012 example, MATH-UO-48c, MATH-UO-66a
    function test_TEST_038_servedTimestampSpecExample() public view {
        uint64[] memory t = new uint64[](2);
        (t[0], t[1]) = (1_762_600_000, 1_762_560_000);
        assertEq(m.servedTimestamp(t, false, 1_700_000_000), 1_762_560_000, "oldest input");
        assertEq(m.servedTimestamp(t, true, 1_700_000_000), 1_700_000_000, "failed: accepted timestamp");
        assertEq(m.servedTimestamp(new uint64[](0), false, 123), 0, "no timestamp: 0, every age check fails");
    }

    // TEST-250 verifies: SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-090, Q-274
    // Sources: SYM-130, MATH-UO-46, MATH-UO-50c
    function test_TEST_250_ageLimitsSpecExample() public view {
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](3);
        legs[0] = LPPriceMath.LegAge(1_762_600_000, 84_600, 84_600, false);
        legs[1] = LPPriceMath.LegAge(1_762_640_000, 88_200, 88_200, true);
        legs[2] = LPPriceMath.LegAge(1_762_645_000, 5400, 5400, true);
        (uint32 b, uint32 l) = m.ageLimits(legs, false);
        assertEq(b, 50_400, "borrow: the hourly ETH/USD leg binds");
        assertEq(l, 50_400, "liquidation");
        LPPriceMath.LegAge[] memory primaries = new LPPriceMath.LegAge[](2);
        primaries[0] = legs[0];
        primaries[1] = LPPriceMath.LegAge(1_762_560_000, 88_200, 88_200, false);
        (b, l) = m.ageLimits(primaries, false);
        assertEq(b, 88_200, "borrow on primaries");
        assertEq(l, 88_200, "liquidation on primaries");
    }

    // TEST-250 verifies: SPEC-ORC-015, REQ-ORACLE-090
    // Sources: MATH-UO-46b, SYM-135 (alternate leg held to a lowered borrow age)
    function test_TEST_250_ageLimitsAlternateHeldToBorrowAge() public view {
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](1);
        legs[0] = LPPriceMath.LegAge(1_762_640_000, 21_600, 88_200, true);
        (uint32 b, uint32 l) = m.ageLimits(legs, false);
        assertEq(b, 21_600, "borrow");
        assertEq(l, 21_600, "alternate: min(liquidation, borrow)");
        legs[0].onAlternate = false;
        (, l) = m.ageLimits(legs, false);
        assertEq(l, 88_200, "primary keeps its liquidation age");
        (b, l) = m.ageLimits(legs, true);
        assertEq(b, 0, "failed: 0");
        assertEq(l, 0, "failed: 0");
        (b, l) = m.ageLimits(new LPPriceMath.LegAge[](0), false);
        assertEq(b + l, 0, "no leg: 0");
    }

    // ─── SPEC-ORC-017 served collateral price ───

    // TEST-230 verifies: SPEC-ORC-017, REQ-ORACLE-020, REQ-ORACLE-085, REQ-ORACLE-086, INV-087, Q-247
    // Sources: SYM-133, MATH-UO-42d, MATH-UO-42h (Drifting serves the fresh price, not min(fresh, A))
    function test_TEST_230_servedPriceSpecExample() public view {
        uint256 a = 199_980_000;
        uint256 lower = 197_483_855;
        uint256 fresh = 199_999_600;
        assertEq(m.servedPrice(PriceState.Drifting, true, fresh, lower, a), lower, "disagreement: min(lower, fresh)");
        assertEq(m.servedPrice(PriceState.Cached, false, fresh, lower, a), a, "Cached");
        assertEq(m.servedPrice(PriceState.Expired, false, fresh, lower, a), 1, "Expired");
        assertEq(m.servedPrice(PriceState.Drifting, false, fresh, lower, a), fresh, "Drifting: fresh, above A");
        assertGt(fresh, a, "the spec example serves a Drifting price above A");
        assertEq(m.servedPrice(PriceState.Live, false, fresh, lower, a), fresh, "Live: fresh");
    }

    // TEST-230 verifies: SPEC-ORC-017, REQ-ORACLE-086, INV-087
    // Sources: SYM-191, MATH-UO-59c (full-range USDC/USDT, d = 6, compositions of SPEC-ORC-009 and SPEC-ORC-006)
    function test_TEST_230_disagreementNeverServedAboveFresh() public view {
        uint256 fresh = _price(_u2(999_173, 1_000_826), _u2(97_544_839, 97_383_701), _d2(6, 6));
        uint256 lower = _price(_u2(999_173, 1_000_827), _u2(97_544_839, 97_383_663), _d2(6, 6));
        assertEq(fresh, 194_928_113, "fresh at v");
        assertEq(lower, 194_928_172, "lower at w <= v is 59 units higher after the floors");
        assertEq(m.servedPrice(PriceState.Drifting, true, fresh, lower, 2e8), fresh, "min(lower, fresh) = fresh");
        assertEq(m.servedPrice(PriceState.Drifting, true, fresh, lower, 1), fresh, "A does not enter: still fresh");
    }

    // TEST-230 verifies: SPEC-ORC-017, REQ-ORACLE-060, REQ-ORACLE-086, INV-087
    function test_TEST_230_servedPricePrecedenceAndFloor() public view {
        assertEq(m.servedPrice(PriceState.Cached, true, 5, 3, 9), 9, "Cached over disagreement");
        assertEq(m.servedPrice(PriceState.Expired, true, 5, 3, 9), 1, "Expired over disagreement");
        assertEq(m.servedPrice(PriceState.Drifting, true, 5, 30, 9), 5, "min(lower, fresh): fresh binds");
        assertEq(m.servedPrice(PriceState.Drifting, true, 50, 30, 9), 30, "min(lower, fresh): lower binds, A ignored");
        assertEq(m.servedPrice(PriceState.Drifting, false, 50, 30, 9), 50, "Drifting: fresh, A ignored");
        assertEq(m.servedPrice(PriceState.Live, false, 50, 30, 9), 50, "Live: fresh, A ignored");
        assertEq(m.servedPrice(PriceState.Drifting, true, 50, 0, 9), 1, "floor 1 disagreement");
        assertEq(m.servedPrice(PriceState.Live, false, 0, 0, 0), 1, "floor 1 Live");
        assertEq(m.servedPrice(PriceState.Cached, false, 0, 0, 0), 1, "floor 1 Cached");
    }

    // ─── SPEC-ORC-018 served debt price ───

    // TEST-230 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087, Q-238
    // Sources: SYM-134, MATH-UO-43
    function test_TEST_230_debtServedPriceSpecExample() public view {
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_990_000, 500), 104_989_500, "delta 500");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_990_000, 200), 101_989_800, "delta 200");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_987_001, 500), 104_986_352, "rounds up");
        assertEq(
            m.debtServedPrice(PriceState.Drifting, 99_990_000, 99_990_000, 100_300_000, 99_995_000, 500),
            100_300_000,
            "disagreement: max(p, b, A)"
        );
        assertEq(m.debtServedPrice(PriceState.Cached, 1, 1, 1, 99_995_000, 500), 99_995_000, "Cached: A");
        assertEq(m.debtServedPrice(PriceState.Live, 99_990_000, 1, 1, 99_995_000, 500), 99_990_000, "Live: q");
        assertEq(m.debtServedPrice(PriceState.Live, 0, 0, 0, 0, 0), 1, "never 0");
        assertEq(10_000 * m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_990_000, 500), 1_049_895 * 1e6, "debt");
    }

    // TEST-230 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087
    // Sources: MATH-UO-65 (delta below 100 read as 100; saturation instead of a revert)
    function test_TEST_230_debtStressRiseFailsClosed() public view {
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_990_000, 0), 100_989_900, "delta 0 read as 100");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 99_990_000, 99), 100_989_900, "delta 99 read as 100");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, SAT, 500), SAT, "saturates");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 1, SAT), SAT, "huge delta saturates");
        assertEq(m.debtServedPrice(PriceState.Expired, 0, 0, 0, 1, 500), 2, "ceil(1.05) = 2 > A");
    }

    // ─── SPEC-ORC-021 sequencer gate ───

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099, Q-324
    // Sources: SYM-170, MATH-UO-55e
    function test_TEST_275_sequencerStatusBaseRestart() public view {
        bool up;
        bool down;
        bool unknown;
        bool grace;
        bool ready;
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 1, 0, 1_000_000, 3600);
        assertTrue(down && !up && !unknown && !grace && !ready, "down");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 1_010_000, 1_013_599, 3600);
        assertTrue(up && grace && !ready && !down && !unknown, "grace to 1,013,599");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 1_010_000, 1_013_600, 3600);
        assertTrue(up && ready && !grace && !down && !unknown, "ready from 1,013,600");
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099
    // Sources: MATH-UO-55c (an unreadable feed blocks borrowing only)
    function test_TEST_275_sequencerStatusUnknownAndNoFeed() public view {
        bool up;
        bool down;
        bool unknown;
        bool grace;
        bool ready;
        (up, down, unknown, grace, ready) = m.sequencerStatus(false, false, 7, 0, 1, 3600);
        assertTrue(ready && !up && !down && !unknown && !grace, "no feed: ready only");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, false, 0, 1, 1_000_000, 3600);
        assertTrue(unknown && !ready && !down, "revert or malformed");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 2, 1, 1_000_000, 3600);
        assertTrue(unknown && !ready && !down, "unexpected answer");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, -1, 1, 1_000_000, 3600);
        assertTrue(unknown && !ready && !down, "negative answer");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 0, 1_000_000, 3600);
        assertTrue(unknown && !up, "startedAt 0");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 1_000_001, 1_000_000, 3600);
        assertTrue(unknown && !up, "startedAt in the future");
        (up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 1_000_000, 1_000_000, 0);
        assertTrue(up && ready && !grace, "grace period 0");
    }

    // ─── SPEC-ORC-022 observation buffer, SPEC-ORC-023 gas guard ───

    // TEST-139 verifies: SPEC-ORC-022, REQ-ORACLE-055, REQ-ORACLE-105, Q-326
    // Sources: SYM-171, MATH-UO-56c, MATH-UO-66a
    function test_TEST_139_minObservationsPerChain() public view {
        assertEq(m.minObservations(1800, 12), 151, "Ethereum");
        assertEq(m.minObservations(1800, 2), 901, "Base");
        assertEq(m.minObservations(1801, 12), 152, "rounds up");
        assertEq(m.minObservations(0, 12), 1, "no window");
        assertEq(m.minObservations(1800, 0), SAT, "zero block time: an impossible requirement, no revert");
        assertEq(m.minObservations(SAT, 1), SAT, "saturates");
    }

    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-038, REQ-ORACLE-039, REQ-ORACLE-102, Q-328
    // Sources: SYM-172, MATH-UO-57d, MATH-UO-66b, MATH-UO-66d
    function test_TEST_042_gasGuardSpecExample() public view {
        uint256 need = m.gasForCall(50_000);
        assertEq(need, 55_794, "50,794 + 5,000");
        assertGe(need - need / 64, 50_000, "the call receives its full gas");
        assertEq(m.gasForCall(100_000), 101_588 + 5000, "pool read");
        assertEq(m.gasForCall(40_000), 40_635 + 5000, "config read");
        assertEq(m.pokeMinGasFloor(450_000, 100_000), 556_588, "floor = 450,000 + 101,588 + 5,000");
        assertEq(m.gasForCall(SAT / 64 + 1), SAT, "64 G above 256 bits: saturated");
        assertEq(m.pokeMinGasFloor(SAT, 1), SAT, "floor saturates");
    }

    // ─── Helpers ───

    function _price(
        uint256[] memory a,
        uint256[] memory v,
        uint8[] memory d
    ) internal view returns (uint256 price8) {
        bool valid;
        (valid, price8) = m.lpPrice(a, v, d);
        assertTrue(valid, "valid composition");
    }

    function _assertInvalid(
        uint256[] memory a,
        uint256[] memory v,
        uint8[] memory d,
        string memory why
    ) internal view {
        (bool valid, uint256 price8) = m.lpPrice(a, v, d);
        assertFalse(valid, why);
        assertEq(price8, 0, why);
    }

    function _band(
        uint256[] memory q,
        uint256[] memory v,
        uint256 low,
        uint256 high
    ) internal view returns (bool inBand) {
        bool valid;
        (valid, inBand) = m.inUsdBand(q, v, low, high);
        assertTrue(valid, "valid band input");
    }

    function _assertBandInvalid(
        uint256[] memory q,
        uint256[] memory v,
        string memory why
    ) internal view {
        (bool valid, bool inBand) = m.inUsdBand(q, v, 0, SAT);
        assertFalse(valid, why);
        assertFalse(inBand, why);
    }

    function _u2(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }

    function _filled(
        uint256 n,
        uint256 x
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = x;
        }
    }

    function _u3(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        (out[0], out[1], out[2]) = (a, b, c);
    }

    function _d2(
        uint8 a,
        uint8 b
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        (out[0], out[1]) = (a, b);
    }
}
