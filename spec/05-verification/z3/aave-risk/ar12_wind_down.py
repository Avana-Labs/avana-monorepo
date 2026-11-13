# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""One-step offboarding target of a market (2.8 REQ-CONFIG-080, 3.8 MKT-059).

`setMarketOffboarding` records LT0, the reserve's collateral factor (bps), and publishes the target
    T = floor(LT0 * S / 10,000),      S = windDownFinalLtBps = 5,000 bps of LT0,
with the earliest date offboardedAt + N, N = 5 days. After that date the Aave DAO lowers the threshold once, to T.
Everything is an exact integer in bps and seconds.
"""
from z3 import Int, And, Implies
from _common import prove, computed, finish, floor_div

S = 5_000
BPS = 10**4
N = 5 * 86_400

lt0, hf = Int('lt0'), Int('hf')
t, ct = floor_div(lt0 * S, BPS, 'target')
base = [lt0 > 0, lt0 < BPS]

# MATH-AR-70 verifies: REQ-CONFIG-080, MKT-059
prove('MATH-AR-70a', 'the target is half LT0 rounded down (2T in {LT0 - 1, LT0}), never 0 and below LT0 for LT0 >= 2',
      base + ct, And(t >= 0, 2 * t <= lt0, 2 * t >= lt0 - 1, Implies(lt0 >= 2, And(t >= 1, t < lt0))))

# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70b', 'every target fits uint16 (the WindDownState field)', base + ct, And(t >= 0, t < 2**16))

lt1 = Int('lt1')
t1, ct1 = floor_div(lt1 * S, BPS, 'target1')
# MATH-AR-70 verifies: REQ-CONFIG-080
prove('MATH-AR-70c', 'a higher threshold at offboarding never gives a lower target (monotone)',
      base + ct + ct1 + [lt1 >= lt0, lt1 < BPS], t1 >= t)

# MATH-AR-70 verifies: REQ-CONFIG-080, MKT-059
# Health factor scales with the threshold: hf' = floor(hf * T / LT0) (in bps of HF), so with an even LT0 an account at
# health factor 2 or more at offboarding stays at or above 1 after the drop; one below 2 falls below 1.
hfa, chf = floor_div(hf * t, lt0, 'hfAfter')
k = Int('k')
prove('MATH-AR-70d', 'with an even LT0, an account at HF >= 2 (20,000 bps) keeps HF >= 1 after the drop to T',
      base + ct + chf + [lt0 == 2 * k, hf >= 20_000], hfa >= 10_000)
prove('MATH-AR-70f', 'with an even LT0, an account below HF 2 falls below HF 1 after the drop to T',
      base + ct + chf + [lt0 == 2 * k, hf >= 0, hf < 20_000], hfa < 10_000)


# MATH-AR-70 verifies: REQ-CONFIG-080, MKT-059
computed('MATH-AR-70e', 'REQ-CONFIG-080 and MKT-059 worked examples and the unit-test vectors', [
    ('8,000 bps -> target', 4_000, 8_000 * S // BPS),
    ('HF 1.30 under 8,000 falls to 1.30 x 4,000 / 8,000 = 0.65', 6_500, 13_000 * 4_000 // 8_000),
    ('7,500 bps -> target', 3_750, 7_500 * S // BPS),
    ('6,100 bps -> target', 3_050, 6_100 * S // BPS),
    ('4,201 bps -> target (rounds down)', 2_100, 4_201 * S // BPS),
    ('MKT-059: 3,400 bps -> 1,700; HF 1.70 -> 0.85', 8_500, 17_000 * 1_700 // 3_400),
    ('3.8 walkthrough: 3,120 bps -> 1,560; Carol HF 20,000 x 0.156 / 5,000', 6_240, 20_000 * 1_560 // 5_000),
    ('earliest date: offboardedAt + 432,000 s', 432_000, N),
])

finish()
