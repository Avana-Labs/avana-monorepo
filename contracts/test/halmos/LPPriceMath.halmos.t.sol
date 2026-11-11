// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPPriceMathHalmosTest
/// @notice Symbolic checks of the LPPriceMath properties 5.2 assigns to Halmos: the price of one whole vault token is
/// at least 1 and never above the exact value of the holdings at the oracle prices, and its products fit 256 bits
/// (`PROP-023`); the stable ceiling never raises a price and is monotone, and the valuation does not depend on token
/// order (`PROP-024`); the agreement check is the exact cross-multiplied rule, symmetric, and false outside
/// `[1, MAX_ROUTE_ANSWER]` (`PROP-026`).
/// @dev The library is compiled into this contract. Amounts are below `2^128` (a composition of `10^d <= 10^18` units),
/// prices at most `MAX_ROUTE_ANSWER = 10^12` (normalised answers inside the listing bounds), tolerances `uint16`.
/// Token decimals are concrete per check (6/6, 18/6 and 18/18 cover the launch pairs), so every division is by a
/// constant power of ten.
contract LPPriceMathHalmosTest is Test {
    uint256 internal constant MAX_ROUTE = 1e12;

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    // Sources: MATH-UO-14, MATH-UO-16, MATH-UO-51a, AMM-A3f
    function check_PROP_023_price8PositiveAndBelowExact_6_6(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8PositiveAndBelowExact(a0, a1, v0, v1, 6, 6);
    }

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    function check_PROP_023_price8PositiveAndBelowExact_18_6(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8PositiveAndBelowExact(a0, a1, v0, v1, 18, 6);
    }

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    function check_PROP_023_price8PositiveAndBelowExact_18_18(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8PositiveAndBelowExact(a0, a1, v0, v1, 18, 18);
    }

    // PROP-024 verifies: SPEC-ORC-004, REQ-ORACLE-009, Q-177
    // Sources: MATH-UO-19a, MATH-UO-19b, MATH-UO-19c
    function check_PROP_024_stableCeilingNeverRaisesAndIsMonotone(
        uint256 q1,
        uint256 q2,
        bool stable
    ) public pure {
        vm.assume(q1 <= q2);
        uint256 c1 = LPPriceMath.valuationPrice(q1, stable);
        uint256 c2 = LPPriceMath.valuationPrice(q2, stable);
        assert(c1 <= q1);
        assert(c1 <= c2);
        if (stable) assert(c2 <= LPPriceMath.STABLE_CEILING_USD);
        if (!stable || q1 <= LPPriceMath.STABLE_CEILING_USD) assert(c1 == q1);
    }

    // PROP-024 verifies: SPEC-ORC-008, REQ-ORACLE-013, Q-177
    // Sources: MATH-UO-18
    function check_PROP_024_valuationSymmetricInTokenOrder(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        vm.assume(v0 <= MAX_ROUTE && v1 <= MAX_ROUTE);
        vm.assume(v0 >= 1 && v1 >= 1);
        (bool okF, uint256 forward) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(18, 6));
        (bool okR, uint256 reverse) = LPPriceMath.lpPrice(_pair(a1, a0), _pair(v1, v0), _decimals(6, 18));
        assert(okF && okR);
        assert(forward == reverse);
    }

    // PROP-026 verifies: SPEC-ORC-003, SPEC-ORC-020, REQ-ORACLE-008, ATTACK-054, Q-184
    // Sources: MATH-UO-24b, MATH-UO-24c, MATH-UO-54a
    function check_PROP_026_agreementCheckIsExactAndSymmetric(
        uint128 p,
        uint128 b,
        uint16 t
    ) public pure {
        bool agreePB = LPPriceMath.routesAgree(p, b, t);
        bool agreeBP = LPPriceMath.routesAgree(b, p, t);
        assert(agreePB == agreeBP);
        uint256 diff = p > b ? uint256(p) - b : uint256(b) - p;
        uint256 lo = p < b ? p : b;
        bool inBounds = p >= 1 && b >= 1 && p <= MAX_ROUTE && b <= MAX_ROUTE;
        assert(agreePB == (inBounds && diff * 10_000 <= uint256(t) * lo));
        assert(LPPriceMath.secondSourceAgrees(true, p, b, t) == agreePB);
        assert(!LPPriceMath.secondSourceAgrees(false, p, b, t));
    }

    /// @dev With `E = a0 * v0 / 10^d0 + a1 * v1 / 10^d1` the exact value of the holdings: `1 <= price8`,
    /// `price8 <= E` whenever `E >= 1` (else `price8 == 1`), every product below `2^256` and `price8 < 2^255`.
    function _price8PositiveAndBelowExact(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1,
        uint8 d0,
        uint8 d1
    ) internal pure {
        vm.assume(v0 >= 1 && v0 <= MAX_ROUTE && v1 >= 1 && v1 <= MAX_ROUTE);
        (bool valid, uint256 price8) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(d0, d1));
        assert(valid);
        assert(price8 >= 1);
        assert(price8 < 2 ** 255);
        // Exact value scaled by 10^(d0 + d1): fits 256 bits for amounts below 2^128, prices <= 10^12 and d <= 18.
        uint256 exactScaled = uint256(a0) * v0 * 10 ** d1 + uint256(a1) * v1 * 10 ** d0;
        uint256 one = 10 ** (uint256(d0) + d1);
        if (exactScaled >= one) assert(price8 * one <= exactScaled);
        else assert(price8 == 1);
    }

    function _pair(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (x, y);
    }

    function _decimals(
        uint8 x,
        uint8 y
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        (out[0], out[1]) = (x, y);
    }
}
