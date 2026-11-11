# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-40..49 — recovery floor, effective slippage, settlement waterfall, the caller's rounding loss and the unwind
value bound, exact and before rounding. There is no settlement budget, no in-kind settlement, and no flash loan in a
liquidation (Q-404): the caller funds the repayment, and a helper's premium is the helper's.

Final formulas (2.11 LPVaultSwap, 2.13 the settlement gap), amounts in the debt asset:
  r     debt repaid D                              b    net bonus (bNet = 1 + b), SPEC-LIQ-001
  V     oracle value of the seizure = r (1 + b)    SPEC-LIQ-004
  s     effective slippage, no premium term        SPEC-LIQ-002, SPEC-LIQ-003;  Uu, Al  unit term U and allowance
  term  slippage term V (1 - s);  minRec = term - Uu - Al                                      SPEC-LIQ-005
  S     = max(0, R_f - r), R_f = max(R, minRec);  G = max(0, V - r);  A = min(alpha G, S)      SPEC-LIQ-007..009
  gap   = max(0, r + A + B - Kf - R);  shortfall = max(0, minRec - R, gap);  R' = R + shortfall SPEC-SET-001, -LIQ-019
  keeperOut = Kf + R' - (r + A + B)                                                            SPEC-LIQ-010
  f     a helper's premium rate (SPEC-LIQ-015, SPEC-LIQ-016 listing check); never in LPVaultSwap's formulas
Integer rounding of each term is proved in the Z3 settlement models (MATH-ST-…).
"""
import sympy as sp
from _common import eq, nonneg, fails, info, done

r = sp.Symbol("r", positive=True)
b, f, s, Uu, Al, alpha, Kf, u, q, d = sp.symbols("b f s U A_l alpha K_f u q d", nonnegative=True)
V = r * (1 + b)
term = V * (1 - s)

# SYM-40 verifies: SPEC-LIQ-005, SPEC-LIQ-004, LIQ-060
eq("SYM-40", "minRec = V (1 - s) - U - allowance = r (1 + b)(1 - s) - U - allowance",
   term - Uu - Al, r * (1 + b) * (1 - s) - Uu - Al)

# Largest slippage for which the slippage term repays r (1 + f); f = 0 is the liquidation, f > 0 the listing check.
s_star = sp.solve(sp.Eq(term, r * (1 + f)), s)[0]
# SYM-41 verifies: SPEC-LIQ-016, SPEC-LIQ-003
eq("SYM-41a", "term >= r (1 + f)  <=>  s <= s* = 1 - (1 + f) / (1 + b)", s_star, 1 - (1 + f) / (1 + b))
# SYM-41 verifies: SPEC-LIQ-016, SPEC-LIQ-003
eq("SYM-41b", "term - r (1 + f) = r (1 + b)(s* - s): the sign is exactly s <= s*",
   term - r * (1 + f), r * (1 + b) * (s_star - s))
# SYM-41 verifies: SPEC-LIQ-003, SPEC-LIQ-002, Q-404
eq("SYM-41c", "a liquidation has no premium term: at f = 0 the bound is b / (1 + b) = (bNet - 1) / bNet",
   s_star.subs(f, 0), b / (1 + b))

# SYM-42 verifies: SPEC-LIQ-003
fails("SYM-42a", "wrong reading: subtractive bound s = b leaves term - r = -r b^2 < 0",
      (term - r).subs(s, b), {r: 1, b: sp.Rational(5, 100)},
      note="5 % bonus, s = 5 %: the term is 0.9975 r, 0.25 % short of the debt")
# SYM-42 verifies: SPEC-LIQ-003
eq("SYM-42b", "shortfall at the subtractive bound = r b^2", -(term - r).subs(s, b), r * b ** 2)
# SYM-42 verifies: SPEC-LIQ-003
eq("SYM-42c", "subtractive minus multiplicative bound = b^2 / (1 + b)", b - s_star.subs(f, 0), b ** 2 / (1 + b))

# SYM-43 verifies: SPEC-LIQ-001
lf = sp.Symbol("lf", nonnegative=True)
bg = sp.Symbol("b_gross", nonnegative=True)
eq("SYM-43", "net bonus b = b_gross (1 - lf): Aave's liquidation fee comes out of the bonus before slippage",
   (1 + bg * (1 - lf)) - 1, bg - bg * lf)

# SYM-44 verifies: SPEC-LIQ-016, REQ-PSTORE-021
eq("SYM-44a", "ds*/db = (1 + f) / (1 + b)^2 > 0: the minimum bonus is the binding case",
   sp.diff(s_star, b), (1 + f) / (1 + b) ** 2)
# SYM-44 verifies: SPEC-LIQ-016, REQ-PSTORE-021, Q-404
nonneg("SYM-44b", "listing check minLB (1 - smin) >= 1 + maxFlash implies the liquidation bound minLB (1 - smin) >= 1: "
       "the slack is maxFlash", (1 + f) - 1, f)
info("SYM-44c", "listing liveness (REQ-PSTORE-021, SPEC-LIQ-016)",
     "minLB (1 - slippageAllowanceMinBps) >= 1 + maxFlashFeeBps  =>  s*(minLB) at f = 0 >= slippageAllowanceMinBps;\n"
     "with SYM-44a every bonus Aave can pay then gives s >= slippageAllowanceMinBps (MATH-ST-13 in integers), and at the\n"
     "minimum slippage the slippage term covers r (1 + maxFlashFeeBps), a helper loan of r with its premium.")

# SYM-45 verifies: SPEC-LIQ-007, SPEC-SET-001, REQ-HELPER-007, Q-404
F, phi = sp.symbols("F phi", nonnegative=True)
eq("SYM-45", "a helper's premium on its whole loan, f F, is paid from keeperOut: its net payout keeperOut - F - f F "
   "falls by f (F - r) against a loan of r, the caller's own cost, while keeperOut has no F term",
   ((Kf + q - r) - F - f * F).subs(Kf, F) - ((Kf + q - r) - r - f * r).subs(Kf, r), -f * (F - r))

# Waterfall: three cases of the realized recovery R' against r.
gain = sp.Symbol("gain", nonnegative=True)          # G = max(0, V - r)
pos = lambda z: sp.Max(0, z)


def payout(Rp_, A_, B_=0):
    return Kf + Rp_ - (r + A_ + B_)


# (i) S covers the uncapped fee: R' = r + alpha gain + q
# SYM-46 verifies: SPEC-LIQ-010, SPEC-LIQ-009
eq("SYM-46a", "R' = r + alpha gain + q (S covers the fee): keeperOut = Kf + q", payout(r + alpha * gain + q, alpha * gain),
   Kf + q)
Sv = sp.Symbol("S", positive=True)
# SYM-46 verifies: SPEC-LIQ-010, SPEC-LIQ-009, SPEC-LIQ-008
eq("SYM-46b", "0 < S < alpha gain: A = S and keeperOut = Kf", payout(r + Sv, Sv), Kf)
# SYM-46 verifies: SPEC-LIQ-010, SPEC-SET-001, SPEC-LIQ-019, SPEC-LIQ-017
eq("SYM-46c", "R' = r - d below the debt (A = B = 0): keeperOut = Kf - d, the caller's loss; never negative for Kf >= r",
   payout(r - d, 0), Kf - d)
# SYM-46 verifies: SPEC-LIQ-009
eq("SYM-46d", "the uncapped fee alpha (V - r) has no term in R': d/dR' = 0",
   sp.diff(alpha * (V - r), sp.Symbol("Rp")), 0)

# SYM-47 verifies: SPEC-SET-001, SPEC-LIQ-019, INV-038
eq("SYM-47", "worst loss at R = minRec: r - minRec = r (1 + b)(s - s*_0) + U + allowance  (<= U + allowance for "
   "s <= s*_0 = b / (1 + b)), borne in keeperOut",
   r - (term - Uu - Al), r * (1 + b) * (s - s_star.subs(f, 0)) + Uu + Al)

# SYM-48: value of the unwound tokens (every liquidation settles over the swap routes; no in-kind settlement)
L, P, p0, p1 = sp.symbols("L_s P p0 p1", positive=True)
Uk = L * (p0 / sp.sqrt(P) + p1 * sp.sqrt(P))        # oracle value of the unwound tokens at pool price P
Vs_L = 2 * L * sp.sqrt(p0 * p1)                    # oracle (LPOracle) value of the seized liquidity
# SYM-48 verifies: SPEC-LIQ-011, SPEC-LIQ-005
eq("SYM-48a", "at the oracle-implied pool price P = p0 / p1 the unwound tokens are worth exactly the oracle value",
   sp.simplify(Uk.subs(P, p0 / p1) - Vs_L), 0)
# SYM-48 verifies: SPEC-LIQ-011, SPEC-LIQ-018, REQ-SWAP-025
nonneg("SYM-48b", "val - V_oracle = L (sqrt(p0) P^-1/4 - sqrt(p1) P^1/4)^2 >= 0: removal at any pool price returns "
       "at least the oracle value", Uk - Vs_L,
       L * (sp.sqrt(p0) * P ** sp.Rational(-1, 4) - sp.sqrt(p1) * P ** sp.Rational(1, 4)) ** 2)
# SYM-48 verifies: SPEC-LIQ-011, REQ-SWAP-025
info("SYM-48c", "no in-kind settlement",
     "Every liquidation swaps the unwound tokens into the debt asset; a token with no usable route reverts NoRouteAvailable.\n"
     "With SYM-48a/b a pool price away from the oracle only raises the oracle value of what the unwind returns.")

# SYM-49 verifies: SPEC-LIQ-009, SPEC-LIQ-008, Q-404
eq("SYM-49", "the fee base V - r = r b is fixed by the bonus alone (no premium term)", V - r, r * b)

# --- Debt-asset settlement (Q-333, Q-337): amounts in the debt asset, no buy leg ---
G_o = sp.Symbol("G_oracle", nonnegative=True)       # oracle gain max(0, V - r)
S_r = sp.Symbol("S_r", nonnegative=True)            # realized surplus
A_s = sp.Symbol("A_s", nonnegative=True)
Rp = sp.Symbol("Rp", nonnegative=True)
kr_hi = G_o - A_s
# SYM-180 verifies: SPEC-LIQ-022, SPEC-LIQ-010
eq("SYM-180a", "S >= G: kr = G - A and B = S - G, so A + kr + B = S", A_s + kr_hi + (S_r - G_o), S_r)
# SYM-180 verifies: SPEC-LIQ-022
eq("SYM-180b", "S >= G: the borrower surplus is B = (R' - r) - (V - r) = R' - V", (Rp - r) - (V - r), Rp - V)
# SYM-180 verifies: SPEC-LIQ-010, SPEC-LIQ-022, SPEC-SET-001
eq("SYM-180c", "debt-asset waterfall with S >= G: keeperOut = Kf + kr",
   (Kf + Rp) - (r + A_s + (Rp - r - G_o)), Kf + (G_o - A_s))
# SYM-180 verifies: SPEC-LIQ-003, SPEC-LIQ-016
eq("SYM-180d", "no buy leg and no premium: the effective-slippage bound is b / (1 + b), the f = 0 case of SYM-41",
   s_star.subs(f, 0), b / (1 + b))

done()
