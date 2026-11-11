# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-19..21 — stable ceiling on valuation prices and the USD band
([2.10] SPEC-ORC-004, SPEC-ORC-010, SPEC-ORC-011).

  SPEC-ORC-004:  v_i = min(q_i, stableCeilingUsd) if isUsdStable[i], else v_i = q_i   (ceiling = 1e8)
  value of one whole token: ideal(v0, v1) = 2 * sqrt(v0 * v1)
  SPEC-ORC-010:  the TWAP reference and the agreement check use the UNCAPPED quotes q_i
  SPEC-ORC-011:  in band iff usdBandLow^2 <= q0 * q1 and v0 * v1 <= usdBandHigh^2
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Real, Reals, Ints, And, If, Implies, Not
from _common import prove, witness, finish, PRICE_ONE, STABLE_CEILING, MAX_ROUTE_ANSWER

C = STABLE_CEILING
q, a, w, wc, w1 = Reals('q_stable q_other ideal ideal_capped ideal_at_ceiling')
cap = If(q < C, q, C)
hyps = [q > 0, a > 0, w > 0, w * w == 4 * q * a, wc > 0, wc * wc == 4 * cap * a,
        w1 > 0, w1 * w1 == 4 * C * a]

# ---------------------------------------------------------------------------
# MATH-UO-19  The ceiling can only lower the value, never raise it; no-op at or below $1; monotone.
# MATH-UO-19 verifies: SPEC-ORC-004
prove('MATH-UO-19a', 'capped value <= uncapped value and <= value with the stable leg exactly at the ceiling', hyps,
      And(wc <= w, wc <= w1))
# MATH-UO-19 verifies: SPEC-ORC-004
prove('MATH-UO-19b', 'stable quote <= $1: the ceiling is a no-op (value unchanged)', hyps,
      Implies(q <= C, wc == w))
q2, wc2 = Reals('q_stable2 ideal_capped2')
cap2 = If(q2 < C, q2, C)
# MATH-UO-19 verifies: SPEC-ORC-004
prove('MATH-UO-19c', 'capped value is monotone non-decreasing in the stable quote (no inversion at the ceiling)',
      hyps + [q2 >= q, wc2 > 0, wc2 * wc2 == 4 * cap2 * a], wc2 >= wc)

# ---------------------------------------------------------------------------
# MATH-UO-20  The TWAP and agreement checks run on uncapped quotes.
tau_factor = 1.0001 ** 50          # example tau = 50 ticks (~0.5%)
qU = Real('q_USDC')
pool_ratio = q / qU                # pool arbitraged to the true market ratio
# MATH-UO-20 verifies: SPEC-ORC-010, SPEC-ORC-004
witness('MATH-UO-20a',
        'wrong reading (ceiling applied before the TWAP check): GHO just above $1.005 with feeds and pool agreeing deviates > tau = 50 ticks -> false Drifting',
        [qU == PRICE_ONE, q > PRICE_ONE, q <= 1.006 * PRICE_ONE,
         pool_ratio / (cap / qU) > tau_factor])
# MATH-UO-20 verifies: SPEC-ORC-010, SPEC-ORC-003
prove('MATH-UO-20b',
      'final rule (uncapped quotes): a stable at any premium whose pool ratio matches its quotes passes the TWAP comparison for every tau >= 0',
      [qU > 0, q > 0, Real('g') >= 1], And(pool_ratio / (q / qU) <= Real('g'), (q / qU) / pool_ratio <= Real('g')))

# USD band in exact integers (8-decimal quotes and band levels).
q0, q1, v0, v1, lo, hi, iq0, iq1 = Ints('q0 q1 v0 v1 usdBandLow usdBandHigh stable0 stable1')
ceil = lambda x: If(x < C, x, C)
bnd = [q0 >= 1, q1 >= 1, q0 <= MAX_ROUTE_ANSWER, q1 <= MAX_ROUTE_ANSWER, lo >= 1, hi >= 1]
# MATH-UO-20 verifies: SPEC-ORC-011
prove('MATH-UO-20c', 'for a market of two stables, v0*v1 <= 1e16, so the upper bound never trips for any usdBandHigh >= $1',
      bnd + [v0 == ceil(q0), v1 == ceil(q1), hi >= PRICE_ONE], v0 * v1 <= hi * hi)
rq, rl = Reals('sqrt_q0q1 low_real')
# MATH-UO-20 verifies: SPEC-ORC-011
prove('MATH-UO-20d', 'the squared integer test low^2 <= q0*q1 is exactly low <= sqrt(q0*q1) (no rounding)',
      [rq >= 0, rq * rq == Real('P'), rl >= 0], (rl * rl <= Real('P')) == (rl <= rq))
# MATH-UO-20 verifies: SPEC-ORC-011, SPEC-ORC-004
prove('MATH-UO-20e', 'a stable above peg is tested at the ceiling: q0 > $1 gives v0 = 1e8, so the upper test reads 1e8 * v1 whatever the premium',
      bnd + [v0 == ceil(q0), q0 > C], v0 == C)

# ---------------------------------------------------------------------------
# MATH-UO-21  An uncapped premium x on one leg raises the value by sqrt(1 + x) <= 1 + x/2.
x, wp = Reals('premium ideal_with_premium')
# MATH-UO-21 verifies: SPEC-ORC-004
prove('MATH-UO-21', 'premium x on one uncapped leg: value rises by factor sqrt(1+x) <= 1 + x/2',
      [a > 0, q > 0, w > 0, w * w == 4 * q * a, x >= 0, x <= 1, wp > 0, wp * wp == 4 * q * a * (1 + x)],
      And(wp >= w, wp <= w * (1 + x / 2)))

finish()
