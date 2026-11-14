# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-60..72 — a borrow-to-liquidation walkthrough of one LP position, derived exactly.

Avana's example: a $100,000 full-range WETH/USDC position in a market whose underlying collateral
factors are 70 % and whose pool risk factor is 50 % (SPEC-CF-001), 25,000 GHO borrowed, a price fall to
HF 0.98 and a liquidation at a 5 % bonus to a 1.05 target (SPEC-HUB-005, SPEC-HUB-008), and the borrow
rate with a 50 % risk premium (SPEC-HUB-007). Formulas from SYM-01..17 and SYM-50..53. Figures written
with fewer digits are checked to half a unit of their last digit.
"""
import sympy as sp
from _common import eq, nonneg, numeric, info, done

Q = sp.Rational
V0, CF0, R, D = 100_000, Q(70, 100), Q(50, 100), 25_000
CF = CF0 * R

# Collateral and Health Factors table
# SYM-60 verifies: SPEC-CF-001
eq("SYM-60", "LP CF = min(CF0, CF1) x pool risk factor = 70% x 50% = 35%", CF, Q(35, 100))
# SYM-61 verifies: SPEC-CF-001
eq("SYM-61", "borrowing capacity = $100,000 x 35% = 35,000 GHO", V0 * CF, 35_000)
# SYM-62 verifies: SPEC-CF-003
numeric("SYM-62", "interface limit at opening HF 1.10 'about 31,800' = 35,000 / 1.10", 31_800, V0 * CF / Q(110, 100), 50,
        note="exact 31,818.18, written to the hundred")
# SYM-63 verifies: SPEC-CF-001, SPEC-HUB-008
eq("SYM-63", "25,000 GHO borrowed -> HF = 35,000 / 25,000 = 1.40", V0 * CF / D, Q(140, 100))
# SYM-64 verifies: SPEC-CF-001
numeric("SYM-64", "collateral at HF 1 with debt unchanged 'about $71,400' = 25,000 / 0.35", 71_400, D / CF, 50)
# SYM-65 verifies: SPEC-CF-001
numeric("SYM-65", "collateral fall to HF 1 'about 29%' = 1 - 1/1.4 = 2/7", 29, 100 * (1 - D / (V0 * CF)), Q(1, 2))

# 49% ETH drop: full range WETH/USDC, USDC = $1, V = 2 L sqrt(p_ETH x 1) (SYM-22)
p, pn, L = sp.symbols("p p_new L", positive=True)
ratio = sp.solve(sp.Eq(2 * L * sp.sqrt(pn) / (2 * L * sp.sqrt(p)), 1 / Q(140, 100)), pn)[0] / p
# SYM-66 verifies: SPEC-ORC-007
eq("SYM-66a", "full range: value ratio 1/1.4 needs ETH price ratio (1/1.4)^2 = 25/49", ratio, Q(25, 49))
# SYM-66 verifies: SPEC-ORC-007
numeric("SYM-66b", "ETH decline 'roughly 49%' = 1 - 25/49 = 24/49", 49, 100 * (1 - ratio), Q(1, 2))

# Liquidation Design example: collateral $70,000, debt 25,000, bonus 5%, target 1.05
Vl, LB, T = 70_000, Q(105, 100), Q(105, 100)
H = Vl * CF / D
# SYM-67 verifies: SPEC-CF-001, SPEC-HUB-008
eq("SYM-67", "HF at $70,000 = 70,000 x 0.35 / 25,000 = 0.98", H, Q(98, 100))
r = D * (T - H) / (T - LB * CF)                    # SYM-12
# SYM-68 verifies: SPEC-HUB-005
eq("SYM-68a", "repay r* = 25,000 (1.05 - 0.98)/(1.05 - 1.05 x 0.35) = 1750 / 0.6825 = 2,564.10", r, Q(1750) / Q(6825, 10000))
# SYM-68 verifies: SPEC-HUB-005
numeric("SYM-68b", "repays 'about 2,564 GHO'", 2_564, r, Q(1, 2))
# SYM-69 verifies: SPEC-HUB-005
numeric("SYM-69a", "removes 'about $2,692' = r x 1.05", 2_692, r * LB, Q(1, 2))
# SYM-69 verifies: SPEC-HUB-005
nonneg("SYM-69b", "'less than 4% of the position': 4% - r x 1.05 / 70,000 = 4% - 3.846% > 0",
       Q(4, 100) - r * LB / Vl, Q(1, 650))
# SYM-70 verifies: SPEC-HUB-005
numeric("SYM-70a", "leaves 'about $67,300' of collateral", 67_300, Vl - r * LB, 50)
# SYM-70 verifies: SPEC-HUB-005
numeric("SYM-70b", "leaves '22,436 GHO' of debt", 22_436, D - r, Q(1, 2))
# SYM-70 verifies: SPEC-HUB-005
eq("SYM-70c", "HF after = (70,000 - r x 1.05) x 0.35 / (25,000 - r) = 1.05 exactly", (Vl - r * LB) * CF / (D - r), T)
# SYM-70 verifies: SPEC-HUB-005
info("SYM-70d", "assumptions the liquidation example needs (Aave V4 @ a3ef63e)",
     "1. LB(0.98) = 1.05 on V4's curve: (maxLB-1)[factor + (1-factor) 0.02/(1-hf_max)] = 0.05,\n"
     "   e.g. maxLB 1.05 with hf_max >= 0.98, or maxLB 1.10, hf_max 0.90, factor 0.375 (SYM-71).\n"
     "2. HF 0.98 > LB x CF = 0.3675, so a partial seizure raises HF (SYM-13).\n"
     "3. Dust rule inactive: remaining debt $22,436 and collateral $67,308 both >= $1,000.\n"
     "4. debtToCover >= 2,564.10; GHO = $1; one collateral and one debt reserve; 25,000 includes premium;\n"
     "   liquidationFee = 0; prices identical for HF and seizure in the same block.")

# SYM-71: bonus-curve parameters that give 5% at HF 0.98
maxLB, hfm, fac = sp.symbols("maxLB hf_max factor", positive=True)
b098 = (maxLB - 1) * (fac + (1 - fac) * (1 - Q(98, 100)) / (1 - hfm))
sol = sp.solve(sp.Eq(b098, Q(5, 100)), fac)[0]
# SYM-71 verifies: SPEC-HUB-005
eq("SYM-71", "factor giving a 5% bonus at HF 0.98 for maxLB 1.10, hf_max 0.90 is 0.375",
   sol.subs({maxLB: Q(110, 100), hfm: Q(90, 100)}), Q(375, 1000))
# SYM-71 verifies: SPEC-HUB-005
info("SYM-71b", "general solution", f"factor = {sp.simplify(sol)}  (valid when 0 <= factor <= 1)")

# Borrowing rate example
# SYM-72 verifies: SPEC-HUB-007
eq("SYM-72", "4.5% base x (1 + 50%) = 6.75% (single collateral market, URP = collateralRisk, APR at refresh: SYM-50, SYM-53)",
   Q(45, 1000) * (1 + Q(1, 2)), Q(675, 10000))

done()
