# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-10..13 — sqrtPriceX96 from two 8-decimal USD prices and the TWAP comparison
([2.10] SPEC-ORC-009, SPEC-ORC-010).

  num = x0 * 10^d1,  den = x1 * 10^d0                (P_raw = num / den)
  SPEC-ORC-009:  if num >= 2^128 * den: s = MAX_SQRT_RATIO - 1 (clamped)
                 elif num >= 2^64 * den: Y = mulDiv(num, 2^128, den) (floor), s = Math.sqrt(Y) * 2^32,
                      then MAX_SQRT_RATIO - 1 (clamped) if s >= MAX_SQRT_RATIO
                 else X = mulDiv(num, 2^192, den) (512-bit, floor), s = Math.sqrt(X) (floor),
                      s = max(s, MIN_SQRT_RATIO) (clamped)
  SPEC-ORC-010:  tickRef = getTickAtSqrtRatio(s_ref) on the uncapped quotes;
                 meanTick = floor(delta / W) (trunc, then -1 when delta < 0 and delta mod W != 0);
                 pass iff |meanTick - tickRef| <= tau
"""
import math
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Int, Ints, Real, Reals, And, Or, If, Not, Implies, ToReal
from _common import (prove, witness, note, finish, TOKENS, LAUNCH_PAIRS, pool_order,
                     MIN_SQRT_RATIO, MAX_SQRT_RATIO, MIN_TICK, sqrt_ratio_at_tick, Q96,
                     MAX_ROUTE_ANSWER, tick_at_sqrt_ratio)

TWO64 = 2 ** 64
A_LO, A_HI = 1, MAX_ROUTE_ANSWER      # normalised answers in [1, MAX_ROUTE_ANSWER] (REQ-ORACLE-049)

# ---------------------------------------------------------------------------
# MATH-UO-10  mulDiv(num, 2^192, den) fits 256 bits  <=>  num < 2^64 * den  (i.e. P_raw < 2^64).
a0, a1 = Ints('a0 a1')
for a, b in LAUNCH_PAIRS:
    t0, t1 = pool_order(a, b)
    d0, d1 = TOKENS[t0], TOKENS[t1]
    num, den = a0 * 10 ** d1, a1 * 10 ** d0
    # MATH-UO-10 verifies: SPEC-ORC-009
    prove(f'MATH-UO-10a[{a}/{b}]', 'answers in [1, MAX_ROUTE_ANSWER]: num < 2^64 * den, so mulDiv runs and X < 2^256',
          [a0 >= A_LO, a0 <= A_HI, a1 >= A_LO, a1 <= A_HI], num < TWO64 * den)

# generic search: any token decimals the Hub/Uniswap accept, answers up to $1e10
found = None
for d0 in range(6, 19):
    for d1 in range(6, 19):
        num, den = a0 * 10 ** d1, a1 * 10 ** d0
        from z3 import Solver, sat
        s = Solver()
        s.add(a0 >= 1, a0 <= 10 ** 18, a1 >= 1, a1 <= 10 ** 18,
              num >= TWO64 * den,                     # mulDiv overflows -> revert
              num < 2 ** 128 * den)                   # yet the price is inside Uniswap's valid range
        if s.check() == sat:
            found = (d0, d1)
            break
    if found:
        break
d0, d1 = found
# MATH-UO-10 verifies: SPEC-ORC-009
witness('MATH-UO-10b',
        f'wrong reading without the num >= 2^64*den pre-check: P_raw in [2^64, 2^128) is a valid Uniswap price but mulDiv reverts before the clamp (first hit d0={d0}, d1={d1})',
        [a0 >= 1, a0 <= 10 ** 18, a1 >= 1, a1 <= 10 ** 18,
         a0 * 10 ** d1 >= TWO64 * a1 * 10 ** d0, a0 * 10 ** d1 < 2 ** 128 * a1 * 10 ** d0])
r_ = Real('r')
# MATH-UO-10 verifies: SPEC-ORC-009
prove('MATH-UO-10c', 'after a successful mulDiv, sqrt(X) < 2^128 < MAX_SQRT_RATIO, so the upper clamp can never fire',
      [r_ >= 0, r_ * r_ < 2 ** 256], r_ < MAX_SQRT_RATIO)

# ---------------------------------------------------------------------------
# MATH-UO-11  Final algorithm: three branches. num >= 2^128*den -> MAX-1; num >= 2^64*den -> isqrt(mulDiv(num, 2^128,
#              den)) * 2^32, MAX-1 at or above MAX; else isqrt(mulDiv(num, 2^192, den)), at least MIN.
num_, den_, X, s0, Y, r = Ints('num den X s0 Y r')
TWO128 = 2 ** 128
pre64 = num_ >= TWO64 * den_
pre128 = num_ >= TWO128 * den_
s_up = r * 2 ** 32
s_final = If(pre128, MAX_SQRT_RATIO - 1,
             If(pre64, If(s_up >= MAX_SQRT_RATIO, MAX_SQRT_RATIO - 1, s_up),
                If(s0 < MIN_SQRT_RATIO, MIN_SQRT_RATIO, s0)))
floor_x = Implies(Not(pre64), And(X * den_ <= num_ * 2 ** 192, num_ * 2 ** 192 < (X + 1) * den_))
floor_y = Implies(And(pre64, Not(pre128)), And(Y * den_ <= num_ * TWO128, num_ * TWO128 < (Y + 1) * den_))
isqrt_x = And(s0 >= 0, s0 * s0 <= X, X < (s0 + 1) * (s0 + 1))
isqrt_y = And(r >= 0, r * r <= Y, Y < (r + 1) * (r + 1))
hyps = [num_ >= 1, den_ >= 1, floor_x, floor_y, isqrt_x, isqrt_y]
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11a', 'below 2^64, X < 2^256 whenever mulDiv runs (no revert path)', hyps,
      Implies(Not(pre64), X < 2 ** 256))
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11c', 'in [2^64, 2^128), Y = mulDiv(num, 2^128, den) < 2^256 (no revert path) and Y >= 2^192', hyps,
      Implies(And(pre64, Not(pre128)), And(Y < 2 ** 256, Y >= 2 ** 192)))
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11d', 'in [2^64, 2^128), isqrt(Y) * 2^32 >= 2^128 > every lower-branch result (monotone across 2^64)',
      hyps + [Y >= 2 ** 192], Implies(And(pre64, Not(pre128)), s_up >= TWO128))
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11e', 'below 2^64 the root is below 2^128', hyps + [X < 2 ** 256], Implies(Not(pre64), s0 < TWO128))
# MATH-UO-11 verifies: SPEC-ORC-009, SPEC-ORC-010
prove('MATH-UO-11b', 'final sqrtPriceX96 is in [MIN_SQRT_RATIO, MAX_SQRT_RATIO) so getTickAtSqrtRatio never reverts',
      hyps + [Implies(And(pre64, Not(pre128)), s_up >= TWO128)], And(s_final >= MIN_SQRT_RATIO, s_final < MAX_SQRT_RATIO))

# MATH-UO-11f  Precision of the upper branch: s = isqrt(floor(num*2^128/den)) * 2^32 lies in (s* - 2^32, s*], where
#              s* = 2^96 * sqrt(num/den) = 2^32 * t and t = sqrt(num * 2^128 / den) exactly.
t_ = Real('t')
Yi, ri = Ints('Y_i r_i')
hyps_f = [t_ >= 0, ToReal(Yi) <= t_ * t_, t_ * t_ < ToReal(Yi) + 1, ri >= 0, ri * ri <= Yi, Yi < (ri + 1) * (ri + 1)]
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11f', 'upper branch: isqrt(floor(t^2)) in (t - 1, t], so s in (s* - 2^32, s*]: never above the exact root',
      hyps_f, And(ToReal(ri) <= t_, t_ < ToReal(ri) + 1))

# MATH-UO-11g  Monotone inside the upper branch: a larger ratio never gives a smaller root.
q1, q2 = Reals('q1 q2')
Y1, Y2, r1, r2 = Ints('Y1 Y2 r1 r2')
hyps_g = [q1 >= 2 ** 64, q2 >= q1,
          ToReal(Y1) <= q1 * TWO128, q1 * TWO128 < ToReal(Y1) + 1,
          ToReal(Y2) <= q2 * TWO128, q2 * TWO128 < ToReal(Y2) + 1,
          r1 >= 0, r1 * r1 <= Y1, Y1 < (r1 + 1) * (r1 + 1),
          r2 >= 0, r2 * r2 <= Y2, Y2 < (r2 + 1) * (r2 + 1)]
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11g', 'upper branch is monotone: q1 <= q2 gives isqrt(Y1) <= isqrt(Y2)', hyps_g, r1 <= r2)

# MATH-UO-11h  Continuity at 2^64: at num = 2^64 * den the upper branch gives exactly 2^128 = s*, and across the
#              boundary the step of s exceeds the step of s* by less than 2^32 (one unit of the upper branch).
sa_, sb_, xa, xb = Reals('s_low s_up exact_low exact_up')
hyps_h = [xa >= 0, xb >= xa, sa_ <= xa, sa_ > xa - 2, sb_ <= xb, sb_ > xb - 2 ** 32, sa_ < TWO128, sb_ >= TWO128]
# MATH-UO-11 verifies: SPEC-ORC-009
prove('MATH-UO-11h', 'across 2^64: 0 < s(q2) - s(q1) < s*(q2) - s*(q1) + 2 (monotone; jump bounded by the rounding)',
      hyps_h, And(sb_ - sa_ > 0, sb_ - sa_ < xb - xa + 2))
assert math.isqrt((TWO64 * 7) * TWO128 // 7) * 2 ** 32 == TWO128      # num = 2^64 * den exactly: s = 2^128 = s*
# MATH-UO-11 verifies: SPEC-ORC-009
note('MATH-UO-11i', 'at num = 2^64 * den the upper branch returns 2^128, the exact root; one step below, the lower branch',
     f'num = 2^64*7, den = 7: s = {TWO128}\n'
     f'num = 2^64*7 - 1, den = 7: s = {math.isqrt((TWO64 * 7 - 1) * 2 ** 192 // 7)} (= 2^128 - {TWO128 - math.isqrt((TWO64 * 7 - 1) * 2 ** 192 // 7)})')

# MATH-UO-11j  Wrong reading (the earlier rule): saturating at MAX_SQRT_RATIO - 1 once num >= 2^64 * den quotes a root
#              more than 2^31 times the exact one, so a full-range composition is valued as all token1 at the range top.
sx_ = Real('s_exact')
qq = Real('q')
# MATH-UO-11 verifies: SPEC-ORC-009, REQ-ORACLE-104
witness('MATH-UO-11j', 'wrong reading: MAX_SQRT_RATIO - 1 for every ratio in [2^64, 2^65] exceeds 2^31 times the exact root',
        [qq >= 2 ** 64, qq <= 2 ** 65, sx_ > 0, sx_ * sx_ == qq * 2 ** 192, MAX_SQRT_RATIO - 1 > 2 ** 31 * sx_])

# MATH-UO-11k  The 2.10 example of the upper branch: token0 6 decimals at $1, token1 18 decimals at $5e-8.
n_k, d_k = 10 ** 8 * 10 ** 18, 5 * 10 ** 6
s_k = math.isqrt(n_k * TWO128 // d_k) * 2 ** 32
e_k = math.isqrt(n_k * 2 ** 256 // d_k)                                # floor(2^32 * s*), s* = 2^96 * sqrt(num/den)
assert n_k >= TWO64 * d_k and n_k < TWO128 * d_k and s_k < MAX_SQRT_RATIO
assert s_k * 2 ** 32 <= e_k < (s_k + 2 ** 32) * 2 ** 32                # s <= s* < s + 2^32
# MATH-UO-11 verifies: SPEC-ORC-009
note('MATH-UO-11k', 'upper-branch example: p0 = 1e8 (d0 = 6), p1 = 5 (d1 = 18)',
     f'num = 1e26, den = 5e6, ratio = 2e19 >= 2^64\ns = {s_k}\n'
     f'floor(s*) - s = {e_k // 2 ** 32 - s_k} (< 2^32 = {2 ** 32}); the lower-branch rule saturated at {MAX_SQRT_RATIO - 1}')

# ---------------------------------------------------------------------------
# MATH-UO-12  Precision: s in (s* - 2, s*] where s* = sqrt(num/den) * 2^96; tickRef is t* or t* - 1.
sx, Xr, sr = Reals('s_exact X s')
hyps = [sx >= 1, Xr <= sx * sx, Xr > sx * sx - 1, sr >= 0, sr * sr <= Xr, (sr + 1) * (sr + 1) > Xr]
# MATH-UO-12 verifies: SPEC-ORC-009
prove('MATH-UO-12a', 'floor(sqrt(floor(num*2^192/den))) in (s* - 2, s*]', hyps, And(sr <= sx, sr > sx - 2))
# consecutive TickMath sqrt ratios are > 2 apart everywhere (smallest gap is at the bottom tick)
gaps = [sqrt_ratio_at_tick(t + 1) - sqrt_ratio_at_tick(t) for t in range(MIN_TICK, MIN_TICK + 2000)]
assert all(g2 >= g1 for g1, g2 in zip(gaps, gaps[1:]))
gmin = gaps[0]
St, Stm1 = Reals('S_t S_tm1')
# MATH-UO-12 verifies: SPEC-ORC-009, SPEC-ORC-010
prove('MATH-UO-12b', f'gap S(t)-S(t-1) >= {gmin} (> 2): s >= S(t*-1), so tickRef >= t* - 1 (at most 1 tick low, never high)',
      hyps + [St <= sx, St - Stm1 >= gmin], And(sr > Stm1, sr <= sx))
# MATH-UO-12e  Upper branch: s is at most 2^32 below s*, and consecutive TickMath ratios at or above 2^128 are far more
#              than 2^32 apart, so tickRef is again the exact tick or one below.
t_hi = next(t for t in range(443_000, 444_000) if sqrt_ratio_at_tick(t) >= 2 ** 128)
gmin_hi = sqrt_ratio_at_tick(t_hi + 1) - sqrt_ratio_at_tick(t_hi)
assert gmin_hi > 2 ** 32 and all(sqrt_ratio_at_tick(t + 1) - sqrt_ratio_at_tick(t) >= gmin_hi
                                 for t in range(t_hi, t_hi + 2000))
St2, Stm12, sx2, sr2 = Reals('S_t2 S_tm12 s_exact2 s2')
# MATH-UO-12 verifies: SPEC-ORC-009, SPEC-ORC-010
prove('MATH-UO-12e', f'upper branch: gap S(t)-S(t-1) >= {gmin_hi:.3e} (> 2^32) for ticks >= {t_hi}: tickRef >= t* - 1',
      [sx2 >= 2 ** 128, sr2 <= sx2, sr2 > sx2 - 2 ** 32, St2 <= sx2, St2 - Stm12 >= gmin_hi], And(sr2 > Stm12, sr2 <= sx2))
rows = []
for a, b in LAUNCH_PAIRS:
    t0, t1 = pool_order(a, b)
    d0, d1 = TOKENS[t0], TOKENS[t1]
    n, dn = 10 ** 8 * 10 ** d1, 10 ** 8 * 10 ** d0
    s512 = math.isqrt(n * 2 ** 192 // dn)
    alt = math.isqrt(n * Q96 // dn) * 2 ** 48            # "priceX96 then sqrt * 2^48" method
    rel_alt = (s512 - alt) / s512
    rows.append(f'{a}/{b}: s = {s512:.6e}; priceX96 method relative error {rel_alt:.2e} '
                f'(1 tick = 5.0e-5 in sqrt price)')
# MATH-UO-12 verifies: SPEC-ORC-009
note('MATH-UO-12c', 'launch pairs at $1: 512-bit method vs priceX96 method', '\n'.join(rows))

# MATH-UO-12d  OracleLibrary.consult rounding: trunc(delta / W), minus 1 when delta < 0 and
#              delta mod W != 0, equals floor(delta / W) for every delta and W >= 1.
dl, Wd = Ints('delta W')
trunc = If(dl >= 0, dl / Wd, -((-dl) / Wd))               # Solidity int division (toward zero)
rem_nz = If(dl >= 0, dl % Wd, (-dl) % Wd) != 0
mean = If(And(dl < 0, rem_nz), trunc - 1, trunc)
# MATH-UO-12 verifies: SPEC-ORC-010
prove('MATH-UO-12d', 'meanTick = trunc(delta/W) - [delta < 0 and delta mod W != 0] is floor(delta/W) (rounds toward -inf)',
      [Wd >= 1, Wd <= 10 ** 6, dl >= -(2 ** 60), dl <= 2 ** 60], And(mean * Wd <= dl, dl < (mean + 1) * Wd))

# ---------------------------------------------------------------------------
# MATH-UO-13  Orientation: tickRef must use the pool's token0/token1, not the listing name.
t_true = math.floor(math.log(10 ** -12) / math.log(1.0001))
t_swapped = math.floor(math.log(10 ** 12) / math.log(1.0001))
tau = Int('tau')
# MATH-UO-13 verifies: SPEC-ORC-009, SPEC-ORC-010
witness('MATH-UO-13', f'wrong reading: listing "USDC/GHO" read as token0=USDC gives tickRef {t_swapped} vs pool tick {t_true}: '
        'permanent Drifting for any tau below 552,000 ticks',
        [tau >= 1, tau <= 10000, abs(t_swapped - t_true) > tau])

finish()
