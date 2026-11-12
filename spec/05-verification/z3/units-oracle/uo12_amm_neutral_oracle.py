# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-50..57 and 72 — AMM-neutral LPOracle rules of [2.10]: per-feed freshness, the clamped
concentrated-liquidity composition with floor-then-one-unit, monotonicity in every price, the
n-token USD band, second-source agreement, the L2 sequencer gate, the observation buffer per
chain block time, the 63/64 gas guard, and the token-decimals verification with the
second-source confirmation as borrow-only gates.

Formulas (final text of spec/02-contracts/10-lp-oracle.md):
  SPEC-ORC-019  feedMaxAge = feedHeartbeat + heartbeatMargin; borrowPriceMaxAge <= feedMaxAge
  SPEC-ORC-015  maxAge() = min_l(updatedAt_l + limit_l) - servedUpdatedAt
  SPEC-ORC-006  s = min(max(sO, sa), sb); amounts by getAmountsForLiquidity (floor)
  SPEC-ORC-008  price8 = max(1, sum_i floor((a_i - 1)^+ * v_i / 10^d_i))
  SPEC-ORC-005  d = smallest integer in [6, 18] with price8(10^d) >= 1e8
  SPEC-ORC-007  composition value is the minimum over pool prices, hence non-decreasing in each price
  SPEC-ORC-011  low^(x)n <= (x)_i q_i and (x)_i v_i <= high^(x)n, x (x) y = floor(x*y/1e8)
  SPEC-ORC-020  |q - s| * 1e4 <= S * min(q, s)
  SPEC-ORC-021  ready = up and now >= startedAt + grace; down pauses seizure; unknown (incl. an answer
                that is not exactly 160 bytes) blocks borrow only
  SPEC-ORC-022  twapMinObservations = ceil(W / blockTime) + 1
  SPEC-ORC-023  pre-call check gasleft >= ceil(64 G / 63) + POST; forwarded = min(G, g - floor(g/64))
  REQ-ORACLE-107 borrowAllowed requires now - decimalsCheckedAt <= 7,200; a mismatch fails the market
"""
import importlib.util
import math
import os
import random

from z3 import (And, If, Implies, Int, Ints, Not, Or, Real, Reals, Bool, Bools, ToInt)

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('uo_common', os.path.join(_here, '_common.py'))
uo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uo)
prove, witness, note, finish = uo.prove, uo.witness, uo.note, uo.finish
Q96 = 2 ** 96


def amounts(s, sa, sb, liq):
    """LiquidityAmounts.getAmountsForLiquidity at sqrt price s for [sa, sb] (floor)."""
    if s <= sa:
        return uo.mul_div(liq << 96, sb - sa, sb) // sa, 0
    if s < sb:
        return uo.mul_div(liq << 96, sb - s, sb) // s, uo.mul_div(liq, s - sa, Q96)
    return 0, uo.mul_div(liq, sb - sa, Q96)


def sqrt_ref(x0, x1, d0, d1):
    return math.isqrt(x0 * 10 ** d1 * 2 ** 192 // (x1 * 10 ** d0))


def price8_cl(v, dec, tl, tu, d, clamp=True):
    sO = sqrt_ref(v[0], v[1], dec[0], dec[1])
    sa, sb = uo.sqrt_ratio_at_tick(tl), uo.sqrt_ratio_at_tick(tu)
    s = min(max(sO, sa), sb) if clamp else sO
    if clamp:
        a = amounts(s, sa, sb, 10 ** d)
    else:  # textbook formulas at the unclamped ratio, negative amount floored at 0
        a0 = max(uo.mul_div(10 ** d << 96, sb - sO, sb) // sO if sb > sO else 0, 0)
        a1 = uo.mul_div(10 ** d, sO - sa, Q96) if sO > sa else 0
        a = (a0, a1)
    ap = [max(x - 1, 0) for x in a]
    return max(1, sum(ap[i] * v[i] // 10 ** dec[i] for i in range(2))), a


# ---------------------------------------------------------------- MATH-UO-50 freshness (SPEC-ORC-019)
# MATH-UO-50 verifies: SPEC-ORC-019, SPEC-ORC-015, REQ-ORACLE-002, REQ-ORACLE-054
now, m = Ints('now margin')
hb = Ints('hb0 hb1 hb2')
up = Ints('u0 u1 u2')
lim = [hb[i] + m for i in range(3)]
served = Int('served')

legs = [And(hb[i] > 0, hb[i] <= 86_400, up[i] <= now, up[i] >= 0) for i in range(3)]
mn = Int('minUpd')
dl = Int('deadline')
h50 = legs + [m >= 0,
              mn <= up[0], mn <= up[1], mn <= up[2], Or(mn == up[0], mn == up[1], mn == up[2]),
              dl <= up[0] + lim[0], dl <= up[1] + lim[1], dl <= up[2] + lim[2],
              Or(dl == up[0] + lim[0], dl == up[1] + lim[1], dl == up[2] + lim[2])]
prove('MATH-UO-50a', 'per-feed limits: maxAge = deadline - servedUpdatedAt >= 0, and now - servedUpdatedAt <= maxAge '
      'iff every leg is within its own heartbeat + margin', h50,
      And(dl - mn >= 0, (now - mn <= dl - mn) == And(*[now - up[i] <= lim[i] for i in range(3)])))
age = Int('age')
witness('MATH-UO-50b', 'wrong reading (old min(heartbeat + 600, 4,200)): a 86,400 s stable feed operating normally at '
        'age 13,500 s (the observed USDC/USD age) is refused although no round is due',
        [age == 13_500, age > min(86_400 + 600, 4_200), age <= 86_400])
note('MATH-UO-50c', 'launch feed limits with heartbeatMargin = 1,800 s',
     '\n'.join(f'{n}: heartbeat {h} -> feedMaxAge {h + 1800}' for n, h in
               [('ETH USDC/USD', 82_800), ('ETH USDT/USD', 86_400), ('ETH GHO/USD', 86_400), ('ETH USDS/USD', 82_800),
                ('ETH DAI/USD', 3_600), ('ETH ETH/USD', 3_600), ('Base USDC/USD', 86_400)]) +
     '\nSPEC-ORC-015 example deadline min(1,762,684,600, 1,762,728,200, 1,762,650,400) - 1,762,600,000 = ' +
     str(min(1_762_600_000 + 84_600, 1_762_640_000 + 88_200, 1_762_645_000 + 5_400) - 1_762_600_000))

# ---------------------------------------------------------------- MATH-UO-51 clamp, floor, -1 (SPEC-ORC-006/008)
# MATH-UO-51 verifies: SPEC-ORC-006, SPEC-ORC-008, SPEC-ORC-005, REQ-ORACLE-012, REQ-ORACLE-050
a0, a1, e0, e1, p0, p1 = Reals('a0 a1 e0 e1 p0 p1')
f0, f1 = Ints('f0 f1')
hyp51 = [e0 >= 0, e1 >= 0, p0 > 0, p1 > 0, a0 >= 0, a1 >= 0, a0 < e0 + 1, a1 < e1 + 1,
         f0 == If(a0 >= 1, ToInt(a0) - 1, 0), f1 == If(a1 >= 1, ToInt(a1) - 1, 0)]
prove('MATH-UO-51a', 'each floored amount within one raw unit above the exact amount: (a_i - 1)^+ valued at any '
      'prices never exceeds the exact composition value', hyp51, f0 * p0 + f1 * p1 <= e0 * p0 + e1 * p1)
sP, sa_, sb_, L = Reals('sP sa sb L')
hc = [sa_ > 0, sb_ > sa_, sP > sb_, L > 0]
prove('MATH-UO-51b', 'above the range the unclamped token1 amount L(sP - sa) exceeds the true holding L(sb - sa): '
      'unclamped math overvalues, the clamp removes it', hc, L * (sP - sa_) > L * (sb_ - sa_))
# integer sampling of the exact claim at the reference amount 10^d
rnd = random.Random(20261110)
worst, n_ok, n = None, 0, 0
from fractions import Fraction
from decimal import Decimal, getcontext
getcontext().prec = 80
for _ in range(400):
    dec = rnd.choice([(6, 6), (18, 6), (6, 18), (18, 18), (8, 18)])
    sp_ = rnd.choice([1, 10, 50, 60, 100, 200])
    w = rnd.randint(1, 400) * sp_
    c = rnd.randint(-200, 200) // sp_ * sp_
    tl, tu = c - w, c + w
    v = [rnd.randint(90_000_000, 110_000_000), rnd.randint(90_000_000, 110_000_000)]
    d = None
    for dd in range(6, 19):
        if price8_cl(v, dec, tl, tu, dd)[0] >= 10 ** 8:
            d = dd
            break
    if d is None:
        continue
    pr, _ = price8_cl(v, dec, tl, tu, d)
    # exact fair value at the exact (unfloored) sqrt price, clamped
    ratio = Decimal(v[0] * 10 ** dec[1]) / Decimal(v[1] * 10 ** dec[0])
    sx = ratio.sqrt() * Decimal(Q96)
    sa, sb = Decimal(uo.sqrt_ratio_at_tick(tl)), Decimal(uo.sqrt_ratio_at_tick(tu))
    s = min(max(sx, sa), sb)
    Ld = Decimal(10 ** d)
    x0 = Ld * Decimal(Q96) * (sb - s) / (sb * s)
    x1 = Ld * (s - sa) / Decimal(Q96)
    exact = x0 * v[0] / Decimal(10 ** dec[0]) + x1 * v[1] / Decimal(10 ** dec[1])
    n += 1
    if Decimal(pr) <= exact:
        n_ok += 1
    gap = exact - Decimal(pr)
    worst = gap if worst is None or gap < worst else worst
p_rt, a_rt = price8_cl([10 ** 8, 95_200_000], [6, 6], -100, 100, 9)
p_un, a_un = price8_cl([10 ** 8, 95_200_000], [6, 6], -100, 100, 9, clamp=False)
p_ex, a_ex = price8_cl([99_987_000, 10 ** 8], [6, 6], -10, 10, 10)
p_dai, a_dai = price8_cl([10 ** 8, 10 ** 8], [18, 6], -887_270, 887_270, 12)
note('MATH-UO-51c', 'exact-integer sampling (400 draws: ranges, spacings, decimals, prices $0.90-$1.10, d by SPEC-ORC-005) '
     'and the worked examples',
     f'price8 <= exact fair value at the exact oracle price in {n_ok} of {n} samples; smallest margin {float(worst):.3f} units\n'
     f'RT-02 example d=9: clamped a={a_rt}, price8={p_rt}; unclamped a={a_un}, price8={p_un}; ratio {p_un / p_rt:.3f}\n'
     f'USDC/USDT [-10,10] d=10: a={a_ex}, price8={p_ex}; DAI/USDC full range d=12: a={a_dai}, price8={p_dai}')
assert n_ok == n and p_rt == 951_956_208 and p_ex == 999_630_568 and p_dai == 199_999_799

# ---------------------------------------------------------------- MATH-UO-52 monotone in every price
# MATH-UO-52 verifies: SPEC-ORC-007, SPEC-ORC-004, SPEC-ORC-017
x0a, x1a, y0a, y1a, q0, q0p, q1 = Reals('x0a x1a y0a y1a q0 q0p q1')
# x = composition at (q0, q1); y = composition at (q0p, q1); minimum property instantiated at both
h52 = [x0a >= 0, x1a >= 0, y0a >= 0, y1a >= 0, q0 > 0, q1 > 0, q0p >= q0,
       x0a * q0 + x1a * q1 <= y0a * q0 + y1a * q1]          # SPEC-ORC-007 at (q0, q1) vs holding y
prove('MATH-UO-52', 'the composition value is non-decreasing in each price: V(q0, q1) <= V(q0p, q1) for q0 <= q0p, '
      'so the stable ceiling and the lower route of a disagreement only lower price8', h52,
      x0a * q0 + x1a * q1 <= y0a * q0p + y1a * q1)

# ---------------------------------------------------------------- MATH-UO-53 n-token USD band
# MATH-UO-53 verifies: SPEC-ORC-011, REQ-ORACLE-015
lo, qa, qb, qc = Ints('low qa qb qc')
E = 10 ** 8
b2 = [lo > 0, qa > 0, qb > 0, lo <= 10 ** 12, qa <= 10 ** 12, qb <= 10 ** 12]
prove('MATH-UO-53a', 'n = 2: the exact test low^2 <= q0*q1 implies the fixed-point test floor(low^2/1e8) <= floor(q0*q1/1e8)',
      b2, Implies(lo * lo <= qa * qb, (lo * lo) / E <= (qa * qb) / E))
prove('MATH-UO-53b', 'n = 2: the fixed-point test passing implies low^2 < q0*q1 + 1e8 (differs only within 1e-8 of the edge)',
      b2, Implies((lo * lo) / E <= (qa * qb) / E, lo * lo < qa * qb + E))
g3 = Int('g3')
b3 = b2 + [qc > 0, qc <= 10 ** 12, g3 == ((qa * qb) / E) * qc / E]
prove('MATH-UO-53c', 'n = 3: the left-to-right fixed-point product is at most the exact product / 1e16 and at least it minus (qc/1e8 + 1)',
      b3, And(g3 * E * E <= qa * qb * qc, (g3 + 1) * E * E + qc * E > qa * qb * qc))
note('MATH-UO-53d', 'band examples', f'GHO/USDC uncapped {104_700_000 * 10 ** 8 // E} capped {10 ** 8} vs low^2 {90_000_000 ** 2 // E}, '
     f'high^2 {102_000_000 ** 2 // E}; both at 0.89: {89_000_000 ** 2 // E}; three tokens: '
     f'{((99_990_000 * 10 ** 8 // E) * 99_980_000) // E} vs {((90_000_000 ** 2 // E) * 90_000_000) // E}')

# ---------------------------------------------------------------- MATH-UO-54 second source
# MATH-UO-54 verifies: SPEC-ORC-020, REQ-ORACLE-100
q_, s_, S_ = Ints('q s S')
b54 = [q_ >= 1, s_ >= 1, q_ <= 10 ** 12, s_ <= 10 ** 12, S_ >= 0, S_ < 2 ** 16]
ag = lambda a, b: If(a > b, a - b, b - a) * 10 ** 4 <= S_ * If(a < b, a, b)
prove('MATH-UO-54a', 'second-source test is symmetric in (quote, second source): |q - s| = |s - q| and min(q, s) = min(s, q), '
      'so both sides of the test are unchanged when the two values swap', b54,
      And(If(q_ > s_, q_ - s_, s_ - q_) == If(s_ > q_, s_ - q_, q_ - s_), If(q_ < s_, q_, s_) == If(s_ < q_, s_, q_)))
prove('MATH-UO-54b', 'both sides fit 256 bits: |q - s| * 1e4 < 2^256 and S * min(q, s) < 2^256', b54,
      And(If(q_ > s_, q_ - s_, s_ - q_) * 10 ** 4 < 2 ** 256, S_ * If(q_ < s_, q_, s_) < 2 ** 256))
note('MATH-UO-54c', 'SPEC-ORC-020 example (S = 100, q = 100,020,000)',
     f's = 99,400,000: {620_000 * 10 ** 4} <= {100 * 99_400_000} -> {620_000 * 10 ** 4 <= 100 * 99_400_000}; '
     f's = 98,900,000: {1_120_000 * 10 ** 4} <= {100 * 98_900_000} -> {1_120_000 * 10 ** 4 <= 100 * 98_900_000}')

# ---------------------------------------------------------------- MATH-UO-55 sequencer gate
# MATH-UO-55 verifies: SPEC-ORC-021, REQ-ORACLE-099, REQ-ORACLE-034, SPEC-ORC-016
ans, st, gp, t, sv, retLen = Ints('answer startedAt grace now55 servedUpdatedAt returnLength')
called, decodes, hasFeed, other = Bools('called decodes hasFeed otherPause')
# The uptime read succeeds only on a call that did not revert, a return of exactly 160 bytes (the five words of
# latestRoundData()) and words that decode; any other length is unknown, whatever its first 160 bytes report.
readok = And(called, retLen == 160, decodes)
upS = And(hasFeed, readok, ans == 0, st != 0, st <= t)
downS = And(hasFeed, readok, ans == 1)
unknownS = And(hasFeed, Not(upS), Not(downS))
ready = Or(Not(hasFeed), And(upS, t >= st + gp))
graceS = And(upS, t < st + gp)
paused = Or(other, downS)
# The restart rule: on an L2 the served price's oldest round must be newer than the restart (startedAt).
borrowOk = And(ready, Or(Not(upS), sv > st))
b55 = [gp >= 0, t >= 0, sv >= 1, sv <= t]
prove('MATH-UO-55a', 'borrowAllowed implies no feed, or the sequencer up for at least the grace period', b55,
      Implies(borrowOk, Or(Not(hasFeed), And(ans == 0, t - st >= gp))))
prove('MATH-UO-55f', 'borrowAllowed on an L2 implies the served price comes from rounds newer than the restart', b55,
      Implies(And(hasFeed, borrowOk), sv > st))
prove('MATH-UO-55g', 'a chain without a sequencer feed is unchanged: borrowOk holds for every served round time',
      b55, Implies(Not(hasFeed), borrowOk))
witness('MATH-UO-55h', 'wrong reading (the grace period alone): past the grace period a price whose round is from '
        'before the restart (sized on prices nobody could react to) would admit a borrow',
        b55 + [hasFeed, upS, t >= st + gp, sv <= st, ready])
prove('MATH-UO-55b', 'down: seizure paused and borrowing blocked', b55, Implies(downS, And(paused, Not(borrowOk))))
prove('MATH-UO-55c', 'an unreadable or unexpected uptime feed blocks borrowing but never pauses seizure by itself',
      b55, Implies(And(unknownS, Not(other)), And(Not(borrowOk), Not(paused))))
prove('MATH-UO-55d', 'after a restart grace and ready partition time: exactly one holds while the sequencer is up', b55,
      Implies(And(hasFeed, upS), Or(And(graceS, Not(ready)), And(ready, Not(graceS)))))
prove('MATH-UO-55i', 'an uptime answer that is not exactly 160 bytes is unknown: borrowing blocked and seizure not '
      'paused by it, whatever its words report', b55 + [retLen >= 0],
      Implies(And(hasFeed, retLen != 160, Not(other)), And(unknownS, Not(borrowOk), Not(paused))))
# The wrong reading decodes the first five words of any answer of at least 160 bytes.
downLong = And(hasFeed, called, retLen >= 160, decodes, ans == 1)
witness('MATH-UO-55j', 'wrong reading (at least 160 bytes): a 192-byte answer whose first five words report down '
        'pauses seizure', b55 + [retLen == 192, downLong, Not(other)])
note('MATH-UO-55e', 'Base example', f'restart 1,010,000, grace 3,600: grace until {1_010_000 + 3_600 - 1}, borrowing from {1_010_000 + 3_600} '
     f'on a round newer than the restart; at 1,013,600 a round of 1,009,000 admits a borrow: {1_009_000 > 1_010_000}; '
     f'a round of 1,010,000: {1_010_000 > 1_010_000}; a round of 1,013,000: {1_013_000 > 1_010_000}')

# ---------------------------------------------------------------- MATH-UO-56 observation buffer
# MATH-UO-56 verifies: SPEC-ORC-022, REQ-ORACLE-055
W_, bt, k = Ints('W blockTime k')
b56 = [W_ > 0, bt > 0, k == (W_ + bt - 1) / bt + 1]
prove('MATH-UO-56a', 'k = ceil(W / blockTime) + 1 observations written one per block span (k - 1) * blockTime >= W',
      b56, (k - 1) * bt >= W_)
witness('MATH-UO-56b', 'wrong reading (buffer sized for 12 s blocks used on a 2 s chain, W = 1,800): 151 observations '
        'span 300 s < W, so observe reverts OLD after 151 dust swaps',
        [W_ == 1800, bt == 2, k == 1800 / 12 + 1, (k - 1) * bt < W_])
note('MATH-UO-56c', 'per-chain buffers for W = 1,800',
     f'Ethereum (12 s): {math.ceil(1800 / 12) + 1}; Base (2 s): {math.ceil(1800 / 2) + 1}')

# ---------------------------------------------------------------- MATH-UO-57 63/64 gas guard
# MATH-UO-57 verifies: SPEC-ORC-023, REQ-ORACLE-102, REQ-ORACLE-024, REQ-ORACLE-039, REQ-ORACLE-038
g, G, P = Ints('gasleft G post')
fwd = If(G < g - g / 64, G, g - g / 64)
b57 = [G > 0, g >= 0, P >= 0]
prove('MATH-UO-57a', 'pre-call check gasleft >= ceil(64 G / 63) + post: the read receives exactly G (independent of the '
      'transaction gas limit)', b57 + [g >= (64 * G + 62) / 63 + P], fwd == G)
pm, F = Ints('pokeMinGas feedNeed')
witness('MATH-UO-57b', 'wrong reading (only gasleft >= pokeMinGas after the catch): a read starved below what the feed '
        'needs still leaves >= pokeMinGas, so the starved failure is accepted as a feed failure',
        [pm == 150_000, F > 63 * pm, g - fwd >= pm, fwd < F, G >= F] + b57)
u1, u2, u3, Wp, Ga, Gb, Gc = Ints('u1 u2 u3 Wpoke G1 G2 G3')
pre = lambda Gk: (64 * Gk + 62) / 63 + 5_000
floor_ = Int('floor')
h57c = [u1 >= 0, u1 <= u2, u2 <= u3, u3 <= Wp, Ga > 0, Gb > 0, Gc > 0,
        floor_ >= Wp, floor_ >= u1 + pre(Ga), floor_ >= u2 + pre(Gb), floor_ >= u3 + pre(Gc), g >= floor_]
prove('MATH-UO-57c', 'entry gas >= max(W_poke, max_k(u_k + ceil(64 G_k / 63) + post)) (reads at u_1 <= u_2 <= u_3 <= W_poke '
      'with any explicit gas): every pre-call check passes and the whole poke fits, so a poke at pokeMinGas never '
      'reverts InsufficientGas', h57c, And(g - u1 >= pre(Ga), g - u2 >= pre(Gb), g - u3 >= pre(Gc), g >= Wp))
prove('MATH-UO-57e', 'the per-read floor is at most the single-term bound W_poke + ceil(64 G_max / 63) + post with G_max '
      'the largest G_k, so the bound of 1.5 is a safe floor when the reads are not measured one by one',
      [u1 >= 0, u1 <= u2, u2 <= u3, u3 <= Wp, Ga > 0, Gb > 0, Gc > 0, Gc >= Ga, Gc >= Gb],
      And(u1 + pre(Ga) <= Wp + pre(Gc), u2 + pre(Gb) <= Wp + pre(Gc), u3 + pre(Gc) <= Wp + pre(Gc)))
pre_i = lambda Gk: (64 * Gk + 62) // 63 + 5_000
note('MATH-UO-57d', 'SPEC-ORC-023 example', f'G = 50,000: bound {pre_i(50_000)}; forwarded at that gasleft '
     f'{min(50_000, pre_i(50_000) - pre_i(50_000) // 64)}; G_inputs(2) = 150,000 + 2 * 140,000 = '
     f'{150_000 + 2 * 140_000}, bound {pre_i(430_000)}; measured worst-case two-token poke with the token-decimals '
     f'reads of REQ-ORACLE-107: W_poke = 830,781, binding feed read at u = 718,836: {718_836 + pre_i(50_000)}; floor '
     f'max(...) = {max(830_781, 718_836 + pre_i(50_000))}; POKE_MIN_GAS_FLOOR = 900,000 leaves '
     f'{900_000 - max(830_781, 718_836 + pre_i(50_000))} gas until the fork calibration')
gl1, gl2, uk, Gk = Ints('gasleft1 gasleft2 uk Gk')
fwdf = lambda gl, Gx: If(Gx < gl - gl / 64, Gx, gl - gl / 64)
prove('MATH-UO-57f', 'any two gas limits at which a read passes its pre-call check forward the same G to it, so a poke '
      'that completes reads every source with its full gas and computes the same failure, timers and decimals result '
      'at any limit; a limit short of a check reverts before that read and commits nothing',
      [Gk > 0, uk >= 0, gl1 - uk >= pre(Gk), gl2 - uk >= pre(Gk)], fwdf(gl1 - uk, Gk) == fwdf(gl2 - uk, Gk))
c_e, p_e = Ints('callerLimit entryLeft')
prove('MATH-UO-57g', 'the entry check measures gas left at the implementation: with a proxy that keeps 1/64 and spends '
      'o >= 0 before its delegatecall, entry gas <= caller limit - o - floor((limit - o)/64) < caller limit, so a '
      'transaction must cover pokeMinGas plus the work before the check',
      [c_e >= 0, P >= 0, c_e - P >= 0, p_e == (c_e - P) - (c_e - P) / 64, c_e > 0], p_e <= c_e)

# ---------------------------------------------------------------- MATH-UO-72 decimals verification, confirmation
# MATH-UO-72 verifies: REQ-ORACLE-107, REQ-ORACLE-100, SPEC-ORC-020, REQ-ORACLE-016
MAX_VERIFY_AGE = 7_200
t72, chk, keeper = Ints('now72 decimalsCheckedAt keeperInterval')
mismatch, otherFail, liveBits, seqReady, confirmed, ageOk, otherPause = Bools(
    'mismatch otherFailure noDriftBits sequencerReady confirmed servedAgeOk otherSeizurePause')
failed72 = Or(mismatch, otherFail)
live72 = And(Not(failed72), liveBits)
verified = t72 - chk <= MAX_VERIFY_AGE
borrow72 = And(live72, seqReady, confirmed, ageOk, verified)
paused72 = Or(failed72, otherPause)
b72 = [chk >= 0, chk <= t72]
prove('MATH-UO-72a', 'borrowAllowed implies every token confirmed and a token-decimals verification at most 7,200 s old',
      b72, Implies(borrow72, And(confirmed, t72 - chk <= MAX_VERIFY_AGE)))
prove('MATH-UO-72b', 'a decimals mismatch fails the market: borrowing and this market\'s seizure are both blocked', b72,
      Implies(mismatch, And(Not(borrow72), paused72, Not(live72))))
prove('MATH-UO-72c', 'an unconfirmed token or an old verification blocks borrowing only: the state and the seizure '
      'pause are those of the same evaluation with every token confirmed and a fresh verification', b72,
      And(live72 == And(Not(failed72), liveBits), paused72 == Or(failed72, otherPause),
          Implies(Or(Not(confirmed), Not(verified)), Not(borrow72))))
prove('MATH-UO-72d', 'with a successful poke at least every keeper interval of at most 3,600 s, the age gate never '
      'blocks: two intervals fit 7,200 s, so one missed keeper run blocks nothing', b72 + [keeper <= 3_600, keeper > 0],
      Implies(t72 - chk <= 2 * keeper, verified))
witness('MATH-UO-72e', 'delayed detection: a token changed at c and read by a view at v before the next poke at p > v '
        'is still priced with the stored decimals (window p - c); a risk-increasing call pokes first (p = v), so its '
        'window is empty', [chk == 1_000, t72 == 1_500, keeper == 3_600, t72 < chk + keeper])
note('MATH-UO-72f', 'REQ-ORACLE-107 example', f'verified at 1,000; a poke-less view at {1_000 + MAX_VERIFY_AGE} allows '
     f'borrowing, at {1_000 + MAX_VERIFY_AGE + 1} it does not (reason bit 19); a 6 -> 18 decimals change found at '
     f'1,060 fails the market from 1,060: Cached until {1_060 + 3_600 - 1}, Expired from {1_060 + 3_600}')

finish()
