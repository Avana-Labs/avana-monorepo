# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-10..19 — Aave V4 liquidation sizing (LiquidationLogic.sol @ a3ef63e), exact algebra.

Spec: SPEC-HUB-005 (bonus curve, target health factor), SPEC-HUB-008 (liquidationCall: seized
value <= debt repaid x bonus), SPEC-LIQ-001 (bonus net of the liquidation fee; launch fee 0).

Code under check (pinned a3ef63e):
  calculateLiquidationBonus: HF <= hfMax -> maxLB; else
      minLB = (maxLB - 1e4).percentMulDown(factor) + 1e4
      LB    = minLB + (maxLB - minLB) * (1e18 - HF) / (1e18 - hfMax)
  _calculateDebtToTargetHealthFactor:
      debtRay = totalDebtValueRay * Ud * (T - HF) / ((T - LB.bpsToWad().percentMulUp(CF)) * Pd.toWad())
  _calculateCollateralToLiquidate:
      collateral = debtRay * Pd * Uc * LB / (Ud * Pc * 1e4 * RAY)
  collateral-capped / dust branch:
      debtRay = collateral * Pc * Ud * 1e4 * RAY / (Pd * Uc * LB)
  collateralSharesToLiquidator = seized - seized * fee * (LB - 1e4) / (LB * 1e4)
Real-valued model: LB, CF, fee as fractions; prices in USD per whole token; no rounding
(rounding: MATH-AR-09..15 and the settlement models).
"""
import sympy as sp
from _common import eq, nonneg, info, done

D, W, H, T, LB, CF, r, Pd, Pc, Ud, Uc, RAY, BPS = sp.symbols(
    "D W H T LB CF r P_d P_c U_d U_c RAY BPS", positive=True)
maxLB, minLB, hfm, fac, fee, n = sp.symbols("maxLB minLB hf_max factor fee n", positive=True)

# ---------- SYM-10: seized collateral = repay x LB x P_d / P_c ----------
r_units = sp.symbols("r_units", positive=True)            # debt repaid, whole debt tokens
debtRay = r_units * Ud * RAY
LB_bps = LB * BPS
seized_raw = debtRay * Pd * Uc * LB_bps / (Ud * Pc * BPS * RAY)
# SYM-10 verifies: SPEC-HUB-008, SPEC-HUB-005
eq("SYM-10a", "code: seized collateral (whole tokens) = repay x LB x P_d / P_c",
   seized_raw / Uc, r_units * LB * Pd / Pc)
eq("SYM-10b", "seized USD value = repaid USD value x LB  (= repay x (1 + bonus) at GHO $1)",
   (seized_raw / Uc) * Pc, (r_units * Pd) * LB)
# collateral-capped / dust branch is the exact inverse
c_units = sp.symbols("c_units", positive=True)
debtRay_cap = (c_units * Uc) * Pc * Ud * BPS * RAY / (Pd * Uc * LB_bps)
eq("SYM-10c", "collateral-capped branch: repaid value = seized value / LB (same ratio in every branch)",
   (debtRay_cap / (Ud * RAY)) * Pd, c_units * Pc / LB)

# ---------- SYM-11: HF after repaying r (USD) against the seized reserve ----------
# W = sum_i value_i * CF_i (all collateral), D = total debt value, H = W / D.
H_after = (W - r * LB * CF) / (D - r)
# SYM-11 verifies: SPEC-HUB-005
eq("SYM-11", "HF after partial liquidation = (H x D - r x LB x CF) / (D - r)",
   H_after.subs(W, H * D), (H * D - r * LB * CF) / (D - r))

# ---------- SYM-12: repay needed to reach target T; equals V4's formula ----------
r_star = sp.solve(sp.Eq(H_after.subs(W, H * D), T), r)[0]
# SYM-12 verifies: SPEC-HUB-005
eq("SYM-12a", "solve HF_after = T  ->  r* = D (T - H) / (T - LB x CF)", r_star, D * (T - H) / (T - LB * CF))
# V4: debtRay = totalDebtValueRay * Ud * (T - HF) / ((T - LB*CF) * Pd); in USD: debtRay/(Ud*RAY) * Pd
totalDebtValueRay = D * RAY
v4_debtRay = totalDebtValueRay * Ud * (T - H) / ((T - LB * CF) * Pd)
eq("SYM-12b", "V4 _calculateDebtToTargetHealthFactor (USD) == r*", v4_debtRay / (Ud * RAY) * Pd, r_star)
eq("SYM-12c", "HF after repaying r* is exactly T", sp.simplify(H_after.subs(W, H * D).subs(r, r_star)), T)

# ---------- SYM-13: direction of HF change; reachability of the target ----------
dH = sp.diff(H_after, r)
# SYM-13 verifies: SPEC-HUB-005
eq("SYM-13a", "dHF_after/dr = (W - LB x CF x D) / (D - r)^2  -> raises HF iff HF > LB x CF",
   dH, (W - LB * CF * D) / (D - r) ** 2)
eq("SYM-13b", "r* - D = D (LB x CF - H) / (T - LB x CF)  -> partial (r* < D) iff HF > LB x CF",
   r_star - D, D * (LB * CF - H) / (T - LB * CF))
info("SYM-13c", "closed form: partial-liquidation regime",
     "Target T is reachable by a partial seizure iff HF > LB x CF and r* x LB <= value of the seized reserve.\n"
     "For HF <= LB x CF, V4 caps at full debt or all of that reserve's collateral (dust/collateral branches).\n"
     "Example: CF 0.35, LB 1.05 -> HF <= 0.3675; stable CF 0.80, LB 1.03 -> HF <= 0.824.")

# ---------- SYM-14: monotonicity of r* ----------
# SYM-14 verifies: SPEC-HUB-005
eq("SYM-14a", "dr*/dH = -D / (T - LB x CF) < 0 (healthier account repays less)",
   sp.diff(r_star, H), -D / (T - LB * CF))
eq("SYM-14b", "dr*/dT = D (H - LB x CF) / (T - LB x CF)^2 (> 0 in the partial regime)",
   sp.diff(r_star, T), D * (H - LB * CF) / (T - LB * CF) ** 2)
eq("SYM-14c", "dr*/dLB = D CF (T - H) / (T - LB x CF)^2 (> 0 for H < T)",
   sp.diff(r_star, LB), D * CF * (T - H) / (T - LB * CF) ** 2)

# ---------- SYM-15: bonus-vs-HF linear curve ----------
minLB_def = 1 + (maxLB - 1) * fac
LB_curve = minLB_def + (maxLB - minLB_def) * (1 - H) / (1 - hfm)
# SYM-15 verifies: SPEC-HUB-005, Q-179
eq("SYM-15a", "curve is continuous at hf_max: LB(hf_max) = maxLB", LB_curve.subs(H, hfm), maxLB)
eq("SYM-15b", "LB(HF -> 1) = minLB = 1 + (maxLB - 1) x factor", LB_curve.subs(H, 1), minLB_def)
eq("SYM-15c", "slope dLB/dHF = -(maxLB - 1)(1 - factor)/(1 - hf_max) (<= 0: bonus falls as HF rises)",
   sp.diff(LB_curve, H), -(maxLB - 1) * (1 - fac) / (1 - hfm))
eq("SYM-15d", "bonus b(HF) = LB - 1 = (maxLB - 1) [factor + (1 - factor)(1 - HF)/(1 - hf_max)]",
   LB_curve - 1, (maxLB - 1) * (fac + (1 - fac) * (1 - H) / (1 - hfm)))
info("SYM-15e", "minimum bonus over the liquidatable range (SPEC-HUB-005 (b): minLB - 1 >= minLiquidationBonus)",
     "inf_{HF<1} LB(HF) = minLB = 1 + (maxLB - 1) x factor (approached as HF -> 1-, not attained).")

# ---------- SYM-16: liquidation fee 0 -> liquidator receives every seized share ----------
seized = sp.symbols("seized", positive=True)
to_liq = seized - seized * fee * (LB - 1) / LB
# SYM-16 verifies: SPEC-HUB-008, SPEC-LIQ-001
eq("SYM-16a", "collateralSharesToLiquidator = seized x (1 - fee x (LB-1)/LB)", to_liq, seized * (1 - fee * (LB - 1) / LB))
eq("SYM-16b", "with liquidationFee = 0 LPVaultSwap receives all seized shares",
   to_liq.subs(fee, 0), seized)

# ---------- SYM-17: residual collateral and debt after r* (single market) ----------
V = sp.symbols("V", positive=True)
H1 = V * CF / D
# SYM-17 verifies: SPEC-HUB-005
eq("SYM-17", "single market: (V - r* LB) CF / (D - r*) = T", sp.simplify(((V - r_star.subs(H, H1) * LB) * CF / (D - r_star.subs(H, H1)))), T)

done()
