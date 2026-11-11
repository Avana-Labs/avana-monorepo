# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-150..165 — Risk-area formulas in exact algebra, and the worked examples of the risk pages
recomputed in exact rationals.

Spec: SPEC-PROXY-009 (repay with collateral), SPEC-CAP-003 (restore amount), SPEC-CF-005 (rescue
units excluded), SPEC-CAP-007 / SPEC-CAP-008 (cap sizing guidance, tail ratio), SPEC-HUB-002 /
SPEC-CAP-006 (addCap), SPEC-PROXY-003 / SPEC-PROXY-007 (repay sizing and quote), SPEC-HUB-007
(borrow rate), SPEC-BRK-001 (price-drop alert), SPEC-CF-003 (opening bound), SPEC-HUB-005 (bonus curve),
SPEC-CF-004 / SPEC-HUB-006 (listing margin), SPEC-PROXY-006 (health factor).
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
numeric("SYM-159b", "example: 100,000 x 5.50% = 5,500 GHO drawn interest (before compounding)", 5500, 100000 * Q(55, 1000), 0)
numeric("SYM-159c", "example: premium 5,500 x 0.15 = 825 GHO", 825, 5500 * Q(15, 100), 0)
numeric("SYM-159d", "example: effective 5.50% x 1.15 = 6.325%", Q(6325, 100000), Q(55, 1000) * Q(115, 100), 0)

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

done()
