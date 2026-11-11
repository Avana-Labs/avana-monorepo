# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Wind-down ramp of an offboarding market (2.8 REQ-CONFIG-080).

The MarketRegistry's `stepWindDown` records and announces the liquidation threshold of the linear ramp
    LT(e) = LT0 - floor((LT0 - LTf) * min(e, R) / R)      for LT0 > LTf, else LT(e) = LT0,
with LT0 the reserve's collateral factor when offboarding began (bps), LTf = 5,000 bps the final threshold,
R = 30 days the ramp length and e >= 0 the seconds elapsed since the notice ended (offboardedAt + 5 days).
Steps are at least one day apart. Everything is an exact integer in bps and seconds.
"""
from z3 import Int, Real, If, And
from _common import prove, computed, finish, floor_div

R = 30 * 86_400
LTF = 5_000
BPS = 10**4

lt0, e, e2 = Int('lt0'), Int('e'), Int('e2')
d, p1, p2 = Int('d'), Int('p1'), Int('p2')

# MATH-AR-70 verifies: REQ-CONFIG-080
# Proved over the reals (complete non-linear real arithmetic), so it holds for every integer instance.
rd, rs1, rs2 = Real('rd'), Real('rs1'), Real('rs2')
prove('MATH-AR-70a', 'lemma: for 0 <= d and 0 <= s1 <= s2 <= R, 0 <= d*s1 <= d*s2 <= d*R',
      [rd >= 0, rd < BPS, rs1 >= 0, rs1 <= rs2, rs2 <= R],
      And(0 <= rd * rs1, rd * rs1 <= rd * rs2, rd * rs2 <= rd * R))

# With the lemma, the products p_i = d * s_i (d = LT0 - LTf, s_i = min(e_i, R)) are linear unknowns.
drop1, f1 = floor_div(p1, R, 'drop1')
drop2, f2 = floor_div(p2, R, 'drop2')
lemma = [d > 0, d < BPS, 0 <= p1, p1 <= p2, p2 <= d * R]

# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70b', 'the ramp stays within [LTf, LT0]: 0 <= drop <= LT0 - LTf',
      lemma + f1, And(drop1 >= 0, drop1 <= d))

# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70c', 'the ramp never rises: a later step drops at least as much as an earlier one',
      lemma + f1 + f2, drop2 >= drop1)


def ramp(start, elapsed, name):
    span = If(elapsed < R, elapsed, R)
    drop, cons = floor_div((start - LTF) * span, R, name)
    return If(start <= LTF, start, start - drop), cons


lt_e, c1 = ramp(lt0, e, 'dropE')
base = [lt0 > 0, lt0 < BPS, e >= 0]

# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70d', 'from the end of the ramp the threshold is LTf (when LT0 > LTf)',
      base + c1 + [lt0 > LTF, e >= R], lt_e == LTF)

# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70e', 'a start at or below LTf never moves, and every result fits uint16',
      base + c1 + [lt0 <= LTF], And(lt_e == lt0, lt_e < 2**16))


def ramp_int(start, elapsed):
    if start <= LTF:
        return start
    return start - (start - LTF) * min(elapsed, R) // R


# MATH-AR-70 verifies: REQ-CONFIG-080
computed('MATH-AR-70f', 'REQ-CONFIG-080 worked example and the unit-test vectors', [
    ('8,000 bps at the notice end (day 5)', 8_000, ramp_int(8_000, 0)),
    ('8,000 bps at day 20 (15 of 30 days)', 6_500, ramp_int(8_000, 15 * 86_400)),
    ('8,000 bps at day 35 (ramp end)', 5_000, ramp_int(8_000, R)),
    ('HF 1.30 under 8,000 falls to 1.30 x 5,000 / 8,000 = 0.8125', 8_125, 13_000 * 5_000 // 8_000),
    ('7,500 bps at day 20 (15 of 30 days)', 6_250, ramp_int(7_500, 15 * 86_400)),
    ('7,500 bps at day 40 (past the ramp)', 5_000, ramp_int(7_500, 35 * 86_400)),
    ('4,000 bps (below LTf) never moves', 4_000, ramp_int(4_000, R)),
])

finish()
