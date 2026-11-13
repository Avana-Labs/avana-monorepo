# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-74..75 — The borrow rate of every lend asset: Aave V4's kinked utilization curve (SPEC-HUB-007, Q-408).

Aave V4 @ a3ef63e, AssetInterestRateStrategy.calculateInterestRate (bps inputs, RAY output):
  rate = bpsToRay(baseDrawnRate)                                    if drawn == 0
  u    = rayDivUp(drawn, liquidity + drawn + swept)
  rate = base + rayDivUp(rayMulUp(bpsToRay(before), u), bpsToRay(opt))                   if u <= opt
  rate = base + bpsToRay(before) + rayDivUp(rayMulUp(bpsToRay(after), u - opt), RAY - opt)  otherwise
  with 1_00 <= optimalUsageRatio <= 99_00 and base + before + after <= MAX_ALLOWED_DRAWN_RATE (1000_00).
bpsToRay(x) = x * 1e23; rayMulUp(a, b) = ceil(a b / RAY); rayDivUp(a, b) = ceil(a RAY / b).
Avana's Hubs set no reinvestment controller (REQ-HUB-010), so swept = 0.
"""
from z3 import Ints, If, And
from _common import prove, computed, finish, ceil_div, RAY, BPS

B2R = 10**23                        # bpsToRay
MAX_RATE_BPS = 1000_00


def curve(u, base, bef, aft, opt, tag):
    """Exact integer rate (RAY) at usage ratio u (RAY) for a curve given in bps, and the rounding constraints."""
    o = opt * B2R
    m1, h1 = ceil_div(bef * B2R * u, RAY, f'm1_{tag}')
    t1, h2 = ceil_div(m1 * RAY, o, f't1_{tag}')
    m2, h3 = ceil_div(aft * B2R * (u - o), RAY, f'm2_{tag}')
    t2, h4 = ceil_div(m2 * RAY, RAY - o, f't2_{tag}')
    below = u <= o
    return If(below, base * B2R + t1, (base + bef) * B2R + t2), [If(below, And(*(h1 + h2)), And(*(h3 + h4)))]


# MATH-AR-74a: every curve (all four values symbolic, the V4 bounds), every utilization.
base, bef, aft, opt = Ints('baseDrawnRate rateGrowthBeforeOptimal rateGrowthAfterOptimal optimalUsageRatio')
params = [base >= 0, bef >= 0, aft >= 0, base + bef + aft <= MAX_RATE_BPS, opt >= 100, opt <= 9900]
u1, u2 = Ints('usage1 usage2')
r1, k1 = curve(u1, base, bef, aft, opt, 'a')
dom = [u1 >= 0, u1 <= RAY, u2 >= 0, u2 <= RAY]
# MATH-AR-74 verifies: SPEC-HUB-007, REQ-HUB-008
prove('MATH-AR-74a', 'every curve: the rate is never below baseDrawnRate at any utilization (a GHO floor set as the base holds)',
      params + dom + k1, r1 >= base * B2R)

# MATH-AR-74b..d: exact V4 integer rate over every utilization u in [0, RAY], for the SPEC-HUB-007 example curve and
# for curves at the edges of V4's bounds (optimal 1 % and 99 %, maximum rate 1,000 %, a stable curve with base 0).
CURVES = [('SPEC-HUB-007 GHO example 550/360/5000 at 90 %', (550, 360, 5000, 9000)),
          ('stable, base 0: 0/650/4000 at 92 %', (0, 650, 4000, 9200)),
          ('optimal 1 %: 100/200/99700 at 1 %', (100, 200, 99_700, 100)),
          ('optimal 99 %: 0/99000/1000 at 99 %', (0, 99_000, 1_000, 9900))]
for i, (label, (cb, cf, ca, co)) in enumerate(CURVES):
    ra, ka = curve(u1, cb, cf, ca, co, f'c{i}a')
    rb, kb = curve(u2, cb, cf, ca, co, f'c{i}b')
    prove(f'MATH-AR-74b{i + 1}', f'{label}: base <= rate <= base + before + after', dom + ka,
          And(ra >= cb * B2R, ra <= (cb + cf + ca) * B2R))
    prove(f'MATH-AR-74c{i + 1}', f'{label}: higher utilization never lowers the rate, across the kink',
          dom + ka + kb + [u1 <= u2], ra <= rb)
    prove(f'MATH-AR-74d{i + 1}', f'{label}: at the kink the rate is exactly base + before (no jump)',
          ka + [u1 == co * B2R], ra == (cb + cf) * B2R)

# MATH-AR-74h..l: the lemmas that carry 74b..d to every curve. Each growth term is ceil(ceil(G x / RAY) RAY / K) with
# G = growth x 1e23 >= 0, 0 <= x <= K (x = u for the first segment with K = U* x 1e23; x = u - K' for the second with
# K = RAY - K') and G x K a multiple of RAY. (h) G x is monotone in x and at most G K; (i) ceil(a / d) is monotone in a;
# (j) p <= k RAY gives ceil(p / RAY) RAY <= k RAY, so the inner ceiling stays <= G K; (k) a <= c d gives
# ceil(a / d) <= c, so each term is at most its growth G (the maximum, 74b); (l) ceil(c d / d) = c, so at x = K each
# term equals G exactly (the kink, 74d). Monotonicity (74c) follows from (h) and (i) within a segment, and across the
# kink from the first term being at most G there (j, k) and the second term being >= 0.
g, x, y, a, b, dd, c, k, pp = Ints('g x y a b d c k p')
qa, ha = ceil_div(a, dd, 'qa')
qb, hb = ceil_div(b, dd, 'qb')
qp, hp = ceil_div(pp, RAY, 'qp')
qc, hc = ceil_div(c * dd, dd, 'qc')
prove('MATH-AR-74h', 'lemma: g >= 0 and 0 <= x <= y  =>  g x <= g y', [g >= 0, x >= 0, x <= y], g * x <= g * y)
prove('MATH-AR-74i', 'lemma: a <= b and d > 0  =>  ceil(a / d) <= ceil(b / d)', ha + hb + [a <= b], qa <= qb)
prove('MATH-AR-74j', 'lemma: p <= k RAY  =>  ceil(p / RAY) x RAY <= k RAY', hp + [pp <= k * RAY], qp * RAY <= k * RAY)
prove('MATH-AR-74k', 'lemma: a <= c d, c >= 0, d > 0  =>  ceil(a / d) <= c', ha + [a <= c * dd, c >= 0], qa <= c)
prove('MATH-AR-74l', 'lemma: c >= 0, d > 0  =>  ceil(c d / d) = c', hc + [c >= 0], qc == c)

# Utilization: u = rayDivUp(drawn, liquidity + drawn) with swept = 0.
dr, lq, dr2, lq2 = Ints('drawn liquidity drawn2 liquidity2')
ua, ha = ceil_div(dr * RAY, lq + dr, 'u_before')
ub, hb = ceil_div(dr2 * RAY, lq2 + dr2, 'u_after')
hub = [dr >= 1, lq >= 0, dr < 2**128, lq < 2**128] + ha + hb
prove('MATH-AR-74e', 'a borrow (drawn up by x, liquidity down by x) never lowers utilization',
      hub + [dr2 >= dr, lq2 >= 0, dr2 + lq2 == dr + lq], ub >= ua)
prove('MATH-AR-74f', 'a withdrawal (liquidity down, drawn unchanged) never lowers utilization',
      hub + [dr2 == dr, lq2 >= 0, lq2 <= lq], ub >= ua)
prove('MATH-AR-74g', 'utilization stays within [0, RAY]', hub, And(ua >= 0, ua <= RAY))


def v4_rate(liquidity, drawn, base_b, bef_b, aft_b, opt_b):
    """Line-for-line port of calculateInterestRate with swept = 0."""
    def rmu(a, b):
        return -(-(a * b) // RAY)

    def rdu(a, b):
        return -(-(a * RAY) // b)
    r = base_b * B2R
    if drawn == 0:
        return r
    u = rdu(drawn, liquidity + drawn)
    o = opt_b * B2R
    if u <= o:
        return r + rdu(rmu(bef_b * B2R, u), o)
    return r + bef_b * B2R + rdu(rmu(aft_b * B2R, u - o), RAY - o)


# Illustrative GHO curve of SPEC-HUB-007: optimal 90 %, base 5.50 % (the floor, at or above a 5.00 % Core Hub GHO
# base rate), 3.60 % before the kink, 50.00 % after it. Amounts in whole GHO (the ratio is scale-free).
G = dict(base_b=550, bef_b=360, aft_b=5000, opt_b=9000)
# MATH-AR-75 verifies: SPEC-HUB-007, REQ-HUB-009
computed('MATH-AR-75a', 'SPEC-HUB-007 curve example: drawn rate at five utilizations (RAY)', [
    ('U = 0: base 5.50 %', 55 * 10**24, v4_rate(1_800_000, 0, **G)),
    ('U = 0.5 (900,000 drawn of 1,800,000): 7.50 %', 75 * 10**24, v4_rate(900_000, 900_000, **G)),
    ('U = 0.9 (kink): 9.10 %', 91 * 10**24, v4_rate(180_000, 1_620_000, **G)),
    ('U = 0.95 (1,710,000 drawn): 34.10 %', 341 * 10**24, v4_rate(90_000, 1_710_000, **G)),
    ('U = 1: maximum 59.10 %', 591 * 10**24, v4_rate(0, 1_800_000, **G))])
r50 = v4_rate(900_000, 900_000, **G)
r95 = v4_rate(90_000, 1_710_000, **G)
computed('MATH-AR-75b', 'SPEC-HUB-007 borrower and supplier figures at those rates (rp 15 %, liquidityFee 10 %)', [
    ('borrower of 100,000 at U 0.5: drawn interest 7,500 GHO', 7_500 * RAY, 100_000 * r50),
    ('premium 7,500 x 0.15 = 1,125 GHO', 1_125 * RAY, 100_000 * r50 * 1500 // BPS),
    ('borrow interest at U 0.5: 900,000 x 7.50 % x 1.15 = 77,625 GHO', 77_625 * RAY, 900_000 * r50 * 11500 // BPS),
    ('suppliers at U 0.5 receive 69,862.5 GHO (x10)', 698_625 * RAY,
     10 * 900_000 * r50 * 11500 * 9000 // (BPS * BPS)),
    ('borrower of 100,000 at U 0.95 pays 39,215 GHO a year', 39_215 * RAY, 100_000 * r95 * 11500 // BPS)])

finish()
