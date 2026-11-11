# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-39..41 — charge basis after a re-credit, rescue units and the pledge counter increments
([2.3] SPEC-BACK-004, SPEC-BACK-013, SPEC-BACK-014; [2.3] REQ-COLL-016).

  re-credit:  u_b = credited after reconciliation, c_b = currentUsdCharge = ceil(V0 * u_b / U0);
              added units charged usdCharge:  U0' = u_b + added, C0' = c_b + usdCharge
              later exits: remainingCharge = ceil(C0' * remainingUnits / U0')
  rescue:     rescueUnits = L if rescue, else ceil(L * sliceUsd / usdCharge) if sliceUsd > 0, else 0;
              record.rescueUnits += rescueUnits; after every debit rescueUnits = min(rescueUnits, credited)
  pledge:     Regular += usdCharge - sliceUsd; Slice += sliceUsd; token0, token1, depositor += usdCharge
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, Int, Bool, And, If, Implies, Not
from _common import prove, finish


def ceil_div(q, num, den):
    return [q * den >= num, q * den < num + den]


# ---------------------------------------------------------------------------
# MATH-UO-39  Rebase at re-credit keeps the exit rule's two properties.
U0, V0, ub, cb, add, ch, U1, C1, x, rc, rc2 = Ints('U0 V0 u_b c_b added usdCharge U0p C0p x rem1 rem2')
reb = [U0 >= 1, V0 >= 1, ub >= 1, ub <= U0, add >= 1, ch >= 1, U1 == ub + add, C1 == cb + ch] + ceil_div(cb, V0 * ub, U0)
# MATH-UO-39 verifies: SPEC-BACK-013, SPEC-BACK-005
prove('MATH-UO-39a', 'the record releases V0 - c_b before the re-credit and C0\' after it: V0 + usdCharge over its life, exactly what was booked',
      reb, (V0 - cb) + C1 == V0 + ch)
seq = reb + [x >= 0, x <= U1] + ceil_div(rc, C1 * (U1 - x), U1)
# MATH-UO-39 verifies: SPEC-BACK-013, SPEC-BACK-005
prove('MATH-UO-39b', 'after the rebase: remainingCharge <= C0\', capReleased >= 0, and the last exit (remainingUnits = 0) leaves 0',
      seq, And(rc <= C1, C1 - rc >= 0, (x == U1) == (rc == 0)))
# MATH-UO-39 verifies: SPEC-BACK-013
prove('MATH-UO-39c', 'c_b = ceil(V0 * u_b / U0) <= V0, so the rebased charge C0\' <= V0 + usdCharge and stays < 2^128 when both are below 2^127',
      reb + [V0 < 2 ** 127, ch < 2 ** 127], And(cb <= V0, C1 <= V0 + ch, C1 < 2 ** 128))
# MATH-UO-39 verifies: SPEC-BACK-013, REQ-VAULT-110
prove('MATH-UO-39d', 'the record stores charges as uint64: with V0 < 2^64 and usdCharge < 2^64 the rebased C0\' is below 2^65, so the sum never overflows and the InvalidCharge check C0\' < 2^64 is the only bound a re-credit adds',
      reb + [V0 < 2 ** 64, ch < 2 ** 64], And(C1 < 2 ** 65, cb < 2 ** 64))

# ---------------------------------------------------------------------------
# MATH-UO-40  Rescue units never exceed credited units, per record and per account.
L, sl, uc, ru = Ints('L sliceUsd usdChargeR rescueUnits')
rescue = Bool('rescue')
rcalc = [L >= 1, uc >= 1, sl >= 0, sl <= uc,
         If(rescue, ru == L, If(sl > 0, And(ru * uc >= L * sl, ru * uc < L * sl + uc), ru == 0))]
# MATH-UO-40 verifies: SPEC-BACK-014
prove('MATH-UO-40a', 'rescueUnits <= L, = L when rescue, and >= L * sliceUsd / usdCharge (rounding up excludes at least the slice share)',
      rcalc, And(ru <= L, ru >= 0, Implies(rescue, ru == L), ru * uc >= L * sl))
cr, rr, d, cr2, rr2 = Ints('credited recordRescue debit credited2 recordRescue2')
inv = [cr >= 0, rr >= 0, rr <= cr]
# MATH-UO-40 verifies: SPEC-BACK-014, REQ-COLL-016
prove('MATH-UO-40b', 'pledge or re-credit of L units adds rescueUnits <= L and L credited: rescueUnits <= credited is kept',
      inv + rcalc + [cr2 == cr + L, rr2 == rr + ru], And(rr2 <= cr2, rr2 >= 0))
# MATH-UO-40 verifies: SPEC-BACK-014, REQ-COLL-016
prove('MATH-UO-40c', 'any debit followed by rescueUnits = min(rescueUnits, credited) keeps 0 <= rescueUnits <= credited and never lowers rescue units that still fit',
      inv + [d >= 0, d <= cr, cr2 == cr - d, rr2 == If(rr < cr2, rr, cr2)],
      And(rr2 <= cr2, rr2 >= 0, Implies(rr <= cr2, rr2 == rr)))
cA, rA, cB, rB, accC, accR = Ints('credA rescA credB rescB accountCredited accountRescue')
# MATH-UO-40 verifies: SPEC-BACK-014, REQ-COLL-016
prove('MATH-UO-40d', 'per-account sum: accountRescueUnits = sum of record rescue units <= accountCredited',
      [cA >= 0, cB >= 0, rA >= 0, rB >= 0, rA <= cA, rB <= cB, accC == cA + cB, accR == rA + rB],
      accR <= accC)

# ---------------------------------------------------------------------------
# MATH-UO-41  Pledge increments: market buckets split the charge; token and depositor take it whole.
R, S, T0, T1, Dp, c, s = Ints('Regular Slice token0 token1 depositor usdChargeP sliceUsdP')
pre = [R >= 0, S >= 0, T0 >= 0, T1 >= 0, Dp >= 0, c >= 1, s >= 0, s <= c]
R2, S2 = R + (c - s), S + s
# MATH-UO-41 verifies: SPEC-BACK-004
prove('MATH-UO-41', 'Regular + Slice rise by exactly usdCharge, each by a non-negative part; token0, token1 and depositor rise by usdCharge',
      pre, And(R2 + S2 == R + S + c, R2 >= R, S2 >= S, (T0 + c) - T0 == c, (T1 + c) - T1 == c, (Dp + c) - Dp == c))

finish()
