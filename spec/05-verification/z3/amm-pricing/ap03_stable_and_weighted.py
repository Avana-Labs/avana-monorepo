# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""AMM-C — n-token pools: StableSwap (NG style) and weighted pools.

Weighted (sum w_i = 1):  k = prod b_i^w_i,  fair value V = k * prod (p_i / w_i)^w_i,
                         fair balances b_i* = w_i V / p_i (the balances an arbitraged pool holds)
StableSwap:              D from  A n^n sum x + D = A D n^n + D^(n+1) / (n^n prod x),
                         quote per LP = min_i(p_i) * D / supply  (= min price * virtual_price),
                         a lower bound, not a fair value

Fractional powers are encoded with fifth / cube roots (b_i = a_i^5 etc.) so Z3 sees polynomials.
Simulations use the integer StableSwap port and an 80-digit weighted-pool model in _common.py.

Check IDs: MATH-AMM-BAL-PRICE-01, 02 (weighted) and MATH-AMM-CURVE-PRICE-01, 02 (StableSwap).
"""
import os
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mpmath
from z3 import Reals, And, RealVal
from _common import prove, witness, note, finish, StableSwap

# ---------------------------------------------------------------------------------------------------
# C1  Weighted pool: the fair quote never exceeds the redeemable value at oracle prices
# MATH-AMM-BAL-PRICE-01 verifies: SPEC-AMM-CORE-001, SPEC-AMM-BAL-001, REQ-AMM-BAL-005, INV-078, AMMN-RT-07
a, c, x, y = Reals('a c x y')             # b1 = a^5, b2 = c^5, p1/w1 = x^5, p2/w2 = y^5 (80/20)
pos = [a > 0, c > 0, x > 0, y > 0]
V8020 = a ** 4 * c * x ** 4 * y           # k * prod (p_i/w_i)^w_i with k = b1^0.8 b2^0.2
R8020 = a ** 5 * RealVal(F(4, 5)) * x ** 5 + c ** 5 * RealVal(F(1, 5)) * y ** 5    # b1 p1 + b2 p2
prove('AMM-C1a', '80/20 pool: V = k (p1/0.8)^0.8 (p2/0.2)^0.2 <= b1 p1 + b2 p2 (weighted AM-GM)', pos, V8020 <= R8020)
u1, u2, u3 = Reals('u1 u2 u3')            # u_i = b_i^(1/3) (p_i/w_i)^(1/3), three tokens at 1/3 each
prove('AMM-C1b', '1/3-1/3-1/3 pool: V = prod (b_i p_i / w_i)^(1/3) <= sum b_i p_i', [u1 > 0, u2 > 0, u3 > 0],
      u1 * u2 * u3 <= (u1 ** 3 + u2 ** 3 + u3 ** 3) / 3)
b, dl, g = Reals('b dl g')
prove('AMM-C1c', 'one swap of size dl into token i with fee (gamma = 1 - fee) grows k by ((b + dl)/(b + gamma dl))^w_i '
      '<= gamma^-w_i: base inequality (b + dl)/(b + gamma dl) <= 1/gamma',
      [b > 0, dl > 0, g > 0, g < 1], (b + dl) * g <= b + g * dl)
D0, D1, s, s2 = Reals('D0 D1 s s2')
prove('AMM-C1d', '50/50 pool at the oracle price: a donation raises V by at most its value (same as AMM-B3a)',
      [a > 0, c > 0, x > 0, y > 0, D0 >= 0, D1 >= 0, a * x == c * y, s >= 0, s * s == a * c * x * y,
       s2 >= 0, s2 * s2 == (a + D0) * (c + D1) * x * y], 2 * s2 - 2 * s <= D0 * x + D1 * y)

# ---------------------------------------------------------------------------------------------------
# C2  StableSwap: D lies between the geometric bound and the sum of balances (n = 2)
# MATH-AMM-CURVE-PRICE-01 verifies: SPEC-AMM-CORE-001, SPEC-AMM-CURVE-001, REQ-AMM-CURVE-001, INV-078, AMMN-RT-07
A, D, xx, yy, pm, px, py, gm = Reals('A D x y pmin px py gm')
inv = [A > 0, xx > 0, yy > 0, D > 0, 4 * A * (xx + yy) + D == 4 * A * D + D ** 3 / (4 * xx * yy)]
prove('AMM-C2a', 'n = 2: any positive D solving the invariant satisfies D <= x + y', inv, D <= xx + yy)
prove('AMM-C2b', 'n = 2: and D >= 2 sqrt(x y) (D^2 >= 4 x y)', inv, D * D >= 4 * xx * yy)
prove('AMM-C2c', 'quote min(p) * D <= x px + y py (the lower-bound quote never exceeds the redeemable value), any A, any imbalance',
      inv + [px > 0, py > 0, pm > 0, pm <= px, pm <= py], pm * D <= xx * px + yy * py)
witness('AMM-C2d', 'deliberate: max(p) * D (or a mean price) is NOT a safe quote: it can exceed the redeemable value when '
        'the pool is imbalanced toward the cheaper coin',
        inv + [px == 1, py == RealVal(F(9, 10)), A == 10, xx == 1, yy == 9, D * px > xx * px + yy * py])

# ---------------------------------------------------------------------------------------------------
# Simulations (exact integers for StableSwap; 80-digit reals for the weighted pool)
# MATH-AMM-CURVE-PRICE-02 verifies: SPEC-AMM-CURVE-001, REQ-AMM-CURVE-006, REQ-AMM-CORE-014, AMMN-RT-07
E18 = 10 ** 18
pool = StableSwap([10 ** 6 * E18, 10 ** 6 * E18])
vp0 = pool.virtual_price()
rows = []
for dx in (10 ** 4 * E18, 10 ** 5 * E18, 9 * 10 ** 5 * E18, 2 * 10 ** 6 * E18, 5 * 10 ** 6 * E18):
    p = StableSwap([10 ** 6 * E18, 10 ** 6 * E18])
    out = p.exchange(0, 1, dx)
    gain = F(p.D() - pool.D(), E18)                  # quote gain of all LPs, both coins at $1
    loss = F(dx - out, E18)                          # swapper's loss at $1 prices
    assert gain <= loss
    rows.append(f'swap {dx // E18:>9,}: vp x{p.virtual_price() / vp0:.8f}, balances {p.x[0] / 1e24:.3f}M / '
                f'{p.x[1] / 1e24:.4f}M, quote gain ${float(gain):,.0f} <= swapper loss ${float(loss):,.0f}')
note('AMM-C3', 'StableSwap A=200, fee 4 bps, off-peg multiplier 2, 1M/1M: virtual price after one imbalancing swap',
     '\n'.join(rows) + '\nvp rises only through the fee kept in the pool; near full imbalance D is very sensitive to the\n'
     'retained fee (+26.6% for a 5M swap) but the swapper pays far more than the quote gains')

worst = F(0)
for pmin_ in (F(95, 100), F(99, 100), F(1)):
    for dx in (10 ** 5 * E18, 9 * 10 ** 5 * E18, 5 * 10 ** 6 * E18):
        p = StableSwap([10 ** 6 * E18, 10 ** 6 * E18])
        p.exchange(0, 1, dx)                    # pool now holds mostly the coin priced pmin_
        quote = pmin_ * p.D()
        redeem = pmin_ * p.x[0] + p.x[1]        # coin 0 at pmin_, coin 1 at $1
        worst = max(worst, quote / redeem)
note('AMM-C4', 'StableSwap after imbalancing swaps, coin 0 depegged to 0.95 / 0.99 / 1.00: max of quote / redeemable',
     f'{float(worst):.8f} (<= 1: the min(p) * D quote stays below what the LP redeems for at the oracle prices)')

p = StableSwap([10 ** 6 * E18, 10 ** 6 * E18])
p.donate([10 ** 5 * E18, 0])
note('AMM-C5', 'StableSwap donation of 100,000 of coin 0 (balance-read pool, e.g. rebasing coins or a direct balance update)',
     f'vp x{p.virtual_price() / vp0:.6f}: the quote rises by about the donation / supply and the donation stays in the pool')

# MATH-AMM-BAL-PRICE-02 verifies: REQ-AMM-BAL-005, REQ-AMM-CORE-014, AMMN-RT-07
mpmath.mp.dps = 80
W = [mpmath.mpf(4) / 5, mpmath.mpf(1) / 5]


def wk(bal):
    return bal[0] ** W[0] * bal[1] ** W[1]


def wfair(bal, prices):
    return wk(bal) * (prices[0] / W[0]) ** W[0] * (prices[1] / W[1]) ** W[1]


def wswap(bal, i, amt, fee=mpmath.mpf(3) / 1000):
    o = 1 - i
    out = bal[o] * (1 - (bal[i] / (bal[i] + amt * (1 - fee))) ** (W[i] / W[o]))
    nb = list(bal)
    nb[i] += amt
    nb[o] -= out
    return nb


prices = [mpmath.mpf(1), mpmath.mpf(1)]
bal = [mpmath.mpf(8 * 10 ** 6), mpmath.mpf(2 * 10 ** 6)]          # 80/20 at the oracle price
v0 = wfair(bal, prices)
g_rows, ratio_max = [], mpmath.mpf(0)
for amt in (10 ** 4, 10 ** 6, 10 ** 8, 10 ** 11):
    for i in (0, 1):
        nb = wswap(bal, i, mpmath.mpf(amt))
        g = wfair(nb, prices) / v0 - 1
        bound = (1 - mpmath.mpf(3) / 1000) ** (-W[i]) - 1
        assert g <= bound
        ratio_max = max(ratio_max, wfair(nb, prices) / (nb[0] * prices[0] + nb[1] * prices[1]))
        g_rows.append(f'in token{i} {amt:>15,}: +{mpmath.nstr(g * 100, 6)}% (bound +{mpmath.nstr(bound * 100, 6)}%)')
note('AMM-C6', 'weighted 80/20, fee 0.3%: fair quote gain from one swap, and max of fair / redeemable after it',
     '\n'.join(g_rows) + f'\nmax fair / redeemable = {mpmath.nstr(ratio_max, 10)} (<= 1)')

finish()
