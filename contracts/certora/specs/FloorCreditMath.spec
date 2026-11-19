/*
 * FloorCreditMath (src/custody/lp-vault/libraries/FloorCreditMath.sol, proof in
 * docs/spec/04-security/05-floor-credit-proof.md), through FloorCreditMathHarness
 * (test/utils/harness/FloorCreditMathHarness.sol), which wraps the internal `credit` in an external function.
 *
 * Notation: `x, y` are the position's and `X, Y` the band's square-root prices (any integers with
 * 0 < X <= x < y <= Y; the library takes them in Q64.96), `L >= 0` the liquidity, `d = y - x`, `D = Y - X`,
 * `Q = 2^96`, `U = 2^128 - 1`, `r1 = d / D` and `r0 = d * X * Y / (D * x * y)`. The library's credit is
 *
 *   a0 = floor(L * Q * d / (x * y))      u0 = ceil(U * Q * D / (X * Y))      side0 = floor(a0 * U / u0)
 *   a1 = floor(L * d / Q)                u1 = ceil(U * D / Q)                side1 = floor(a1 * U / u1)
 *   credit = min(side0, side1)
 *
 * (Uniswap v4-core SqrtPriceMath amounts of the position, rounded down, and of U band units, rounded up). That the
 * bytecode returns this value is the Halmos check `check_creditMatchesReference` (test/halmos/FloorCreditMath.halmos.t.sol).
 *
 * The rules below are over unbounded CVL integers, so they hold for every band and position:
 *
 *   creditAtMostToken1Ratio, creditAtMostToken0Ratio   credit <= L * r1 and credit <= L * r0: the position covers its
 *                                                      credit at the upper and the lower band edge (and beyond them)
 *   creditMonotoneInLiquidity                          the credit is non-decreasing in L
 *   creditValueCovered{Below,Inside,Above}Position     every credit c with 0 <= c, c <= L * r1 and c <= L * r0 (so the
 *                                                      library's, by the two edge rules) is worth at most the position
 *                                                      at every price s in the band: c * V_band(s) <= L * V_position(s)
 *
 * With V(s) the value in token1 of one unit of liquidity at square-root price s, inside the band
 * V_band(s) = (2 * s * Y - X * Y - s^2) / Y, and V_position(s) is s^2 * d / (x * y) below the position,
 * (2 * s * y - x * y - s^2) / y inside it and d above it; each rule clears the denominators.
 *
 * The `assert` lines before each rule's last one are proof steps: each holds, and the prover takes each as known
 * when it checks the next, so every step is a single product monotonicity or polynomial identity.
 *
 * One rule calls the harness: `credit` reverts for a position outside its band.
 */

definition Q() returns mathint = 2^96;
definition U() returns mathint = 2^128 - 1;

// Numerators of V_band(s) * Y and V_position(s) * y while the position is in range.
definition bandNum(mathint s, mathint X, mathint Y) returns mathint = 2 * s * Y - X * Y - s * s;
definition posNum(mathint s, mathint x, mathint y) returns mathint = 2 * s * y - x * y - s * s;

function requireShape(mathint L, mathint x, mathint y, mathint X, mathint Y) {
    require 0 < X && X <= x && x < y && y <= Y;
    require L >= 0;
}

// The band unit's amounts, rounded up, and their defining bounds.
function unit0(mathint X, mathint Y) returns mathint {
    return (U() * Q() * (Y - X) + X * Y - 1) / (X * Y);
}

function unit1(mathint X, mathint Y) returns mathint {
    return (U() * (Y - X) + Q() - 1) / Q();
}

// A credit at most L * r1 and L * r0: what creditAtMostToken1Ratio and creditAtMostToken0Ratio prove of the library's.
function requireEdgeBounds(mathint c, mathint L, mathint x, mathint y, mathint X, mathint Y) {
    require c >= 0;
    require c * (Y - X) <= L * (y - x);
    require c * (Y - X) * x * y <= L * (y - x) * X * Y;
}

// For X <= s <= Y: 0 <= bandNum(s) <= D * Y (V_band(s) <= D) and X * bandNum(s) <= s^2 * D (V_band(s) <= s^2 * (1/X - 1/Y)).
function assertBandValueBounds(mathint s, mathint X, mathint Y) {
    mathint b = bandNum(s, X, Y);
    assert b == (s - X) * (Y - s) + s * (Y - X);
    assert b >= 0;
    assert (Y - X) * Y - b == (Y - s) * (Y - s);
    assert b <= (Y - X) * Y;
    assert s * s * (Y - X) - X * b == Y * (s - X) * (s - X);
    assert X * b <= s * s * (Y - X);
}

// X <= s <= x: c * bandNum(s) * x * y <= L * s^2 * d * Y.
function assertCoveredBelow(mathint c, mathint L, mathint s, mathint x, mathint y, mathint X, mathint Y) {
    mathint b = bandNum(s, X, Y);
    mathint d = y - x;
    mathint D = Y - X;
    assertBandValueBounds(s, X, Y);
    assert c * D * x * y * b <= L * d * X * Y * b;
    assert L * d * Y * (X * b) <= L * d * Y * (s * s * D);
    assert c * x * y * b * D <= L * d * Y * s * s * D;
    assert c * x * y * b <= L * d * Y * s * s;
}

// y <= s <= Y: c * bandNum(s) <= L * d * Y.
function assertCoveredAbove(mathint c, mathint L, mathint s, mathint x, mathint y, mathint X, mathint Y) {
    mathint b = bandNum(s, X, Y);
    mathint D = Y - X;
    assertBandValueBounds(s, X, Y);
    assert c * b <= c * D * Y;
    assert c * D * Y <= L * (y - x) * Y;
    assert c * b <= L * (y - x) * Y;
}

// ---------------------------------------------------------------------------------------------------------------------
// Band edges
// ---------------------------------------------------------------------------------------------------------------------

// At or above the upper band edge both hold only token1, the value ratio is r1, and credit <= side1 <= L * r1.
rule creditAtMostToken1Ratio(mathint L, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L, x, y, X, Y);
    mathint d = y - x;
    mathint D = Y - X;
    mathint a1 = L * d / Q();
    mathint u1 = unit1(X, Y);
    mathint side1 = a1 * U() / u1;

    assert a1 >= 0 && u1 > 0 && side1 >= 0;
    assert a1 * Q() <= L * d;
    assert u1 * Q() >= U() * D;
    assert side1 * u1 <= a1 * U();
    assert side1 * U() * D <= side1 * u1 * Q();
    assert side1 * u1 * Q() <= a1 * U() * Q();
    assert a1 * U() * Q() <= L * d * U();
    assert side1 * U() * D <= L * d * U();
    assert side1 * D <= L * d, "the token1 side exceeds L * r1";
}

// At or below the lower band edge both hold only token0, the value ratio is r0, and credit <= side0 <= L * r0.
rule creditAtMostToken0Ratio(mathint L, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L, x, y, X, Y);
    mathint d = y - x;
    mathint D = Y - X;
    mathint a0 = L * Q() * d / (x * y);
    mathint u0 = unit0(X, Y);
    mathint side0 = a0 * U() / u0;

    assert a0 >= 0 && u0 > 0 && side0 >= 0;
    assert a0 * x * y <= L * Q() * d;
    assert u0 * X * Y >= U() * Q() * D;
    assert side0 * u0 <= a0 * U();
    assert side0 * U() * Q() * D <= side0 * u0 * X * Y;
    assert side0 * U() * Q() * D * x * y <= side0 * u0 * X * Y * x * y;
    assert side0 * u0 * X * Y * x * y <= a0 * U() * X * Y * x * y;
    assert a0 * x * y * U() * X * Y <= L * Q() * d * U() * X * Y;
    assert side0 * U() * Q() * D * x * y <= L * Q() * d * U() * X * Y;
    assert side0 * D * x * y <= L * d * X * Y, "the token0 side exceeds L * r0";
}

// ---------------------------------------------------------------------------------------------------------------------
// Monotone in L
// ---------------------------------------------------------------------------------------------------------------------

// floor(n1 / q) <= floor(n2 / q) when 0 <= n1 <= n2 and q > 0.
function assertFloorMonotone(mathint n1, mathint n2, mathint q) {
    mathint f1 = n1 / q;
    mathint f2 = n2 / q;
    assert f1 * q <= n1 && n1 <= n2 && n2 < (f2 + 1) * q;
    assert f1 * q < (f2 + 1) * q;
    assert f1 <= f2;
}

rule creditMonotoneInLiquidity(mathint L1, mathint L2, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L1, x, y, X, Y);
    require L1 <= L2;
    mathint d = y - x;
    mathint u0 = unit0(X, Y);
    mathint u1 = unit1(X, Y);
    assert u0 > 0 && u1 > 0;

    assert L1 * Q() * d <= L2 * Q() * d;
    assertFloorMonotone(L1 * Q() * d, L2 * Q() * d, x * y);
    mathint a01 = L1 * Q() * d / (x * y);
    mathint a02 = L2 * Q() * d / (x * y);
    assert a01 * U() <= a02 * U();
    assertFloorMonotone(a01 * U(), a02 * U(), u0);

    assert L1 * d <= L2 * d;
    assertFloorMonotone(L1 * d, L2 * d, Q());
    mathint a11 = L1 * d / Q();
    mathint a12 = L2 * d / Q();
    assert a11 * U() <= a12 * U();
    assertFloorMonotone(a11 * U(), a12 * U(), u1);

    mathint s01 = a01 * U() / u0;
    mathint s02 = a02 * U() / u0;
    mathint s11 = a11 * U() / u1;
    mathint s12 = a12 * U() / u1;
    mathint c1 = s01 < s11 ? s01 : s11;
    mathint c2 = s02 < s12 ? s02 : s12;
    assert c1 <= c2, "more liquidity earned less credit";
}

// ---------------------------------------------------------------------------------------------------------------------
// Value at every price in the band
// ---------------------------------------------------------------------------------------------------------------------

// X <= s <= x: the position holds only token0.
rule creditValueCoveredBelowPosition(mathint c, mathint L, mathint s, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L, x, y, X, Y);
    requireEdgeBounds(c, L, x, y, X, Y);
    require X <= s && s <= x;
    assertCoveredBelow(c, L, s, x, y, X, Y);
    assert c * bandNum(s, X, Y) * x * y <= L * s * s * (y - x) * Y, "the credit is worth more than the position";
}

// y <= s <= Y: the position holds only token1.
rule creditValueCoveredAbovePosition(mathint c, mathint L, mathint s, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L, x, y, X, Y);
    requireEdgeBounds(c, L, x, y, X, Y);
    require y <= s && s <= Y;
    assertCoveredAbove(c, L, s, x, y, X, Y);
    assert c * bandNum(s, X, Y) <= L * (y - x) * Y, "the credit is worth more than the position";
}

// x < s < y: f(s) = L * posNum(s) * Y - c * bandNum(s) * y is a quadratic in s with leading coefficient c * y - L * Y <= 0,
// non-negative at s = x and s = y (the two rules above at those prices), so non-negative between them:
// f(s) * (y - x) = (y - s) * f(x) + (s - x) * f(y) - lead * (s - x) * (y - s) * (y - x).
rule creditValueCoveredInsidePosition(mathint c, mathint L, mathint s, mathint x, mathint y, mathint X, mathint Y) {
    requireShape(L, x, y, X, Y);
    requireEdgeBounds(c, L, x, y, X, Y);
    require x < s && s < y;
    mathint d = y - x;
    mathint D = Y - X;

    // f(x) >= 0
    assertCoveredBelow(c, L, x, x, y, X, Y);
    assert posNum(x, x, y) == x * d;
    assert c * bandNum(x, X, Y) * y * x <= L * x * d * Y * x;
    assert c * bandNum(x, X, Y) * y <= L * x * d * Y;
    mathint fx = L * posNum(x, x, y) * Y - c * bandNum(x, X, Y) * y;
    assert fx >= 0;

    // f(y) >= 0
    assertCoveredAbove(c, L, y, x, y, X, Y);
    assert posNum(y, x, y) == y * d;
    mathint fy = L * posNum(y, x, y) * Y - c * bandNum(y, X, Y) * y;
    assert fy >= 0;

    // leading coefficient <= 0: c <= L since c * D <= L * d <= L * D
    assert L * d <= L * D;
    assert c * D <= L * D;
    assert c <= L;
    assert c * y <= L * y && L * y <= L * Y;
    mathint lead = c * y - L * Y;
    assert lead <= 0;

    mathint fs = L * posNum(s, x, y) * Y - c * bandNum(s, X, Y) * y;
    assert fs * d == (y - s) * fx + (s - x) * fy - lead * (s - x) * (y - s) * d;
    assert (y - s) * fx >= 0 && (s - x) * fy >= 0;
    assert (s - x) * (y - s) * d > 0;
    assert lead * (s - x) * (y - s) * d <= 0;
    assert fs * d >= 0;
    assert fs >= 0;
    assert c * bandNum(s, X, Y) * y <= L * posNum(s, x, y) * Y, "the credit is worth more than the position";
}

// ---------------------------------------------------------------------------------------------------------------------
// Domain (the harness, on the library's bytecode)
// ---------------------------------------------------------------------------------------------------------------------

rule creditRevertsOutsideTheBand(int24 a, int24 b, int24 bandA, int24 bandB, uint128 L) {
    env e;
    credit@withrevert(e, a, b, bandA, bandB, L);
    bool reverted = lastReverted;
    assert !(bandA <= a && a < b && b <= bandB) => reverted, "a position outside its band got a credit";
}
