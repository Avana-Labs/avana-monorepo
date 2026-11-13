# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-58..66 — LPPriceMath input bounds, fail-closed results and the fixed-point USD level
([2.10] SPEC-ORC-001, SPEC-ORC-002, SPEC-ORC-003, SPEC-ORC-008, SPEC-ORC-011, SPEC-ORC-012, SPEC-ORC-017,
SPEC-ORC-018, SPEC-ORC-020, SPEC-ORC-022, SPEC-ORC-023, REQ-ORACLE-042, REQ-ORACLE-049, REQ-ORACLE-103).

  SPEC-ORC-001:  n = 0 if a <= 0 or a >= 2^128 (a the signed answer); else a * 10^(8 - f) or floor(a / 10^(f - 8))
  SPEC-ORC-002:  r = mulDiv(aA, aB, 10^(fA + fB - 8)) for 0 < aA, aB < 2^128, else 0
  SPEC-ORC-008:  valid only for one length n in [2, 8], a_i < 2^128, d_i <= 77, 1 <= v_i <= MAX_ROUTE_ANSWER
  SPEC-ORC-011:  x (x) y = floor(x * y / 1e8), saturating at 2^256 - 1 and staying there;
                 usdLevel = max{L : L^(x)n <= (x)_i q_i}
  SPEC-ORC-017:  disagreement serves max(1, min(lower, fresh)); the accepted price A is served only while Cached
  SPEC-ORC-018:  Expired serves ceil(A * (1e4 + max(delta, 100)) / 1e4), saturating at 2^256 - 1
  REQ-ORACLE-042: deviation = floor(|x - y| * 1e4 / min(x, y)), 2^256 - 1 when min is 0 or the product needs 257 bits
  SPEC-ORC-023:  POKE_MIN_GAS_FLOOR >= max(W_poke, max_k(u_k + ceil(64 G_k / 63) + POST_CALL_GAS));
                 LPPriceMath.pokeMinGasFloor(u_k, G_k) is one read's term
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Int, Ints, BitVec, BitVecVal, And, Or, Not, If, Implies, ULT, UGT, BVMulNoOverflow
from _common import (prove, witness, note, finish, MAX_ROUTE_ANSWER, MIN_SQRT_RATIO, MAX_SQRT_RATIO, Q96,
                     U256, isqrt)

E = 10 ** 8
U128 = 2 ** 128

# ---------------------------------------------------------------- MATH-UO-58 signed answers and route products
# MATH-UO-58 verifies: SPEC-ORC-001, SPEC-ORC-002, REQ-ORACLE-002, REQ-ORACLE-049
a = BitVec('answer', 256)
prove('MATH-UO-58a', 'a signed answer in (0, 2^128) times 10^8 (f = 0, the largest factor) never overflows 256 bits',
      [UGT(a, BitVecVal(0, 256)), ULT(a, BitVecVal(U128, 256))],
      BVMulNoOverflow(a, BitVecVal(E, 256), False))
aA, aB = Ints('aA aB')
prove('MATH-UO-58b', 'two-leg route: 0 < aA, aB < 2^128 keeps aA * aB < 2^256, so mulDiv fits 256 bits at every k >= 0',
      [aA > 0, aB > 0, aA < U128, aB < U128], aA * aB <= U256)
witness('MATH-UO-58c', 'wrong reading (old bound aA, aB < 2^255): with fA + fB = 8 the mulDiv result needs more than '
        '256 bits, so the old bound does not prevent a revert',
        [aA > 0, aB > 0, aA < 2 ** 255, aB < 2 ** 255, aA * aB > U256])
neg = Int('negative_answer')
witness('MATH-UO-58d', 'wrong reading (unsigned input): a negative answer cast to uint256 normalises from 18 decimals '
        'to more than 10^60, a huge "valid" price; the signed rule returns 0',
        [neg < 0, neg >= -10 ** 18, (neg + 2 ** 256) / 10 ** 10 > 10 ** 60])
note('MATH-UO-58e', 'every answer below 2^128 floors to 0 once f >= 47',
     f'10^39 = {10 ** 39} > 2^128 = {U128}: {10 ** 39 > U128}; 10^38 > 2^128: {10 ** 38 > U128}')

# ---------------------------------------------------------------- MATH-UO-59 disagreement served price
# MATH-UO-59 verifies: SPEC-ORC-017, REQ-ORACLE-086, REQ-ORACLE-020, INV-087
lower, fresh = Ints('lower fresh')
m2 = If(lower < fresh, lower, fresh)
served = If(m2 < 1, 1, m2)
prove('MATH-UO-59a', 'served = max(1, min(lower, fresh)) is >= 1 and <= fresh for any lower >= 0 when fresh >= 1',
      [lower >= 0, fresh >= 1], And(served >= 1, served <= fresh))
old = If(lower < 1, 1, lower)
witness('MATH-UO-59b', 'wrong reading (the lower-route price alone): a floored lower-route price above the fresh price is '
        'served above fresh', [lower >= 1, fresh >= 1, lower > fresh, old > fresh])


def _sqrt_x96(x0, x1, d0, d1):
    num, den = x0 * 10 ** d1, x1 * 10 ** d0
    if num >= (1 << 64) * den:
        return MAX_SQRT_RATIO - 1
    return max(isqrt(num * (1 << 192) // den), MIN_SQRT_RATIO)


def _full_range(u, x, dec):
    s = min(max(_sqrt_x96(x[0], x[1], dec[0], dec[1]), MIN_SQRT_RATIO), MAX_SQRT_RATIO)
    return ((u << 96) * (MAX_SQRT_RATIO - s) // MAX_SQRT_RATIO // s, u * (s - MIN_SQRT_RATIO) // Q96)


def _price8(am, v, dec):
    return max(1, sum(max(am[i] - 1, 0) * v[i] // 10 ** dec[i] for i in range(len(am))))


v_ex, w_ex = (97_544_839, 97_383_701), (97_544_839, 97_383_663)
a_v, a_w = _full_range(10 ** 6, v_ex, (6, 6)), _full_range(10 ** 6, w_ex, (6, 6))
p_v, p_w = _price8(a_v, v_ex, (6, 6)), _price8(a_w, w_ex, (6, 6))
from decimal import Decimal, getcontext
getcontext().prec = 80
s_exact = (Decimal(v_ex[0]) / Decimal(v_ex[1])).sqrt() * Q96
x0 = Decimal(10 ** 6) * Q96 * (MAX_SQRT_RATIO - s_exact) / (MAX_SQRT_RATIO * s_exact)
x1 = Decimal(10 ** 6) * (s_exact - MIN_SQRT_RATIO) / Q96
exact_v = x0 * v_ex[0] / 10 ** 6 + x1 * v_ex[1] / 10 ** 6
note('MATH-UO-59c', 'full-range USDC/USDT, d = 6: w <= v but the floored lower price exceeds the floored fresh price; '
     'both stay below the exact value at v',
     f'composition at v {a_v}, fresh {p_v}; at w {a_w}, lower {p_w}; exact value at v {float(exact_v):.3f}; '
     f'served min(lower, fresh) = {min(p_w, p_v)}')
assert a_v == (999_173, 1_000_826) and a_w == (999_173, 1_000_827)
assert p_v == 194_928_113 and p_w == 194_928_172 and p_w > p_v and Decimal(p_w) < exact_v

# ---------------------------------------------------------------- MATH-UO-60 deviation and agreement bounds
# MATH-UO-60 verifies: REQ-ORACLE-042, SPEC-ORC-003, SPEC-ORC-020
x, y = Ints('x y')
lo_, hi_ = If(x < y, x, y), If(x < y, y, x)
diff = hi_ - lo_
sat_ = diff > U256 // 10 ** 4
prove('MATH-UO-60a', 'deviation: when not saturated, |x - y| * 1e4 fits 256 bits, so the floor is computed exactly',
      [x >= 0, y >= 0, x <= U256, y <= U256, Not(sat_)], diff * 10 ** 4 <= U256)
prove('MATH-UO-60b', 'deviation saturates only when |x - y| * 1e4 really needs more than 256 bits (minus one bps step)',
      [x >= 0, y >= 0, x <= U256, y <= U256, sat_], diff * 10 ** 4 > U256 - 10 ** 4)
p_, b_, T_ = Ints('p b T')
inb = And(p_ >= 1, b_ >= 1, p_ <= MAX_ROUTE_ANSWER, b_ <= MAX_ROUTE_ANSWER)
prove('MATH-UO-60c', 'agreement with the bound check: inside [1, MAX_ROUTE_ANSWER] both sides fit 256 bits; outside, '
      'the test is false (fails closed) for every uint256 input',
      [p_ >= 0, b_ >= 0, p_ <= U256, b_ <= U256, T_ >= 0, T_ < 2 ** 16],
      And(Implies(inb, And(If(p_ > b_, p_ - b_, b_ - p_) * 10 ** 4 <= U256, T_ * If(p_ < b_, p_, b_) <= U256)),
          Implies(Not(inb), Not(And(inb, If(p_ > b_, p_ - b_, b_ - p_) * 10 ** 4 <= T_ * If(p_ < b_, p_, b_))))))

# ---------------------------------------------------------------- MATH-UO-61 fixed-point USD level
# MATH-UO-61 verifies: SPEC-ORC-011, REQ-ORACLE-042
L, L2, t, t2 = Ints('L Lp t tp')
sq = lambda z, w: And(w * E <= z * z, z * z < (w + 1) * E)       # w = floor(z^2 / 1e8)
prove('MATH-UO-61a', 'n = 2: L -> L^(x)2 is non-decreasing', [L >= 0, L2 >= L, L2 <= MAX_ROUTE_ANSWER, sq(L, t), sq(L2, t2)],
      t <= t2)
xs_, xs2, Lm, Lm2, pr1, pr2 = Ints('x xp Lm Lmp prod prodp')
# One step of a fixed-point power or product, with sticky saturation at 2^256 - 1. Every L^(x)n and every
# left-to-right product is a chain of such steps, so step monotonicity gives monotonicity for every n by induction.
prove('MATH-UO-61b', 'one step x (x) L is non-decreasing in both arguments, saturation included (i: the raw products '
      'are ordered; ii: the floored, saturating step preserves the order), so L -> L^(x)n is non-decreasing for every n',
      [xs_ >= 0, xs2 >= xs_, Lm >= 0, Lm2 >= Lm], xs_ * Lm <= xs2 * Lm2)
step = lambda xv, lv, pv: If(Or(xv == U256, lv == U256), U256, If(pv > U256, U256, pv / E))
prove('MATH-UO-61c', 'step monotonicity (ii): with the raw products ordered, the saturating floor keeps the order',
      [xs_ >= 0, xs2 >= xs_, xs2 <= U256, Lm >= 0, Lm2 >= Lm, Lm2 <= U256, pr1 >= 0,
       pr1 <= pr2], step(xs_, Lm, pr1) <= step(xs2, Lm2, pr2))
qa, qb, qc, qa2, g1, g2, h1, h2 = Ints('qa qb qc qa2 g1 g2 h1 h2')
fx2 = lambda p, q, w: And(w * E <= p * q, p * q < (w + 1) * E)
prove('MATH-UO-61d', 'the left-to-right product is non-decreasing in each argument (n = 3, first and last argument), '
      'so (min q)^(x)n <= (x)q <= (max q)^(x)n bound the search',
      [qa >= 0, qb >= 0, qc >= 0, qa2 >= qa, qa2 <= MAX_ROUTE_ANSWER, qb <= MAX_ROUTE_ANSWER, qc <= MAX_ROUTE_ANSWER,
       fx2(qa, qb, g1), fx2(g1, qc, h1), fx2(qa2, qb, g2), fx2(g2, qc, h2)], h1 <= h2)
low, Ls, P, fl, fs, fs1 = Ints('low Lstar P f_low f_Lstar f_Lstar1')
prove('MATH-UO-61e', 'with usdLevel = max{L : L^(x)2 <= P}: usdBandLow <= usdLevel exactly when usdBandLow^(x)2 <= P',
      [low >= 0, Ls >= 0, low <= MAX_ROUTE_ANSWER, Ls <= MAX_ROUTE_ANSWER, P >= 0, sq(low, fl), sq(Ls, fs), sq(Ls + 1, fs1),
       fs <= P, fs1 > P],
      (low <= Ls) == (fl <= P))
fLow, fL, fL1 = Ints('pow_low pow_level pow_level1')
prove('MATH-UO-61h', 'every n: with L -> L^(x)n non-decreasing (61b, 61c) and usdLevel = max{L : L^(x)n <= P}, '
      'usdBandLow <= usdLevel exactly when usdBandLow^(x)n <= P',
      [low >= 0, Ls >= 0, fL <= P, fL1 > P,
       Implies(low <= Ls, fLow <= fL), Implies(low >= Ls + 1, fLow >= fL1)],
      (low <= Ls) == (fLow <= P))
r_ = Int('real_root_form')
witness('MATH-UO-61f', 'wrong reading (real root floor((P * 1e8)^(1/2))): the reported level sits below usdBandLow '
        'while the band test passes', [low >= 1, low <= MAX_ROUTE_ANSWER, P >= 1, sq(low, fl), fl <= P,
                                         r_ >= 0, r_ * r_ <= P * E, (r_ + 1) * (r_ + 1) > P * E, r_ < low])


def _fx(xs):
    acc = xs[0]
    for z in xs[1:]:
        acc = acc * z // E
    return acc


def _level(q):
    n, prod = len(q), _fx(q)
    lo, hi = min(q), max(q) + 1
    while _fx([hi] * n) <= prod:
        hi *= 2
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if _fx([mid] * n) <= prod:
            lo = mid
        else:
            hi = mid
    return lo


ex = [(99_987_000, 100_010_000), (89_000_000, 89_000_000), (99_990_000, 10 ** 8, 99_980_000), (81_000_001, 10 ** 8)]
levels = [_level(list(q)) for q in ex]
note('MATH-UO-61g', 'usdLevel of the SPEC-ORC-011 examples and the root-form counterexample',
     f'levels {levels}; 99,998,499^(x)2 = {_fx([99_998_499] * 2)}, 99,998,500^(x)2 = {_fx([99_998_500] * 2)}; '
     f'(81,000,001, 1e8): level 90,000,001, real root {isqrt(81_000_001 * E)}')
assert levels == [99_998_499, 89_000_000, 99_990_000, 90_000_001]

# ---------------------------------------------------------------- MATH-UO-62 sticky saturation
# MATH-UO-62 verifies: SPEC-ORC-011
_k6 = _fx([MAX_ROUTE_ANSWER] * 6)
note('MATH-UO-62a', 'products of valid quotes saturate only beyond six factors: six factors at MAX_ROUTE_ANSWER = 10^18 '
     'stay below 2^256, a seventh needs more than 256 bits, so a market of seven or eight tokens near the bound reaches the '
     'sticky saturation of 62b (defined behaviour, MATH-UO-75)',
     f'six factors: product {_k6:.3e} < 2^256 = {2 ** 256:.3e}; seventh raw product {_k6 * MAX_ROUTE_ANSWER:.3e} >= 2^256: '
     f'{_k6 * MAX_ROUTE_ANSWER >= 2 ** 256}; eight factors exactly: {_fx([MAX_ROUTE_ANSWER] * 8):.3e}')
assert _k6 < 2 ** 256 <= _k6 * MAX_ROUTE_ANSWER
sx, sy = Ints('sat_x sat_y')
stick = If(Or(sx == U256, sy == U256), U256, If(sx * sy > U256, U256, sx * sy / E))
prove('MATH-UO-62b', 'sticky rule: a saturated factor gives a saturated product, and a product below 2^256 - 1 is the '
      'exact floor; a genuine floor never equals 2^256 - 1, so saturation is unambiguous',
      [sx >= 0, sy >= 0, sx <= U256, sy <= U256],
      And(Implies(Or(sx == U256, sy == U256), stick == U256),
          Implies(And(sx < U256, sy < U256, sx * sy <= U256), And(stick == sx * sy / E, stick < U256))))
witness('MATH-UO-62c', 'wrong reading (non-sticky saturation): a saturated product times 1 drops back below the '
        'saturation value', [sy == 1, (U256 * sy) / E < U256])

# ---------------------------------------------------------------- MATH-UO-63 token order of the band products
# MATH-UO-63 verifies: SPEC-ORC-011
q3, low3 = (95_243_313, 98_905_925, 97_089_205), 97_067_963
note('MATH-UO-63', 'the fixed-point product depends on the order of its factors; pool order fixes it per market',
     f'{q3} -> {_fx(list(q3))}, reversed -> {_fx(list(q3[::-1]))}; low^(x)3 = {_fx([low3] * 3)}: '
     f'in band {_fx([low3] * 3) <= _fx(list(q3))} in pool order, {_fx([low3] * 3) <= _fx(list(q3[::-1]))} reversed')
assert _fx(list(q3)) == 91_459_272 and _fx(list(q3[::-1])) == 91_459_273 == _fx([low3] * 3)

# ---------------------------------------------------------------- MATH-UO-64 lpPrice input bounds
# MATH-UO-64 verifies: SPEC-ORC-008, REQ-ORACLE-103
am, vv = Ints('amount price')
prove('MATH-UO-64', 'with a_i < 2^128 and 1 <= v_i <= MAX_ROUTE_ANSWER = 10^18, each term is below 2^188 and eight terms '
      'sum below 2^191 < 2^255: no mulDiv or addition reverts once the inputs pass the checks',
      [am >= 0, am < U128, vv >= 1, vv <= MAX_ROUTE_ANSWER], And(am * vv < 2 ** 188, 8 * am * vv < 2 ** 191))

# ---------------------------------------------------------------- MATH-UO-65 debt stress price
# MATH-UO-65 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087
Ad, dl, dd, cs = Ints('A delta delta_eff served_expired')
prove('MATH-UO-65', 'Expired debt price with delta read as max(delta, 100): ceil(A (1e4 + delta) / 1e4) >= A + 1 for '
      'every A >= 1, and the saturated value 2^256 - 1 is above A whenever the product overflows',
      [Ad >= 1, Ad <= U256, dl >= 0, dd == If(dl < 100, 100, dl),
       cs == If(Ad * (10 ** 4 + dd) > U256, U256, (Ad * (10 ** 4 + dd) + 10 ** 4 - 1) / 10 ** 4)],
      And(cs >= Ad, Implies(Ad < U256, cs >= Ad + 1)))

# ---------------------------------------------------------------- MATH-UO-66 fail-closed sentinels and the poke floor
# MATH-UO-66 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-022, SPEC-ORC-023, REQ-ORACLE-038, REQ-ORACLE-102
nowt, card = Ints('now cardinality')
prove('MATH-UO-66a', 'no route timestamps: servedUpdatedAt = 0 and both age limits 0, so now - 0 <= 0 fails for every '
      'now > 0; a zero block interval asks for 2^256 - 1 observations, which no uint16 cardinality meets',
      [nowt > 0, card >= 0, card < 2 ** 16], And(Not(nowt - 0 <= 0), card < U256))
g, G, W, u = Ints('gasleft G Wpoke used_before_read')
pre = (64 * G + 62) / 63 + 5_000
prove('MATH-UO-66b', 'one read term u_k + ceil(64 G_k / 63) + POST_CALL_GAS (LPPriceMath.pokeMinGasFloor(u_k, G_k)): '
      'an entry gas at least the term leaves the read its pre-call bound after u_k of work, whatever u_k is',
      [G > 0, u >= 0, g >= u + (64 * G + 62) / 63 + 5_000], g - u >= pre)
witness('MATH-UO-66c', 'wrong reading (term without POST_CALL_GAS): a poke entered at u_k + ceil(64 G / 63) fails the '
        'pre-call check of read k', [G == 50_000, u == 748_926, g == u + (64 * G + 62) / 63, g - u < pre])
note('MATH-UO-66d', 'SPEC-ORC-023 floor example (two-token worst-case poke with the token-decimals reads, measured)',
     f'binding read 748,926 + {(64 * 50_000 + 62) // 63} + 5,000 = {748_926 + (64 * 50_000 + 62) // 63 + 5_000}; '
     f'W_poke 861,000; floor max = {max(861_000, 748_926 + (64 * 50_000 + 62) // 63 + 5_000)}; configuration read '
     f'bound G_inputs(2) = 430,000: {(64 * 430_000 + 62) // 63 + 5_000}')

finish()
