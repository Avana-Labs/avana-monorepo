# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-20..26 — Uniswap v3 full-range amounts per unit of liquidity and LP value
([2.10] SPEC-ORC-006, SPEC-ORC-007; [2.4] SPEC-UNIT-002, SPEC-UNIT-003; [2.3] SPEC-BACK-001).

Uniswap v3 core SqrtPriceMath (sqrt prices in Q64.96, s = sqrt(P) * 2^96):
  getAmount0Delta(sA, sB, L) = L * 2^96 * (sB - sA) / sB / sA      (sA < sB)
  getAmount1Delta(sA, sB, L) = L * (sB - sA) / 2^96
  in range: amount0 = getAmount0Delta(s, s_upper, L), amount1 = getAmount1Delta(s_lower, s, L)
P = raw token1 per raw token0; p0, p1 = USD per RAW unit (p_i = USD price / 10^d_i).
Exact reals, no rounding (rounding: MATH-UO-06..09, MATH-UO-14..18).
"""
import sympy as sp
from _common import eq, nonneg, info, done

L, P, Pl, Pu, p0, p1, Q = sp.symbols("L P P_l P_u p0 p1 Q96", positive=True)
sP, sl, su = sp.sqrt(P), sp.sqrt(Pl), sp.sqrt(Pu)

# finite-range closed forms
x_fin = L * (1 / sP - 1 / su)
y_fin = L * (sP - sl)

# ---------- SYM-20: SqrtPriceMath Q96 forms equal the closed forms ----------
s, s_l, s_u = sP * Q, sl * Q, su * Q
amount0 = L * Q * (s_u - s) / (s_u * s)
amount1 = L * (s - s_l) / Q
# SYM-20 verifies: SPEC-ORC-006
eq("SYM-20a", "getAmount0Delta(s, s_upper, L) == L (1/sqrtP - 1/sqrtP_upper)", amount0, x_fin)
# SYM-20 verifies: SPEC-ORC-006
eq("SYM-20b", "getAmount1Delta(s_lower, s, L) == L (sqrtP - sqrtP_lower)", amount1, y_fin)

# ---------- SYM-21: ideal full range limit x = L/sqrtP, y = L sqrtP ----------
# SYM-21 verifies: SPEC-ORC-006
eq("SYM-21a", "x -> L/sqrtP as P_upper -> oo", sp.limit(x_fin, Pu, sp.oo), L / sP)
# SYM-21 verifies: SPEC-ORC-006
eq("SYM-21b", "y -> L sqrtP as P_lower -> 0", sp.limit(y_fin, Pl, 0), L * sP)

# ---------- SYM-22: LP value at the fair price is 2 L sqrt(p0 p1) ----------
x, y = L / sP, L * sP
Vspot = x * p0 + y * p1
# SYM-22 verifies: SPEC-ORC-007, SPEC-UNIT-003
eq("SYM-22a", "value at fair spot P = p0/p1: x p0 + y p1 == 2 L sqrt(p0 p1)", Vspot.subs(P, p0 / p1), 2 * L * sp.sqrt(p0 * p1))
# SYM-22 verifies: SPEC-ORC-007
eq("SYM-22b", "legs are equal at the fair price: x p0 == y p1",
   (x * p0).subs(P, p0 / p1), (y * p1).subs(P, p0 / p1))

# ---------- SYM-23: AM-GM: oracle value of the unwound tokens is never below 2 L sqrt(p0 p1) ----------
cert = L * (sp.sqrt(p0) * P ** sp.Rational(-1, 4) - sp.sqrt(p1) * P ** sp.Rational(1, 4)) ** 2
# SYM-23 verifies: SPEC-ORC-007
nonneg("SYM-23", "x p0 + y p1 - 2 L sqrt(p0 p1) = L (sqrt(p0) P^-1/4 - sqrt(p1) P^1/4)^2 >= 0 at any spot P",
       Vspot - 2 * L * sp.sqrt(p0 * p1), cert)

# ---------- SYM-24: finite min/max ticks: exact shortfall versus the ideal formula ----------
Vfin_fair = (x_fin * p0 + y_fin * p1).subs(P, p0 / p1)
gap = 2 * L * sp.sqrt(p0 * p1) - Vfin_fair
# SYM-24 verifies: SPEC-ORC-006, SPEC-BACK-001
eq("SYM-24a", "ideal - finite value at fair spot = L (p0/sqrtP_u + p1 sqrtP_l)", gap, L * (p0 / su + p1 * sl))
eps = sp.simplify(gap / (2 * L * sp.sqrt(p0 * p1)))
# SYM-24 verifies: SPEC-ORC-006
eq("SYM-24b", "relative overvaluation by 2 sqrt(p0 p1): eps = (sqrt(P/P_u) + sqrt(P_l/P)) / 2",
   eps.subs(p0, P * p1), (sp.sqrt(P / Pu) + sp.sqrt(Pl / P)) / 2)

# numeric bound for the usable full-range ticks (SPEC-BACK-001: trunc(MAX_TICK / s) * s) and launch decimals
MAX_TICK = 887272
rows, worst = [], 0
for spacing in (1, 10, 60, 200):
    t = (MAX_TICK // spacing) * spacing
    for (d0, d1) in [(6, 6), (6, 18), (18, 6), (18, 18)]:
        Praw = sp.Integer(10) ** (d1 - d0)            # both tokens at $1
        su_n = sp.Float(1.0001, 60) ** (sp.Rational(t, 2))
        e_n = (sp.sqrt(Praw) / su_n + 1 / (su_n * sp.sqrt(Praw))) / 2
        worst = max(worst, e_n)
        rows.append(f"spacing {spacing:>3} tick +-{t}  d0={d0:>2} d1={d1:>2}: eps = {sp.N(e_n, 3)}")
# SYM-24 verifies: SPEC-ORC-006, SPEC-UNIT-003
info("SYM-24c", "eps for launch pools at $1 (the ideal value exceeds the tick-bounded holdings by eps; negligible)",
     "\n".join(rows) + f"\nmax eps = {sp.N(worst, 3)}")

# ---------- SYM-25: amounts per unit L in whole tokens at $1 / $1 ----------
d0, d1 = sp.symbols("d0 d1", positive=True)
# SYM-25 verifies: SPEC-UNIT-002, SPEC-ORC-006
info("SYM-25", "full-range amounts per unit of liquidity at the fair price (whole tokens)",
     "x = L / sqrtP = L sqrt(p1/p0),  y = L sqrtP = L sqrt(p0/p1)  (raw units)\n"
     "with P_i = USD price of a whole token: x_whole = L 10^-(d0+d1)/2 sqrt(P1/P0), "
     "y_whole = L 10^-(d0+d1)/2 sqrt(P0/P1)\n"
     "=> one unit of L holds 10^-(d0+d1)/2 of each whole token at a 1:1 peg.")
X0, X1 = sp.symbols("P0 P1", positive=True)
# SYM-25 verifies: SPEC-UNIT-002
eq("SYM-25b", "x_raw / 10^d0 == L 10^-(d0+d1)/2 sqrt(P1/P0)",
   ((L * sp.sqrt(p1 / p0)) / 10 ** d0).subs({p0: X0 / 10 ** d0, p1: X1 / 10 ** d1}),
   L * 10 ** (-(d0 + d1) / 2) * sp.sqrt(X1 / X0))

# ---------- SYM-26: ideal value is the min over spot, so a spot move cannot cut oracle value ----------
crit = sp.solve(sp.diff(Vspot, P), P)
# SYM-26 verifies: SPEC-ORC-007
eq("SYM-26", "argmin_P (x p0 + y p1) = p0 / p1 (the oracle ratio)", crit[0], p0 / p1)

done()
