# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-68..69 — the feed-agreement tolerance lower bound over every route pair a standby switch can put in force
([2.9] REQ-CONFIG-024, [2.8] REQ-MREG-027).

  recorded routes of a token: primary P, alternate A, standby S, with summed deviation thresholds dP, dA, dS (bps)
  a guardian's useStandbyRoute puts S in place of P or of A at once, so the pairs in force are (P, A), (S, A), (P, S)
  bound:  Tmin = max(dP + dA, dS + dA, dP + dS) + m,  m = feedAgreementMarginBps
  every tolerance setter, setFeed and setFeedAgreementMarginBps require the stored T >= Tmin (saturated at 2^16 - 1)
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, Or, If
from _common import prove, witness, note, finish

dP, dA, dS, m, T = Ints('dP dA dS margin T')
dom = [dP >= 0, dA >= 0, dS >= 0, m >= 0, dP <= 10 ** 4, dA <= 10 ** 4, dS <= 10 ** 4, m <= 10 ** 4, T >= 0,
       T <= 10 ** 4]


def mx(x, y):
    return If(x > y, x, y)


tmin = mx(mx(dP + dA, dS + dA), dP + dS) + m

# ---------------------------------------------------------------------------
# MATH-UO-68 verifies: REQ-CONFIG-024, REQ-MREG-027
prove('MATH-UO-68a',
      'a stored tolerance T >= max(dP + dA, dS + dA, dP + dS) + m meets the in-force bound d1 + d2 + m for every route '
      'pair a standby switch can produce, so no guardian switch leaves the token below its bound',
      dom + [T >= tmin],
      And(T >= dP + dA + m, T >= dS + dA + m, T >= dP + dS + m))
# MATH-UO-68 verifies: REQ-CONFIG-024, REQ-MREG-027
prove('MATH-UO-68b', 'the bound is the least such value: it equals the in-force bound of one of the three pairs',
      dom, Or(tmin == dP + dA + m, tmin == dS + dA + m, tmin == dP + dS + m))
# MATH-UO-68 verifies: REQ-CONFIG-024
witness('MATH-UO-68c',
        'wrong reading (bound over the routes in force only): T = dP + dA + m passes, then the standby in place of the '
        'primary leaves T below dS + dA + m (25/25/120 bps, m = 50: T = 100 < 195)',
        dom + [dP == 25, dA == 25, dS == 120, m == 50, T == dP + dA + m, T < dS + dA + m])
# MATH-UO-68 verifies: REQ-CONFIG-024
prove('MATH-UO-68d', 'with no standby (dS = 0) the bound is the recorded pair dP + dA + m',
      dom + [dS == 0], tmin == dP + dA + m)

# ---------------------------------------------------------------------------
# MATH-UO-69 verifies: REQ-CONFIG-024
note('MATH-UO-69', 'REQ-CONFIG-024 examples',
     f'25/25/25, m 50: {max(25 + 25, 25 + 25, 25 + 25) + 50}; 25/25/120, m 50: {max(50, 145, 145) + 50}; '
     f'40/25/120, m 50: {max(65, 145, 160) + 50}; USDC 25 / 150 (100 x 50) / standby 25, m 50: '
     f'{max(25 + 150, 25 + 150, 25 + 25) + 50}')

finish()
