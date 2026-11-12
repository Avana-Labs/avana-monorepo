# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-150..165 — Risk-area formulas in exact algebra, and the worked examples of the risk pages
recomputed in exact rationals.

Spec: SPEC-PROXY-009 (repay with collateral), SPEC-CAP-003 (restore amount), SPEC-CF-005 (rescue
units excluded), SPEC-CAP-007 / SPEC-CAP-008 (cap sizing guidance, tail ratio), SPEC-HUB-002 /
SPEC-CAP-006 (addCap), SPEC-PROXY-003 / SPEC-PROXY-007 (repay sizing and quote), SPEC-HUB-007
(borrow rate), SPEC-BRK-001 (price-drop alert), SPEC-CF-003 (opening bound), SPEC-HUB-005 (bonus curve),
SPEC-CF-004 / SPEC-HUB-006 (listing margin), SPEC-PROXY-006 (health factor), SPEC-HUB-007 supply rate
(SYM-192, Q-407, Q-408), DEF-014 loss after an early withdrawal (SYM-193, Q-353, Q-408).
Exact integer rounding of the same formulas is in the Z3 models (z3/aave-risk, MATH-AR-...).
"""
import sympy as sp
from _common import eq, nonneg, numeric, info, done

Q = sp.Rational
A, D, a, y, V, CF, s, U, f, E, k = sp.symbols("A D a y V CF s U f E k", positive=True)

# ---------- SYM-150..152: repay with collateral (SPEC-PROXY-009) ----------
# SYM-150 verifies: SPEC-PROXY-009, INV-089
eq("SYM-150", "lemma: (A - a)/(D - y) - A/D = (y A - a D) / (D (D - y)), so HF' >= HF  <=>  y A >= a D",
   (A - a) / (D - y) - A / D, (y * A - a * D) / (D * (D - y)))
ysize = (V * (1 - s) - U) / (1 + f)
H = sp.symbols("H", positive=True)
crit = sp.solve(sp.Eq(ysize * H, CF * V), H)[0]
# SYM-151 verifies: SPEC-PROXY-009
eq("SYM-151a", "critical HF where the sized repayment exactly keeps HF: CF V (1 + f) / (V (1 - s) - U)",
   crit, CF * V * (1 + f) / (V * (1 - s) - U))
eq("SYM-151b", "with U = 0 the critical HF is CF (1 + f) / (1 - s)", crit.subs(U, 0), CF * (1 + f) / (1 - s))
yx = (Q(3000) * Q(99, 100) - Q(1, 100)) / Q(10009, 10000)
# SYM-152 verifies: SPEC-PROXY-009, REP-POST-008
numeric("SYM-152a", "example: y = (3,000 x 0.99 - 0.01) / 1.0009 = 2,967.32 GHO", Q(296732, 100), yx, Q(1, 200))
numeric("SYM-152b", "example: HF' = 11,064 / 7,032.68 = 1.5732", Q(15732, 10000), Q(11064) / (10000 - yx), Q(1, 20000))
numeric("SYM-152c", "example: lemma bound 936 / 1.20 = 780", 780, Q(936) / Q(12, 10), 0)
numeric("SYM-152d", "example: critical HF 0.312 x 1.0009 / 0.99 = 0.3154",
        Q(3154, 10000), crit.subs({CF: Q(312, 1000), f: Q(9, 10000), s: Q(1, 100), U: 0}), Q(1, 20000))

# ---------- SYM-153: restore amount (SPEC-CAP-003) ----------
u, hf, ho, M, p = sp.symbols("u hf h_o M p", positive=True)
u_star = sp.solve(sp.Eq((hf * D + CF * u) / D, ho), u)[0]
# SYM-153 verifies: SPEC-CAP-003, REQ-RISK-066
eq("SYM-153a", "collateral value that restores h_o: u = (h_o - hf) x D / CF (x = (h_o - hf) D, usdToRestore = x / CF)",
   u_star, (ho - hf) * D / CF)
numeric("SYM-153b", "example: usdToRestore = 0.08 x 10,000 / 0.30 = $2,666.67", Q(266667, 100),
        u_star.subs({ho: Q(110, 100), hf: Q(102, 100), D: 10000, CF: Q(3, 10)}), Q(1, 200))
numeric("SYM-153c", "example: restoreBooked at $0.80 with a $1.00 floor = $3,333.33", Q(333333, 100),
        Q(800, 3) * 10 * Q(1, 1) / Q(8, 10), Q(1, 200))

# ---------- SYM-154: rescue units excluded (SPEC-CF-005) ----------
# SYM-154 verifies: SPEC-CF-005, INV-082
eq("SYM-154a", "hfEx = (A - E)/D = hf - E/D", (A - E) / D, A / D - E / D)
eq("SYM-154b", "largest debt with hfEx >= k: D* = (A - E)/k", sp.solve(sp.Eq((A - E) / D, k), D)[0], (A - E) / k)
numeric("SYM-154c", "example: hfEx = (12,000 - 312)/10,000 = 1.1688", Q(11688, 10000), Q(12000 - 312, 10000), 0)
numeric("SYM-154d", "example: largest debt 11,688 / 1.10 = $10,625.45", Q(1062545, 100), Q(11688) / Q(11, 10), Q(1, 200))
numeric("SYM-154e", "example: Aave hf at that debt 12,000 / 10,625.45 = 1.1294", Q(11294, 10000),
        Q(12000) / Q(1062545, 100), Q(1, 20000))
numeric("SYM-154f", "example: borrowing to hf 1.10 gives hfEx = 11,688 / 10,909.09 = 1.0714", Q(10714, 10000),
        Q(11688) / Q(1090909, 100), Q(1, 20000))

# ---------- SYM-155: incident term (SPEC-CAP-007 (i)) ----------
g, dl, h0, LB, dLP = sp.symbols("g delta h0 LB dLP", nonnegative=True)
lam = (1 + g) * (1 + dl) - h0 * (1 - dLP) / (CF * LB)
# SYM-155 verifies: SPEC-CAP-007, Q-192
eq("SYM-155a", "loss starts at dLP* = 1 - (1 + g)(1 + delta) CF LB / h0", sp.solve(sp.Eq(lam, 0), dLP)[0],
   1 - (1 + g) * (1 + dl) * CF * LB / h0)
eq("SYM-155b", "d lambda / d dLP = h0 / (CF LB) > 0 (the loss grows linearly with the LP drop past dLP*)",
   sp.diff(lam, dLP), h0 / (CF * LB))
launch = {g: Q(55, 100000), dl: 0, CF: Q(312, 1000), LB: Q(105, 100), h0: Q(95, 100)}
numeric("SYM-155c", "SPEC-CAP-007 Why: no loss up to a 65.5% LP drop", Q(655, 1000),
        (1 - (1 + g) * (1 + dl) * CF * LB / h0).subs(launch), Q(1, 2000))
ex = {g: Q(1, 1000), h0: Q(95, 100), dLP: Q(70, 100), CF: Q(30, 100), LB: Q(105, 100)}
numeric("SYM-155d", "example: lambda GHO = 0.096238", Q(96238, 10**6), lam.subs(ex).subs(dl, 0), Q(1, 2 * 10**6))
numeric("SYM-155e", "example: lambda USDC (delta 0.05) = 0.146288", Q(146288, 10**6), lam.subs(ex).subs(dl, Q(5, 100)),
        Q(1, 2 * 10**6))
numeric("SYM-155f", "example: 600,000 x lambda GHO = $57,743 (rounded up)", 57743, 600000 * lam.subs(ex).subs(dl, 0), 1)
numeric("SYM-155g", "example: 300,000 x lambda USDC = $43,887 (rounded up)", 43887,
        300000 * lam.subs(ex).subs(dl, Q(5, 100)), 1)

# ---------- SYM-156: tail term and tail coverage (SPEC-CAP-007 (ii), SPEC-CAP-008) ----------
Tc, Zs, R_ = sp.symbols("T Z R", positive=True)
tail = (Tc + Zs) * CF          # debt carried before liquidation: booked value x CF_t (health factor 1)
# SYM-156 verifies: SPEC-CAP-007, SPEC-CAP-008
eq("SYM-156a", "largest token cap plus slices a reserve R covers: T + Z = R / CF", sp.solve(sp.Eq(tail, R_), Tc)[0] + Zs,
   R_ / CF)
numeric("SYM-156b", "launch: 400,000 GHO covers $1,282,051 of token cap plus slices (down)", 1282051,
        Q(400000) / Q(312, 1000), 1)
numeric("SYM-156c", "SPEC-CAP-008: tail of $1,800,000 at CF 0.312 = $561,600", Q(561600),
        Q(1800000) * Q(312, 1000), Q(1, 100))
numeric("SYM-156d", "SPEC-CAP-008: 400,000 / 561,600 = 71.22% (7,122 bps, down)", Q(7122, 10000),
        Q(400000) / (Q(1800000) * Q(312, 1000)), Q(1, 10000))

# ---------- SYM-157: addCap sizing (SPEC-HUB-002, SPEC-CAP-006) ----------
K, Z, F, n = sp.symbols("K Z F n", positive=True)
# SYM-157 verifies: SPEC-HUB-002, SPEC-CAP-006
eq("SYM-157a", "units booked at >= floor F within K + Z: n F = K + Z gives n = (K + Z)/F", sp.solve(sp.Eq(n * F, K + Z), n)[0],
   (K + Z) / F)
numeric("SYM-157b", "example: 5,500,000 / 1.00 = 5,500,000 whole tokens", 5500000, Q(5500000), 0)
numeric("SYM-157c", "example: 5,500,000 / 1.30 = 4,230,769.23 (addCap 4,230,770)", Q(423076923, 100), Q(5500000) / Q(13, 10),
        Q(1, 100))
numeric("SYM-157d", "example: 1,100,000 / 1.00 = 1,100,000", 1100000, Q(1100000), 0)

# ---------- SYM-158: repay sizing and the deadline quote (SPEC-PROXY-003, SPEC-PROXY-007) ----------
yr = 31536000
# SYM-158 verifies: SPEC-PROXY-003, SPEC-PROXY-007
numeric("SYM-158a", "USDC 5,000 at 6.00% for 30 days = 5,024.657535 (rounded up to base units)", Q(5024657535, 10**6),
        5000 * (1 + Q(6, 100) * 30 * 86400 / yr), Q(1, 10**6))
numeric("SYM-158b", "GHO 8,000 at 5.00% for 30 days = 8,032.876712328767123288 (rounded up)",
        Q(8032876712328767123288, 10**18), 8000 * (1 + Q(5, 100) * 30 * 86400 / yr), Q(1, 10**18))
numeric("SYM-158c", "quoteRepayAll = 5,024,657,535 x (1 + 0.06 x 600 / 31,536,000) x 1.001 -> 5,029,687,935",
        5029687935, 5024657535 * (1 + Q(6, 100) * 600 / yr) * Q(1001, 1000), 1)

# ---------- SYM-159: borrow rate (SPEC-HUB-007) ----------
b, rp = sp.symbols("b rp", positive=True)
# SYM-159 verifies: SPEC-HUB-007
eq("SYM-159a", "drawn interest b plus premium b x rp = b (1 + rp)", b + b * rp, b * (1 + rp))
numeric("SYM-159b", "example: 100,000 x 7.50% (curve rate at U = 0.5) = 7,500 GHO drawn interest (before compounding)",
        7500, 100000 * Q(75, 1000), 0)
numeric("SYM-159c", "example: premium 7,500 x 0.15 = 1,125 GHO", 1125, 7500 * Q(15, 100), 0)
numeric("SYM-159d", "example: effective 7.50% x 1.15 = 8.625%", Q(8625, 100000), Q(75, 1000) * Q(115, 100), 0)

# ---------- SYM-160: price-drop alert (SPEC-BRK-001; monitoring only, 3 % in 2 hours) ----------
cp, pr, bp = sp.symbols("cp p b", positive=True)
# SYM-160 verifies: SPEC-BRK-001
eq("SYM-160a", "cp (1e4 - b) - 1e4 p = 1e4 cp x ((cp - p)/cp - b/1e4): the alert fires iff the drop exceeds b bps",
   cp * (10**4 - bp) - 10**4 * pr, 10**4 * cp * ((cp - pr) / cp - bp / 10**4))
numeric("SYM-160b", "example: $2.0000 to $1.9399 is a 3.005% drop, above the 3% alert threshold", Q(3005, 100000), (2 - Q(19399, 10000)) / 2, 0)

# ---------- SYM-161..162: opening bound and bonus curve ----------
# SYM-161 verifies: SPEC-CF-003
numeric("SYM-161", "SPEC-CF-003 example: 24,600 / 1.10 = $22,363.63 (cents, down)", Q(2236363, 100), Q(24600) / Q(11, 10),
        Q(1, 100))
mx, fac, hfm = sp.symbols("maxLB factor hfm", positive=True)
minLB = 1 + (mx - 1) * fac
curve = minLB + (mx - minLB) * (1 - H) / (1 - hfm)
# SYM-162 verifies: SPEC-HUB-005
numeric("SYM-162a", "SPEC-HUB-005 example: minLB = 1 + 0.05 x 0.40 = 1.0200", Q(102, 100), minLB.subs({mx: Q(105, 100), fac: Q(4, 10)}), 0)
numeric("SYM-162b", "SPEC-HUB-005 example: bonus at hf 0.97 = 1.0290", Q(1029, 1000),
        curve.subs({mx: Q(105, 100), fac: Q(4, 10), hfm: Q(9, 10), H: Q(97, 100)}), 0)

# ---------- SYM-163: listing margin (SPEC-CF-004, SPEC-HUB-006) ----------
e_ = sp.symbols("e", positive=True)
# SYM-163 verifies: SPEC-CF-004, SPEC-HUB-006
eq("SYM-163", "reported HF 1 and true price (1 - e) x reported: true collateral / debt = (1 - e)/CF, which is > 1 iff e < 1 - CF",
   ((1 - e_) * V) / (V * CF), (1 - e_) / CF)

# ---------- SYM-164..165: health factor examples (SPEC-PROXY-006) ----------
# SYM-164 verifies: SPEC-PROXY-006, SPEC-PROXY-001
numeric("SYM-164a", "24,600 / 12,999.5 = 1.892380476172160467 (18 decimals, down)", Q(1892380476172160467, 10**18),
        Q(24600) / Q(129995, 10), Q(1, 10**18))
numeric("SYM-164b", "24,600 / 22,998.5 = 1.069634976194099615 (18 decimals, down)", Q(1069634976194099615, 10**18),
        Q(24600) / Q(229985, 10), Q(1, 10**18))
# SYM-165 verifies: SPEC-CF-001
numeric("SYM-165", "SPEC-CF-001 example: (24,600 - 8,000) / 0.9999 = 16,601.66 USDC exhausts B", Q(1660166, 100),
        Q(16600) / Q(9999, 10000), Q(1, 100))

# ---------- SYM-192: supply rate under the kinked borrow-rate curve (SPEC-HUB-007, Q-407, Q-408) ----------
r_, rp_, f_, Dr, Sup = sp.symbols("r rp f D S", positive=True)
interest = Dr * r_ * (1 + rp_)                       # borrow interest per year at constant state
supply_rate = interest * (1 - f_) / Sup              # shared over every supplied unit
# SYM-192 verifies: SPEC-HUB-007, REQ-HUB-008, REQ-HUB-009
eq("SYM-192a", "supply rate = D r (1 + rp)(1 - f) / S = r (1 + rp) U (1 - f) with U = D / S",
   supply_rate, r_ * (1 + rp_) * (Dr / Sup) * (1 - f_))
b0, g1, g2, uo, uu = sp.symbols("b0 g1 g2 Uopt U", positive=True)
below = b0 + g1 * uu / uo                            # Aave V4 AssetInterestRateStrategy, U <= U*
above = b0 + g1 + g2 * (uu - uo) / (1 - uo)          # U > U*
eq("SYM-192e", "the curve is continuous at the kink: both branches equal base + before at U = U*",
   below.subs(uu, uo) - above.subs(uu, uo), 0)
curve = {b0: Q(55, 1000), g1: Q(36, 1000), g2: Q(50, 100), uo: Q(9, 10)}
r50 = below.subs(curve).subs(uu, Q(1, 2))
r95 = above.subs(curve).subs(uu, Q(95, 100))
numeric("SYM-192f", "curve example: 5.50% + 3.60% x 0.5 / 0.9 = 7.50% at U = 0.5", Q(75, 1000), r50, 0)
numeric("SYM-192g", "curve example: 9.10% + 50% x 0.05 / 0.10 = 34.10% at U = 0.95", Q(341, 1000), r95, 0)
numeric("SYM-192i", "curve example: 9.10% at the kink U = 0.9", Q(91, 1000), below.subs(curve).subs(uu, Q(9, 10)), 0)
numeric("SYM-192j", "curve example: maximum 5.50% + 3.60% + 50% = 59.10% at U = 1", Q(591, 1000),
        above.subs(curve).subs(uu, 1), 0)
ex = {Dr: 900_000, Sup: 1_000_000 + 500_000 + 300_000, r_: r50, rp_: Q(15, 100), f_: Q(1, 10)}
numeric("SYM-192b", "example: 900,000 x 7.50% x 1.15 = 77,625 GHO of borrow interest a year", Q(77625),
        interest.subs(ex), 0)
numeric("SYM-192c", "example: U = 900,000 / 1,800,000 = 0.5; supply rate 0.075 x 1.15 x 0.5 x 0.9 = 3.88125%",
        Q(388125, 10**7), supply_rate.subs(ex), 0)
numeric("SYM-192d", "example: the public lender's 500,000 GHO earns 19,406.25 GHO a year", Q(1940625, 100),
        500_000 * supply_rate.subs(ex), 0)
numeric("SYM-192k", "example: suppliers receive 77,625 x 0.9 = 69,862.5 GHO a year", Q(698625, 10),
        interest.subs(ex) * (1 - ex[f_]), 0)
ex95 = {**ex, Dr: 1_710_000, r_: r95}
numeric("SYM-192h", "at U = 0.95: supply rate 0.341 x 1.15 x 0.95 x 0.9 = 33.528825%", Q(33528825, 10**8),
        supply_rate.subs(ex95), 0)

# ---------- SYM-193: who bears an uncovered deficit when a lender withdraws before realization (Q-353, Q-408) ----------
A_, Sh_, Un_, w_ = sp.symbols("A Sh Un w", positive=True)   # assets, shares, uncovered deficit, withdrawn shares
paid = w_ * A_ / Sh_                                           # Aave pays the unadjusted price before realization
left_after = (A_ - paid) - Un_                                 # remaining suppliers' assets after realization
# SYM-193 verifies: DEF-014, Q-353, Q-408
eq("SYM-193a", "the early withdrawer is paid w A / Sh and carries none of the loss: the remaining (Sh - w) shares carry all Un",
   (Sh_ - w_) * A_ / Sh_ - left_after, Un_)
eq("SYM-193b", "the loss per remaining share rises from Un / Sh to Un / (Sh - w)",
   Un_ / (Sh_ - w_) - Un_ / Sh_, Un_ * w_ / (Sh_ * (Sh_ - w_)))
d14 = {A_: 2_000_000 - 100_000, Sh_: 1_950_000 - 97_500, Un_: 30_000, w_: 18_525}
numeric("SYM-193c", "DEF-014 example: 18,525 shares withdrawn before realization are paid 1,900,000 / 1,852,500 each, "
        "19,000 GHO", Q(19000), paid.subs(d14), 0)
numeric("SYM-193d", "DEF-014 example: the 1,834,000 remaining shares carry all 30,000 GHO: 0.016358 GHO a share "
        "instead of 0.016194", Q(16358, 10**6), (Un_ / (Sh_ - w_)).subs(d14), Q(1, 10**6))
numeric("SYM-193e", "DEF-014 example: the loss the early withdrawer avoided, 18,525 x 30,000 / 1,852,500 = 300 GHO",
        Q(300), (w_ * Un_ / Sh_).subs(d14), 0)

done()
