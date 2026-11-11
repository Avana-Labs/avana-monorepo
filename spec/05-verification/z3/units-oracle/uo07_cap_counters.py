# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-25..29 — USD exposure charges and counters: the pledge charge, the fixed-basis
release on exit, slice-first market counters, the Hub addCap sized at the stress floor and the
counter arithmetic bounds ([2.3] SPEC-BACK-003, SPEC-BACK-004, SPEC-BACK-005, [2.4] SPEC-UNIT-005,
[2.7] SPEC-CAP-001).

  pledge:  usdCharge = mulDiv(c, max(price8, stressFloorUsd), 10^d, Ceil);
           record basis U0 = c, V0 = usdCharge; currentUsdCharge = V0
  exit of x <= unitsBefore units (seizure, reconciliation, partial removal, deleverage, release):
           remainingCharge = mulDiv(V0, unitsBefore - x, U0, Ceil)
           capReleased     = currentUsdCharge - remainingCharge;   currentUsdCharge = remainingCharge
           fromSlice = min(capReleased, Slice);  Slice -= fromSlice;
           Regular   = max(Regular - (capReleased - fromSlice), 0)
           token and depositor counters: max(counter - capReleased, 0)
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import (Int, Ints, Reals, And, If, BitVec, BitVecVal, ULE, ULT, BVAddNoOverflow, BVMulNoOverflow,
                ZeroExt)
from _common import prove, witness, note, finish


def ceil_div(q, num, den):
    """q == ceil(num / den) for den > 0 (num >= 0)."""
    return [q * den >= num, q * den < num + den]


U0, V0, u1, x1, x2, c1, c2, c3 = Ints('U0 V0 unitsBefore x1 x2 charge1 charge2 charge3')
basis = [U0 >= 1, V0 >= 1, V0 < 2 ** 128, U0 < 2 ** 120]

# ---------------------------------------------------------------------------
# MATH-UO-25  Final rule: the charge depends only on the remaining units.
# c(r) = ceil(V0 * r / U0). Two consecutive exits x1, x2 from the full record.
seq = basis + [x1 >= 0, x2 >= 0, x1 + x2 <= U0,
               c1 == V0] + ceil_div(c2, V0 * (U0 - x1), U0) + ceil_div(c3, V0 * (U0 - x1 - x2), U0)
# MATH-UO-25 verifies: SPEC-BACK-005
prove('MATH-UO-25a', 'capReleased >= 0 and remainingCharge <= currentUsdCharge at every exit (charge monotone in remaining units)',
      seq, And(c1 - c2 >= 0, c2 - c3 >= 0, c3 >= 0))
# MATH-UO-25 verifies: SPEC-BACK-005
prove('MATH-UO-25b', 'any split of exits telescopes: released1 + released2 == V0 - c(remaining); a record emptied in two exits releases exactly V0',
      seq, And((c1 - c2) + (c2 - c3) == V0 - c3, ((x1 + x2 == U0) == (c3 == 0))))
r_ = Int('remaining')
# MATH-UO-25 verifies: SPEC-BACK-005
prove('MATH-UO-25c', 'conservative rounding: V0*r/U0 <= remainingCharge < V0*r/U0 + 1 and remainingCharge <= V0',
      basis + [r_ >= 0, r_ <= U0] + ceil_div(c2, V0 * r_, U0),
      And(c2 * U0 >= V0 * r_, c2 * U0 < V0 * r_ + U0, c2 <= V0))

# Counters: R (regular) + S (slice) equals the sum of current charges over the market's records;
# one record's release r <= its charge <= R + S keeps the equality with no clamp firing.
R, S, rel, rest, ch, Tk = Ints('Regular Slice capReleased chargesOfOtherRecords recordCharge tokenCounter')
fs = If(rel < S, rel, S)
R2 = If(R - (rel - fs) > 0, R - (rel - fs), 0)
S2 = S - fs
cnt = [R >= 0, S >= 0, rest >= 0, ch >= 0, rel >= 0, rel <= ch, R + S == rest + ch, Tk >= rest + ch]
# MATH-UO-25 verifies: SPEC-BACK-005, SPEC-BACK-004
prove('MATH-UO-25d', 'slice first: Slice and Regular stay >= 0, the slice drops by min(capReleased, Slice), and Regular + Slice drops by exactly capReleased (saturation never clamps)',
      cnt, And(S2 >= 0, R2 >= 0, S2 == S - fs, R2 + S2 == R + S - rel, R - (rel - fs) >= 0))
# MATH-UO-25 verifies: SPEC-BACK-005
prove('MATH-UO-25e', 'token and depositor counters (>= sum of charges) fall by exactly capReleased; max(counter - capReleased, 0) never clamps',
      cnt, If(Tk - rel > 0, Tk - rel, 0) == Tk - rel)

# ---------------------------------------------------------------------------
# MATH-UO-26  Readings of "pro-rata release" that the fixed-basis rule replaces drift.
V0f, U0f = Ints('V0 U0')
d1, d2 = Ints('d1 d2')
# MATH-UO-26 verifies: SPEC-BACK-005
witness('MATH-UO-26a',
        'wrong reading (fixed V0 / current U): two half-slices of a record decrement 1.5 x V0, wiping other records out of the counter',
        [U0f == 2, V0f == 10 ** 14,
         d1 * 2 <= V0f * 1, V0f * 1 < d1 * 2 + 2,                     # floor(V0 * 1 / 2)
         d2 * 1 <= V0f * 1, V0f * 1 < d2 * 1 + 1,                     # floor(V0 * 1 / 1)
         d1 + d2 > V0f])
H10 = sum(1 / k for k in range(1, 11))
# MATH-UO-26 verifies: SPEC-BACK-005
note('MATH-UO-26b', 'size of the MATH-UO-26a error for n equal slices',
     f'n slices decrement V0 * (1 + 1/2 + ... + 1/n): n = 10 gives {H10:.3f} x V0, i.e. a $1M record\n'
     f'removes ${(H10 - 1):.2f}M of other records from the counter; saturation would hide it.')
e1, e2, e3 = Ints('e1 e2 e3')
# MATH-UO-26 verifies: SPEC-BACK-005
witness('MATH-UO-26c',
        'wrong reading (floor of V0*x/U0 per exit): three 1-unit exits of a 3-unit record leave a residue in the counter',
        [U0f == 3, V0f >= 1, V0f <= 100,
         e1 * 3 <= V0f, V0f < e1 * 3 + 3, e2 == e1, e3 == e1, e1 + e2 + e3 < V0f])

# ---------------------------------------------------------------------------
# MATH-UO-27  Pledge charge and pledge value rounding (d = 18 worst case, also d = 6).
units, p8, flr = Ints('units price8 stressFloorUsd')
for d in (6, 18):
    D = 10 ** d
    if d == 18:
        vfl = units * p8 / D
        # MATH-UO-27 verifies: SPEC-BACK-003, SPEC-CAP-001
        witness(f'MATH-UO-27a[d={d}]', 'wrong reading (floor-rounded charge): a dust pledge at $2 per whole token books 0 and the counters never see it',
                [units >= 1, p8 == 2 * 10 ** 8, vfl == 0])
    vc, bp = Int('usdCharge'), If(p8 > flr, p8, flr)
    # MATH-UO-27 verifies: SPEC-BACK-003, SPEC-CAP-001
    prove(f'MATH-UO-27b[d={d}]',
          'usdCharge = ceil(c * max(price8, floor) / 10^d) is >= 1, >= the value at price8 and >= the value at the stress floor',
          [units >= 1, units < 2 ** 120, p8 >= 1, p8 < 2 ** 64, flr >= 1, flr < 2 ** 64] + ceil_div(vc, units * bp, D),
          And(vc >= 1, vc * D >= units * p8, vc * D >= units * flr))
    pv = Int('pledgeUsd')
    # MATH-UO-27 verifies: SPEC-CAP-001, MKT-043
    prove(f'MATH-UO-27c[d={d}]', 'pledgeUsd = floor(c * price8 / 10^d) never overstates the pledge (minPledgeUsd test is conservative)',
          [units >= 1, units < 2 ** 120, p8 >= 1, p8 < 2 ** 64, pv * D <= units * p8, units * p8 < pv * D + D],
          And(pv * D <= units * p8, pv >= 0))

# ---------------------------------------------------------------------------
# MATH-UO-28  Hub addCap (whole tokens) versus Avana's USD caps with a top-up slice.
K, Sl, Psz, P1, H, used = Reals('K_usd slice_usd P_sizing P_pledge HubCap_tokens tokens_used')
# MATH-UO-28 verifies: SPEC-UNIT-005
witness('MATH-UO-28a',
        "wrong reading (Hub cap sized at today's $2 price, charges at the oracle price): pledges at a 5% lower price fill K and leave no Hub room for the slice",
        [K == 10 ** 7, Sl == 0.05 * K, Psz == 2, H == (K + Sl) / Psz,
         P1 == 0.95 * Psz, used == K / P1, H - used <= 0])
F, v1, v2, w1, w2, P2 = Reals('stressFloor charge1 charge2 tokens1 tokens2 P_pledge2')
# MATH-UO-28 verifies: SPEC-UNIT-005, SPEC-BACK-003, MKT-014
prove('MATH-UO-28b',
      'final rule: charges at max(price, stressFloor) and addCap >= (K + slice) / stressFloor: the Hub never blocks a pledge Avana\'s caps admit, even at prices below the floor',
      [K > 0, Sl >= 0, F > 0, H >= (K + Sl) / F, P1 > 0, P2 > 0, w1 >= 0, w2 >= 0,
       v1 == w1 * If(P1 > F, P1, F), v2 == w2 * If(P2 > F, P2, F), v1 + v2 <= K + Sl],
      w1 + w2 <= H)

# ---------------------------------------------------------------------------
# MATH-UO-29  Counter and charge arithmetic bounds (uint256).
Cb, Kb, vb = BitVec('C', 256), BitVec('K', 256), BitVec('v', 256)
# MATH-UO-29 verifies: SPEC-BACK-004
prove('MATH-UO-29a', 'counter C <= cap K < 2^128 and charge v < 2^128: C + v cannot overflow',
      [ULE(Cb, Kb), ULT(Kb, BitVecVal(2 ** 128, 256)), ULT(vb, BitVecVal(2 ** 128, 256))],
      BVAddNoOverflow(Cb, vb, False))
Vb, rb = BitVec('V0', 128), BitVec('remaining', 128)
# MATH-UO-29 verifies: SPEC-BACK-005, SPEC-BACK-013
prove('MATH-UO-29b', 'V0 < 2^128 and remainingUnits < 2^120: V0 * remainingUnits < 2^248 (no mulDiv overflow)',
      [ULT(rb, BitVecVal(2 ** 120, 128))],
      ULT(ZeroExt(128, Vb) * ZeroExt(128, rb), BitVecVal(2 ** 248, 256)))
cbv, pbv = BitVec('c', 256), BitVec('price', 256)
# MATH-UO-29 verifies: SPEC-BACK-003
prove('MATH-UO-29c', 'c < 2^120 and max(price8, floor) < 2^64: the charge product is below 2^184',
      [ULT(cbv, BitVecVal(2 ** 120, 256)), ULT(pbv, BitVecVal(2 ** 64, 256))],
      And(BVMulNoOverflow(cbv, pbv, False), ULT(cbv * pbv, BitVecVal(2 ** 184, 256))))

finish()
