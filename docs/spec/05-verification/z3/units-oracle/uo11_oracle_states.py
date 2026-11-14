# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-42..49 and 76 — served prices and timers of the LPOracle and the DebtOracle, and the
borrow-side bound by the accepted price ([2.10] SPEC-ORC-001, SPEC-ORC-002, SPEC-ORC-012..018,
REQ-ORACLE-095; [2.7] REQ-RISK-026, REQ-RISK-059).

  price8(x0, x1) = isqrt(4 * x0 * x1) - 1                                   (SPEC-ORC-008)
  collateral (SPEC-ORC-017): Live and Drifting with no disagreement fresh;
      some token disagrees (not failed) max(1, min(lower, fresh)) with lower = price8(w0, w1),
      w_i = ceil_i(min(p_i, b_i)); Cached A (also the block a quote-change cap holds); Expired 1
  borrow side (REQ-RISK-026, REQ-RISK-059): bookingPrice(A, fresh) = fresh if 0 < fresh < A else A;
      boundedHealthFactor(hf, served, A) = hf if served == 0 or A >= served else floor(hf * A / served)
  debt (SPEC-ORC-018): Live q; Drifting (routes disagree) max(p, b, A); Cached A;
      Expired ceil(A * (10^4 + delta) / 10^4), delta = min(max(read, 100), 5,000) for any uint16 read;
      served route while Drifting: the route of max(p, b), none (accepted timestamp) when A > max(p, b)
  failure start (SPEC-ORC-013): staleFrom_r = min over stale legs (updatedAt + feedMaxAge) + 1,
      staleAt_i = max(staleFrom_primary, staleFrom_alternate), failureStart = min(S_ts, failedSince, now)
  windows (SPEC-ORC-016): pauseActive = D and now < s + pauseMax (s = disagreeSince or now);
      disagreementExpired = D and now >= s + pauseMax (the same s)
  age limits (SPEC-ORC-015): maxAge() = min over legs (updatedAt_l + limit_l) - servedUpdatedAt
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, Int, Bool, Bools, And, Or, If, Implies, Not
from _common import prove, witness, note, finish, MAX_ROUTE_ANSWER, STABLE_CEILING

C = STABLE_CEILING


def isqrt_c(s, X):
    return [s >= 0, s * s <= X, X < (s + 1) * (s + 1)]


def mn(a, b):
    return If(a < b, a, b)


def mx(a, b):
    return If(a > b, a, b)


# ---------------------------------------------------------------------------
# MATH-UO-42  Collateral served price (SPEC-ORC-017).
s1, s2, X1, X2 = Ints('root1 root2 X1 X2')
# MATH-UO-42 verifies: SPEC-ORC-008, SPEC-ORC-017
prove('MATH-UO-42a', 'lemma: the floored square root is monotone (X1 <= X2 => isqrt(X1) <= isqrt(X2))',
      isqrt_c(s1, X1) + isqrt_c(s2, X2) + [X1 >= 0, X1 <= X2], s1 <= s2)
w0, w1, v0, v1 = Ints('w0 w1 v0 v1')
# MATH-UO-42 verifies: SPEC-ORC-017
prove('MATH-UO-42b', 'lemma: 1 <= w_i <= v_i => 4*w0*w1 <= 4*v0*v1',
      [w0 >= 1, w1 >= 1, w0 <= v0, w1 <= v1], 4 * w0 * w1 <= 4 * v0 * v1)
p, b, qsel, stable = Int('p'), Int('b'), Bool('quoteIsPrimary'), Bool('isUsdStable')
ceil_i = lambda z: If(stable, mn(z, C), z)
q = If(qsel, p, b)
# MATH-UO-42 verifies: SPEC-ORC-017, SPEC-ORC-004
prove('MATH-UO-42c', 'lemma: the disagreement price w = ceil(min(p, b)) is <= the valuation price v = ceil(q) for either quote route, and >= 1',
      [p >= 1, b >= 1], And(ceil_i(mn(p, b)) <= ceil_i(q), ceil_i(mn(p, b)) >= 1))
fresh, lower, A, served, st = Ints('fresh lower A served state')     # state 0 Live 1 Drift 2 Disagree 3 Cached 4 Expired


def served_rule(state, fr, lw, acc):
    """LPPriceMath.servedPrice: Expired 1; Cached A; disagreement min(lower, fresh); Live, Drifting fresh; at least 1."""
    v = If(state == 4, 1, If(state == 3, acc, If(state == 2, mn(lw, fr), fr)))
    return If(v < 1, 1, v)


srv = served_rule(st, fresh, lower, A)
# lower is not assumed <= fresh: the floored lower-route price can exceed fresh by a few units (MATH-UO-59c).
facts = [fresh >= 1, lower >= 0, A >= 1, st >= 0, st <= 4, served == srv]
# MATH-UO-42 verifies: SPEC-ORC-017, SPEC-ORC-012
prove('MATH-UO-42d', 'served >= 1 in every state; served = A when Cached; served <= fresh whenever not failed (Live, Drifting, disagreement)',
      facts, And(served >= 1, Implies(st == 3, served == A), Implies(st <= 2, served <= fresh)))
r0, X0 = Ints('root X')
# MATH-UO-42 verifies: SPEC-ORC-008, SPEC-ORC-017
prove('MATH-UO-42e', 'fresh and lower are >= 1: prices >= 1 give isqrt(4*x0*x1) >= 2, so price8 >= 1',
      isqrt_c(r0, X0) + [X0 >= 4], r0 - 1 >= 1)
capped, evalState = Bool('quoteChangeCapped'), Int('evaluatedState')   # the cap turns a Live evaluation into Cached
st_cap = If(And(capped, evalState == 0), 3, evalState)
# MATH-UO-42 verifies: SPEC-ORC-017, REQ-ORACLE-103
prove('MATH-UO-42f', 'served <= fresh whenever the market is not failed and the quote-change cap does not hold it Cached; '
      'the capped block serves A in place of fresh',
      [fresh >= 1, lower >= 0, A >= 1, evalState >= 0, evalState <= 2],
      And(Implies(Not(capped), served_rule(st_cap, fresh, lower, A) <= fresh),
          Implies(And(capped, evalState == 0), served_rule(st_cap, fresh, lower, A) == A)))
f_old, f_new, A_old, A_new, s_old, s_new = Ints('freshOld freshNew acceptedOld acceptedNew stateOld stateNew')
rally = [f_old >= 1, f_new >= f_old, A_old >= 1, A_new >= 1, Or(s_old == 0, s_old == 1), Or(s_new == 0, s_new == 1)]
# MATH-UO-42 verifies: SPEC-ORC-017, INV-087
prove('MATH-UO-42g', 'a rally never lowers the served price: for any accepted prices and any Live/Drifting states before and '
      'after (Live -> Drifting included), fresh_new >= fresh_old gives served_new >= served_old',
      rally, served_rule(s_new, f_new, 0, A_new) >= served_rule(s_old, f_old, 0, A_old))
old_rule = lambda state, fr, acc: If(state == 0, fr, mn(fr, acc))    # the replaced rule: Drifting min(fresh, A)
# MATH-UO-42 verifies: SPEC-ORC-017, INV-087
witness('MATH-UO-42h', 'wrong reading (Drifting serves min(fresh, A)): a Live market served at fresh above an older A '
        'rallies into Drifting and its served price falls to A, so a rally could make an account liquidatable',
        rally + [A_new == A_old, s_old == 0, s_new == 1, old_rule(s_new, f_new, A_new) < old_rule(s_old, f_old, A_old)])

# ---------------------------------------------------------------------------
# MATH-UO-43  Debt served price (SPEC-ORC-018).
Ad, qd, pd, bd, dl, ex, sd = Ints('A q p b delta expiredPrice state')
expired = [ex * 10 ** 4 >= Ad * (10 ** 4 + dl), ex * 10 ** 4 < Ad * (10 ** 4 + dl) + 10 ** 4]
dsrv = If(sd == 0, qd, If(sd == 1, mx(mx(pd, bd), Ad), If(sd == 2, Ad, ex)))      # 0 Live 1 Drift 2 Cached 3 Expired
dfacts = [Ad >= 1, Ad <= MAX_ROUTE_ANSWER, qd >= 1, pd >= 1, bd >= 1, dl >= 100, dl <= 5000, sd >= 0, sd <= 3] + expired
# MATH-UO-43 verifies: SPEC-ORC-018
prove('MATH-UO-43a', 'served debt price >= 1 always, >= A whenever the state is not Live (debt that cannot be priced never counts lower)',
      dfacts, And(dsrv >= 1, Implies(sd != 0, dsrv >= Ad)))
mm = Int('A_times_rise')
# MATH-UO-43 verifies: SPEC-ORC-018
prove('MATH-UO-43b-i', 'lemma: 100 <= delta <= 5,000 and A >= 1 give 10,100*A <= A*(10^4 + delta) <= 15,000*A',
      [Ad >= 1, dl >= 100, dl <= 5000, mm == Ad * (10 ** 4 + dl)], And(mm >= 10100 * Ad, mm <= 15000 * Ad))
# MATH-UO-43 verifies: SPEC-ORC-018
prove('MATH-UO-43b', 'Expired value ceil(A*(10^4+delta)/10^4) is strictly above A and never exceeds 1.5 * A + 1',
      [Ad >= 1, mm >= 10100 * Ad, mm <= 15000 * Ad, ex * 10 ** 4 >= mm, ex * 10 ** 4 < mm + 10 ** 4],
      And(ex > Ad, 2 * ex <= 3 * Ad + 2))
# MATH-UO-43 verifies: SPEC-ORC-018
prove('MATH-UO-43c', 'A <= MAX_ROUTE_ANSWER keeps A * (10^4 + delta) < 2^256',
      dfacts, Ad * (10 ** 4 + dl) < 2 ** 256)

dr, dc = Ints('deltaRead deltaClamped')
clamp = [dr >= 0, dr <= 65535, dc == If(dr < 100, 100, If(dr > 5000, 5000, dr))]
# MATH-UO-43 verifies: SPEC-ORC-018, REQ-ORACLE-092
prove('MATH-UO-43d', 'the DebtOracle reads any uint16 stress rise into [100, 5,000] (min(max(read, 100), 5,000)), so MATH-UO-43b-i and -43b keep the Expired value in (A, 1.5 * A + 1] whatever the store returns',
      clamp, And(dc >= 100, dc <= 5000, Implies(And(dr >= 100, dr <= 5000), dc == dr)))
# MATH-UO-43 verifies: SPEC-ORC-018
witness('MATH-UO-43e', 'wrong reading (review DO-03): the lower bound alone; a store returning 65,535 bps serves ceil(A * 75,535 / 10^4) > 1.5 * A + 1 (A = 99,990,000 gives 755,274,465)',
        [Ad == 99_990_000, dr == 65535, mm == Ad * (10 ** 4 + If(dr < 100, 100, dr)), ex * 10 ** 4 >= mm, ex * 10 ** 4 < mm + 10 ** 4,
         2 * ex > 3 * Ad + 2, ex == 755_274_465])

# ---------------------------------------------------------------------------
# MATH-UO-67  DebtOracle served route while Drifting (SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093).
sel = Int('servedRoute')          # 0 none (accepted), 1 primary, 2 alternate
selr = If(Ad > mx(pd, bd), 0, If(bd > pd, 2, 1))
drift = [Ad >= 1, pd >= 1, bd >= 1, pd != bd, sel == selr]
# MATH-UO-67 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
prove('MATH-UO-67', 'while the routes disagree the reported route is the one whose value max(p, b, A) serves: the alternate serves b, the primary p, and none serves A, so the timestamp, legs and age limits always describe the served value',
      drift, And(Implies(sel == 2, mx(mx(pd, bd), Ad) == bd), Implies(sel == 1, mx(mx(pd, bd), Ad) == pd),
                 Implies(sel == 0, mx(mx(pd, bd), Ad) == Ad)))

# ---------------------------------------------------------------------------
# MATH-UO-76  The accepted price bounds borrowing only (REQ-RISK-026, REQ-RISK-059, SPEC-ORC-017).
WAD = 10 ** 18
hf, sv, ac, bh = Ints('hf served76 accepted76 boundedHf')
bhf = lambda h, srv_, acc: If(Or(srv_ == 0, acc >= srv_), h, (h * acc) / srv_)     # RiskModuleMath.boundedHealthFactor
base76 = [hf >= 0, sv >= 0, ac >= 1, bh == bhf(hf, sv, ac)]
# MATH-UO-76 verifies: REQ-RISK-059, SPEC-ORC-017
prove('MATH-UO-76a', 'boundedHealthFactor never exceeds hf, equals floor(hf * A / served) when A < served and hf when '
      'A >= served', base76,
      And(bh <= hf, Implies(And(sv > 0, ac < sv), And(bh * sv <= hf * ac, hf * ac < (bh + 1) * sv)),
          Implies(ac >= sv, bh == hf)))
K, Dbt, h_s, b_s, t_a, ks, ka = Ints('K debtValue hfAtServed boundedAtServed hfAtAccepted KS KA')
# Aave's health factor of an account whose only collateral is the vault token: hf(P) = floor(K * P / D), with
# K = units * liquidation threshold * WAD scale (constant in P) and D the debt value: linear in P, then floored.
lin = [K >= 0, Dbt >= 1, sv >= 1, ac >= 1, ac < sv, ks == K * sv, ka == K * ac,
       h_s * Dbt <= ks, ks < (h_s + 1) * Dbt,                 # Aave's hf at the served price
       b_s * sv <= h_s * ac, h_s * ac < (b_s + 1) * sv,        # bounded by A / served
       t_a * Dbt <= ka, ka < (t_a + 1) * Dbt]                  # Aave's hf at the accepted price
lx, ly, lz = Ints('lemmaX lemmaY lemmaZ')
# MATH-UO-76 verifies: REQ-RISK-059, SPEC-CF-005
prove('MATH-UO-76b-i', 'lemma: x <= y and z >= 0 give x * z <= y * z (used to scale the two floors of 76b and 76c)',
      [lx <= ly, lz >= 0], lx * lz <= ly * lz)
# MATH-UO-76 verifies: REQ-RISK-059, SPEC-CF-005
prove('MATH-UO-76b', 'linear health factor: the bounded value is never above the health factor at price A and at most one '
      'wei below it (hf(A) - 1 <= bounded <= hf(A))', lin + [b_s * sv * Dbt <= h_s * ac * Dbt, h_s * Dbt * ac <= ks * ac],
      And(b_s <= t_a, b_s >= t_a - 1))
# MATH-UO-76 verifies: REQ-RISK-059, SPEC-CF-005
prove('MATH-UO-76c', 'linear health factor with no floor in Aave (D divides K * served): the bounded value is exactly the '
      'health factor at price A', lin + [h_s * Dbt == ks, b_s * sv * Dbt <= h_s * ac * Dbt, h_s * ac * Dbt == ka * sv],
      b_s == t_a)
fr76, bp = Ints('fresh76 bookingPrice')
bpr = If(And(fr76 != 0, fr76 < ac), fr76, ac)                         # RiskModuleMath.bookingPrice
# MATH-UO-76 verifies: REQ-RISK-026, SPEC-ORC-017
prove('MATH-UO-76d', 'bookingPrice = min(fresh, A) when fresh > 0, A when fresh = 0 (a failed market), and never above A',
      [ac >= 1, fr76 >= 0, bp == bpr],
      And(Implies(fr76 > 0, bp == mn(fr76, ac)), Implies(fr76 == 0, bp == ac), bp <= ac, bp >= 1))
req = Int('requiredHf')
# MATH-UO-76 verifies: REQ-RISK-059, SPEC-ORC-017
witness('MATH-UO-76e', 'wrong reading (post-action check at the served price): after a rally the unbounded health factor '
        'passes the required 1.0 while the health factor at the accepted price is below it',
        [req == WAD, sv == 219_999_899, ac == 199_999_899, hf == 11 * WAD // 10, hf >= req, bhf(hf, sv, ac) < req])
_b = (11 * WAD // 10) * 199_999_899 // 219_999_899
_book = lambda acc, fresh_: fresh_ if 0 < fresh_ < acc else acc
note('MATH-UO-76f', 'RiskModuleMath examples',
     f'boundedHealthFactor(1.10e18, served 219,999,899, accepted 199,999,899) = {_b:,} (below 1e18); '
     f'bookingPrice(199,999,899, fresh 219,999,899) = {_book(199_999_899, 219_999_899):,}; '
     f'bookingPrice(199,999,899, fresh 189,999,899) = {_book(199_999_899, 189_999_899):,}; '
     f'bookingPrice(199,999,899, fresh 0) = {_book(199_999_899, 0):,}')
assert _b < WAD and _book(199_999_899, 219_999_899) == 199_999_899 and _book(199_999_899, 189_999_899) == 189_999_899

# ---------------------------------------------------------------------------
# MATH-UO-44  Failure start and the Cached window (SPEC-ORC-013).
spf, saf, fs, now, cw, fst = Ints('staleFromPrimary staleFromAlternate failedSince now cachedWindow failureStart')
stale_at = mx(spf, saf)
fstart = mn(mn(stale_at, If(fs == 0, stale_at, fs)), now)
ft = [spf >= 1, saf >= 1, fs >= 0, fs <= now, cw >= 1, stale_at <= now, fst == fstart]
# MATH-UO-44 verifies: SPEC-ORC-013
prove('MATH-UO-44a', 'both routes stale: the market is Expired at every now >= staleAt + cachedWindow, whatever failedSince or the poke time',
      ft + [now >= stale_at + cw], now >= fst + cw)
# MATH-UO-44 verifies: SPEC-ORC-013
prove('MATH-UO-44b', 'a late or missed poke can only report Expired earlier: failureStart <= staleAt and <= now',
      ft, And(fst <= stale_at, fst <= now))
# MATH-UO-44 verifies: SPEC-ORC-013
prove('MATH-UO-44c', 'staleFrom is the first failed second: a leg updated at u with feedMaxAge m is valid at u + m and stale at u + m + 1',
      [Int('u') >= 0, Int('m') >= 1],
      And(Int('u') + Int('m') - Int('u') <= Int('m'), (Int('u') + Int('m') + 1) - Int('u') > Int('m')))

# ---------------------------------------------------------------------------
# MATH-UO-45  Disagreement pause and expiry windows (SPEC-ORC-016).
D = Bool('someTokenDisagrees')
ds, pm, nw, stt = Ints('disagreeSince pauseMax now2 priceState')        # stt 3 Cached, 4 Expired
s_ = If(ds != 0, ds, nw)
pa = And(D, nw < s_ + pm)
de = And(D, nw >= s_ + pm)
lp = Or(stt == 3, stt == 4, pa, de, Bool('alternatePastBorrowAge'))
wn = [ds >= 0, ds <= nw, pm >= 0, pm <= 3600]
# MATH-UO-45 verifies: SPEC-ORC-016
prove('MATH-UO-45a', 'pauseActive and disagreementExpired never both hold, and every disagreement blocks this market\'s seizure (liquidationPaused)',
      wn, And(Not(And(pa, de)), Implies(D, lp)))
# MATH-UO-45 verifies: SPEC-ORC-016, REQ-ORACLE-095
prove('MATH-UO-45b', 'a disagreement first seen now (disagreeSince = 0, or a route-version change that reads it as 0) is in its pause window',
      wn + [D, ds == 0, pm >= 1], And(pa, Not(de)))
# MATH-UO-45 verifies: SPEC-ORC-016, REQ-ORACLE-095
prove('MATH-UO-45c', 'with pauseMax = 0, a disagreement read with disagreeSince = 0 is disagreementExpired, so liquidationPaused holds and the lower routes are served',
      wn + [D, ds == 0, pm == 0], And(de, Not(pa), lp))

# ---------------------------------------------------------------------------
# MATH-UO-46  Age limits of the served price (SPEC-ORC-015), three legs in use.
u1, u2, u3, l1, l2, l3, t, svd = Ints('updated1 updated2 updated3 limit1 limit2 limit3 now3 servedUpdatedAt')
legs = [u1 >= 0, u2 >= 0, u3 >= 0, l1 >= 0, l2 >= 0, l3 >= 0, svd == mn(mn(u1, u2), u3)]
deadline = mn(mn(u1 + l1, u2 + l2), u3 + l3)
# MATH-UO-46 verifies: SPEC-ORC-015, SPEC-ORC-012
prove('MATH-UO-46a', 'maxAge() = deadline - servedUpdatedAt >= 0 (no underflow) and the consumer test now - servedUpdatedAt <= maxAge holds iff every leg is within its own limit',
      legs, And(deadline - svd >= 0,
                (t - svd <= deadline - svd) == And(t - u1 <= l1, t - u2 <= l2, t - u3 <= l3)))
lq, bw = Ints('liquidationPriceMaxAgeLeg borrowPriceMaxAgeLeg')
# MATH-UO-46 verifies: SPEC-ORC-015
prove('MATH-UO-46b', 'an alternate leg is held to min(liquidation age, borrow age): its liquidation limit never exceeds its borrow limit',
      [lq >= 0, bw >= 0], mn(lq, bw) <= bw)

# ---------------------------------------------------------------------------
# MATH-UO-47  Recovery evidence with the phase fallback (SPEC-ORC-014).
prv, prvf, upd, fm, sa, ea, rec, cw2 = Ints('prevTrue prevFallback updatedAt feedMaxAge altStart altEnd recoveredAt cachedWindow2')
gs_true, gs_fb = prv + fm + 1, prvf + fm + 1
B_lo_t, B_lo_f, B_hi = mx(gs_true, sa), mx(gs_fb, sa), mn(upd, ea)
ev = [prvf <= prv, prv < upd, fm >= 1, sa <= ea, cw2 >= 1, rec >= 0]
qual = lambda lo: And(B_hi - lo >= cw2, B_hi > rec)
# MATH-UO-47 verifies: SPEC-ORC-014
prove('MATH-UO-47a', 'the fallback prev (stored timestamp, never later than the true previous round) only lengthens the measured gap: same end, earlier or equal start',
      ev, And(gs_fb <= gs_true, B_lo_f <= B_lo_t))
# MATH-UO-47 verifies: SPEC-ORC-014
prove('MATH-UO-47b', 'an outage that reached Expired by the true timestamps is also detected with the fallback, with the same end E_i (recoveredAt)',
      ev + [qual(B_lo_t)], qual(B_lo_f))

# ---------------------------------------------------------------------------
# MATH-UO-48  Leg normalisation, route value and timestamps never overstate (SPEC-ORC-001, SPEC-ORC-002, SPEC-ORC-012).
a_, n_, k_ = Ints('rawAnswer normalised scale')
# MATH-UO-48 verifies: SPEC-ORC-001
prove('MATH-UO-48a', 'f > 8: n = floor(a / 10^(f-8)) satisfies n * 10^(f-8) <= a < (n+1) * 10^(f-8): rounded down, never above the feed',
      [a_ >= 0, k_ >= 10, n_ * k_ <= a_, a_ < (n_ + 1) * k_], And(n_ * k_ <= a_, n_ >= 0))
aA, aB, rr, kk = Ints('aA aB route scaleAB')
# MATH-UO-48 verifies: SPEC-ORC-002
prove('MATH-UO-48b', 'two-leg route r = mulDiv(aA, aB, 10^(fA+fB-8)) floors: r <= aA*aB/10^k < r + 1',
      [aA >= 0, aB >= 0, kk >= 1, rr * kk <= aA * aB, aA * aB < (rr + 1) * kk], And(rr * kk <= aA * aB, rr >= 0))
tA, tB, t0, t1, tr0, tr1 = Ints('tLegA tLegB tToken0 tToken1 tRoute0 tRoute1')
# MATH-UO-48 verifies: SPEC-ORC-002, SPEC-ORC-012
prove('MATH-UO-48c', 'route timestamp = oldest leg and servedUpdatedAt = oldest route: the served age is never understated',
      [tr0 == mn(tA, tB), tr1 == t1], And(mn(tr0, tr1) <= tA, mn(tr0, tr1) <= tB, mn(tr0, tr1) <= t1))

# ---------------------------------------------------------------------------
# MATH-UO-49  Standby switch: a route-version change keeps failedSince (REQ-ORACLE-095).
fs0, S_new, now4, cw4 = Ints('failedSinceStored staleAtStandby now4 cachedWindow4')
before = fs0                               # poke stored failedSince = failureStart while failed
after = mn(mn(If(S_new == 0, now4, S_new), fs0), now4)
# MATH-UO-49 verifies: REQ-ORACLE-095, SPEC-ORC-013
prove('MATH-UO-49', 'a switch to a standby that is also stale never delays Cached or Expired: failureStart after the switch <= the stored failedSince',
      [fs0 >= 1, fs0 <= now4, S_new >= 0, cw4 >= 1], And(after <= before, Implies(now4 >= before + cw4, now4 >= after + cw4)))

finish()
