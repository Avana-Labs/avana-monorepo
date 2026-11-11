# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-14..18 — LPOracle output: USD price of ONE WHOLE vault token, 8 decimals
([2.10] SPEC-ORC-008, SPEC-ORC-001, SPEC-ORC-002).

  a0, a1  valuation prices v0, v1 (8 decimals, normalised per SPEC-ORC-001, stable ceiling applied)
  ideal   = 2 * sqrt(a0 * a1)                       (MATH-UO-02a; 2d = d0 + d1)
  price8  = Math.sqrt(4 * a0 * a1) - 1              (SPEC-ORC-008: round down, then one unit down)
  actual holdings at the reference price are worth ideal * (1 - eps)   (MATH-UO-06c)
In the checks below `price8` names the floored square root and `price8_fixed` the served value
isqrt(4*a0*a1) - 1; MATH-UO-16a shows why the extra unit is subtracted.
"""
import math
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import (Int, Ints, Real, Reals, And, Or, If, BitVec, BitVecVal, ULE, ULT, UDiv,
                BVMulNoOverflow, Extract)
from _common import prove, witness, note, finish, PRICE_ONE, MAX_ROUTE_ANSWER

A_MAX = MAX_ROUTE_ANSWER   # listing bound on any route value ($10,000, 8 decimals)

# ---------------------------------------------------------------------------
# MATH-UO-14  Rounding direction and error of price8 = isqrt(4*a0*a1).
X, p, w = Reals('X price8 ideal')
iso = [X >= 4, p >= 0, p * p <= X, (p + 1) * (p + 1) > X, w >= 0, w * w == X]   # X = 4*a0*a1, w = 2*sqrt(a0*a1)
# MATH-UO-14 verifies: SPEC-ORC-008
prove('MATH-UO-14a', 'price8 <= ideal (never above the closed-form value)', iso, p <= w)
# MATH-UO-14 verifies: SPEC-ORC-008
prove('MATH-UO-14b', 'ideal - price8 < 1 unit (1e-8 USD); relative error < 1/price8 (<= 1e-8 when a whole token >= $1)',
      iso, w - p < 1)
q, Y = Reals('q Y')
iso2 = [Y >= 1, q >= 0, q * q <= Y, (q + 1) * (q + 1) > Y, w >= 0, w * w == 4 * Y]
# MATH-UO-14 verifies: SPEC-ORC-008
prove('MATH-UO-14c', 'alternative 2*isqrt(a0*a1) is also <= ideal but can be up to 2 units low',
      iso2, And(2 * q <= w, w - 2 * q < 2))
bv = [BitVec(n, 256) for n in ('a0', 'a1')]
b0, b1 = bv
hyp_bv = [ULE(BitVecVal(1, 256), b0), ULE(b0, BitVecVal(A_MAX, 256)),
          ULE(BitVecVal(1, 256), b1), ULE(b1, BitVecVal(A_MAX, 256))]
four = BitVecVal(4, 256)
# MATH-UO-14 verifies: SPEC-ORC-008, SPEC-ORC-002
prove('MATH-UO-14d', f'answers <= {A_MAX:.0e}: 4*a0*a1 does not overflow uint256 and price8 < 2^255 (int256 cast safe)',
      hyp_bv, And(BVMulNoOverflow(b0, b1, False), BVMulNoOverflow(four, b0 * b1, False),
                  ULT(b0 * b1 * four, BitVecVal(2 ** 255, 256))))

# ---------------------------------------------------------------------------
# MATH-UO-15  Never 0: positive answers give a served price8 >= 1.
# MATH-UO-15 verifies: SPEC-ORC-008
prove('MATH-UO-15a', 'a0, a1 >= 1  =>  floored root > 1 (so >= 2), hence served price8 = root - 1 >= 1; AaveOracle never sees 0', iso, p > 1)
raw, f = Ints('raw feedDecimals')
pw = If(f == 8, 1, If(f == 9, 10, If(f == 10, 100, If(f == 12, 10 ** 4, If(f == 18, 10 ** 10, 10 ** 20)))))
a_norm = raw / pw
# MATH-UO-15 verifies: SPEC-ORC-001
witness('MATH-UO-15b', 'why a normalised 0 is a failure: a feed with > 8 decimals and a tiny positive answer normalises (floor) to 0',
        [Or(f == 8, f == 9, f == 10, f == 12, f == 18), raw >= 1, raw <= 10 ** 30, a_norm == 0])
# MATH-UO-15 verifies: SPEC-ORC-001
prove('MATH-UO-15c', '8-decimal feeds with answer > 0 never normalise to 0',
      [f == 8, raw >= 1], a_norm >= 1)

# ---------------------------------------------------------------------------
# MATH-UO-16  "Never overvalue" against the ACTUAL Uniswap holdings (ideal * (1 - eps)).
eps = Real('eps')
EPS_LAUNCH = 2.72e-14              # largest eps over launch pairs and fee tiers (MATH-UO-07z)
# MATH-UO-16 verifies: SPEC-ORC-008
witness('MATH-UO-16a',
        'wrong reading without the - 1: isqrt(4*a0*a1) can exceed the true value ideal*(1-eps) when 4*a0*a1 is a perfect square (e.g. both legs exactly $1.00000000)',
        iso + [X == 4 * PRICE_ONE * PRICE_ONE, eps > 0, eps <= EPS_LAUNCH, p == w, p > w * (1 - eps)])
pf = Real('price8_fixed')
# MATH-UO-16 verifies: SPEC-ORC-008, SPEC-UNIT-003
prove('MATH-UO-16b', 'final: price8 = isqrt(4*a0*a1) - 1 is <= ideal*(1-eps) whenever ideal*eps < 1 (ideal < 3.6e13 for launch eps)',
      iso + [eps > 0, w * eps < 1, pf == p - 1], pf <= w * (1 - eps))
# MATH-UO-16 verifies: SPEC-ORC-008
prove('MATH-UO-16c', 'final formula keeps price8 > 0 for every positive answer pair (price8_fixed >= 1)',
      iso + [pf == p - 1], pf > 0)
ex = 4 * PRICE_ONE * PRICE_ONE
# MATH-UO-16 verifies: SPEC-ORC-008
note('MATH-UO-16d', 'size of the overvaluation in MATH-UO-16a',
     f'a0 = a1 = 1e8: price8 = {math.isqrt(ex)} exactly; true value of holdings = 2e8 * (1 - 2.72e-14) '
     f'= {2e8 * (1 - 2.72e-14):.10f}.\nOver by 5.4e-6 of one 8-decimal unit per whole token: about $5.4e-14 per $2, '
     'i.e. $2.7e-5 per $1B of collateral. The served price subtracts one unit so the rule holds strictly.')

# ---------------------------------------------------------------------------
# MATH-UO-17  Max relative error of the served price versus actual holdings (launch eps, final formula).
# MATH-UO-17 verifies: SPEC-ORC-008
prove('MATH-UO-17', 'final formula, whole token in [$1, $10,000] (ideal in [1e8, 1e12]): 0 <= (true - price8_fixed)/true < 2.1e-8',
      iso + [w >= 10 ** 8, w <= 10 ** 12, eps > 0, eps <= EPS_LAUNCH, pf == p - 1],
      And(pf <= w * (1 - eps), (w * (1 - eps) - pf) < 2.1e-8 * w * (1 - eps)))

# ---------------------------------------------------------------------------
# MATH-UO-18  Symmetry: swapping (a0,d0) <-> (a1,d1) (token order or feed assignment) leaves price8 unchanged.
x0, x1 = Ints('a0 a1')
# MATH-UO-18 verifies: SPEC-ORC-008
prove('MATH-UO-18', '4*a0*a1 == 4*a1*a0: the closed form cannot be broken by token0/token1 orientation',
      [x0 >= 1, x1 >= 1], 4 * x0 * x1 == 4 * x1 * x0)

finish()
