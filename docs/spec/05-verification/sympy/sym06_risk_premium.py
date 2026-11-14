# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-50..54 — User risk premium and the borrow rate vs Aave V4's actual formulas.

Spec: SPEC-HUB-004 (riskPremium_i = ceil(sum w x collateralRisk / sum w) <= max collateralRisk;
threshold = highest collateralRisk + 1), SPEC-HUB-007 (premium accrues at drawnRate x riskPremium
on drawn debt and does not compound on itself; the effective rate at refresh is
drawnRate x (1 + riskPremium), with drawnRate the kinked curve's rate at the utilization of the last Hub action).

Aave V4 @ a3ef63e:
  Spoke._processUserAccountData: collaterals with CF > 0 sorted by collateralRisk ASC (value DESC);
    walk until debt is covered: RP += min(value_i, debtLeft) * risk_i; RP = ceil(RP / covered)
    (covered = min(totalDebtValue, sum of collateral values); values are NOT CF-weighted)
  UserPositionUtils.calculatePremiumDelta: premiumShares = drawnShares.percentMulUp(RP);
    premiumOffsetRay = premiumShares * index - premiumDebtRay (keeps premium debt continuous)
  Premium.calculatePremiumRay = premiumShares * index - premiumOffsetRay
  Hub._applyPremiumDelta: spoke.premiumShares <= spoke.drawnShares.percentMulUp(threshold)
Exact reals; percentMulUp/divUp rounding is listed for Z3 in README.
"""
import sympy as sp
from _common import eq, nonneg, info, done

c1, c2, D, rho1, rho2, dlt = sp.symbols("c1 c2 D rho1 rho2 delta", positive=True)
u = sp.Symbol("u", positive=True)


def v4_urp(colls, debt):
    """colls: list of (value, risk) already sorted by risk ascending; exact V4 walk."""
    left, acc, covered = debt, 0, 0
    for v, rk in colls:
        take = sp.Min(v, left)
        acc += take * rk
        covered += take
        left = left - take
    return acc / covered


# ---------- SYM-50: single collateral market: URP = collateral risk ----------
# SYM-50 verifies: SPEC-HUB-004, SPEC-HUB-007
eq("SYM-50", "one collateral market (any value, any debt): V4 URP = collateralRisk",
   v4_urp([(c1, rho1)], D).subs(D, c1 + u), rho1)

# ---------- SYM-51: two markets, rho1 < rho2: three regimes ----------
two = [(c1, rho1), (c2, rho1 + dlt)]              # rho2 = rho1 + delta > rho1
naive = (c1 * rho1 + c2 * (rho1 + dlt)) / (c1 + c2)
urp_a = v4_urp(two, D).subs(c1, D + u)            # debt covered by the low-risk market alone
# SYM-51 verifies: SPEC-HUB-004
eq("SYM-51a", "D <= c1: V4 URP = rho1 (only the cheapest collateral backs the debt)", urp_a, rho1)
w1 = sp.Min(c1, D)
w2 = sp.Max(0, sp.Min(c2, D - w1))
weighted = ((w1 * rho1 + w2 * (rho1 + dlt)) / (w1 + w2)).subs(c1, D + u)
eq("SYM-51b", "SPEC-HUB-004 form: the V4 walk is sum w x risk / sum w with w_i = min(value_i, debt left) in risk order",
   urp_a, weighted,
   note="weights: min(value_i, debt left) in risk order; collateral beyond the debt has weight 0 "
        "(c1 = $100 at 10%, c2 = $100 at 50%, debt $50: 10%)")
k = sp.Symbol("k", positive=True)                  # D = c1 + k, k < c2
urp_b = v4_urp(two, D).subs({D: c1 + k, c2: k + u})
eq("SYM-51c", "c1 < D <= c1 + c2: V4 URP = (c1 rho1 + (D - c1) rho2) / D",
   urp_b, (c1 * rho1 + k * (rho1 + dlt)) / (c1 + k))
urp_c = v4_urp(two, D).subs(D, c1 + c2 + u)
eq("SYM-51d", "D > c1 + c2 (under-collateralised): V4 URP = value-weighted average of all collateral",
   urp_c, naive)

# ---------- SYM-52: URP never exceeds the highest collateral risk (Q-111/Q-141 threshold) ----------
# SYM-52 verifies: SPEC-HUB-004, Q-141
nonneg("SYM-52", "rho_max - URP >= 0 (regime c1 < D <= c1 + c2 shown; the others are rho1 or the average)",
       (rho1 + dlt) - urp_b, c1 * dlt / (c1 + k))

# ---------- SYM-53: premium accrual vs 'Base x (1 + URP)' ----------
s_, I0, I, RP = sp.symbols("s I_0 I RP", positive=True)   # drawn shares, index at refresh, index now
prem_shares = s_ * RP
offset = prem_shares * I0                                  # premium debt 0 at refresh (fresh position)
debt = s_ * I + (prem_shares * I - offset)
# SYM-53 verifies: SPEC-HUB-007
eq("SYM-53a", "interest accrued since refresh = drawn interest x (1 + URP) (exact)",
   debt - s_ * I0, (s_ * I - s_ * I0) * (1 + RP))
Id = sp.Symbol("I_dot", positive=True)                     # dI/dt = base rate x I
rate_total = s_ * Id * (1 + RP) / debt                      # d(debt)/dt / debt
base = Id / I
eq("SYM-53b", "at the refresh instant (I = I_0) the rate on total debt = base x (1 + URP)",
   rate_total.subs(I, I0), (base * (1 + RP)).subs(I, I0))
eq("SYM-53c", "after accrual: rate on total debt - base x (1 + URP) = -base (1+RP) RP (I - I_0) / (I (1+RP) - RP I_0)",
   rate_total - base * (1 + RP), -base * (1 + RP) * RP * (I - I0) / (I * (1 + RP) - RP * I0))
prem_debt = prem_shares * I - offset
eq("SYM-53d", "SPEC-HUB-007: premium accrues at drawnRate x URP on drawn debt only: d(premium)/dt = URP x d(drawn debt)/dt",
   sp.diff(prem_debt.subs(I, sp.Function("I_t")(sp.Symbol("t"))), sp.Symbol("t")),
   RP * sp.diff((s_ * sp.Function("I_t")(sp.Symbol("t"))), sp.Symbol("t")),
   note="so the premium does not compound on itself; the rate on total debt equals base x (1 + URP) only at refresh (SYM-53b)")
yr = sp.exp(sp.Rational(45, 1000))
info("SYM-53e", "one-year illustration, 4.5% continuously compounded base, URP 50%, no refresh",
     f"V4 debt growth = 1.5 x e^0.045 - 0.5 = {sp.N(sp.Rational(3, 2) * yr - sp.Rational(1, 2), 8)} "
     f"(6.905%); 'Base x (1+URP)' as APR = 6.75%; compounded at 6.75% = {sp.N(sp.exp(sp.Rational(675, 10000)), 8)}")

# ---------- SYM-54: Hub threshold check with Q-141's +1 bps margin ----------
n_users, S = sp.symbols("n S", positive=True)              # S = sum of drawn shares on the Spoke
# SYM-54 verifies: SPEC-HUB-004, Q-141
info("SYM-54", "riskPremiumThreshold margin (Q-141) — closed form, rounding bounded by hand",
     "Each user: premiumShares_i = ceil(s_i rho_i) <= s_i rho_max + 1. Hub: sum premiumShares <= ceil(S theta).\n"
     "Sufficient: S rho_max + n <= S theta  <=>  theta - rho_max >= n / S.\n"
     "With theta = rho_max + 1 bps: sufficient when average drawn shares per user S/n >= 10_000 (wei-scale shares);\n"
     "There is no minimum debt (Q-169): the aggregate form sum s_i (theta - rho_i) >= 9,999 n is what holds in practice\n"
     "(MATH-AR-23c, MATH-AR-24); exact integer proofs are in Z3.")

done()
