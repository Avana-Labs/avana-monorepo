# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-75 — overflow analysis of the price path at MAX_ROUTE_ANSWER = 10^18
($10,000,000,000 per whole token, 8 decimals) ([2.10] SPEC-ORC-003, SPEC-ORC-008, SPEC-ORC-009,
SPEC-ORC-011, SPEC-ORC-018, SPEC-ORC-020, REQ-ORACLE-047, REQ-ORACLE-049, REQ-ORACLE-050; [1.5]).

Every route value, valuation price, quote and second-source value that reaches the math is in
[1, M] with M = MAX_ROUTE_ANSWER = 10^18; composition amounts are below 2^128; token decimals of a
concentrated-liquidity market are at most 18; a market has 2 <= n <= 8 tokens.

  SPEC-ORC-008  price8 = max(1, sum_i mulDiv(a_i - 1, v_i, 10^d_i))
  SPEC-ORC-009  num = x0 * 10^d1, den = x1 * 10^d0; branch (a) num < 2^64 den: X = mulDiv(num, 2^192, den)
  SPEC-ORC-003 / SPEC-ORC-020  |p - b| * 10^4 <= T * min(p, b), T < 2^16
  REQ-ORACLE-050  shocked quotes min(q * 100, M) and max(q / 100, 1)
  SPEC-ORC-018  Expired debt price ceil(A * (10^4 + delta) / 10^4), delta in [100, 5,000]
  SPEC-ORC-011  x (x) y = floor(x * y / 10^8), saturating at 2^256 - 1 when x * y >= 2^256 and sticky;
                usdLevel = 2^256 - 1 when the product of the quotes saturates, else max{L : L^(x)n <= product}
The listing reason for 10^18: WBTC near $100,000 (10^13) must be listable and ETH above $10,000 (10^12)
must stay a valid route value instead of turning Invalid and the market Expired.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, Or, If, Implies, Not
from _common import prove, witness, note, finish, MAX_ROUTE_ANSWER, U256

M = MAX_ROUTE_ANSWER
assert M == 10 ** 18
E = 10 ** 8
SAT = U256                     # type(uint256).max
SHOCK = 100                    # LISTING_SHOCK_FACTOR
U128 = 2 ** 128

# ---------------------------------------------------------------- MATH-UO-75a lpPrice terms and sum
# MATH-UO-75 verifies: SPEC-ORC-008, REQ-ORACLE-103
a, v, t = Ints('amount price term')
prove('MATH-UO-75a', 'lpPrice: a_i < 2^128 and 1 <= v_i <= 10^18 keep each product (a_i - 1) * v_i below 2^188, so '
      'every mulDiv term is below 2^188, eight terms sum below 2^191 < 2^255 and the int256 cast of price8 is safe',
      [a >= 1, a < U128, v >= 1, v <= M, t == (a - 1) * v],
      And(t < 2 ** 188, 8 * t < 2 ** 191, 8 * t < 2 ** 255))
witness('MATH-UO-75b', 'wrong reading (the term bound 2^168 of the 10^12 listing bound): at 10^18 a term reaches 2^168',
        [a >= 1, a < U128, v >= 1, v <= M, (a - 1) * v >= 2 ** 168])

# ---------------------------------------------------------------- MATH-UO-75c SPEC-ORC-009 operands
# MATH-UO-75 verifies: SPEC-ORC-009, REQ-ORACLE-105
x0, x1, e0, e1, num, den = Ints('x0 x1 tenPowD0 tenPowD1 num den')
ops = [x0 >= 1, x0 <= M, x1 >= 1, x1 <= M, e0 >= 1, e0 <= 10 ** 18, e1 >= 1, e1 <= 10 ** 18,
       num == x0 * e1, den == x1 * e0]
prove('MATH-UO-75c', 'SPEC-ORC-009 with prices <= 10^18 and token decimals <= 18: num, den <= 10^36 < 2^120 and '
      'den << 64 < 2^184, so neither product nor shift overflows (the listing shock check computes the same operands)',
      ops, And(num <= 10 ** 36, num < 2 ** 120, den < 2 ** 120, den * 2 ** 64 < 2 ** 184))
prove('MATH-UO-75d', 'branch (a): num < 2^64 * den gives mulDiv(num, 2^192, den) < 2^256, so the 512-bit mulDiv '
      'returns a 256-bit result and never reverts',
      ops + [num < 2 ** 64 * den], num * 2 ** 192 < 2 ** 256 * den)

# ---------------------------------------------------------------- MATH-UO-75e agreement and second source
# MATH-UO-75 verifies: SPEC-ORC-003, SPEC-ORC-020
p, b, T = Ints('primary alternate toleranceBps')
dif, lo = If(p > b, p - b, b - p), If(p < b, p, b)
prove('MATH-UO-75e', 'agreement and second-source tests: with p, b in [1, 10^18] and T < 2^16, |p - b| * 10^4 <= 10^22 '
      'and T * min(p, b) < 2^76, both far below 2^256',
      [p >= 1, p <= M, b >= 1, b <= M, T >= 0, T < 2 ** 16],
      And(dif * 10 ** 4 <= 10 ** 22, T * lo < 2 ** 76, dif * 10 ** 4 < 2 ** 256, T * lo < 2 ** 256))

# ---------------------------------------------------------------- MATH-UO-75f stored price vectors
# MATH-UO-75 verifies: REQ-ORACLE-047, REQ-ORACLE-029
pv = Ints('vectorEntry')[0]
prove('MATH-UO-75f', 'every entry of the accepted price vector and of the listing price vector is a route value '
      '<= 10^18 < 2^128, so the uint128 casts that store them are exact',
      [pv >= 1, pv <= M], pv < U128)

# ---------------------------------------------------------------- MATH-UO-75g listing shock
# MATH-UO-75 verifies: REQ-ORACLE-050, REQ-ORACLE-105
q, up, dn = Ints('quote raised lowered')
prove('MATH-UO-75g', 'listing shock: q * 100 <= 10^20 < 2^67 never overflows, and the shocked quotes min(q * 100, 10^18) '
      'and max(q / 100, 1) stay in [1, 10^18], the range lpPrice and SPEC-ORC-009 accept',
      [q >= 1, q <= M, up == If(q * SHOCK < M, q * SHOCK, M), dn == If(q / SHOCK > 1, q / SHOCK, 1)],
      And(q * SHOCK <= 10 ** 20, q * SHOCK < 2 ** 67, up >= 1, up <= M, dn >= 1, dn <= M))

# ---------------------------------------------------------------- MATH-UO-75h DebtOracle served price
# MATH-UO-75 verifies: SPEC-ORC-018, REQ-ORACLE-093
A, dl, ex, pd, bd, dr = Ints('accepted delta expiredPrice debtPrimary debtAlternate driftingPrice')
prove('MATH-UO-75h', 'DebtOracle: with A, p, b <= 10^18 and delta in [100, 5,000], the Drifting value max(p, b, A) is '
      '<= 10^18 and the Expired value ceil(A (10^4 + delta) / 10^4) <= 1.5 * 10^18 + 1 < 2^255: every served debt '
      'price fits int256',
      [A >= 1, A <= M, pd >= 1, pd <= M, bd >= 1, bd <= M, dl >= 100, dl <= 5000,
       ex * 10 ** 4 >= A * (10 ** 4 + dl), ex * 10 ** 4 < A * (10 ** 4 + dl) + 10 ** 4,
       dr == If(If(pd > bd, pd, bd) > A, If(pd > bd, pd, bd), A)],
      And(dr <= M, 2 * ex <= 3 * M + 2, ex < 2 ** 255, A * (10 ** 4 + dl) < 2 ** 256))

# ---------------------------------------------------------------- MATH-UO-75i band products saturate
# MATH-UO-75 verifies: SPEC-ORC-011


def fixed_mul(x, y):
    """LPPriceMath._fixedMul: sticky saturation, else floor(x * y / 10^8), saturating when x * y needs 257 bits."""
    if x == SAT or y == SAT:
        return SAT
    return x * y // E if x * y < 2 ** 256 else SAT


def fixed_product(xs):
    acc = xs[0]
    for z in xs[1:]:
        acc = fixed_mul(acc, z)
    return acc


steps, acc = [], M
for k in range(2, 9):
    raw = acc * M
    acc = fixed_mul(acc, M)
    steps.append(f'{k} factors: raw {raw:.2e} -> {"saturated" if acc == SAT else f"{acc:.2e}"}')
exact8 = M ** 8 // E ** 7
note('MATH-UO-75i', 'USD-band product of eight quotes at 10^18: the exact value 10^88 exceeds 2^256 (about 1.16e77), so '
     'the product saturates at the seventh factor and stays saturated; the implementation returns 2^256 - 1, the '
     'defined value, never a revert or a wrapped number',
     '; '.join(steps) + f'; exact 10^144 / 10^56 = {exact8:.2e} > 2^256: {exact8 > 2 ** 256}')
assert fixed_product([M] * 8) == SAT and fixed_product([M] * 6) == 10 ** 68 and exact8 > 2 ** 256

# ---------------------------------------------------------------- MATH-UO-75j level and band test agree under saturation
# MATH-UO-75 verifies: SPEC-ORC-011, REQ-ORACLE-042
low, P, Ls, pl, pL, pL1, level = Ints('usdBandLow product levelSearch powLow powLevel powLevelPlus1 level')
search = [Ls >= 0, pL <= P, pL1 > P, Implies(low <= Ls, pl <= pL), Implies(low >= Ls + 1, pl >= pL1)]
prove('MATH-UO-75j', 'usdLevel = 2^256 - 1 when the product saturates, the search value otherwise: for every usdBandLow '
      'in uint256 and every power, usdBandLow <= usdLevel exactly when usdBandLow^(x)n <= product (the band test of '
      'inUsdBand), saturated or not',
      [low >= 0, low <= SAT, P >= 0, P <= SAT, pl >= 0, pl <= SAT,
       Implies(P < SAT, And(search + [level == Ls])), Implies(P == SAT, level == SAT)],
      (low <= level) == (pl <= P))
acc_, h_ = Ints('accumulator base')
step = lambda xv, yv: If(Or(xv == SAT, yv == SAT), SAT, If(xv * yv > SAT, SAT, (xv * yv) / E))
prove('MATH-UO-75k', 'the doubling search of usdLevel stops below 2^129 when the product is not saturated: from h >= 10^8 '
      'every step acc (x) h is >= acc, and h >= 2^128 saturates h (x) h, so h^(x)n = 2^256 - 1 > product for every '
      'n >= 2 and the loop exits before hi * 2 could overflow',
      [acc_ >= 0, acc_ <= SAT, h_ >= E, h_ <= SAT],
      And(step(acc_, h_) >= acc_, Implies(h_ >= U128, step(h_, h_) == SAT)))
hi_ = Ints('hi')[0]
witness('MATH-UO-75l', 'wrong reading (no early return on a saturated product): every power is <= 2^256 - 1, so the '
        'doubling condition h^(x)n <= product stays true and hi * 2 passes 2^256 (a checked-arithmetic revert)',
        [P == SAT, hi_ >= 2 ** 255, hi_ <= SAT, step(hi_, hi_) <= P, hi_ * 2 > SAT])

# ---------------------------------------------------------------- MATH-UO-75m listing reason
# MATH-UO-75 verifies: REQ-ORACLE-049
wbtc, eth = 100_000 * E, 12_000 * E
note('MATH-UO-75m', 'why 10^18: a WBTC route near $100,000 and an ETH route above $10,000 are valid route values',
     f'WBTC {wbtc:.0e} <= 10^18: {wbtc <= M}, <= old 10^12: {wbtc <= 10 ** 12}; ETH at $12,000 {eth:.1e} <= 10^18: '
     f'{eth <= M}, <= old 10^12: {eth <= 10 ** 12}; headroom over WBTC {M // wbtc:,}x')
assert wbtc <= M < 2 ** 63 and wbtc > 10 ** 12 and eth > 10 ** 12

finish()
