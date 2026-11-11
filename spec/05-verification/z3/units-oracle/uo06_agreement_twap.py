# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-22..24 — primary-vs-alternate agreement, the TWAP ratio check and the USD band: what
they can and cannot catch ([2.10] SPEC-ORC-003, SPEC-ORC-010, SPEC-ORC-011).

  per token i: true price t_i, primary p_i, alternate b_i, served s_i (p_i, or b_i after failover)
  agreement (when both routes are valid):  |p_i - b_i| <= T * min(p_i, b_i)
  TWAP gate: pool ratio R = t0/t1 (arbitraged pool), passes iff  1/g <= R / (s0/s1) <= g,  g = 1.0001^tau
  overvaluation factor of the vault token:  O = sqrt(s0*s1 / (t0*t1))   (value = 2*sqrt(s0*s1))
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Real, Reals, Int, Ints, And, Or, If, Implies, BitVec, BitVecVal, ULE, ULT, UGT, BVMulNoOverflow
from _common import prove, witness, finish

t0, t1, p0, p1, b0, b1, s0, s1, T, g, O = Reals('t0 t1 p0 p1 b0 b1 s0 s1 T g O')
pos = [t0 > 0, t1 > 0, p0 > 0, p1 > 0, b0 > 0, b1 > 0, s0 > 0, s1 > 0, O > 0]
params = [T > 0, T <= 0.02, g > 1, g <= 1.0001 ** 200]        # T <= 2%, tau <= 200 ticks


def mn(x, y):
    return If(x < y, x, y)


def agree(p, b):
    return And(p - b <= T * mn(p, b), b - p <= T * mn(p, b))


R = t0 / t1
twap_ok = And(R * s1 / s0 <= g, s0 / (s1 * R) <= g)
O_def = O * O * t0 * t1 == s0 * s1

# ---------------------------------------------------------------------------
# MATH-UO-22  Common-mode error: every route of both tokens off by the same factor k passes every check.
k = Real('k')
# MATH-UO-22 verifies: SPEC-ORC-003, SPEC-ORC-010, SPEC-ORC-011
witness('MATH-UO-22a',
        'why the USD band exists: all four routes report k x true (k = 2): agreement and TWAP both pass, collateral overvalued 2x',
        pos + params + [t0 == 1, t1 == 1, k == 2, p0 == k * t0, b0 == k * t0, p1 == k * t1, b1 == k * t1,
                        s0 == p0, s1 == p1, agree(p0, b0), agree(p1, b1), twap_ok, O_def, O >= 2])
# MATH-UO-22 verifies: SPEC-ORC-010, MKT-005
witness('MATH-UO-22b',
        'why the two tokens\' alternate routes share no intermediate feed: alternates through one shared X/ETH x ETH/USD leg carry the same error k and pass the TWAP gate',
        pos + params + [t0 == 1, t1 == 1, k == 1.5, s0 == k * t0, s1 == k * t1, twap_ok, O_def, O >= 1.5])

# Band: with true prices at or below peg and a common factor k, sqrt(q0*q1) <= k * $1, so any
# downward common-mode error with k < usdBandLow / $1 is out of band (Drifting, USD_BAND).
lowr, sq = Reals('usdBandLow_ratio sqrt_q0q1')
# MATH-UO-22 verifies: SPEC-ORC-011
prove('MATH-UO-22c', 'the USD band catches a downward common-mode error: k < usdBandLow with true prices <= $1 gives sqrt(q0*q1) < usdBandLow',
      [t0 > 0, t0 <= 1, t1 > 0, t1 <= 1, k > 0, lowr > 0, k < lowr, sq >= 0, sq * sq == k * t0 * k * t1],
      sq < lowr)

# ---------------------------------------------------------------------------
# MATH-UO-23  What the checks DO bound.
# MATH-UO-23 verifies: SPEC-ORC-003
prove('MATH-UO-23a',
      'both routes report and alternates are correct (b_i = t_i): served value overvalued by at most factor (1 + T)',
      pos + params + [b0 == t0, b1 == t1, s0 == p0, s1 == p1, agree(p0, b0), agree(p1, b1), twap_ok, O_def],
      O <= 1 + T)
# MATH-UO-23 verifies: SPEC-ORC-010
prove('MATH-UO-23b',
      'only ONE token mispriced on all its routes (other token correct): TWAP bounds overvaluation by sqrt(g) (~ tau/2 bps)',
      pos + params + [s1 == t1, twap_ok, O_def], O * O <= g)
# MATH-UO-23 verifies: SPEC-ORC-010, SPEC-ORC-011
witness('MATH-UO-23c',
        'why the band is needed besides TWAP: mispricing split between the two tokens in the same direction escapes the TWAP gate even with tau = 0 ticks',
        pos + [t0 == 1, t1 == 1, g == 1, s0 == 1.3 * t0, s1 == 1.3 * t1, twap_ok, O_def, O > 1.29])

# ---------------------------------------------------------------------------
# MATH-UO-24  Integer implementation of the agreement tolerance (8-decimal answers, T in bps).
pi, bi, Tb = Ints('primary backup T_bps')
dev_floor = (If(pi > bi, pi - bi, bi - pi) * 10000) / bi           # Solidity floor division
exact_ok = If(pi > bi, pi - bi, bi - pi) * 10000 <= Tb * If(pi < bi, pi, bi)
# MATH-UO-24 verifies: SPEC-ORC-003
witness('MATH-UO-24a',
        'wrong reading: deviation computed as floor(|p-b|*1e4 / b) <= T passes a deviation the exact rule (cross-multiplied, vs min) rejects',
        [pi >= 9 * 10 ** 7, bi >= 9 * 10 ** 7, pi <= 11 * 10 ** 7, bi <= 11 * 10 ** 7, Tb == 50, dev_floor <= Tb, exact_ok == False])
dev_cross = If(pi > bi, pi - bi, bi - pi) * 10000
# MATH-UO-24 verifies: SPEC-ORC-003
prove('MATH-UO-24b', 'cross-multiplied rule |p-b|*1e4 <= T*min(p,b) is symmetric in (primary, alternate) for every T: both sides are symmetric terms',
      [pi >= 1, bi >= 1, Tb >= 0, Tb <= 10000],
      And(If(pi > bi, pi - bi, bi - pi) == If(bi > pi, bi - pi, pi - bi), If(pi < bi, pi, bi) == If(bi < pi, bi, pi)))

pb, bb, Tbv = BitVec('p', 256), BitVec('b', 256), BitVec('T', 256)
# MATH-UO-24 verifies: SPEC-ORC-003
prove('MATH-UO-24c', 'p, b <= MAX_ROUTE_ANSWER and T < 2^16: |p-b|*1e4 and T*min(p,b) fit in 256 bits',
      [ULE(pb, BitVecVal(10 ** 12, 256)), ULE(bb, BitVecVal(10 ** 12, 256)), ULT(Tbv, BitVecVal(2 ** 16, 256))],
      And(BVMulNoOverflow(If(UGT(pb, bb), pb - bb, bb - pb), BitVecVal(10 ** 4, 256), False),
          BVMulNoOverflow(Tbv, If(ULT(pb, bb), pb, bb), False)))

finish()
