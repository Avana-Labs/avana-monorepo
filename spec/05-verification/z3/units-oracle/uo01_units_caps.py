# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-01..05 — vault-token units, per-market decimals, whole-token value, Hub addCap
granularity and integer bounds ([2.4] SPEC-UNIT-001..006, [2.10] SPEC-ORC-005).

Unit definitions
  L          credited Uniswap v3 liquidity (uint128); 1 vault-token base unit = 1 L (SPEC-UNIT-002)
  d          vault-token decimals = (d0 + d1) / 2, so one whole token = 10^d L (SPEC-UNIT-001)
  p0, p1     USD per WHOLE token0 / token1
  P_raw      token1 raw units per token0 raw unit = (p0 * 10^d1) / (p1 * 10^d0)
Ideal full range: q0 = L / sqrt(P_raw), q1 = L * sqrt(P_raw) (raw units), so the USD value of
L units is 2 * L * sqrt(P_raw) * p1 / 10^d1 (SPEC-UNIT-003).
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Reals, Ints, And, Or, BitVec, BitVecVal, ULE, ULT, BVMulNoOverflow
from _common import (prove, witness, note, finish, TOKENS, LAUNCH_PAIRS, pool_order,
                     TICK_SPACINGS, max_liquidity_per_tick, usable_ticks, U120, HUB_CAP_MAX)

# ---------------------------------------------------------------------------
# MATH-UO-01  Decimals rule d = (d0 + d1) / 2.
rows = []
for a, b in LAUNCH_PAIRS:
    t0, t1 = pool_order(a, b)
    d0, d1 = TOKENS[t0], TOKENS[t1]
    d = (d0 + d1) // 2
    ok = (d0 + d1) % 2 == 0 and 12 <= d0 + d1 <= 36
    rows.append(f"{a}/{b:5s} pool token0/token1 = {t0}/{t1}  d0={d0:2d} d1={d1:2d}  d={d:2d}  deployable={ok}")
    assert ok
# MATH-UO-01 verifies: SPEC-UNIT-001, SPEC-ORC-005
note('MATH-UO-01a', 'launch pairs: (d0+d1) even and 12 <= d0+d1 <= 36, so d = (d0+d1)/2 is exact and in [6,18]', '\n'.join(rows))

d0, d1, dv = Ints('d0 d1 d')
# MATH-UO-01 verifies: SPEC-UNIT-001, REQ-VTOKEN-022
witness('MATH-UO-01b',
        'wrong reading without the parity check: an odd d0+d1 truncates d, so 2d != d0+d1 and 2*sqrt(p0*p1) misprices a whole token by sqrt(10)',
        [d0 >= 6, d0 <= 18, d1 >= 6, d1 <= 18, (d0 + d1) % 2 == 1,
         dv == (d0 + d1) / 2, dv >= 6, dv <= 18, 2 * dv != d0 + d1])
# MATH-UO-01 verifies: SPEC-UNIT-001, REQ-VTOKEN-022
prove('MATH-UO-01c',
      'deployment check (d0+d1) % 2 == 0 and 12 <= d0+d1 <= 36 gives an integer d with 2d == d0+d1 and 6 <= d <= 18',
      [d0 >= 0, d0 <= 255, d1 >= 0, d1 <= 255, (d0 + d1) % 2 == 0, d0 + d1 >= 12, d0 + d1 <= 36,
       dv == (d0 + d1) / 2],
      And(2 * dv == d0 + d1, dv >= 6, dv <= 18))

# ---------------------------------------------------------------------------
# MATH-UO-02  One whole vault token is worth exactly 2*sqrt(p0*p1) USD (ideal full range),
#             for every launch pair, independent of orientation, when 2d = d0 + d1.
for a, b in LAUNCH_PAIRS:
    t0, t1 = pool_order(a, b)
    e0, e1 = TOKENS[t0], TOKENS[t1]
    d = (e0 + e1) // 2
    p0, p1, x, w = Reals('p0 p1 sqrtPraw w')
    L = 10 ** d
    value = 2 * L * x * p1 / 10 ** e1                       # USD of one whole token
    hyps = [p0 > 0, p1 > 0, x > 0, x * x == p0 * 10 ** e1 / (p1 * 10 ** e0), w > 0, w * w == p0 * p1]
    # MATH-UO-02 verifies: SPEC-UNIT-003, SPEC-ORC-005
    prove(f'MATH-UO-02a[{a}/{b}]', 'USD(one whole token) == 2*sqrt(p0*p1)', hyps, value == 2 * w)

p0, p1, w = Reals('p0 p1 w')
band = [p0 >= 0.5, p0 <= 1.5, p1 >= 0.5, p1 <= 1.5, w > 0, w * w == p0 * p1]
# MATH-UO-02 verifies: SPEC-UNIT-003
prove('MATH-UO-02b', 'legs p0, p1 in [$0.50, $1.50] => whole-token value in [$1, $3]',
      band, And(2 * w >= 1, 2 * w <= 3))
# MATH-UO-02 verifies: SPEC-UNIT-003
witness('MATH-UO-02c', 'outside the stated bounds: a deep depeg of one or both legs takes a whole token below $1',
        [p0 > 0, p0 <= 1.5, p1 > 0, p1 <= 1.5, w > 0, w * w == p0 * p1, 2 * w < 1])
# MATH-UO-02 verifies: SPEC-UNIT-003, SPEC-ORC-008
prove('MATH-UO-02d', 'price resolution: relative step 1/price8 <= 1e-6 while a whole token is worth >= $0.01',
      [w > 0, 2 * w >= 0.01], 1 / (2 * w * 10 ** 8) <= 10 ** -6)

# ---------------------------------------------------------------------------
# MATH-UO-03  Hub addCap granularity and range (Hub._validateAdd:
#             addCap * 10^dec >= toAddedAssetsUp(spoke.addedShares) + amount, addCap uint40).
for d in (6, 12, 18):
    cap = BitVec('addCap', 256)
    prod = cap * BitVecVal(10 ** d, 256)
    # MATH-UO-03 verifies: SPEC-UNIT-005
    prove(f'MATH-UO-03a[d={d}]',
          'finite addCap (< 2^40-1) * 10^d never overflows and stays below 2^120 (Hub uint120 shares never bind first)',
          [ULT(cap, BitVecVal(HUB_CAP_MAX, 256))],
          And(BVMulNoOverflow(cap, BitVecVal(10 ** d, 256), False), ULE(prod, BitVecVal(U120, 256))))
# MATH-UO-03 verifies: SPEC-UNIT-005, MKT-014
note('MATH-UO-03b', 'addCap granularity: 1 cap unit = 1 whole token',
     'At $1.00 legs one whole token = $2.00; the cap is sized at stressFloorUsd = $1.00 per whole token.\n'
     f'Largest finite addCap = 2^40-2 = {HUB_CAP_MAX - 1:,} whole tokens = about ${HUB_CAP_MAX - 1:.3e} at the floor.')

# ---------------------------------------------------------------------------
# MATH-UO-04  uint128 liquidity bounds. All full-range positions in a pool share the two
#             usable boundary ticks, so total full-range liquidity <= maxLiquidityPerTick(s).
lines = []
for s in TICK_SPACINGS:
    m = max_liquidity_per_tick(s)
    lo, hi = usable_ticks(s)
    lines.append(f"spacing {s:3d}: ticks [{lo},{hi}] maxLiquidityPerTick = {m:.4e}  (< 2^120: {m < 2**120});"
                 f" whole tokens at d=6: {m / 1e6:.2e}, d=12: {m / 1e12:.2e}, d=18: {m / 1e18:.2e}")
    assert m < 2 ** 120
first_bad = next(s for s in range(1, 16384) if max_liquidity_per_tick(s) >= 2 ** 120)
lines.append(f"exhaustive s in [1,16383]: smallest spacing with maxLiquidityPerTick >= 2^120 is s = {first_bad}")
# MATH-UO-04 verifies: SPEC-UNIT-006, SPEC-BACK-001, SPEC-BACK-002
note('MATH-UO-04a', 'credited units per pool fit Hub uint120 shares for every standard fee tier', '\n'.join(lines))
s_ = Ints('tickSpacing')[0]
# MATH-UO-04 verifies: SPEC-UNIT-006, REQ-VTOKEN-022
witness('MATH-UO-04b',
        f'why only spacings 1, 10, 60, 200 are deployable: a spacing >= {first_bad} lets one pool hold more full-range liquidity than Hub uint120 shares',
        [s_ == first_bad, s_ < 16384])

# ---------------------------------------------------------------------------
# MATH-UO-05  Aave value math: toValue = amount * price8 * 10^(18-dec) (checked), then
#             KeyValueList value < 2^224 and avgCollateralFactor += CF_bps * value, then bpsToWad (x1e14).
def value_chain(amount_max, price_max, scale=10 ** 12):
    """scale = 10^(18-dec) <= 1e12 for dec >= 6 (or 1e18 when amount is in whole tokens)."""
    amt, pr, cf = BitVec('amount', 256), BitVec('price8', 256), BitVec('cf_bps', 256)
    e = BitVecVal(scale, 256)
    v1 = amt * pr
    v2 = v1 * e
    v3 = v2 * cf
    hyps = [ULE(amt, BitVecVal(amount_max, 256)), ULE(pr, BitVecVal(price_max, 256)),
            ULE(cf, BitVecVal(10 ** 4, 256))]
    goal = And(BVMulNoOverflow(amt, pr, False), BVMulNoOverflow(v1, e, False),
               ULT(v2, BitVecVal(2 ** 224 - 1, 256)),
               BVMulNoOverflow(v2, cf, False), BVMulNoOverflow(v3, BitVecVal(10 ** 14, 256), False))
    return hyps, goal


mlt1 = max_liquidity_per_tick(1)
h, g = value_chain(mlt1, 2 * 10 ** 10)
# MATH-UO-05 verifies: SPEC-UNIT-004
prove('MATH-UO-05a', 'amount <= maxLiquidityPerTick(1) (~1.9e32 units), price8 <= 2e10: no overflow anywhere in Aave value math',
      h, g)
h, g = value_chain(HUB_CAP_MAX - 1, 10 ** 20, scale=10 ** 18)
# MATH-UO-05 verifies: SPEC-UNIT-004, SPEC-UNIT-005
prove('MATH-UO-05b', 'finite Hub addCap (amount <= 2^40-2 whole tokens) and price8 <= 1e20: no overflow (value = whole * price8 * 1e18)',
      h, g)
h, g = value_chain(U120, 10 ** 12)
# MATH-UO-05 verifies: SPEC-UNIT-004
prove('MATH-UO-05c', 'outside the stated bounds (2^120 units, d=6, price8 up to 1e12): overflow is reachable, which is why the bounds are listing conditions',
      h, g, expect='COUNTEREXAMPLE')

finish()
