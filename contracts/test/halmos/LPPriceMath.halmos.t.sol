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
/// prices at most `MAX_ROUTE_ANSWER = 10^18` (normalised answers inside the listing bounds), tolerances `uint16`.
/// Token decimals are concrete per check (6/6, 18/6 and 18/18 cover the example pairs), so every division is by a
/// constant power of ten. The `PROP-023` and `PROP-024` valuation checks prove that `lpPrice` returns a reference
/// formula whose products are the code's own; MATH-UO-79 proves the price bounds on that formula.
contract LPPriceMathHalmosTest is Test {
    uint256 internal constant MAX_ROUTE = 1e18;

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    // Sources: MATH-UO-14, MATH-UO-16, MATH-UO-51a, AMM-A3f, MATH-UO-79
    /// @notice `lpPrice` of two 6-decimal tokens returns `valid` and the reference formula `R` of `_price8Formula`.
    /// @dev Proved in two parts (see `_price8IsTheFormula`); the decimals pairs 6/6, 18/6 and 18/18 are the three pairs
    /// the check made before the split.
    function check_PROP_023_price8PositiveAndBelowExact_6_6Formula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8IsTheFormula(a0, a1, v0, v1, 6, 6);
    }

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    /// @notice `check_PROP_023_price8PositiveAndBelowExact_6_6Formula` with token0 at 18 and token1 at 6 decimals.
    function check_PROP_023_price8PositiveAndBelowExact_18_6Formula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8IsTheFormula(a0, a1, v0, v1, 18, 6);
    }

    // PROP-023 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055, Q-191
    /// @notice `check_PROP_023_price8PositiveAndBelowExact_6_6Formula` with both tokens at 18 decimals.
    function check_PROP_023_price8PositiveAndBelowExact_18_18Formula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        _price8IsTheFormula(a0, a1, v0, v1, 18, 18);
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
    // Sources: MATH-UO-18, MATH-UO-79
    /// @notice The valuation does not depend on token order: `lpPrice` of a pair at 18 and 6 decimals and of the same
    /// pair listed the other way round both return `R`, the sum of the same two floored terms, for every amount below
    /// `2^128` and every price in `[1, MAX_ROUTE_ANSWER]`.
    /// @dev The two calls of the check before the split, with the assumptions of `_price8Formula` made first. That
    /// form ran out of its 5-hour budget (run 43677588077) with no counterexample, with the 512-bit branch of
    /// `Math.mulDiv` open on every term (a product of two symbolic values). The assumptions rule that branch out, and
    /// both results then equal `R` term by term (MATH-UO-79). `R` is computed once, so `forward == reverse` follows.
    function check_PROP_024_valuationSymmetricInTokenOrderFormula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1
    ) public pure {
        vm.assume(v0 >= 1 && v0 <= MAX_ROUTE && v1 >= 1 && v1 <= MAX_ROUTE);
        uint256 ref = _price8Formula(a0, a1, v0, v1, 18, 6);
        (bool okF, uint256 forward) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(18, 6));
        (bool okR, uint256 reverse) = LPPriceMath.lpPrice(_pair(a1, a0), _pair(v1, v0), _decimals(6, 18));
        assert(okF && okR);
        assert(forward == ref);
        assert(reverse == ref);
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

    /// @dev Proved in two parts. This check: for every `a0, a1 < 2^128` and `v0, v1` in `[1, MAX_ROUTE_ANSWER]`,
    /// `lpPrice` returns `valid` and `R = max(1, Σ_i [a_i > 1] ⌊(a_i − 1) v_i / 10^(d_i)⌋)`, with the products and
    /// quotients of `_price8Formula`. MATH-UO-79 (`docs/spec/05-verification/z3/units-oracle/uo20_halmos_references.py`)
    /// proves, over the same inputs, `1 <= R < 2^255`, and with `E = a0 v0 10^(d1) + a1 v1 10^(d0)` (the exact value of
    /// the holdings scaled by `10^(d0 + d1)`, each product below `2^248`) `R × 10^(d0 + d1) <= E` when
    /// `E >= 10^(d0 + d1)` and `R = 1` below it: the assertions this check made before the split. That form compared the
    /// code's `(a − 1) × v` with the test's `a × v`, two products of symbolic values, and ran out of its 5-hour budget
    /// (run 43677588077). Here the code and `R` divide the same product, so no query needs the product's bits.
    function _price8IsTheFormula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1,
        uint8 d0,
        uint8 d1
    ) internal pure {
        vm.assume(v0 >= 1 && v0 <= MAX_ROUTE && v1 >= 1 && v1 <= MAX_ROUTE);
        uint256 ref = _price8Formula(a0, a1, v0, v1, d0, d1);
        (bool valid, uint256 price8) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(d0, d1));
        assert(valid);
        assert(price8 >= 1);
        assert(price8 == ref);
    }

    /// @dev `R = max(1, Σ_i [a_i > 1] ⌊(a_i − 1) v_i / 10^(d_i)⌋)`, the shape `lpPrice` computes when every
    /// `Math.mulDiv` takes its 256-bit branch. The sum is unchecked: each term is below `2^188`, so it cannot wrap
    /// (MATH-UO-79b). Called before `lpPrice`, so the assumptions of `_floorTerm` are on the path when the code branches.
    function _price8Formula(
        uint128 a0,
        uint128 a1,
        uint256 v0,
        uint256 v1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256 r) {
        unchecked {
            if (a0 > 1) r += _floorTerm(uint256(a0) - 1, v0, 10 ** d0);
            if (a1 > 1) r += _floorTerm(uint256(a1) - 1, v1, 10 ** d1);
        }
        if (r == 0) r = 1;
    }

    /// @dev `⌊x y / s⌋` for `x < 2^128`, `y <= 10^18` and `s` a power of ten, after `_assumeExactProduct(x, y)`.
    function _floorTerm(
        uint256 x,
        uint256 y,
        uint256 s
    ) internal pure returns (uint256) {
        _assumeExactProduct(x, y);
        unchecked {
            return x * y / s;
        }
    }

    /// @dev Assumes `mulmod(x, y, 2^256 - 1) == x * y` (and `== y * x`). The caller passes `x < 2^128` and
    /// `y <= 10^18`, so `x * y < 2^188` and both sides are the exact product (MATH-UO-79a): the assumption removes no
    /// input. It states, without a multiplication, the fact `Math.mulDiv` tests first: the high word of the 512-bit
    /// product is 0. The solver then rules out the 512-bit branch of `mulDiv` from this equality alone. Both operand
    /// orders are given because the optimizer may emit either order for the code's `x * y`.
    function _assumeExactProduct(
        uint256 x,
        uint256 y
    ) internal pure {
        unchecked {
            vm.assume(mulmod(x, y, type(uint256).max) == x * y);
            vm.assume(mulmod(x, y, type(uint256).max) == y * x);
        }
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
