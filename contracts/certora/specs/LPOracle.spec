/*
 * LPOracle (src/oracle/LPOracle.sol, arithmetic in src/oracle/LPPriceMath.sol, design in src/oracle/DESIGN.md),
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
 * leg read was bad. The immutables (band, decimals, feeds) are unconstrained, so the oracle rules hold for every
 * deployment.
 */

methods {
    function latestAnswer() external returns (int256) envfree;

    function _.latestRoundData() external => feedRound(calledContract) expect (uint80, int256, uint256, uint256, uint80);
    function _.decimals() external => NONDET;
}

definition Q96() returns mathint = 2^96;
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

rule sqrtPriceMonotoneInPrices(uint256 p0, uint256 p0b, uint256 p1, uint256 p1b, uint8 d0, uint8 d1) {
    env e;
    require to_mathint(d0) <= MAX_DECIMALS() && to_mathint(d1) <= MAX_DECIMALS();
    require 0 < p0 && p0 <= p0b && to_mathint(p0b) <= MAX_PRICE();
    require 0 < p1b && p1b <= p1 && to_mathint(p1) <= MAX_PRICE();
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
rule unitAmountsAtMostExact(uint160 s, uint160 sqrtLower, uint160 sqrtUpper, uint128 units) {
    env e;
    require 0 < sqrtLower && sqrtLower < sqrtUpper;
    mathint c = s < sqrtLower ? to_mathint(sqrtLower) : (s > sqrtUpper ? to_mathint(sqrtUpper) : to_mathint(s));
    uint256 a0;
    uint256 a1;
    a0, a1 = amounts(e, s, sqrtLower, sqrtUpper, units);
    assert a0 * c * sqrtUpper <= units * Q96() * (sqrtUpper - c), "the token0 amount exceeds the band unit's";
    assert a1 * Q96() <= units * (c - sqrtLower), "the token1 amount exceeds the band unit's";
}

rule valueAtMostExact(uint256 a0, uint256 a1, uint256 p0, uint256 p1, uint8 d0, uint8 d1) {
    env e;
    require to_mathint(d0) <= MAX_DECIMALS() && to_mathint(d1) <= MAX_DECIMALS();
    mathint v = value(e, a0, a1, p0, p1, d0, d1);
    assert v * 10^d0 * 10^d1 <= a0 * p0 * 10^d1 + a1 * p1 * 10^d0, "the value exceeds the amounts at the feed prices";
}
