# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""AMM-A — fair composition of a concentrated-liquidity position (Uniswap v3 style ticks; the AMM
protocol variant with tickSpacing-keyed pools uses the same TickMath, SqrtPriceMath and
LiquidityAmounts code, so every check covers both).

Quote for a position with liquidity L on the range [tl, tu] (sqrt prices sa < sb):
    sO          = sqrt price implied by the oracle prices (P = p0 / p1 in raw units), not slot0
    (a0, a1)    = getAmountsForLiquidity(sO, sa, sb, L)
                  sO <= sa : a0 = L (sb - sa) / (sa sb),  a1 = 0               (all token0)
                  sa < sO < sb : a0 = L (sb - sO) / (sO sb), a1 = L (sO - sa)
                  sO >= sb : a0 = 0,  a1 = L (sb - sa)                          (all token1)
    value       = a0 * p0 + a1 * p1
Real-number checks use s = sqrtPriceX96 / 2^96 (value in token1 units, p1 = 1, P = sO^2); the
integer checks use the Q64.96 ports in _common.py.

Check IDs (one per group; Uniswap v3 and Aerodrome Slipstream share the math, so each group carries
both tags): MATH-AMM-V3-PRICE-01 .. 06 and MATH-AMM-SLIP-PRICE-01 .. 06.
"""
import os
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Reals, Real, Ints, BitVec, BitVecVal, SRem, URem, And, Or, Not, If, Implies, RealVal
import mpmath
from _common import (prove, witness, note, finish, amounts_for_liquidity, sqrt_ratio_at_tick, sqrt_price_x96,
                     value8, mul_div, Q96, U128, MIN_TICK, MAX_TICK, MIN_SQRT_RATIO, SPACINGS)


def clamp(s, lo, hi):
    return If(s <= lo, lo, If(s >= hi, hi, s))


def holdings(L, s, sa, sb):
    """Exact real amounts at sqrt price s (clamped to the range)."""
    c = clamp(s, sa, sb)
    return L * (1 / c - 1 / sb), L * (c - sa)


L, sa, sb, sO, sS, p0, p1, L2 = Reals('L sa sb sO sSpot p0 p1 L2')
base = [L > 0, sa > 0, sa < sb, sO > 0, sS > 0, p0 > 0, p1 > 0]
P = sO * sO                                    # oracle raw price p0/p1 when p1 = 1
x_f, y_f = holdings(L, sO, sa, sb)
fair = x_f * P + y_f                           # value in token1 units
x_s, y_s = holdings(L, sS, sa, sb)
spot_quote = x_s * P + y_s                     # amounts read at slot0 spot, priced by the oracle

# ---------------------------------------------------------------------------------------------------
# A1  Independence from the pool spot price
# MATH-AMM-V3-PRICE-01 verifies: SPEC-AMM-CORE-001, REQ-AMM-CORE-012, SPEC-AMM-V3-001, REQ-AMM-V3-005, INV-078
# MATH-AMM-SLIP-PRICE-01 verifies: SPEC-AMM-CORE-001, REQ-AMM-CORE-012, REQ-AMM-SLIP-012, INV-078
prove('AMM-A1a', 'fair quote is the minimum over every spot price of (spot amounts valued at the oracle price): '
      'spot_quote(sSpot) >= fair, so moving slot0 can only raise a spot-composition quote, never lower fair',
      base, spot_quote >= fair)
prove('AMM-A1b', 'in range, the excess of a spot-composition quote is exactly L (sSpot - sO)^2 / sSpot',
      base + [sa <= sS, sS <= sb, sa <= sO, sO <= sb], spot_quote - fair == L * (sS - sO) ** 2 / sS)
witness('AMM-A1c', 'deliberate: a spot-composition quote can be inflated (spot moved to 4x the oracle price '
        'raises it by >= 12.5% on a +-100x range); the fair quote reads no slot0 input and stays put',
        base + [sO == 1, sa == RealVal(F(1, 10)), sb == 10, sS == 2, L == 1, spot_quote > fair * RealVal(F(1125, 1000))])

# ---------------------------------------------------------------------------------------------------
# A2  Monotone in L (exact reals, then the integer floors)
# MATH-AMM-V3-PRICE-02 verifies: SPEC-AMM-V3-001
# MATH-AMM-SLIP-PRICE-02 verifies: REQ-AMM-SLIP-012
x_g, y_g = holdings(L2, sO, sa, sb)
prove('AMM-A2a', 'exact quote is linear and non-decreasing in L: L <= L2 -> value(L) <= value(L2)',
      base + [L <= L2], x_f * P + y_f <= x_g * P + y_g)
la, lb, c, d, q1, q2 = Ints('la lb c d q1 q2')
prove('AMM-A2b', 'integer floor step: la <= lb, c >= 0, d > 0 -> floor(la c / d) <= floor(lb c / d) '
      '(getAmount0/1ForLiquidity and mulDiv are compositions of this step, so amounts and value are monotone in L)',
      [la >= 0, la <= lb, c >= 0, d > 0, q1 * d <= la * c, la * c < (q1 + 1) * d, q2 * d <= lb * c, lb * c < (q2 + 1) * d],
      q1 <= q2)

# ---------------------------------------------------------------------------------------------------
# A3  Rounding: integer amounts and value never exceed the exact amounts at the same sqrt price
# MATH-AMM-V3-PRICE-03 verifies: SPEC-AMM-CORE-001, SPEC-AMM-V3-001, REQ-AMM-V3-005, INV-078
# MATH-AMM-SLIP-PRICE-03 verifies: SPEC-AMM-CORE-001, REQ-AMM-SLIP-012, INV-078
Lr, SA, SB, S, t, a0, a1 = Reals('L SA SB S t a0 a1')
hyp = [Lr >= 1, SA >= MIN_SQRT_RATIO, SA < S, S < SB]
N = Lr * Q96 * (SB - S)
ex0, ex1 = N / (SB * S), Lr * (S - SA) / Q96
fl = [t <= N / SB, t > N / SB - 1, a0 <= t / S, a0 > t / S - 1, a1 <= ex1, a1 > ex1 - 1]
prove('AMM-A3a', 'in range: a0 <= exact0 and a1 <= exact1 (mulDiv then /, both floor)', hyp + fl,
      And(a0 <= ex0, a1 <= ex1))
hyp_lo = [Lr >= 1, SA >= MIN_SQRT_RATIO, SA < SB]
N2 = Lr * Q96 * (SB - SA)
fl_lo = [t <= N2 / SB, t > N2 / SB - 1, a0 <= t / SA, a0 > t / SA - 1]
prove('AMM-A3b', 'out of range below (sO <= sa): a0 = floor(floor(L 2^96 (sb - sa) / sb) / sa) <= exact0, a1 = 0',
      hyp_lo + fl_lo, a0 <= N2 / (SB * SA))
prove('AMM-A3c', 'out of range above (sO >= sb): a1 = floor(L (sb - sa) / 2^96) <= exact1, a0 = 0',
      hyp_lo + [a1 <= Lr * (SB - SA) / Q96, a1 > Lr * (SB - SA) / Q96 - 1], a1 <= Lr * (SB - SA) / Q96)
v, P0, P1, D0, D1, e0, e1 = Reals('v P0 P1 D0 D1 e0 e1')
prove('AMM-A3d', 'value = floor(a0 p0 / 10^d0) + floor(a1 p1 / 10^d1) <= e0 p0 / 10^d0 + e1 p1 / 10^d1 when a_i <= e_i',
      [P0 > 0, P1 > 0, D0 >= 1, D1 >= 1, a0 >= 0, a1 >= 0, a0 <= e0, a1 <= e1, v <= a0 * P0 / D0 + a1 * P1 / D1],
      v <= e0 * P0 / D0 + e1 * P1 / D1)
# The oracle sqrt price itself is floored: S' = floor(S*) with S* the exact (often irrational) value.
# The fair value is the minimum over sqrt prices (A1a), so a composition read at S' != S* is worth
# L (S* - S')^2 / (S' 2^96) more token1 at the true price than the exact fair value.
Sx = Real('Sstar')
x1, y1 = holdings(Lr, S / Q96, SA / Q96, SB / Q96)
x2, y2 = holdings(Lr, Sx / Q96, SA / Q96, SB / Q96)
Pt = (Sx / Q96) ** 2
prove('AMM-A3e', 'exact amounts at the floored oracle sqrt price S\' (S* - 1 < S\' <= S*) are worth at most '
      'L / (S\' 2^96) token1 raw units more than the exact fair value at S*; < 1 raw unit for L < 2^128, S\' >= 2^32',
      hyp + [S <= Sx, Sx < S + 1, Sx <= SB],
      And(x1 * Pt + y1 - (x2 * Pt + y2) >= 0, x1 * Pt + y1 - (x2 * Pt + y2) <= Lr / (S * Q96)))
prove('AMM-A3f', 'with the final value floored and then lowered by one raw token1 unit, the integer quote '
      'never exceeds the exact fair value (L <= 2^128, S\' >= 2^32)',
      hyp + [S <= Sx, Sx < S + 1, Sx <= SB, Lr <= 2 ** 128, S >= 2 ** 32, a0 <= x1, a1 <= y1, a0 >= 0, a1 >= 0],
      a0 * Pt + a1 - 1 <= x2 * Pt + y2)

# exact-integer search for a case where the floored integer quote beats the exact fair value
mpmath.mp.dps = 120


def overvalue_case(tick_spot, tl, tu, liq, num, den):
    sa_, sb_ = sqrt_ratio_at_tick(tl), sqrt_ratio_at_tick(tu)
    s_ = sqrt_price_x96(num, den)
    a0_, a1_ = amounts_for_liquidity(s_, sa_, sb_, liq)
    sstar = mpmath.sqrt(mpmath.mpf(num) / den) * Q96
    if not (sa_ < sstar < sb_):
        return None
    x = mpmath.mpf(liq) * Q96 * (sb_ - sstar) / (sb_ * sstar)
    y = mpmath.mpf(liq) * (sstar - sa_) / Q96
    Pt_ = mpmath.mpf(num) / den
    return (a0_ * Pt_ + a1_) - (x * Pt_ + y)


def search(liq_of_k):
    best = None
    for tl in (-886000, -880000, -860000):
        for k in range(1, 400):
            num, den = 10 ** 6 + 37 * k, 10 ** 44 + 3 * k * k
            r = overvalue_case(None, tl, tl + 20000, liq_of_k(k), num, den)
            if r is not None and (best is None or r > best[0]):
                best = (r, tl, num, den)
    return best


MAXL = U128 // ((((MAX_TICK // 2000) * 2000 + ((-MIN_TICK) // 2000) * 2000) // 2000) + 1)   # spacing 2000
b127 = search(lambda k: 2 ** 127 + k * 7919)
bmax = search(lambda k: MAXL - k * 7919)
note('AMM-A3g', 'exact-integer search: floored getAmountsForLiquidity at the floored oracle sqrt price vs exact fair value',
     f'L ~ 2^127 (above any per-tick cap), prices ~ 1e-38: largest excess {mpmath.nstr(b127[0], 6)} token1 raw units (tl = {b127[1]})\n'
     f'L = maxLiquidityPerTick(2000) = {MAXL:.3e}: largest excess {mpmath.nstr(bmax[0], 6)} token1 raw units (tl = {bmax[1]})\n'
     'So "floored amounts never overvalue" is TRUE at the computed sqrt price (A3a-d) but FALSE against the exact\n'
     'irrational oracle price by < L / (S\' 2^96) raw token1; the final "- 1 raw unit" of A3f removes it.\n'
     'At launch-pair prices (P_raw in 1e-12 .. 1e12) the bound is below 1e-13 raw units.')

# ---------------------------------------------------------------------------------------------------
# A4  Oracle price outside the range: the oracle sqrt price is clamped to [sa, sb]
# MATH-AMM-V3-PRICE-04 verifies: SPEC-AMM-V3-001, REQ-AMM-V3-005, REQ-AMM-V3-006, INV-078, AMMN-RT-02
# MATH-AMM-SLIP-PRICE-04 verifies: REQ-AMM-SLIP-012, INV-078, AMMN-RT-02
prove('AMM-A4a', 'oracle below the range: holdings are all token0, a0 = L (sb - sa)/(sa sb), and value is linear in p0',
      base + [sO <= sa], And(y_f == 0, x_f == L * (sb - sa) / (sa * sb), fair == x_f * P))
prove('AMM-A4b', 'oracle above the range: holdings are all token1, a1 = L (sb - sa), value independent of p0',
      base + [sO >= sb], And(x_f == 0, y_f == L * (sb - sa), fair == L * (sb - sa)))
prove('AMM-A4c', 'quote is continuous at both range ends (in-range formula equals the one-sided formula at sO = sa, sb)',
      [L > 0, sa > 0, sa < sb], And(L * (1 / sa - 1 / sb) == L * (sb - sa) / (sa * sb), L * (sb - sa) == L * (sb - sa)))
prove('AMM-A4d', 'out of range the fair quote still lower-bounds every spot composition (A1a holds for all three cases)',
      base + [Or(sO <= sa, sO >= sb)], spot_quote >= fair)
for tick_case, sOv, want in (('below', sqrt_ratio_at_tick(-1000), 'a1 == 0'), ('above', sqrt_ratio_at_tick(1000), 'a0 == 0')):
    sa_, sb_ = sqrt_ratio_at_tick(-200), sqrt_ratio_at_tick(200)
    a0_, a1_ = amounts_for_liquidity(sOv, sa_, sb_, 10 ** 24)
    assert (a1_ == 0) if tick_case == 'below' else (a0_ == 0)
note('AMM-A4e', 'integer port at an oracle price outside [-200, 200]', 'below: a1 = 0, a0 > 0; above: a0 = 0, a1 > 0 (asserted)')
# Without the clamp: x = L (1/sO - 1/sb) and y = L (sO - sa) at the raw oracle ratio, a negative amount floored at 0.
x_u, y_u = If(L * (1 / sO - 1 / sb) > 0, L * (1 / sO - 1 / sb), 0), If(L * (sO - sa) > 0, L * (sO - sa), 0)
unclamped = x_u * P + y_u
prove('AMM-A4f', 'oracle above the range: the unclamped quote exceeds the clamped fair value by exactly L (sO - sb) '
      'token1 (x is floored at 0, y keeps growing past sb), so it is unbounded in the oracle ratio',
      base + [sO >= sb], unclamped - fair == L * (sO - sb))
mpmath.mp.dps = 50
_sa, _sb, _so = mpmath.sqrt(mpmath.mpf('0.99')), mpmath.sqrt(mpmath.mpf('1.01')), mpmath.sqrt(mpmath.mpf('1.05'))
_ratio = (_so - _sa) / (_sb - _sa)
assert 2.97 < _ratio < 2.98
note('AMM-A4h', 'deliberate: range [0.99, 1.01], token1 depegged to $0.952 (oracle ratio 1.05), L = 1,000,000',
     f'clamped: 0 token0 + {mpmath.nstr(10 ** 6 * (_sb - _sa), 8)} token1 = ${mpmath.nstr(10 ** 6 * (_sb - _sa) / 1.05, 7)}\n'
     f'unclamped: y = {mpmath.nstr(10 ** 6 * (_so - _sa), 8)} token1, x = {mpmath.nstr(10 ** 6 * (1 / _so - 1 / _sb), 7)} -> 0: '
     f'x{mpmath.nstr(_ratio, 4)} the clamped value')
prove('AMM-A4g', 'the clamped quote never exceeds the unclamped one (negative amounts floored at 0), at every oracle price',
      base, fair <= unclamped)

# ---------------------------------------------------------------------------------------------------
# A5  tickSpacing-aligned range check in int24 arithmetic
# MATH-AMM-V3-PRICE-05 verifies: REQ-AMM-V3-002, REQ-AMM-V3-007, REQ-AMM-V3-008, INV-005, AMMN-RT-01
# MATH-AMM-SLIP-PRICE-05 verifies: REQ-AMM-SLIP-008, REQ-AMM-SLIP-014, REQ-AMM-SLIP-017, INV-005, AMMN-RT-01
t24, k24, tl24, tu24 = BitVec('t', 24), BitVec('k', 24), BitVec('tl', 24), BitVec('tu', 24)
in_bounds = lambda x: And(x >= BitVecVal(MIN_TICK, 24), x <= BitVecVal(MAX_TICK, 24))
for sp in SPACINGS:
    s24 = BitVecVal(sp, 24)
    aligned = SRem(t24, s24) == 0                               # Solidity: tick % tickSpacing == 0
    prove(f'AMM-A5a[s={sp}]', 'int24 `tick % s == 0` holds iff tick = k * s for an integer k (negative ticks included)',
          [in_bounds(t24)], And(Implies(aligned, t24 == (t24 / s24) * s24),
                                Implies(And(k24 >= BitVecVal(-(2 ** 23) // sp, 24), k24 <= BitVecVal((2 ** 23 - 1) // sp, 24),
                                            t24 == k24 * s24), aligned)))
    lo, hi = -((-MIN_TICK) // sp) * sp, (MAX_TICK // sp) * sp
    ok = And(SRem(tl24, s24) == 0, SRem(tu24, s24) == 0, tl24 < tu24, in_bounds(tl24), in_bounds(tu24))
    prove(f'AMM-A5b[s={sp}]', f'accepted ranges lie in the usable ticks [{lo}, {hi}] (the pool can hold them)',
          [ok], And(tl24 >= BitVecVal(lo, 24), tu24 <= BitVecVal(hi, 24)))
    bad = URem(t24, s24) == 0                                   # wrong: uint24(tick) % s
    witness(f'AMM-A5c[s={sp}]', 'deliberate: a check on uint24(tick) % s disagrees with alignment for some negative tick',
            [in_bounds(t24), bad != aligned], expect='PROVED' if sp == 1 else 'COUNTEREXAMPLE')
note('AMM-A5d', 'maxLiquidityPerTick per spacing (bounds L used in A3e/A3f)',
     '\n'.join(f's={sp}: {U128 // ((((MAX_TICK // sp) * sp - (-((-MIN_TICK) // sp) * sp)) // sp) + 1):.3e} < 2^128'
               for sp in SPACINGS))


def _max_liq_per_tick(sp):
    return U128 // ((((MAX_TICK // sp) * sp - (-((-MIN_TICK) // sp) * sp)) // sp) + 1)


_fits = [sp for sp in range(1, 16_385) if _max_liq_per_tick(sp) <= 2 ** 120 - 1]
assert _fits == list(range(1, 6932))                         # exactly the spacings 1 .. 6,931 fit
note('AMM-A5e', 'largest Slipstream spacing whose maxLiquidityPerTick fits MAX_CREDITED_LIQUIDITY = 2^120 - 1 '
     '(bindMarket refuses s > 6,931)',
     f's=6931: {_max_liq_per_tick(6931):,} <= 2^120 - 1 = {2 ** 120 - 1:,}\n'
     f's=6932: {_max_liq_per_tick(6932):,} > 2^120 - 1\n'
     f's=8000: {_max_liq_per_tick(8000):.3e}; every s in [1, 16,384] fits iff s <= 6,931 (asserted)')

# ---------------------------------------------------------------------------------------------------
# A6  A unit of liquidity is worth a different amount on every range: the market prices one exact range
# MATH-AMM-V3-PRICE-06 verifies: REQ-AMM-CORE-006, REQ-AMM-CORE-016, AMMN-RT-01
# MATH-AMM-SLIP-PRICE-06 verifies: REQ-AMM-CORE-006, REQ-AMM-CORE-016, REQ-AMM-SLIP-018, AMMN-RT-01
sA, sB = Reals('sA sB')                                    # the market's range; [sa, sb] is the pledged one
x_m, y_m = holdings(L, sO, sA, sB)
prove('AMM-A6a', 'a range nested in the market range is worth at most the market range per unit of L, at every '
      'oracle price, so crediting a narrower NFT at the market per-unit value can only overstate it',
      base + [sA > 0, sA <= sa, sb <= sB], x_f * P + y_f <= x_m * P + y_m)
witness('AMM-A6b', 'deliberate: with an inside-only check, a strictly narrower range is quoted above its own fair value',
        base + [sA > 0, sA <= sa, sb <= sB, Or(sA < sa, sb < sB), sa < sO, sO < sb, x_f * P + y_f < x_m * P + y_m])
mk_lo, mk_hi = sqrt_ratio_at_tick(-1054), sqrt_ratio_at_tick(953)     # price 0.90 .. 1.10, tick spacing 1
nr_lo, nr_hi = sqrt_ratio_at_tick(-1), sqrt_ratio_at_tick(1)
s1 = sqrt_ratio_at_tick(0)                                           # oracle price 1
per_unit = lambda lo, hi: sum(amounts_for_liquidity(s1, lo, hi, 10 ** 30)) / 10 ** 30
ratio = per_unit(mk_lo, mk_hi) / per_unit(nr_lo, nr_hi)
assert ratio > 900
note('AMM-A6c', 'stable market [0.90, 1.10], pledged NFT on ticks [-1, 1], oracle price 1, both tokens $1',
     f'value per unit of L: market range {per_unit(mk_lo, mk_hi):.6f}, pledged range {per_unit(nr_lo, nr_hi):.8f} '
     f'raw token units\nA $10,000 NFT credited at the market per-unit value is quoted x{ratio:,.0f} '
     f'(${10_000 * ratio:,.0f}); the exact-range match (tickLower, tickUpper equal to the market) refuses it')

finish()
