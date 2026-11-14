# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-06..09 — full-range token amounts per liquidity unit, the full-range error eps,
Uniswap removal rounding and the principal-capped collect ([2.10] SPEC-ORC-006, SPEC-ORC-007,
[2.4] SPEC-UNIT-003, [2.3] SPEC-BACK-008).

  ideal:              q0 = L / sP,              q1 = L * sP
  exact (Uniswap):    e0 = L * (1/sP - 1/sU),   e1 = L * (sP - sL)
  where sP = sqrt(P_raw), sL / sU = sqrt price at the pool's min / max USABLE tick for its spacing.
  Uniswap burn / LiquidityAmounts (both round down):
    amount0 = floor( floor(L * 2^96 * (SU - SP) / SU) / SP ),   amount1 = floor(L * (SP - SL) / 2^96)
  with SP, SL, SU the Q64.96 integers.
"""
import os
import sys
from fractions import Fraction as F
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Real, Reals, Ints, And, If, RealVal
from _common import (prove, note, finish, MAX_FULL_RANGE_EPSILON_INV, TOKENS, LAUNCH_PAIRS, pool_order, TICK_SPACINGS,
                     usable_ticks, sqrt_ratio_at_tick, Q96, MIN_SQRT_RATIO)

# ---------------------------------------------------------------------------
# MATH-UO-06  The idealised formula overstates each leg; exact relative errors.
L, sL, sP, sU = Reals('L sL sP sU')
base = [L > 0, sL > 0, sL < sP, sP < sU]
q0, q1 = L / sP, L * sP
e0, e1 = L * (1 / sP - 1 / sU), L * (sP - sL)
# MATH-UO-06 verifies: SPEC-ORC-006, SPEC-UNIT-003
prove('MATH-UO-06a', 'e0 <= q0 and q0 - e0 == q0 * (sP/sU)', base, And(e0 <= q0, q0 - e0 == q0 * (sP / sU)))
# MATH-UO-06 verifies: SPEC-ORC-006, SPEC-UNIT-003
prove('MATH-UO-06b', 'e1 <= q1 and q1 - e1 == q1 * (sL/sP)', base, And(e1 <= q1, q1 - e1 == q1 * (sL / sP)))
Pr = sP * sP
v_ideal = 2 * L * sP                      # value at the reference price, token1 raw units
v_exact = e0 * Pr + e1
eps = (sP / sU + sL / sP) / 2
# MATH-UO-06 verifies: SPEC-ORC-006, SPEC-UNIT-003
prove('MATH-UO-06c', 'value at reference price: exact == ideal * (1 - eps), eps = (sP/sU + sL/sP)/2 > 0',
      base, And(v_exact == v_ideal * (1 - eps), v_exact < v_ideal))

# ---------------------------------------------------------------------------
# MATH-UO-07  Size of eps for every launch pair and fee tier, over a LISTING_SHOCK_FACTOR (100x)
#             price shock either way: below MAX_FULL_RANGE_EPSILON = 1e-12 (and so below 1e-9).
rows = []
for s in TICK_SPACINGS:
    lo, hi = usable_ticks(s)
    SL, SU = sqrt_ratio_at_tick(lo), sqrt_ratio_at_tick(hi)
    for a, b in LAUNCH_PAIRS:
        t0, t1 = pool_order(a, b)
        praw = F(10 ** TOKENS[t1], 10 ** TOKENS[t0])          # $1 legs
        # sP = sqrt(P_raw); exact rational here because P_raw is 1 or 1e-12
        sp_mid = F(1) if praw == 1 else F(1, 10 ** 6)
        e_mid = (sp_mid * Q96 / SU + F(SL, Q96) / sp_mid) / 2
        x = Real('sP')
        hyps = [x >= sp_mid / 10, x <= sp_mid * 10]          # P_raw shocked by 1/100 .. 100x
        epsx = (x * RealVal(F(Q96)) / RealVal(SU) + RealVal(F(SL, Q96)) / x) / 2
        # MATH-UO-07 verifies: SPEC-ORC-006, SPEC-UNIT-003
        r = prove(f'MATH-UO-07[{a}/{b},s={s}]', f'eps < 1e-12 for P_raw in [P/100, 100P] (eps at $1 = {float(e_mid):.2e})',
                  hyps, epsx < RealVal(F(1, MAX_FULL_RANGE_EPSILON_INV)))
        rows.append((s, a, b, float(e_mid)))
worst = max(rows, key=lambda r: r[3])
# MATH-UO-07 verifies: SPEC-ORC-006
note('MATH-UO-07z', 'largest eps at $1 legs across launch pairs and fee tiers',
     f'spacing {worst[0]}, {worst[1]}/{worst[2]}: eps = {worst[3]:.3e} '
     f'(MAX_FULL_RANGE_EPSILON = 1e-12 holds with a margin of more than 30x)')

# ---------------------------------------------------------------------------
# MATH-UO-08  Uniswap's own rounding on removal (roundUp = false) loses < 1 raw unit per leg
#             (plus < 1/SP for amount0) versus the exact amounts at the same Q64.96 prices.
Lr, SLr, SPr, SUr, t, a0, a1 = Reals('L SL SP SU t amount0 amount1')
hyps = [Lr >= 1, SLr >= MIN_SQRT_RATIO, SLr < SPr, SPr < SUr]
N = Lr * Q96 * (SUr - SPr)
ex0 = N / (SUr * SPr)
ex1 = Lr * (SPr - SLr) / Q96
# floors relaxed to their defining intervals (integrality only tightens the bound)
fl = [t <= N / SUr, t > N / SUr - 1, a0 <= t / SPr, a0 > t / SPr - 1,
      a1 <= ex1, a1 > ex1 - 1]
# MATH-UO-08 verifies: SPEC-ORC-006, SPEC-BACK-008, SPEC-UNIT-003
prove('MATH-UO-08a', 'amount0 <= exact0 and exact0 - amount0 < 1 + 1/SP (< 1.0000000003 raw units)',
      hyps + fl, And(a0 <= ex0, ex0 - a0 < 1 + 1 / SPr))
# MATH-UO-08 verifies: SPEC-ORC-006, SPEC-BACK-008, SPEC-UNIT-003
prove('MATH-UO-08b', 'amount1 <= exact1 and exact1 - amount1 < 1 raw unit', hyps + fl, And(a1 <= ex1, ex1 - a1 < 1))

# ---------------------------------------------------------------------------
# MATH-UO-09  AM-GM lower bound in the exact (tick-bounded) form: holdings at ANY pool price sQ,
#             valued at the reference price P = sP^2, are worth at least the holdings at sP.
sQ = Real('sQ')
hyps = base + [sQ > sL, sQ < sU]
held_at_Q = L * (1 / sQ - 1 / sU) * Pr + L * (sQ - sL)
# MATH-UO-09 verifies: SPEC-ORC-007
prove('MATH-UO-09', 'value_at_P(holdings at sQ) >= value_at_P(holdings at sP) (pool manipulation cannot inflate)',
      hyps, held_at_Q >= v_exact)

# ---------------------------------------------------------------------------
# MATH-UO-08c  Principal-capped collect (SPEC-BACK-008): decreaseLiquidity moves principal (a0, a1)
#              into tokensOwed on top of accrued fees f; collect(amount0Max = a0, amount1Max = a1)
#              pays min(owed, max) = a exactly and leaves the fees owed to the NFT; the recipient
#              receives r <= c (transfer fee) and Collateralization books min(r, a).
o0, f0, a0_, c0_, r0_, booked = Ints('owedBefore fees a0 c0 r0 booked0')
capped = [o0 >= 0, f0 >= 0, a0_ >= 0, o0 == f0,                      # owed before the removal = fees
          c0_ == If(o0 + a0_ < a0_, o0 + a0_, a0_),                  # collect pays min(owed, a0)
          r0_ >= 0, r0_ <= c0_, booked == If(r0_ < a0_, r0_, a0_)]
# MATH-UO-08 verifies: SPEC-BACK-008, REQ-VAULT-059
prove('MATH-UO-08c', 'capped collect pays exactly the principal a0, leaves exactly the accrued fees owed, and books min(r0, a0) = r0 <= a0',
      capped, And(c0_ == a0_, (o0 + a0_) - c0_ == f0, booked == r0_, booked <= a0_))

finish()
