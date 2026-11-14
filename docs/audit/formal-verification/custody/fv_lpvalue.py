"""Credited LP value versus realizable exit value (coordinator item 1).

Scope after the AMM-neutral design: this file proves the full-range case, which is the
special case tickLower = -floor(887272/s)*s, tickUpper = floor(887272/s)*s of an exact
range (SPEC-BACK-001). The bounded-range case, with the oracle ratio clamped to the range
(SPEC-AMM-V3-001), is proved in fv_amm.py (FV-CUS-37-inrange, -above, -below).

Proved (Z3, nonlinear reals):
  * at ANY pool price (including a manipulated one followed by an immediate full
    withdrawal) an ideal full-range position of liquidity L is worth at least
    2 * L * sqrt(p0 * p1) at the external prices (AM-GM), and the LPOracle answer
    price8 = isqrt(4 * v0 * v1) - 1 never exceeds that per-unit value;
  * with collateral factor CF, the credited borrowing value L * price8 * CF is covered
    by the realizable value after a sale impact s on each leg whenever s <= 1 - CF,
    and after an adverse external move m before the exit whenever (1 - m)(1 - s) >= CF.
  * SPEC-UNIT-003 residual: when the credited value is at most the value of the
    unrounded removal amounts, Uniswap's round-down removal leaves a shortfall below
    one raw unit of each token at its price.
Randomized (seeded, 20,000 draws) with exact Uniswap v3 integer amounts
(SqrtPriceMath, rounding down on removal), full-range ticks for spacings 1/10/60/200,
decimals 6..18 with an even sum, leg prices $0.30..$3.00, any pool price in range,
values compared as exact rationals:
  * credited value <= realizable value + one raw unit of each token at its price
    (the SPEC-UNIT-003 bound), with the largest shortfall reported.
"""
import math
import random
from fractions import Fraction
from decimal import Decimal, getcontext
from z3 import Reals, And, Implies
from common import prove, concrete, summary

getcontext().prec = 80
Q96 = 2 ** 96


def sqrt_at_tick(t):
    return int((Decimal("1.0001") ** t).sqrt() * Q96)


def amount0(sa, sb, L):
    if sa > sb:
        sa, sb = sb, sa
    return ((L << 96) * (sb - sa) // sb) // sa


def amount1(sa, sb, L):
    if sa > sb:
        sa, sb = sb, sa
    return L * (sb - sa) // Q96


def proofs():
    L, r, p0, p1, q, price, CF, s, m = Reals("L r p0 p1 q price CF s m")
    V = L / r * p0 + L * r * p1
    base = [L > 0, r > 0, p0 > 0, p1 > 0, q > 0, q * q == p0 * p1]
    # FV-CUS-25 verifies: SPEC-UNIT-003, SPEC-CF-001, SPEC-BACK-002
    prove("FV-CUS-25-amgm", "item 1: at any pool price the removed amounts are worth >= 2 L sqrt(p0 p1) (immediate full withdrawal after manipulation included)",
          V >= 2 * L * q, base)
    prove("FV-CUS-25-oracle", "item 1: credited value L * price8 <= removal value when price8 <= 2 sqrt(p0 p1)",
          L * price <= V, base + [price >= 0, price <= 2 * q])
    prove("FV-CUS-25-cf", "item 1: L * price8 * CF <= realizable after sale impact s on each leg whenever s <= 1 - CF",
          L * price * CF <= V * (1 - s),
          base + [price >= 0, price <= 2 * q, CF >= 0, CF <= 1, s >= 0, s <= 1 - CF])
    # FV-CUS-25 verifies: SPEC-UNIT-003, SPEC-BACK-008
    x0, x1, a0, a1, q0, q1, cred = Reals("x0 x1 a0 a1 q0 q1 credited")
    prove("FV-CUS-25-residual", "SPEC-UNIT-003: removal amounts rounded down by less than one raw unit per leg leave the credited value short of the realizable value by less than one raw unit of each token",
          cred - (a0 * q0 + a1 * q1) < q0 + q1,
          [x0 >= 0, x1 >= 0, q0 > 0, q1 > 0, a0 <= x0, a0 > x0 - 1, a1 <= x1, a1 > x1 - 1,
           a0 >= 0, a1 >= 0, cred <= x0 * q0 + x1 * q1])
    prove("FV-CUS-25-move", "item 1: after an adverse external move m and impact s, coverage holds whenever (1 - m)(1 - s) >= CF",
          L * price * CF <= V * (1 - m) * (1 - s),
          base + [price >= 0, price <= 2 * q, CF >= 0, CF <= 1, s >= 0, s < 1, m >= 0, m < 1,
                  (1 - m) * (1 - s) >= CF])


def fuzz(n=20000, seed=20261109):
    rnd = random.Random(seed)
    worst_usd8 = Fraction(0)
    violations_beyond_rounding = 0
    examples = 0
    for k in range(n):
        s = rnd.choice([1, 10, 60, 200])
        tmax = (887272 // s) * s
        smin, smax = sqrt_at_tick(-tmax), sqrt_at_tick(tmax)
        dsum = rnd.choice(range(12, 37, 2))
        d0 = rnd.randint(max(0, dsum - 18), min(18, dsum)) if dsum <= 36 else 18
        d0 = min(max(d0, 6), 18)
        d1 = dsum - d0
        if not (6 <= d1 <= 18):
            continue
        d = dsum // 2
        P0 = rnd.randint(30_000_000, 300_000_000)      # USD per whole token0, 8 decimals
        P1 = rnd.randint(30_000_000, 300_000_000)
        L = rnd.choice([rnd.randint(1, 10 ** 6), rnd.randint(10 ** 6, 10 ** 15), rnd.randint(10 ** 15, 10 ** 30)])
        # pool price: fair, mildly off, or manipulated anywhere in range
        mode = rnd.random()
        fair = Decimal(P0) / Decimal(P1) * Decimal(10) ** (d1 - d0)       # raw token1 per raw token0
        if mode < 0.4:
            P = fair
        elif mode < 0.8:
            P = fair * Decimal(math.exp(rnd.uniform(-1, 1)))
        else:
            P = Decimal(math.exp(rnd.uniform(-80, 80)))
        sp = int(P.sqrt() * Q96)
        sp = min(max(sp, smin + 1), smax - 1)
        a0 = amount0(sp, smax, L)
        a1 = amount1(smin, sp, L)
        realizable = Fraction(a0 * P0, 10 ** d0) + Fraction(a1 * P1, 10 ** d1)   # USD x 1e8, exact
        price8 = math.isqrt(4 * P0 * P1) - 1
        credited = Fraction(L * price8, 10 ** d)
        allow = Fraction(P0, 10 ** d0) + Fraction(P1, 10 ** d1)                # one raw unit per leg
        examples += 1
        if credited > realizable:
            worst_usd8 = max(worst_usd8, credited - realizable)
            if credited - realizable > allow:
                violations_beyond_rounding += 1
    return examples, worst_usd8, violations_beyond_rounding


def main():
    proofs()
    ex, worst, beyond = fuzz()
    # FV-CUS-25 verifies: SPEC-UNIT-003, SPEC-BACK-002, SPEC-BACK-008
    concrete("FV-CUS-25-fuzz", f"SPEC-UNIT-003 (randomized, {ex} samples, exact rationals): credited value never exceeds realizable value by more than one raw unit of each token (largest shortfall {float(worst):.2f} in 8-decimal USD)",
             beyond == 0, f"{beyond} samples beyond one raw unit per leg")
    s0, smax0 = sqrt_at_tick(-887272), sqrt_at_tick(887272)
    one = Q96
    e0, e1 = amount0(one, smax0, 1), amount1(s0, one, 1)
    cred1 = (1 * (math.isqrt(4 * 10 ** 8 * 10 ** 8) - 1)) // 10 ** 6
    concrete("FV-CUS-25-example", "SPEC-UNIT-003 example: L = 1 at pool price 1, both legs $1, 6 decimals removes (0, 0) against a credited value of 199, below one raw unit of each token (100 + 100)",
             e0 == 0 and e1 == 0 and cred1 == 199 and cred1 < 100 + 100)
    return summary("fv_lpvalue")


if __name__ == "__main__":
    raise SystemExit(main())
