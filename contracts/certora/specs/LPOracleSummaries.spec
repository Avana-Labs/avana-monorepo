/*
 * The library summaries of LPOracle.spec and LiquidationModule.spec, proved against the library bytecode through
 * LPOracleSummariesHarness (test/utils/harness/LPOracleSummariesHarness.sol). No summaries here: each rule runs the
 * real code.
 *
 *   ozMulDivIsFloor        OpenZeppelin Math.mulDiv(x, y, den) returns floor(x * y / den) whenever den > 0 and that
 *                          quotient is a word, and reverts exactly when it is not
 *   fullMathMulDivIsFloor  the same for Uniswap v4-core FullMath.mulDiv
 *   ozSqrtIsFloorSqrt      OpenZeppelin Math.sqrt(a) is the integer square root: r * r <= a < (r + 1) * (r + 1)
 *
 * Why the split. As single rules the two mulDiv claims failed on counterexamples the Prover itself flagged as
 * "Imprecision detected" in the 512-bit code's bitwise operations (`BWXOr(2, 9) = 11, but is 0` in OpenZeppelin's
 * modular inverse, a `BWAnd` in FullMath's). Those operations are exact only under `precise_bitwise_ops`, which in
 * turn bounds every CVL integer to a word, so the 512-bit claim cannot be stated there directly. The claim is
 * therefore proved in two modes, all in this spec:
 *
 *   word mode (LPOracleSummariesPrecise.conf, precise_bitwise_ops), every term a word with no overflow:
 *     ozMulDivLimbs, fullMathMulDivLimbs   mulDiv reverts exactly when den == 0 or hi >= den, where (hi, lo) are the
 *                                          limbs of x * y; otherwise, with (rh, rl) the limbs of r * den and
 *                                          rem = mulmod(x, y, den), rem < den and (rh, rl) + rem == (hi, lo)
 *   integer mode (LPOracleSummaries.conf):
 *     mul512IsProduct                      the harness limbs are the product: hi * 2^256 + lo == x * y
 *     floorFromRemainder, floorDivAtLeast  one-step floor-division lemmas over fresh integers
 *     ozMulDivIsFloor, fullMathMulDivIsFloor
 *                                          require the rules above at their own terms (named on each line) and
 *                                          assert the claim, linear in the named terms
 *
 * The word-mode asserts use no operation that wraps, so they mean the same integer facts in both modes.
 *
 * Math.sqrt (no bitwise operations) timed out as one rule. It is split by the input's size, which fixes the branches of
 * the initial estimate, and into its two bounds: ozSqrtLowerBound* (r * r <= a) and ozSqrtUpperBound* (a < (r + 1)^2)
 * for a < 2^64, [2^64, 2^128), [2^128, 2^192) and [2^192, 2^256); ozSqrtIsFloorSqrt requires the eight.
 */

definition W() returns mathint = 2^256;

// (rh, rl) + rem == (hi, lo) as 512-bit numbers, written without any operation that wraps a word.
definition limbsAddUp(mathint rh, mathint rl, mathint rem, mathint hi, mathint lo) returns bool =
    rl <= max_uint256 - rem
        ? (rl + rem == lo && rh == hi)
        : (rl - (max_uint256 - rem) - 1 == lo && rh < max_uint256 && rh + 1 == hi);

// ---------------------------------------------------------------------------------------------------------------------
// Word mode (LPOracleSummariesPrecise.conf)
// ---------------------------------------------------------------------------------------------------------------------

rule ozMulDivLimbs(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    uint256 r = ozMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);
    assert reverted <=> (den == 0 || hi >= den), "mulDiv reverts other than on a zero denominator or an overflow";
    assert !reverted => (rem < den && limbsAddUp(rh, rl, rem, hi, lo)), "r * den + x * y mod den is not x * y";
}

rule fullMathMulDivLimbs(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    uint256 r = fullMathMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);
    assert reverted <=> (den == 0 || hi >= den), "mulDiv reverts other than on a zero denominator or an overflow";
    assert !reverted => (rem < den && limbsAddUp(rh, rl, rem, hi, lo)), "r * den + x * y mod den is not x * y";
}

// ---------------------------------------------------------------------------------------------------------------------
// Integer mode (LPOracleSummaries.conf): lemmas
// ---------------------------------------------------------------------------------------------------------------------

rule mul512IsProduct(uint256 x, uint256 y) {
    env e;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    assert hi * W() + lo == x * y, "the limbs are not the product";
}

rule floorFromRemainder(mathint n, mathint d, mathint q, mathint rem) {
    require d > 0 && 0 <= rem && rem < d && q * d + rem == n;
    assert q == n / d, "q is not floor(n / d)";
}

rule floorDivAtLeast(mathint n, mathint q, mathint t) {
    require n >= 0 && q > 0 && n >= t * q;
    assert n / q >= t, "floor(n / q) is below t although n >= t * q";
}

// ---------------------------------------------------------------------------------------------------------------------
// Integer mode: the mulDiv summaries
// ---------------------------------------------------------------------------------------------------------------------

rule ozMulDivIsFloor(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    mathint q = den > 0 ? (x * y) / den : 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    uint256 r = ozMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);

    // ozMulDivLimbs
    require reverted <=> (den == 0 || hi >= den);
    require !reverted => (rem < den && limbsAddUp(rh, rl, rem, hi, lo));
    // mul512IsProduct at (x, y) and at (r, den)
    require hi * W() + lo == x * y;
    require rh * W() + rl == r * den;
    // floorDivAtLeast(n = x * y, q = den, t = 2^256): a quotient past a word means hi >= den
    require (x * y >= 0 && den > 0 && x * y >= W() * den) => (x * y) / den >= W();
    // floorFromRemainder(n = x * y, d = den, q = r, rem)
    require (den > 0 && 0 <= rem && rem < den && r * den + rem == x * y) => r == (x * y) / den;

    assert (den > 0 && q <= max_uint256) => (!reverted && to_mathint(r) == q), "mulDiv is not floor(x * y / den)";
}

rule fullMathMulDivIsFloor(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    mathint q = den > 0 ? (x * y) / den : 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    uint256 r = fullMathMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);

    // fullMathMulDivLimbs
    require reverted <=> (den == 0 || hi >= den);
    require !reverted => (rem < den && limbsAddUp(rh, rl, rem, hi, lo));
    // mul512IsProduct at (x, y) and at (r, den)
    require hi * W() + lo == x * y;
    require rh * W() + rl == r * den;
    // floorDivAtLeast(n = x * y, q = den, t = 2^256)
    require (x * y >= 0 && den > 0 && x * y >= W() * den) => (x * y) / den >= W();
    // floorFromRemainder(n = x * y, d = den, q = r, rem)
    require (den > 0 && 0 <= rem && rem < den && r * den + rem == x * y) => r == (x * y) / den;

    assert (den > 0 && q <= max_uint256) => (!reverted && to_mathint(r) == q), "mulDiv is not floor(x * y / den)";
}

// ---------------------------------------------------------------------------------------------------------------------
// Integer mode: Math.sqrt, by input size and by bound
// ---------------------------------------------------------------------------------------------------------------------

definition inBand(mathint a, mathint lowExp, mathint highExp) returns bool = 2^lowExp <= a && a < 2^highExp;

rule ozSqrtLowerBound64(uint256 a) {
    env e;
    require to_mathint(a) < 2^64;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtLowerBound128(uint256 a) {
    env e;
    require inBand(a, 64, 128);
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtLowerBound192(uint256 a) {
    env e;
    require inBand(a, 128, 192);
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtLowerBound256(uint256 a) {
    env e;
    require to_mathint(a) >= 2^192;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound64(uint256 a) {
    env e;
    require to_mathint(a) < 2^64;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtUpperBound128(uint256 a) {
    env e;
    require inBand(a, 64, 128);
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtUpperBound192(uint256 a) {
    env e;
    require inBand(a, 128, 192);
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtUpperBound256(uint256 a) {
    env e;
    require to_mathint(a) >= 2^192;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtIsFloorSqrt(uint256 a) {
    env e;
    mathint r = ozSqrt(e, a);
    // ozSqrtLowerBound64/128/192/256 and ozSqrtUpperBound64/128/192/256, each on its band of a
    require to_mathint(a) < 2^64 => (r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1));
    require inBand(a, 64, 128) => (r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1));
    require inBand(a, 128, 192) => (r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1));
    require to_mathint(a) >= 2^192 => (r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1));
    assert r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1), "sqrt is not the integer square root";
}
