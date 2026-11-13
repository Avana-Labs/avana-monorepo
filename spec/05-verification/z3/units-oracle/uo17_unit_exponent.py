# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-77 — the concentrated-liquidity unit exponent k ([2.10] SPEC-ORC-005, [2.4] SPEC-UNIT-002).

One vault-token unit is 10^k liquidity, k fixed per pool at its first binding:
    e_ref = smallest e in [6, 36] with price8(amounts(10^e) on the one-spacing reference range) >= 10^8,
    k     = max(0, e_ref + 2 - 18)  (two decades of headroom), refused when k > 18;
    d     = smallest d in [6, 18] with price8(amounts(10^(d + k)) on the market's range) >= 10^8.
A position of liquidity L credits floor(L / 10^k) units; a removal of u units removes u * 10^k liquidity.
amounts() is v3-periphery LiquidityAmounts over the exact TickMath port (both round down); price8 is SPEC-ORC-008
with one raw unit off each token.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, Reals, And
from _common import (prove, witness, note, finish, sqrt_ratio_at_tick, tick_at_sqrt_ratio, usable_ticks, isqrt,
                     TOKENS, LAUNCH_PAIRS, pool_order, Q96, PRICE_ONE)

HEADROOM = 2


def amounts(s, sa, sb, liq):
    if s <= sa:
        return (liq * Q96 * (sb - sa) // sb // sa, 0)
    if s < sb:
        return (liq * Q96 * (sb - s) // sb // s, liq * (s - sa) // Q96)
    return (0, liq * (sb - sa) // Q96)


def price8(a, p, d):
    return sum((ai - 1) * pi // 10 ** di for ai, pi, di in zip(a, p, d) if ai > 1)


def oracle_sqrt(p0, p1, d0, d1):
    return isqrt(p0 * 10 ** d1 * 2 ** 192 // (p1 * 10 ** d0))


def first(lo, hi, p, d, s, frm, to):
    sa, sb = sqrt_ratio_at_tick(lo), sqrt_ratio_at_tick(hi)
    sc = min(max(s, sa), sb)
    for e in range(frm, to + 1):
        if price8(amounts(sc, sa, sb, 10 ** e), p, d) >= PRICE_ONE:
            return e
    return 0


def unit_exponent(p, d, spacing):
    s = oracle_sqrt(p[0], p[1], d[0], d[1])
    t = tick_at_sqrt_ratio(s)
    lo = (t // spacing) * spacing
    umin, umax = usable_ticks(spacing)
    lo = max(lo, umin)
    lo = min(lo, umax - spacing)
    e = first(lo, lo + spacing, p, d, s, 6, 34)
    if e == 0:
        return None
    return max(0, e + HEADROOM - 18)


def decimals(p, d, k, lo, hi):
    s = oracle_sqrt(p[0], p[1], d[0], d[1])
    e = first(lo, hi, p, d, s, 6 + k, 18 + k)
    return e - k if e else None


# ---------------------------------------------------------------------------
# MATH-UO-77a  Every launch pair lists on every spacing and on narrow, wide and full ranges at $1 legs.
rows, bad = [], []
for spacing in (1, 10, 60):
    umin, umax = usable_ticks(spacing)
    for a, b in LAUNCH_PAIRS:
        t0, t1 = pool_order(a, b)
        dec = (TOKENS[t0], TOKENS[t1])
        price = (PRICE_ONE, PRICE_ONE)
        k = unit_exponent(price, dec, spacing)
        # Ranges centred on the listing price's tick, aligned to the spacing (an 18/6 pair at $1 sits near -276,324).
        c = (tick_at_sqrt_ratio(oracle_sqrt(price[0], price[1], dec[0], dec[1])) // spacing) * spacing
        for w in (spacing * 10, spacing * 100, spacing * 1000, None):
            lo, hi = (umin, umax) if w is None else (max(c - w, umin), min(c + w, umax))
            dd = decimals(price, dec, k, lo, hi) if k is not None else None
            rows.append((spacing, t0, t1, w, k, dd))
            if dd is None or not 6 <= dd <= 18:
                bad.append(rows[-1])
# MATH-UO-77 verifies: SPEC-ORC-005, SPEC-UNIT-001, SPEC-UNIT-002
note('MATH-UO-77a', 'every launch pair, spacings 1/10/60, ranges of +-10, +-100, +-1,000 spacings around the price and full: d in [6, 18]',
     f'{len(rows)} listings, {len(bad)} unlistable; k per pool: ' +
     ', '.join(sorted({f'{r[1]}/{r[2]}@{r[0]}:k={r[4]}' for r in rows})))
assert not bad, bad

# MATH-UO-77b  The SPEC-ORC-005 example: GHO/USDS at $1, spacing 1.
g = (TOKENS['GHO'], TOKENS['USDS'])
p1 = (PRICE_ONE, PRICE_ONE)
kg = unit_exponent(p1, g, 1)
ex = [decimals(p1, g, kg, -10, 10), decimals(p1, g, kg, -100, 100), decimals(p1, g, kg, -1000, 1000),
      decimals(p1, g, kg, *usable_ticks(1))]
# MATH-UO-77 verifies: SPEC-ORC-005, SPEC-UNIT-002
note('MATH-UO-77b', 'SPEC-ORC-005 example: GHO/USDS spacing 1 has k = 7 and d = 15, 14, 13, 11 on +-10, +-100, '
     '+-1,000 and the full range', f'k = {kg}, d = {ex}')
assert kg == 7 and ex == [15, 14, 13, 11], (kg, ex)

# MATH-UO-77c  Without the exponent (k = 0) the same narrow ranges need d > 18: the listing limit k removes.
narrow = [decimals(p1, g, 0, -w, w) for w in (10, 100, 1000, 10_000)]
# MATH-UO-77 verifies: SPEC-ORC-005
note('MATH-UO-77c', 'wrong reading k = 0: GHO/USDS on +-10 .. +-10,000 ticks has no d in [6, 18] (unlistable)',
     f'd = {narrow}')
assert narrow == [None, None, None, None], narrow

# MATH-UO-77g  The reference search always ends inside [6, 34]: at the cheapest listing prices ($10^-8 per whole
#              token) two 18-decimal tokens on a one-tick range around par list at e <= 34.
cheap = (1, 1)
e_cheap = first(0, 1, cheap, g, oracle_sqrt(1, 1, 18, 18), 6, 34)
# MATH-UO-77 verifies: SPEC-ORC-005
note('MATH-UO-77g', 'cheapest listing prices ($1e-8, $1e-8), 18/18 decimals, one tick: the reference exponent is found below 34',
     f'e = {e_cheap}')
assert 0 < e_cheap <= 34, e_cheap

# MATH-UO-77d  Credit and removal: floor(L / 10^k) units, the remainder below one unit stays with the NFT, and a
#              removal of u <= credited units removes u * 10^k <= L liquidity.
L, K, u, q = Ints('L K u q')
hyp = [L >= 0, K >= 1, q * K <= L, L < q * K + K, u >= 0, u <= q]
# MATH-UO-77 verifies: SPEC-UNIT-002, SPEC-BACK-010
prove('MATH-UO-77d', 'credited q = floor(L / 10^k): 0 <= L - q*10^k < 10^k, and u <= q removes u*10^k <= L',
      hyp, And(L - q * K >= 0, L - q * K < K, u * K <= L))

# MATH-UO-77e  Headroom: with k = e_ref + 2 - 18, a market whose liquidity is worth at least 1/100 of the reference
#              range's per unit lists at d <= 18 (over the reals, x = 10^e).
xr, vref, vm = Reals('xref vref vm')
# MATH-UO-77 verifies: SPEC-ORC-005
prove('MATH-UO-77e', 'xref * vref >= $1 and vm >= vref / 100 imply (100 * xref) * vm >= $1 (so e_m <= e_ref + 2 = 18 + k)',
      [xr > 0, vref > 0, vm > 0, xr * vref >= 1, vm * 100 >= vref], (100 * xr) * vm >= 1)

# MATH-UO-77f  Wrong reading without headroom (k = e_ref - 18): a market worth 1/50 of the reference per unit needs
#              more than 10^(18 + k) liquidity for $1.
# MATH-UO-77 verifies: SPEC-ORC-005
witness('MATH-UO-77f', 'k without headroom: xref * vref = $1 and vm = vref / 50 leave xref * vm < $1 (d > 18)',
        [xr > 0, vref > 0, vm > 0, xr * vref == 1, vm * 50 == vref, xr * vm < 1])

finish()
