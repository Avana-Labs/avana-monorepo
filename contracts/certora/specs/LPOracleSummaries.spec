/*
 * The library summaries of LPOracle.spec, proved against the library bytecode through LPOracleSummariesHarness
 * (test/utils/harness/LPOracleSummariesHarness.sol). No summaries here: each rule runs the real code.
 *
 *   ozMulDivIsFloor        OpenZeppelin Math.mulDiv(x, y, den) returns floor(x * y / den) whenever den > 0 and that
 *                          quotient is a word (otherwise it reverts, a path LPOracle.spec drops)
 *   fullMathMulDivIsFloor  the same for Uniswap v4-core FullMath.mulDiv
 *   ozSqrtIsFloorSqrt      OpenZeppelin Math.sqrt(a) is the integer square root: r * r <= a < (r + 1) * (r + 1)
 */

rule ozMulDivIsFloor(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    mathint q = den > 0 ? (x * y) / den : 0;
    uint256 r = ozMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    assert (den > 0 && q <= max_uint256) => (!reverted && to_mathint(r) == q), "mulDiv is not floor(x * y / den)";
}

rule fullMathMulDivIsFloor(uint256 x, uint256 y, uint256 den) {
    env e;
    require e.msg.value == 0;
    mathint q = den > 0 ? (x * y) / den : 0;
    uint256 r = fullMathMulDiv@withrevert(e, x, y, den);
    bool reverted = lastReverted;
    assert (den > 0 && q <= max_uint256) => (!reverted && to_mathint(r) == q), "mulDiv is not floor(x * y / den)";
}

rule ozSqrtIsFloorSqrt(uint256 a) {
    env e;
    mathint r = ozSqrt(e, a);
    assert r * r <= to_mathint(a) && to_mathint(a) < (r + 1) * (r + 1), "sqrt is not the integer square root";
}
