# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-79..81 — Second parts of the split Halmos checks of PROP-023, PROP-024 and PROP-025.

Each Halmos check below proves a fact about the Solidity code that needs no bit-level product or division of symbolic
values; this script proves, over the same inputs, the part that does, so the two parts together give the assertions
the checks made before the split.

  MATH-UO-79  contracts/test/halmos/LPPriceMath.halmos.t.sol
              check_PROP_023_price8PositiveAndBelowExact_{6_6,18_6,18_18}Formula,
              check_PROP_024_valuationSymmetricInTokenOrderFormula
              Halmos: lpPrice returns R = max(1, sum_i [a_i > 1] floor((a_i - 1) v_i / 10^d_i)), assuming
              mulmod(x, y, 2^256 - 1) == x * y for each term. Here: that assumption removes no input, the sum does not
              wrap, and R is at least 1, below 2^255 and at most the exact value of the holdings (SPEC-ORC-008).
  MATH-UO-80  contracts/test/halmos/LPOracleCL.halmos.t.sol
              check_PROP_025_meanTickRoundsTowardNegativeInfinityFormula
              Halmos: meanOf returns F = trunc(delta / W) - [delta < 0 and delta mod W != 0] (EVM SDIV and SMOD) and
              refuses exactly when F is outside [MIN_TICK, MAX_TICK]. Here: F is the floor of delta / W for every
              56-bit delta and every window in [1, 2^32) (SPEC-ORC-010). MATH-UO-12d proves the same rounding for
              W <= 10^6; this item covers every uint32 window.
  MATH-UO-81  contracts/test/halmos/LPOracleCL.halmos.t.sol check_PROP_025_oracleSqrtIsTickableLower{X64,...,X256}
              Halmos assumes Math.sqrt(X) < 2^129 for the code's square-root input X. Here: OpenZeppelin 5.1.0
              Math.sqrt(a) < 2^129 for every a < 2^256, so the assumption removes no input.

Math.sqrt (OpenZeppelin 5.1.0, utils/math/Math.sol), every operation unchecked:
  a <= 1: return a.
  xn = 2^e from the cascade `if (aa >= 2^k) { aa >>= k; xn <<= k / 2; }` for k = 128, 64, 32, 16, 8, 4, then
  `if (aa >= 4) xn <<= 1`; then xn = (3 * xn) >> 1; then six times xn = (xn + a / xn) >> 1;
  return xn - (xn > a / xn ? 1 : 0).
Each decision of the cascade compares a >> s with a constant, where s is fixed by the earlier decisions, so it is
monotone in a: inputs between two inputs that take the same decisions take them too. 81a runs the cascade on both ends
of every bit length, so every a of that bit length gets the same e, and checks 2^(2e) <= a < 2^(2e+2).
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, If, Implies
from _common import prove, note, finish, MIN_TICK, MAX_TICK, MAX_ROUTE_ANSWER

B256 = 2 ** 256
A_MAX = 2 ** 128 - 1        # amounts are uint128
PAIRS = [(6, 6), (18, 6), (6, 18), (18, 18)]   # the decimals pairs of the Halmos checks (6/18 is PROP-024's reverse)

# ---------------------------------------------------------------------------
# MATH-UO-79  lpPrice reference formula R of the PROP-023 and PROP-024 Halmos checks.
x, v = Ints('x v')
# MATH-UO-79 verifies: SPEC-ORC-008, REQ-ORACLE-103
prove('MATH-UO-79a', 'x = a - 1 with 2 <= a < 2^128, 1 <= v <= MAX_ROUTE_ANSWER: x * v < 2^188 < 2^256 - 1, so '
      'mulmod(x, v, 2^256 - 1) and x * v are both the exact product (the checks\' assumption removes no input)',
      [x >= 1, x <= A_MAX - 1, v >= 1, v <= MAX_ROUTE_ANSWER], And(x * v < 2 ** 188, x * v < B256 - 1))

a0, a1, v0, v1 = Ints('a0 a1 v0 v1')


def floor_term(a, val, c, tag):
    """(T, hyps): T = floor((a - 1) val / c) when a > 1, else 0, with an explicit quotient and remainder."""
    q, m = Ints(f'{tag}_quot {tag}_rem')
    hyps = [Implies(a > 1, And((a - 1) * val == q * c + m, m >= 0, m < c, q >= 0)), Implies(a <= 1, q == 0)]
    return q, hyps


inputs = [a0 >= 0, a0 <= A_MAX, a1 >= 0, a1 <= A_MAX,
          v0 >= 1, v0 <= MAX_ROUTE_ANSWER, v1 >= 1, v1 <= MAX_ROUTE_ANSWER]
for d0, d1 in PAIRS:
    c0, c1 = 10 ** d0, 10 ** d1
    t0, h0 = floor_term(a0, v0, c0, f't0_{d0}_{d1}')
    t1, h1 = floor_term(a1, v1, c1, f't1_{d0}_{d1}')
    s = t0 + t1
    r = If(s == 0, 1, s)
    one = 10 ** (d0 + d1)
    e = a0 * v0 * c1 + a1 * v1 * c0          # exact value of the holdings, scaled by 10^(d0 + d1)
    hyps = inputs + h0 + h1
    # MATH-UO-79 verifies: SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103, INV-055
    prove(f'MATH-UO-79b[{d0}/{d1}]', 'the unchecked sum T0 + T1 stays below 2^189 (no wrap); 1 <= R < 2^255',
          hyps, And(s < 2 ** 189, r >= 1, r < 2 ** 255))
    # MATH-UO-79 verifies: SPEC-ORC-008, REQ-ORACLE-012, INV-055
    prove(f'MATH-UO-79c[{d0}/{d1}]', 'E = a0 v0 10^d1 + a1 v1 10^d0 (each product below 2^248): R * 10^(d0+d1) <= E '
          'when E >= 10^(d0+d1), and R = 1 below it',
          hyps, And(a0 * v0 * c1 < 2 ** 248, a1 * v1 * c0 < 2 ** 248,
                    Implies(e >= one, r * one <= e), Implies(e < one, r == 1)))

# ---------------------------------------------------------------------------
# MATH-UO-80  Mean tick: trunc(delta / W) - [delta < 0 and delta mod W != 0] is floor(delta / W).
# EVM SDIV and SMOD with W >= 1: delta = q W + r with 0 <= r < W when delta >= 0 and -W < r <= 0 when delta < 0
# (truncation toward zero, remainder with the sign of delta); these constraints fix q and r uniquely.
# F = q - k with k = [delta < 0 and r != 0], so F * W = q * W - k * W. The product q * W is written as one integer m
# (delta = m + r), which keeps 80a linear; it is proved for every integer m, a superset of the multiples of W.
dl, w, m, rm = Ints('delta W qW r')
k_w = If(And(dl < 0, rm != 0), w, 0)                     # k * W
f_w = m - k_w                                            # F * W
sdiv = [dl == m + rm, Implies(dl >= 0, And(rm >= 0, rm < w)), Implies(dl < 0, And(rm <= 0, rm > -w))]
base80 = [dl >= -(2 ** 55), dl < 2 ** 55, w >= 1, w < 2 ** 32] + sdiv
# MATH-UO-80 verifies: SPEC-ORC-010, REQ-ORACLE-014
prove('MATH-UO-80a', '56-bit delta, 1 <= W < 2^32: F * W <= delta < F * W + W (F rounds toward -inf)',
      base80, And(f_w <= dl, dl < f_w + w))
t, ff, w2, d2 = Ints('t F W2 delta2')
# MATH-UO-80 verifies: SPEC-ORC-010, REQ-ORACLE-014
prove('MATH-UO-80b', 'floors are unique: with t = f - F for two integers f, F that both satisfy 80a, -W < t * W < W '
      'and W >= 1 give t = 0, so ok (F in [MIN_TICK, MAX_TICK]) is exactly floor(delta / W) in range',
      [w2 >= 1, t * w2 < w2, t * w2 > -w2], t == 0)
# MATH-UO-80 verifies: SPEC-ORC-010, REQ-ORACLE-014
prove('MATH-UO-80c', 'F * W <= delta < (F + 1) * W with a 56-bit delta and W >= 1 gives -2^55 <= F < 2^55: the '
      'decrement never wraps, and an F in [MIN_TICK, MAX_TICK] fits int24',
      [d2 >= -(2 ** 55), d2 < 2 ** 55, w2 >= 1, w2 < 2 ** 32, ff * w2 <= d2, d2 < (ff + 1) * w2],
      And(ff >= -(2 ** 55), ff < 2 ** 55,
          Implies(And(ff >= MIN_TICK, ff <= MAX_TICK), And(ff >= -(2 ** 23), ff < 2 ** 23))))

# ---------------------------------------------------------------------------
# MATH-UO-81  OpenZeppelin 5.1.0 Math.sqrt(a) < 2^129 for every a < 2^256.


def oz_sqrt_estimate(a):
    """Cascade and initial estimate of Math.sqrt, exact port: returns (e, x0) with xn = 2^e before (3 * xn) >> 1."""
    aa, xn = a, 1
    for k in (128, 64, 32, 16, 8, 4):
        if aa >= 1 << k:
            aa >>= k
            xn <<= k // 2
    if aa >= 1 << 2:
        xn <<= 1
    return xn.bit_length() - 1, (3 * xn) >> 1


def oz_sqrt(a):
    """Math.sqrt, exact port (unchecked: each sum is checked below 2^256 here)."""
    if a <= 1:
        return a
    _, xn = oz_sqrt_estimate(a)
    for _ in range(6):
        t = xn + a // xn
        assert t < B256
        xn = t >> 1
    return xn - (1 if xn > a // xn else 0)


rows = []
for n in range(2, 257):                     # bit length of a; a <= 1 returns a
    lo_a, hi_a = 1 << (n - 1), (1 << n) - 1
    e_lo, x_lo = oz_sqrt_estimate(lo_a)
    e_hi, x_hi = oz_sqrt_estimate(hi_a)
    assert e_lo == e_hi and x_lo == x_hi, n
    e = e_lo
    assert 2 ** (2 * e) <= lo_a and hi_a < 2 ** (2 * e + 2) and e <= 127
    assert 2 ** e <= x_lo < 2 ** (e + 2)
    for a in (lo_a, hi_a, (lo_a + hi_a) // 2):
        r_ = oz_sqrt(a)
        assert r_ * r_ <= a < (r_ + 1) * (r_ + 1) and r_ < 2 ** 129, a
    if n in (2, 3, 128, 129, 255, 256):
        rows.append(f'bit length {n}: e = {e}, x0 = {x_lo}')
# MATH-UO-81 verifies: SPEC-ORC-009
note('MATH-UO-81a', 'every bit length n in [2, 256] takes one cascade path: e = floor((n - 1) / 2) <= 127, '
     '2^(2e) <= a < 2^(2e+2), x0 = (3 * 2^e) >> 1 in [2^e, 2^(e+2)); the port returns isqrt(a) at both ends and the '
     'middle of every bit length', '\n'.join(rows))

L, aa_, xk, qk, nk = Ints('L a x q N')
step = [L >= 1, L <= 2 ** 127, aa_ >= L * L, aa_ < 4 * L * L, xk >= L, xk < 4 * L,
        qk >= 0, qk * xk <= aa_, aa_ < (qk + 1) * xk,          # q = floor(a / x)
        2 * nk <= xk + qk, xk + qk <= 2 * nk + 1]              # N = (x + q) >> 1
# MATH-UO-81 verifies: SPEC-ORC-009
prove('MATH-UO-81b', 'one Newton step with L = 2^e, L^2 <= a < 4 L^2 and L <= x < 4 L: x + a / x < 8 L <= 2^130 '
      '(the unchecked sum does not wrap) and L <= (x + a / x) >> 1 < 4 L',
      step, And(xk + qk < 8 * L, xk + qk < 2 ** 130, nk >= L, nk < 4 * L))
# MATH-UO-81 verifies: SPEC-ORC-009
prove('MATH-UO-81c', 'after six steps L <= x < 4 L, so x - [x > a / x] is in [0, 4 L) and below 2^129; '
      'with 81a and 81b, Math.sqrt(a) < 2^129 for every a < 2^256 (a <= 1 returns a)',
      [L >= 1, L <= 2 ** 127, xk >= L, xk < 4 * L, qk >= 0], And(xk - If(xk > qk, 1, 0) >= 0,
                                                                xk - If(xk > qk, 1, 0) < 2 ** 129))

finish()
