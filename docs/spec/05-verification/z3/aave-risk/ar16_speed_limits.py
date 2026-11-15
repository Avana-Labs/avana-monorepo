# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-85..89 — Borrow-speed and pledge-speed limits (Q-411).

Spec: SPEC-CAP-011 (two-bucket net-flow window), SPEC-CAP-012 (clamped limit on the window-start base), SPEC-CAP-013
(units and rounding), REQ-RISK-092..097.

Window of one scope: (start, prev, curr) with window length tau > 0. At a check at time t >= start:
  t >= start + 2 tau      ->  (t, 0, 0)                 reset, both buckets empty
  start + tau <= t < +2tau ->  (start + tau, curr, 0)   one rollover
  otherwise               ->  (start, prev, curr)
then a charge x passes iff prev' + curr' + x <= L, and curr' += x; a credit y (a repay or a withdrawal) takes
min(y, curr') from curr' and the rest, up to prev', from prev' (the stored-frame credit of the code equals this on the
rolled state, and rolling is idempotent, MATH-AR-85d).
Limit: L = min(max, max(min, floor(rate * B / 10^4))) with B the window-start base: sat(D - prev') read when a charge
opens the bucket, stored and reused for every later check in that bucket.
Launch values (1.5): tau = 21,600 s; borrow rate 2,500 bps, $250,000 .. $2,500,000 per market;
(Hub, asset) 2,500 bps, 500,000 .. 5,000,000 whole tokens; pledge 2,500 bps, $1,000,000 .. $10,000,000.
"""
from z3 import Ints, Int, If, And, Or, Not, Implies
from _common import prove, witness, computed, finish, BPS


def roll(t, s, p, c, tau):
    """State after the rollover at time t (start, prev, curr)."""
    reset = t >= s + 2 * tau
    one = And(Not(reset), t >= s + tau)
    s2 = If(reset, t, If(one, s + tau, s))
    p2 = If(reset, 0, If(one, c, p))
    c2 = If(reset, 0, If(one, 0, c))
    return s2, p2, c2


def clamp_limit(rate, base, lo, hi, name):
    """L = min(hi, max(lo, floor(rate * base / 10^4))); returns (L, side conditions)."""
    q = Int(name + '_q')
    side = [q * BPS <= rate * base, rate * base < q * BPS + BPS]
    lim = If(q < lo, lo, If(q > hi, hi, q))
    return lim, side


# ---------------------------------------------------------------------------
# MATH-AR-85  SPEC-CAP-011: the window bound, by induction over any number of charges.
# Ghost: T0 the start of an observed interval [T0, T0 + tau), A the charges made at times >= T0 so far, `last`
# the time of the latest check. Invariant Inv:
#   start <= last < start + tau  (the state was rolled at `last`; holds after every check),
#   A > 0 -> last >= T0,
#   start <= T0 -> A <= curr,     start > T0 -> A <= prev + curr and start <= T0 + tau.
tau, T0, A, last, s, p, c, t, x, L = Ints('tau T0 A last start prev curr t x L')
inv = And(tau > 0, p >= 0, c >= 0, A >= 0, s <= last, last < s + tau, last < T0 + tau,
          Implies(A > 0, last >= T0),
          Implies(s <= T0, A <= c),
          Implies(s > T0, And(A <= p + c, s <= T0 + tau)))
s2, p2, c2 = roll(t, s, p, c, tau)
passes = p2 + c2 + x <= L
A2 = If(t >= T0, A + x, A)
step = [inv, x >= 0, t >= last, t < T0 + tau, passes]
inv_after = And(p2 >= 0, c2 + x >= 0, A2 >= 0, s2 <= t, t < s2 + tau,
                Implies(A2 > 0, t >= T0),
                Implies(s2 <= T0, A2 <= c2 + x),
                Implies(s2 > T0, And(A2 <= p2 + c2 + x, s2 <= T0 + tau)))
# MATH-AR-85 verifies: SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093
prove('MATH-AR-85a', 'one passing charge inside [T0, T0 + tau) preserves the window invariant (induction step)',
      step, inv_after)
prove('MATH-AR-85b', 'every charge inside [T0, T0 + tau) leaves the interval total at most the L of that check',
      step, A2 <= L)
prove('MATH-AR-85c', 'the invariant holds before the first charge of the interval (A = 0, any rolled state)',
      [tau > 0, p >= 0, c >= 0, s <= last, last < s + tau, last < T0 + tau, A == 0], inv)
t9 = Int('t9')
sv, pv, cv = roll(t, s, p, c, tau)
sw, pw, cw = roll(t9, sv, pv, cv, tau)
sd, pd, cd = roll(t9, s, p, c, tau)
prove('MATH-AR-85d', 'rolling at a view time t and again at t9 gives the same window total as rolling once at t9',
      [tau > 0, p >= 0, c >= 0, s <= last, last < s + tau, t >= last, t9 >= t], pw + cw == pd + cd)

# Credits. Ghost N, the net amount (charges less credits) made at times >= T0, replaces A; the invariant is Inv with
# A := N (N may be negative). A credit takes k = min(y, prev' + curr') from the rolled window.
yv, N = Ints('y N')
invN = And(tau > 0, p >= 0, c >= 0, s <= last, last < s + tau, last < T0 + tau,
           Implies(N > 0, last >= T0),
           Implies(s <= T0, N <= c),
           Implies(s > T0, And(N <= p + c, s <= T0 + tau)))
takeC = If(yv < c2, yv, c2)
restY = yv - takeC
takeP = If(restY < p2, restY, p2)
c2k = c2 - takeC
p2k = p2 - takeP
N2 = If(t >= T0, N - takeC - takeP, N)
cstep = [invN, yv >= 0, t >= last, t < T0 + tau]
# MATH-AR-85 verifies: SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093
prove('MATH-AR-85j', 'a credit inside [T0, T0 + tau) preserves the net window invariant (induction step)',
      cstep, And(p2k >= 0, c2k >= 0, s2 <= t, t < s2 + tau,
                 Implies(s2 <= T0, N2 <= c2k),
                 Implies(s2 > T0, And(N2 <= p2k + c2k, s2 <= T0 + tau))))
prove('MATH-AR-85k', 'a credit takes exactly min(y, prev + curr) and never makes a bucket negative',
      [tau > 0, p >= 0, c >= 0, yv >= 0],
      And(p2k >= 0, c2k >= 0, takeC + takeP == If(yv < p2 + c2, yv, p2 + c2)))
NA = If(t >= T0, N + x, N)
prove('MATH-AR-85l', 'with credits, every charge inside [T0, T0 + tau) leaves the net interval total at most its L',
      [invN, x >= 0, t >= last, t < T0 + tau, passes], NA <= L)

# Bounded unrolling from an arbitrary rolled state: six charges at non-decreasing times within tau, each against its
# own limit; the interval total never exceeds the last limit.
ts = Ints('t1 t2 t3 t4 t5 t6')
xs = Ints('x1 x2 x3 x4 x5 x6')
Ls = Ints('L1 L2 L3 L4 L5 L6')
st = (Int('s0'), Int('p0'), Int('c0'))
hyp = [tau > 0, st[1] >= 0, st[2] >= 0, st[0] <= ts[0], ts[5] < ts[0] + tau]
cur = st
for i in range(6):
    if i > 0:
        hyp.append(ts[i] >= ts[i - 1])
    hyp.append(xs[i] >= 0)
    sr, pr, cr = roll(ts[i], *cur, tau)
    hyp.append(pr + cr + xs[i] <= Ls[i])
    cur = (sr, pr, cr + xs[i])
# MATH-AR-85 verifies: SPEC-CAP-011, REQ-RISK-092
prove('MATH-AR-85e', 'six charges split across times within one tau total at most the last check\'s L (no split dodges it)',
      hyp, sum(xs) <= Ls[5])

# Tightness and the release time.
ta, tb, xa, xb, LL = Ints('ta tb xa xb LL')
sa, pa, ca = roll(ta, 0, 0, 0, tau)
sb, pb, cb = roll(tb, sa, pa, ca + xa, tau)
# MATH-AR-85 verifies: SPEC-CAP-011
witness('MATH-AR-85f', 'over an interval of length tau + 1 two charges of L each pass (more than tau can hold 2L; design)',
        [tau > 0, LL > 0, ta == tau - 1, tb == 2 * tau, xa == LL, xb == LL]
        + [roll(ta, 0, 0, 0, tau)[1] + roll(ta, 0, 0, 0, tau)[2] + xa <= LL]
        + [roll(tb, *roll(ta, 0, 0, 0, tau)[:2], roll(ta, 0, 0, 0, tau)[2] + xa, tau)[1]
           + roll(tb, *roll(ta, 0, 0, 0, tau)[:2], roll(ta, 0, 0, 0, tau)[2] + xa, tau)[2] + xb <= LL])
prove('MATH-AR-85i', 'over any interval of length 2 tau at most 2L passes (two consecutive tau intervals)',
      hyp[:0] + [tau > 0, LL >= 0, Int('A1') >= 0, Int('A2') >= 0, Int('A1') <= LL, Int('A2') <= LL],
      Int('A1') + Int('A2') <= 2 * LL)
s9, p9, c9 = Ints('s9 p9 c9')
sg, pg, cg = roll(ta, s9, p9, c9, tau)
sh_, ph_, ch_ = roll(tb, sg, pg, cg + xa, tau)
prove('MATH-AR-85g', 'a charge made at time ta no longer counts at any check at ta + 2 tau or later',
      [tau > 0, s9 <= ta, p9 >= 0, c9 >= 0, xa >= 0, tb >= ta + 2 * tau], And(ph_ == 0, ch_ == 0))
prove('MATH-AR-85h', 'the bucket holding a charge at ta starts after ta - tau, so the charge frees within 2 tau',
      [tau > 0, s9 <= ta, p9 >= 0, c9 >= 0], And(sg <= ta, sg > ta - tau))

# ---------------------------------------------------------------------------
# MATH-AR-86  SPEC-CAP-012: the clamp and the window-start base.
rate, base, lo, hi = Ints('rate base lo hi')
lim, side = clamp_limit(rate, base, lo, hi, 'lim')
b86 = [rate >= 0, rate <= BPS, base >= 0, lo >= 0, hi >= lo] + side
# MATH-AR-86 verifies: SPEC-CAP-012, REQ-RISK-092, REQ-RISK-093
prove('MATH-AR-86a', 'min <= L <= max whenever min <= max', b86, And(lim >= lo, lim <= hi))
P1, P2, q1, q2 = Ints('P1 P2 q1 q2')
lim1 = If(q1 < lo, lo, If(q1 > hi, hi, q1))
lim2 = If(q2 < lo, lo, If(q2 > hi, hi, q2))
prove('MATH-AR-86b', 'L never decreases when the base grows (rate >= 0 makes rate x base monotone: P2 >= P1)',
      [lo >= 0, hi >= lo, P1 >= 0, P2 >= P1, q1 * BPS <= P1, P1 < q1 * BPS + BPS, q2 * BPS <= P2, P2 < q2 * BPS + BPS],
      lim2 >= lim1)
D0, u, y = Ints('D0 used y')
# Window-start base: inside a bucket a charge opened with base B, every check uses B whatever the live base D1, D2.
Bs, D1, D2 = Ints('B D1 D2')
limA, sideA = clamp_limit(rate, Bs, lo, hi, 'limA')
limB, sideB = clamp_limit(rate, Bs, lo, hi, 'limB')
prove('MATH-AR-86c', 'inside an opened bucket L is the L of the window-start base B, whatever the live base does',
      [rate >= 0, rate <= BPS, Bs >= 0, D1 >= 0, D2 >= 0, lo >= 0, hi >= lo] + sideA + sideB, limA == limB)
limN1, sN1 = clamp_limit(rate, D0, lo, hi, 'limN1')
limN2, sN2 = clamp_limit(rate, D0 + u, lo, hi, 'limN2')
witness('MATH-AR-86d', 'on the raw D a split would grow L inside the window (why the base is fixed when the bucket opens)',
        [rate == 2500, D0 == 4_000_000, lo == 0, hi == 10**9, u == 1_000_000] + sN1 + sN2
        + [u <= limN1, u + Int('more') <= limN2, Int('more') > 0])
limR1, sR1 = clamp_limit(rate, D0, lo, hi, 'limR1')
limR2, sR2 = clamp_limit(rate, D0 - u, lo, hi, 'limR2')
witness('MATH-AR-86f', 'on D less gross charges a borrow-and-repay would shrink L (why repays credit and B is fixed)',
        [rate == 2500, D0 == 4_000_000, lo == 0, hi == 10**9, u == 1_000_000] + sR1 + sR2 + [limR2 < limR1])
prove('MATH-AR-86e', 'fail closed: an unset scope (all zero) refuses every positive charge',
      [rate == 0, lo == 0, hi == 0, base >= 0] + side + [x > 0], Not(x <= lim))

# ---------------------------------------------------------------------------
# MATH-AR-87  SPEC-CAP-013: rounding of the USD charge (against the borrower) and the Spoke debt (floor).
amt, price, dec, usd = Ints('amount price8 decimals amountUsd')
p10 = Int('p10')
b87 = [amt >= 0, amt < 2**128, price > 0, price < 2**64, p10 >= 1, usd * p10 >= amt * price,
       usd * p10 < amt * price + p10]
# MATH-AR-87 verifies: SPEC-CAP-013, REQ-RISK-092
prove('MATH-AR-87a', 'the USD charge is never below the exact value (ceiling)', b87, usd * p10 >= amt * price)
prove('MATH-AR-87b', 'the USD charge exceeds the exact value by less than one 8-decimal unit', b87,
      usd * p10 - amt * price < p10)
prove('MATH-AR-87c', 'products stay below 2^192 (no overflow in mulDiv)', b87, amt * price < 2**192)

# ---------------------------------------------------------------------------
# MATH-AR-88  SPEC-CAP-011 next-capacity time (moreAt) and amount.
mA, mt = Ints('moreAt mt')
sr, pr, cr = roll(mt, s, p, c, tau)
more_at = If(pr > 0, sr + tau, If(cr > 0, sr + 2 * tau, 0))
b88 = [tau > 0, p >= 0, c >= 0, s <= mt, mt < s + tau]
s3, p3, c3 = roll(sr + tau, sr, pr, cr, tau)
# MATH-AR-88 verifies: SPEC-CAP-011, REQ-RISK-097
prove('MATH-AR-88a', 'at moreAt (prev > 0) the window holds exactly curr: prev has been released',
      b88 + [pr > 0], And(p3 + c3 == cr))
s4, p4, c4 = roll(sr + 2 * tau, sr, pr, cr, tau)
prove('MATH-AR-88b', 'at start + 2 tau the window is empty', b88, p4 + c4 == 0)
prove('MATH-AR-88c', 'moreAt is never in the past and at most 2 tau ahead', b88 + [Or(pr > 0, cr > 0)],
      And(more_at > mt, more_at <= mt + 2 * tau))

# ---------------------------------------------------------------------------
# MATH-AR-89  Worked examples of 2.7 (SPEC-CAP-011, SPEC-CAP-012) and 3.2 BOR-023.
def L_of(rate_, base_, lo_, hi_):
    return min(hi_, max(lo_, rate_ * base_ // BPS))


E8 = 10**8
ex_L = L_of(2500, 3_400_000 * E8, 250_000 * E8, 2_500_000 * E8)
ex_avail = ex_L - 600_000 * E8
ex_usd = -(-(300_000 * 10**6) * 99_990_000 // 10**6)
# MATH-AR-89 verifies: SPEC-CAP-011, SPEC-CAP-012, SPEC-CAP-013, BOR-023
computed('MATH-AR-89a', 'SPEC-CAP-012 example: window-start base $3,400,000, $600,000 borrowed in the window',
         [('window-start base $3,400,000 (no prev)', 3_400_000 * E8, 3_400_000 * E8 - 0),
          ('L = $850,000', 850_000 * E8, ex_L),
          ('available now $250,000', 250_000 * E8, ex_avail),
          ('300,000 USDC at $0.9999 charges $299,970.00', 29_997_000_000_000, ex_usd),
          ('so it is refused', True, 600_000 * E8 + ex_usd > ex_L),
          ('new market (D = 0): L = L_min $250,000', 250_000 * E8, L_of(2500, 0, 250_000 * E8, 2_500_000 * E8)),
          ('large market D = $20M: L = L_max $2,500,000', 2_500_000 * E8,
           L_of(2500, 20_000_000 * E8, 250_000 * E8, 2_500_000 * E8))])
# Timeline: tau = 21,600; $500,000 at t = 0 (start 0), $350,000 at t = 18,000, a $100,000 repay at t = 20,000, then at
# t = 25,000 (one rollover): prev = 750,000, curr = 0, more at 43,200 (prev released).
s_, p_, c_ = 0, 0, 500_000
c_ += 350_000
c_ -= min(100_000, c_)
t2_ = 25_000
s_r, p_r, c_r = (s_ + 21_600, c_, 0) if t2_ >= s_ + 21_600 and t2_ < s_ + 43_200 else (s_, p_, c_)
cyc = 0
for _ in range(10):
    cyc += 100_000
    cyc -= min(100_000, cyc)
computed('MATH-AR-89b', 'SPEC-CAP-011 timeline with L = $1,000,000 and tau = 6 h',
         [('after the repay at t = 20,000 the window holds $750,000', 750_000, c_),
          ('at t = 25,000: start 21,600, prev 750,000, curr 0', (21_600, 750_000, 0), (s_r, p_r, c_r)),
          ('available at t = 25,000: $250,000', 250_000, 1_000_000 - p_r - c_r),
          ('more at 43,200 (start + tau)', 43_200, s_r + 21_600),
          ('ten $100,000 borrow-and-repay cycles leave the window empty', 0, cyc)])
computed('MATH-AR-89c', 'pledge example: booked $5,000,000 when the bucket opens, beta 25 %',
         [('P = $1,250,000 (within $1M .. $10M)', 1_250_000 * E8, L_of(2500, 5_000_000 * E8, 1_000_000 * E8, 10_000_000 * E8))])

finish()
