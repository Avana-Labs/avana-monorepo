# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-01..07 — LP collateral factor, borrowing capacity, health factor, opening gate.

Spec: SPEC-HUB-001 / SPEC-CF-001 (CF_LP = min(CF0, CF1) x poolRiskFactor; capacity
B = sum_m V_m x CF_m), SPEC-PROXY-006 (HF = sum V_m CF_m / sum DV_r), SPEC-CF-003 (opening debt
bound B / max(1, hardHealthFloor, minHealthFactor); no on-chain opening floor, Q-398),
SPEC-HUB-005 (maxLB x CF < 1). Aave V4 @ a3ef63e Spoke._processUserAccountData:
  HF = sum_i(value_i * CF_i) / totalDebtValue        (CF of the user's dynamic config key)
Exact real arithmetic; BPS rounding is in the Z3 models (MATH-AR-01..08).
"""
import sympy as sp
from _common import eq, nonneg, info, done

V, D, R, h_o, h_f, maxLB, T = sp.symbols("V D R h_o h_f maxLB T", positive=True)
c0, c1 = sp.symbols("CF0 CF1", positive=True)

CF = sp.Min(c0, c1) * R                 # SPEC-CF-001 LP collateral factor
B = V * CF                              # SPEC-CF-001 borrowing capacity

# SYM-01: capacity is exactly the debt at which V4's HF equals 1 (single collateral market).
HF = V * CF / D
D_at_1 = sp.solve(sp.Eq(HF, 1), D)[0]
# SYM-01 verifies: SPEC-CF-001, SPEC-HUB-001
eq("SYM-01", "V4 HF(D) = 1  <=>  D = V_LP x min(CF0,CF1) x R_pool (SPEC-CF-001)", D_at_1, B)

# SYM-02: monotone non-decreasing in every input.
dV, dR = sp.diff(B, V), sp.diff(B, R)
# SYM-02 verifies: SPEC-CF-001, SPEC-HUB-001
nonneg("SYM-02a", "dB/dV = min(CF0,CF1) x R >= 0", dV, sp.Min(c0, c1) * R)
nonneg("SYM-02b", "dB/dR = V x min(CF0,CF1) >= 0", dR, V * sp.Min(c0, c1))
for name, (lo, hi) in {"CF0<CF1": (c0, c1), "CF1<CF0": (c1, c0)}.items():
    Bb = V * lo * R
    nonneg(f"SYM-02c[{name}]", f"on {name}: dB/d(min) = V x R >= 0 and dB/d(max) = 0",
           sp.diff(Bb, lo) + sp.diff(Bb, hi), V * R)
e, g = sp.symbols("e g", nonnegative=True)
for name, sub in {"CF0<=CF1": {c1: c0 + e + g}, "CF1<=CF0": {c0: c1 + g}}.items():
    delta = (B.subs(c0, c0 + e) - B).subs(sub)
    cert = V * R * e if name == "CF0<=CF1" else sp.Integer(0)
    nonneg(f"SYM-02d[{name}]", f"B(CF0 + e) - B(CF0) >= 0 on branch {name}", sp.simplify(delta), cert)

# SYM-03: capacity never exceeds V x CF_i x R for either leg.
# SYM-03 verifies: SPEC-CF-001, SPEC-HUB-001
for name, sub, leg, cert in [("CF0<=CF1", {c1: c0 + g}, c1, V * R * g),
                             ("CF1<=CF0", {c0: c1 + g}, c0, V * R * g)]:
    nonneg(f"SYM-03[{name}]", f"V x (larger CF) x R - B >= 0 on branch {name} (and = 0 for the smaller leg)",
           sp.simplify((V * leg * R - B).subs(sub)), cert)

# SYM-04: liquidation value and drop to HF = 1 for a single market, debt fixed.
HF0 = sp.symbols("HF0", positive=True)
V_liq = D / CF
# SYM-04 verifies: SPEC-PROXY-006
eq("SYM-04a", "HF(V_liq) = 1 with V_liq = D / CF", (V_liq * CF / D), 1)
drop = 1 - V_liq / V
eq("SYM-04b", "collateral drop to HF 1 = 1 - 1/HF0 (HF0 = V x CF / D)", drop.subs(D, V * CF / HF0), 1 - 1 / HF0)

# SYM-05: opening gate: max debt at opening HF h_o and at the RiskModule floor h_f.
D_open = sp.solve(sp.Eq(V * CF / D, h_o), D)[0]
# SYM-05 verifies: SPEC-CF-003, SPEC-PROXY-001
eq("SYM-05a", "max debt at opening HF h_o = B / h_o", D_open, B / h_o)
info("SYM-05b", "binding opening limit (Q-398)",
     "D_max = B / max(1, hardHealthFloor, minHealthFactor); with the hard floor off (0) and minHealthFactor <= 1 the\n"
     "limit is Aave's own HF 1.00, D_max = B. The Lens recommended borrow uses h_o = 1.10 (D = B / 1.10), a display\n"
     "value only: $100,000 at CF 0.70 gives $63,636 recommended and $70,000 maximum.")

# SYM-06: V4's config constraint maxLB x CF < 1 makes the target-HF denominator positive.
LB = sp.symbols("LB", positive=True)
info("SYM-06a", "pool-risk-factor ceiling implied by maxLB x CF < 1 (SPEC-HUB-005 (a), SPEC-CF-002)",
     "R < 1 / (maxLB x min(CF0, CF1))")
u, w = sp.symbols("u w", nonnegative=True)
# SYM-06 verifies: SPEC-HUB-005, SPEC-CF-002
nonneg("SYM-06b", "T - LB x CF = (T - 1) + (1 - LB x CF) > 0 for T >= 1, LB x CF < 1",
       (1 + u) - (1 - w), u + w)

# SYM-07: capacity is additive across markets: HF = sum V_i CF_i / D = 1  <=>  D = sum B_i.
V1, V2, k1, k2 = sp.symbols("V1 V2 k1 k2", positive=True)
# SYM-07 verifies: SPEC-CF-001, SPEC-PROXY-006
eq("SYM-07", "two markets: D at HF 1 equals B_1 + B_2 (capacity is additive across markets)",
   sp.solve(sp.Eq((V1 * k1 + V2 * k2) / D, 1), D)[0], V1 * k1 + V2 * k2)

done()
