/*
 * LPOracle (src/oracle/LPOracle.sol, arithmetic in src/oracle/libraries/LPPriceMath.sol, design in src/oracle/DESIGN.md),
 * through LPOracleHarness (test/utils/harness/LPOracleHarness.sol), which is the LPOracle plus external wrappers of
 * the internal LPPriceMath steps.
 *
 * The oracle's answer is the USD value of one whole vault token (U units of band liquidity) at the fair price of the
 * market's own Chainlink feeds, clamped to the band:
 *
 *   p_i = normalize(feed legs)            s = sqrtPriceX96(p0, p1, d0, d1)       s' = clamp(s, sqrtLower, sqrtUpper)
 *   (a0, a1) = amounts(s, sqrtLower, sqrtUpper, U)                                answer = max(value(a0, a1, ...), 1)
 *
 * The rules:
 *
 *   Monotone in the feeds
 *     normalizeMonotoneInAnswer       a larger feed answer is never a smaller 8-decimal price
 *     sqrtPriceMonotoneInPrices       the fair square-root price is non-decreasing in p0 and non-increasing in p1
 *     valueMonotoneInPrices           at fixed amounts the value is non-decreasing in both prices
 *     unitValueMonotoneInFairPrice    one band unit's exact value in token1 is non-decreasing in the (clamped) fair
 *                                     price, over unbounded CVL integers; with the three above, a feed moving up never
 *                                     moves the unit's value down except by the rounding of each step
 *   Bad feed data
 *     normalizeIsZeroOnBadAnswer      an answer <= 0 or >= 2^128 normalizes to 0, which the oracle treats as a failed leg
 *     latestAnswerRevertsOnBadLeg     latestAnswer reverts when any leg it reads answered <= 0 or >= 2^128
 *   Never above the floor credit value
 *     unitAmountsAtMostExact          the amounts one unit holds are at most the exact amounts at the clamped price
 *     valueAtMostExact                the value is at most the exact value of those amounts at the feed prices
 *
 * With FloorCreditMath.spec (credit * V_band(s) <= L * V_position(s) at every price in the band, and credit <= L * r
 * at and past the band edges), the last two give credit * answer / U <= the position's value at the feed price: every
 * step of the oracle rounds down from the exact band value the credit proof uses. The floor of 1 (DESIGN.md decision
 * 5) is the only step that rounds up, by at most 10^-8 USD per whole vault token.
 *
 * Summaries: each Chainlink feed's `latestRoundData` returns a ghost answer per feed address, and records whether any
 * leg read was bad. OpenZeppelin `Math.mulDiv` and v4-core `FullMath.mulDiv` are floor(x * y / den), and `Math.sqrt`
 * is the integer square root; LPOracleSummaries.spec proves each against the library bytecode. The immutables (band,
 * decimals, feeds) are unconstrained, so the oracle rules hold for every deployment.
 *
 * Three rules each needed several nonlinear steps at once and did not finish. They now `require` each step as an
 * instance (hypotheses => conclusion) of a lemma rule at the end of this spec, named on its line, and assert only the
 * last, linear step:
 *     sqrtPriceMonotoneInPrices   productMonotone, floorDivMonotone, floorDivBelow, floorDivAtLeast,
 *                                 floorSqrtMonotone, floorSqrtBelow, floorSqrtAtLeast
 *     unitAmountsAtMostExact      floorDivAtMost, productMonotone
 *     valueAtMostExact            floorDivAtMost, productMonotone, scaleSum
 */

methods {
    function latestAnswer() external returns (int256) envfree;

    function _.latestRoundData() external => feedRound(calledContract) expect (uint80, int256, uint256, uint256, uint80);
    function _.decimals() external => NONDET;

    // Proven against the library bytecode in LPOracleSummaries.spec (ozMulDivIsFloor, fullMathMulDivIsFloor,
    // ozSqrtLowerBound* and ozSqrtUpperBound*, whose bands cover every word).
    function Math.mulDiv(uint256 x, uint256 y, uint256 den) internal returns (uint256) => mulDivFloor(x, y, den);
    function FullMath.mulDiv(uint256 x, uint256 y, uint256 den) internal returns (uint256) => mulDivFloor(x, y, den);
    function Math.sqrt(uint256 a) internal returns (uint256) => floorSqrtOf(a);
}

definition Q96() returns mathint = 2^96;
definition Q128() returns mathint = 2^128;
definition Q192() returns mathint = 2^192;

// ---------------------------------------------------------------------------------------------------------------------
// Library summaries
// ---------------------------------------------------------------------------------------------------------------------

// floor(x * y / den); the library reverts when den is 0 or the quotient is not a word, so those paths are dropped.
function mulDivFloor(uint256 x, uint256 y, uint256 den) returns uint256 {
    require den > 0;
    mathint q = (x * y) / den;
    require q <= max_uint256;
    return require_uint256(q);
}

// The integer square root, as a function of its input so that rules can name it.
ghost isqrtGhost(mathint) returns mathint;

// isqrtGhost(x) is floor(sqrt(x)) for every word x (ozSqrtLowerBound*, ozSqrtUpperBound*: their bands cover every
// word).
function requireFloorSqrt(mathint x) {
    mathint r = isqrtGhost(x);
    require (0 <= x && x <= max_uint256) => (r >= 0 && r * r <= x && x < (r + 1) * (r + 1));
}

function floorSqrtOf(uint256 a) returns uint256 {
    requireFloorSqrt(a);
    return require_uint256(isqrtGhost(a));
}
definition ANSWER_BOUND() returns mathint = 2^128;
definition MAX_PRICE() returns mathint = 10^18;
definition MAX_DECIMALS() returns mathint = 18;

// ---------------------------------------------------------------------------------------------------------------------
// Feeds
// ---------------------------------------------------------------------------------------------------------------------

ghost mapping(address => int256) feedAnswer;
ghost bool badLegRead;

function feedRound(address feed) returns (uint80, int256, uint256, uint256, uint80) {
    int256 answer = feedAnswer[feed];
    if (answer <= 0 || to_mathint(answer) >= ANSWER_BOUND()) {
        badLegRead = true;
    }
    uint80 roundId;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 answeredInRound;
    return (roundId, answer, startedAt, updatedAt, answeredInRound);
}

// ---------------------------------------------------------------------------------------------------------------------
// Monotone in the feeds
// ---------------------------------------------------------------------------------------------------------------------

rule normalizeMonotoneInAnswer(int256 a1, int256 a2, uint8 d) {
    env e;
    require to_mathint(d) <= MAX_DECIMALS();
    require 0 < a1 && a1 <= a2 && to_mathint(a2) < ANSWER_BOUND();
    assert normalize(e, a1, d) <= normalize(e, a2, d), "a larger feed answer gave a smaller price";
}

// rawSqrtPrice with num = p0 * 10^d1 and den = p1 * 10^d0 takes one of three branches: isqrt(floor(num * 2^192 / den))
// when num < den * 2^64; "high" when num / 2^128 >= den; else isqrt(floor(num * 2^128 / den)) * 2^32. With the
// Math.mulDiv and Math.sqrt summaries those are the CVL terms below, and sqrtPriceX96 clamps the result to
// [MIN_SQRT_PRICE, MAX_SQRT_PRICE - 1]. The second call (b) has num' >= num and den' <= den.
rule sqrtPriceMonotoneInPrices(uint256 p0, uint256 p0b, uint256 p1, uint256 p1b, uint8 d0, uint8 d1) {
    env e;
    require to_mathint(d0) <= MAX_DECIMALS() && to_mathint(d1) <= MAX_DECIMALS();
    require 0 < p0 && p0 <= p0b && to_mathint(p0b) <= MAX_PRICE();
    require 0 < p1b && p1b <= p1 && to_mathint(p1) <= MAX_PRICE();
    mathint E0 = 10^d0;
    mathint E1 = 10^d1;
    mathint num = p0 * E1;
    mathint den = p1 * E0;
    mathint numB = p0b * E1;
    mathint denB = p1b * E0;
    mathint x = (num * Q192()) / den;
    mathint xB = (numB * Q192()) / denB;
    mathint y = (num * Q128()) / den;
    mathint yB = (numB * Q128()) / denB;

    // productMonotone(p0, p0b, E1) and productMonotone(p1b, p1, E0)
    require (p0 <= p0b && E1 >= 0) => p0 * E1 <= p0b * E1;
    require (p1b <= p1 && E0 >= 0) => p1b * E0 <= p1 * E0;
    // floorDivMonotone on both branches' quotients
    require (0 <= num * Q192() && num * Q192() <= numB * Q192() && 0 < denB && denB <= den) => x <= xB;
    require (0 <= num * Q128() && num * Q128() <= numB * Q128() && 0 < denB && denB <= den) => y <= yB;
    // floorDivBelow(n = num * 2^192, q = den, t = 2^256): the first branch's quotient is a word
    require (num * Q192() >= 0 && den > 0 && num * Q192() < 2^256 * den) => x < 2^256;
    // floorDivAtLeast(n = numB * 2^128, q = denB, t = 2^192): the third branch's quotient is at least 2^192
    require (numB * Q128() >= 0 && denB > 0 && numB * Q128() >= 2^192 * denB) => yB >= 2^192;
    // ozSqrtLowerBound*, ozSqrtUpperBound* (LPOracleSummaries.spec), through the Math.sqrt summary, at each quotient
    requireFloorSqrt(x);
    requireFloorSqrt(xB);
    requireFloorSqrt(y);
    requireFloorSqrt(yB);
    // floorSqrtMonotone at (x, xB) and (y, yB)
    require (0 <= x && x <= xB && isqrtGhost(x) >= 0 && isqrtGhost(xB) >= 0
        && isqrtGhost(x) * isqrtGhost(x) <= x && xB < (isqrtGhost(xB) + 1) * (isqrtGhost(xB) + 1))
        => isqrtGhost(x) <= isqrtGhost(xB);
    require (0 <= y && y <= yB && isqrtGhost(y) >= 0 && isqrtGhost(yB) >= 0
        && isqrtGhost(y) * isqrtGhost(y) <= y && yB < (isqrtGhost(yB) + 1) * (isqrtGhost(yB) + 1))
        => isqrtGhost(y) <= isqrtGhost(yB);
    // floorSqrtBelow at x and floorSqrtAtLeast at yB: the first branch stays below 2^128, the third reaches it
    require (0 <= x && x < 2^256 && isqrtGhost(x) >= 0 && isqrtGhost(x) * isqrtGhost(x) <= x) => isqrtGhost(x) < 2^128;
    require (yB >= 2^192 && isqrtGhost(yB) >= 0 && yB < (isqrtGhost(yB) + 1) * (isqrtGhost(yB) + 1))
        => isqrtGhost(yB) >= 2^96;

    assert sqrtPriceX96(e, p0, p1, d0, d1) <= sqrtPriceX96(e, p0b, p1b, d0, d1),
        "a higher token0 or lower token1 price gave a lower fair price";
}

rule valueMonotoneInPrices(uint256 a0, uint256 a1, uint256 p0, uint256 p0b, uint256 p1, uint256 p1b, uint8 d0, uint8 d1) {
    env e;
    require to_mathint(d0) <= MAX_DECIMALS() && to_mathint(d1) <= MAX_DECIMALS();
    require to_mathint(a0) < 2^192 && to_mathint(a1) < 2^192;
    require p0 <= p0b && to_mathint(p0b) <= MAX_PRICE();
    require p1 <= p1b && to_mathint(p1b) <= MAX_PRICE();
    assert value(e, a0, a1, p0, p1, d0, d1) <= value(e, a0, a1, p0b, p1b, d0, d1), "higher prices gave a lower value";
}

// One band unit's value in token1 at the square-root price s, times A * B (A, B the band's square-root edges):
// below the band all token0, (1/A - 1/B) * s^2; inside, 2s - s^2/B - A; above, all token1, B - A.
definition unitValueNum(mathint s, mathint A, mathint B) returns mathint =
    s <= A ? (B - A) * s * s : (s >= B ? A * B * (B - A) : A * (2 * s * B - s * s - A * B));

rule unitValueMonotoneInFairPrice(mathint s1, mathint s2, mathint A, mathint B) {
    require 0 < A && A < B;
    require 0 < s1 && s1 <= s2;
    mathint n1 = unitValueNum(s1, A, B);
    mathint n2 = unitValueNum(s2, A, B);
    mathint atA = (B - A) * A * A;
    mathint atB = A * B * (B - A);

    // Below the band: (B - A) * s^2 rises with s and is at most its value at A.
    assert s1 * s1 <= s2 * s2;
    assert s2 <= A => n1 <= n2;
    assert s1 <= A => s1 * s1 <= A * A;
    assert s1 <= A => n1 <= atA;
    // Inside: n(s) - n(A) = A * (s - A) * (2B - s - A) >= 0, B * A * (B - s)^2 = n(B) - n(s) >= 0, and
    // n(s2) - n(s1) = A * (s2 - s1) * (2B - s1 - s2) >= 0.
    assert (A < s2 && s2 < B) => n2 - atA == A * (s2 - A) * (2 * B - s2 - A);
    assert (A < s2 && s2 < B) => n2 >= atA;
    assert (A < s1 && s1 < B) => atB - n1 == A * (B - s1) * (B - s1);
    assert (A < s1 && s1 < B) => n1 <= atB;
    assert (A < s1 && s2 < B) => n2 - n1 == A * (s2 - s1) * (2 * B - s1 - s2);
    assert (A < s1 && s2 < B) => n1 <= n2;
    // The edges agree: n(A) <= n(B), and above the band the value is n(B).
    assert A * A <= A * B;
    assert atA <= atB;
    assert s2 >= B => n2 == atB;
    assert n1 <= n2, "a higher fair price gave one band unit a lower value";
}

// ---------------------------------------------------------------------------------------------------------------------
// Bad feed data
// ---------------------------------------------------------------------------------------------------------------------

rule normalizeIsZeroOnBadAnswer(int256 answer, uint8 d) {
    env e;
    require to_mathint(d) <= MAX_DECIMALS();
    require answer <= 0 || to_mathint(answer) >= ANSWER_BOUND();
    assert normalize(e, answer, d) == 0, "a non-positive or oversized feed answer gave a price";
}

rule latestAnswerRevertsOnBadLeg() {
    require !badLegRead;
    latestAnswer@withrevert();
    assert badLegRead => lastReverted, "latestAnswer answered after reading a bad feed leg";
}

// ---------------------------------------------------------------------------------------------------------------------
// Never above the floor credit value
// ---------------------------------------------------------------------------------------------------------------------

// a0 <= U * Q96 * (B - s') / (s' * B) and a1 <= U * (s' - A) / Q96: the exact band amounts at the clamped price.
// With the FullMath.mulDiv summary, getAmount0Delta(s', B, U) is m / s' with m = floor(U * Q96 * (B - s') / B), and
// getAmount1Delta(A, s', U) is floor(U * (s' - A) / Q96).
rule unitAmountsAtMostExact(uint160 s, uint160 sqrtLower, uint160 sqrtUpper, uint128 units) {
    env e;
    require 0 < sqrtLower && sqrtLower < sqrtUpper;
    mathint c = s < sqrtLower ? to_mathint(sqrtLower) : (s > sqrtUpper ? to_mathint(sqrtUpper) : to_mathint(s));
    uint256 a0;
    uint256 a1;
    a0, a1 = amounts(e, s, sqrtLower, sqrtUpper, units);
    mathint B = sqrtUpper;
    mathint n0 = units * Q96() * (B - c);
    mathint m = n0 / B;
    mathint n1 = units * (c - sqrtLower);

    // floorDivAtMost(n = m, q = c): a0 = m / c
    require (m >= 0 && c > 0) => (m / c) * c <= m;
    // floorDivAtMost(n = n0, q = B)
    require (n0 >= 0 && B > 0) => m * B <= n0;
    // productMonotone(a = a0 * c, b = m, k = B)
    require (a0 * c <= m && B >= 0) => (a0 * c) * B <= m * B;
    // floorDivAtMost(n = n1, q = Q96)
    require (n1 >= 0 && Q96() > 0) => (n1 / Q96()) * Q96() <= n1;

    assert a0 * c * sqrtUpper <= units * Q96() * (sqrtUpper - c), "the token0 amount exceeds the band unit's";
    assert a1 * Q96() <= units * (c - sqrtLower), "the token1 amount exceeds the band unit's";
}

// With the Math.mulDiv summary, value is q0 + q1 with q_i = floor(a_i * p_i / 10^d_i).
rule valueAtMostExact(uint256 a0, uint256 a1, uint256 p0, uint256 p1, uint8 d0, uint8 d1) {
    env e;
    require to_mathint(d0) <= MAX_DECIMALS() && to_mathint(d1) <= MAX_DECIMALS();
    mathint v = value(e, a0, a1, p0, p1, d0, d1);
    mathint D0 = 10^d0;
    mathint D1 = 10^d1;
    mathint n0 = a0 * p0;
    mathint n1 = a1 * p1;
    mathint q0 = n0 / D0;
    mathint q1 = n1 / D1;

    // floorDivAtMost(n = n0, q = D0) and floorDivAtMost(n = n1, q = D1)
    require (n0 >= 0 && D0 > 0) => q0 * D0 <= n0;
    require (n1 >= 0 && D1 > 0) => q1 * D1 <= n1;
    // productMonotone(a = q0 * D0, b = n0, k = D1) and productMonotone(a = q1 * D1, b = n1, k = D0)
    require (q0 * D0 <= n0 && D1 >= 0) => (q0 * D0) * D1 <= n0 * D1;
    require (q1 * D1 <= n1 && D0 >= 0) => (q1 * D1) * D0 <= n1 * D0;
    // scaleSum(v, a = q0, b = q1, k = D0 * D1)
    require v == q0 + q1 => v * (D0 * D1) == q0 * (D0 * D1) + q1 * (D0 * D1);

    assert v * 10^d0 * 10^d1 <= a0 * p0 * 10^d1 + a1 * p1 * 10^d0, "the value exceeds the amounts at the feed prices";
}

// ---------------------------------------------------------------------------------------------------------------------
// Lemmas: one nonlinear step each, over fresh integers. The main rules above require them at their own terms.
// ---------------------------------------------------------------------------------------------------------------------

rule floorDivAtMost(mathint n, mathint q) {
    require n >= 0 && q > 0;
    assert (n / q) * q <= n, "floor(n / q) * q exceeds n";
}

rule floorDivBelow(mathint n, mathint q, mathint t) {
    require n >= 0 && q > 0 && n < t * q;
    assert n / q < t, "floor(n / q) reached t although n < t * q";
}

rule floorDivAtLeast(mathint n, mathint q, mathint t) {
    require n >= 0 && q > 0 && n >= t * q;
    assert n / q >= t, "floor(n / q) is below t although n >= t * q";
}

rule floorDivMonotone(mathint n1, mathint n2, mathint q1, mathint q2) {
    require 0 <= n1 && n1 <= n2 && 0 < q2 && q2 <= q1;
    assert n1 / q1 <= n2 / q2, "a larger numerator over a smaller denominator gave a smaller quotient";
}

rule productMonotone(mathint a, mathint b, mathint k) {
    require a <= b && k >= 0;
    assert a * k <= b * k, "multiplying by a non-negative reversed an order";
}

rule scaleSum(mathint v, mathint a, mathint b, mathint k) {
    require v == a + b;
    assert v * k == a * k + b * k, "a product did not distribute";
}

// r1 = floor(sqrt(x1)), r2 = floor(sqrt(x2)) by their defining bounds.
rule floorSqrtMonotone(mathint x1, mathint x2, mathint r1, mathint r2) {
    require 0 <= x1 && x1 <= x2 && r1 >= 0 && r2 >= 0;
    require r1 * r1 <= x1 && x2 < (r2 + 1) * (r2 + 1);
    assert r1 <= r2, "a larger input had a smaller integer square root";
}

rule floorSqrtBelow(mathint x, mathint r) {
    require 0 <= x && x < 2^256 && r >= 0 && r * r <= x;
    assert r < 2^128, "the integer square root of a word reached 2^128";
}

rule floorSqrtAtLeast(mathint x, mathint r) {
    require x >= 2^192 && r >= 0 && x < (r + 1) * (r + 1);
    assert r >= 2^96, "the integer square root of x >= 2^192 is below 2^96";
}
