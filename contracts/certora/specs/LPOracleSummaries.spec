/*
 * The library summaries of LPOracle.spec and LiquidationModule.spec, proved against the library bytecode through
 * LPOracleSummariesHarness (test/utils/harness/LPOracleSummariesHarness.sol). No summaries here: each rule runs the
 * real code.
 *
 *   ozMulDivIsFloor        OpenZeppelin Math.mulDiv(x, y, den) returns floor(x * y / den) whenever den > 0 and that
 *                          quotient is a word, and reverts exactly when it is not
 *   fullMathMulDivIsFloor  the same for Uniswap v4-core FullMath.mulDiv
 *   ozSqrtLowerBound<k>,   OpenZeppelin Math.sqrt(a) is the integer square root, r * r <= a < (r + 1) * (r + 1), on
 *   ozSqrtUpperBound<k>    each band 2^(k-32) <= a < 2^k (k = 32, 64, ..., 256; the first band starts at 0). The eight
 *                          bands cover every word, so together they are the Math.sqrt summary.
 *
 * mulDiv in two modes. As single rules the two mulDiv claims failed on counterexamples the Prover flagged as
 * "Imprecision detected" in the 512-bit code's bitwise operations. Those are exact only under `precise_bitwise_ops`,
 * which bounds every CVL integer to a word, so the 512-bit claim is split:
 *
 *   word mode (LPOracleSummariesPrecise.conf), no operation that wraps a word:
 *     ozMulDivReverts, fullMathMulDivReverts      mulDiv reverts exactly when den == 0 or hi >= den, with (hi, lo) the
 *                                                 limbs of x * y
 *     ozMulDivRemainder, fullMathMulDivRemainder  otherwise, with (rh, rl) the limbs of r * den and
 *                                                 rem = mulmod(x, y, den): rem < den and (rh, rl) + rem == (hi, lo)
 *   integer mode (LPOracleSummaries.conf):
 *     mul512IsProduct                      the harness limbs are the product: hi * 2^256 + lo == x * y
 *     floorFromRemainder, floorDivAtLeast  one-step floor-division lemmas over fresh integers
 *     ozMulDivIsFloor, fullMathMulDivIsFloor
 *                                          require the rules above at their own terms (named on each line) and
 *                                          assert the claim, linear in the named terms
 *
 * A reverted mulDiv call returns no word, so the rules pass r on only when the call did not revert (`rOk`).
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

rule ozMulDivReverts(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    ozMulDiv@withrevert(e, x, y, den);
    assert lastReverted <=> (den == 0 || hi >= den), "mulDiv reverts other than on a zero denominator or an overflow";
}

rule ozMulDivRemainder(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    require den > 0 && hi < den;
    uint256 r = ozMulDiv(e, x, y, den);
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);
    assert rem < den && limbsAddUp(rh, rl, rem, hi, lo), "r * den + x * y mod den is not x * y";
}

rule fullMathMulDivReverts(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    fullMathMulDiv@withrevert(e, x, y, den);
    assert lastReverted <=> (den == 0 || hi >= den), "mulDiv reverts other than on a zero denominator or an overflow";
}

rule fullMathMulDivRemainder(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    uint256 hi;
    uint256 lo;
    hi, lo = mul512(e, x, y);
    require den > 0 && hi < den;
    uint256 r = fullMathMulDiv(e, x, y, den);
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, r, den);
    assert rem < den && limbsAddUp(rh, rl, rem, hi, lo), "r * den + x * y mod den is not x * y";
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

// n >= 0: CVL division truncates toward zero, so for a negative n the floor and the quotient differ.
rule floorFromRemainder(mathint n, mathint d, mathint q, mathint rem) {
    require n >= 0 && d > 0 && 0 <= rem && rem < d && q * d + rem == n;
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
    uint256 rOk = reverted ? 0 : r;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, rOk, den);

    // ozMulDivReverts
    require reverted <=> (den == 0 || hi >= den);
    // ozMulDivRemainder
    require (den > 0 && hi < den) => (rem < den && limbsAddUp(rh, rl, rem, hi, lo));
    // mul512IsProduct at (x, y) and at (rOk, den)
    require hi * W() + lo == x * y;
    require rh * W() + rl == rOk * den;
    // floorDivAtLeast(n = x * y, q = den, t = 2^256): a quotient past a word means hi >= den
    require (x * y >= 0 && den > 0 && x * y >= W() * den) => (x * y) / den >= W();
    // floorFromRemainder(n = x * y, d = den, q = rOk, rem)
    require (x * y >= 0 && den > 0 && 0 <= rem && rem < den && rOk * den + rem == x * y) => rOk == (x * y) / den;

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
    uint256 rOk = reverted ? 0 : r;
    uint256 rem = mulMod(e, x, y, den);
    uint256 rh;
    uint256 rl;
    rh, rl = mul512(e, rOk, den);

    // fullMathMulDivReverts
    require reverted <=> (den == 0 || hi >= den);
    // fullMathMulDivRemainder
    require (den > 0 && hi < den) => (rem < den && limbsAddUp(rh, rl, rem, hi, lo));
    // mul512IsProduct at (x, y) and at (rOk, den)
    require hi * W() + lo == x * y;
    require rh * W() + rl == rOk * den;
    // floorDivAtLeast(n = x * y, q = den, t = 2^256): a quotient past a word means hi >= den
    require (x * y >= 0 && den > 0 && x * y >= W() * den) => (x * y) / den >= W();
    // floorFromRemainder(n = x * y, d = den, q = rOk, rem)
    require (x * y >= 0 && den > 0 && 0 <= rem && rem < den && rOk * den + rem == x * y) => rOk == (x * y) / den;

    assert (den > 0 && q <= max_uint256) => (!reverted && to_mathint(r) == q), "mulDiv is not floor(x * y / den)";
}

// ---------------------------------------------------------------------------------------------------------------------
// Integer mode: Math.sqrt, by input band and by bound
// ---------------------------------------------------------------------------------------------------------------------

rule ozSqrtLowerBound32(uint256 a) {
    env e;
    require to_mathint(a) < 2^32;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound32(uint256 a) {
    env e;
    require to_mathint(a) < 2^32;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound64(uint256 a) {
    env e;
    require to_mathint(a) >= 2^32 && to_mathint(a) < 2^64;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound64(uint256 a) {
    env e;
    require to_mathint(a) >= 2^32 && to_mathint(a) < 2^64;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound96(uint256 a) {
    env e;
    require to_mathint(a) >= 2^64 && to_mathint(a) < 2^96;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound96(uint256 a) {
    env e;
    require to_mathint(a) >= 2^64 && to_mathint(a) < 2^96;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound128(uint256 a) {
    env e;
    require to_mathint(a) >= 2^96 && to_mathint(a) < 2^128;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound128(uint256 a) {
    env e;
    require to_mathint(a) >= 2^96 && to_mathint(a) < 2^128;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound160(uint256 a) {
    env e;
    require to_mathint(a) >= 2^128 && to_mathint(a) < 2^160;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound160(uint256 a) {
    env e;
    require to_mathint(a) >= 2^128 && to_mathint(a) < 2^160;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound192(uint256 a) {
    env e;
    require to_mathint(a) >= 2^160 && to_mathint(a) < 2^192;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound192(uint256 a) {
    env e;
    require to_mathint(a) >= 2^160 && to_mathint(a) < 2^192;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound224(uint256 a) {
    env e;
    require to_mathint(a) >= 2^192 && to_mathint(a) < 2^224;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound224(uint256 a) {
    env e;
    require to_mathint(a) >= 2^192 && to_mathint(a) < 2^224;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}

rule ozSqrtLowerBound256(uint256 a) {
    env e;
    require to_mathint(a) >= 2^224;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a), "sqrt is above the integer square root";
}

rule ozSqrtUpperBound256(uint256 a) {
    env e;
    require to_mathint(a) >= 2^224;
    mathint r = ozSqrt(e, a);
    assert to_mathint(a) < (r + 1) * (r + 1), "sqrt is below the integer square root";
}
