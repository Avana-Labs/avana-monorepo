# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-76..78: First-Loss reserve sizing (SPEC-FLR-004, SPEC-FLR-005).

Incident term (SPEC-FLR-004), per account of debt asset a (amounts in units of a, ratios as reals):
  at the pause start HF0 = C CF / Dt >= h (h = pauseLossStartHealthFactor, C the collateral value in units of a);
  over the window: debt Dt (1 + g), collateral C (1 - dLP) in USD, a's price x (1 + u);
  liquidation at bonus LB repays C (1 - dLP) / ((1 + u) LB) of debt; the rest is the deficit.
  lossFactor = max(0, (1 + g) - h (1 - dLP) / (CF LB (1 + u))).
Tail term (SPEC-FLR-005): tail = (tokenUsdCap + slices) x CF_t / minOpeningHealthFactor (capped by the draw capacity).
"""
from z3 import Reals, Real, If, And, Or, Not
from _common import check, done

C, Dt, CF, LB, g, dLP, u, h, hf0 = Reals("C Dt CF LB g dLP u h HF0")
lossF = Real("lossFactor")
pre = [Dt > 0, C > 0, CF > 0, CF < 1, LB >= 1, LB <= 1.2, g >= 0, g <= 0.1, dLP >= 0, dLP <= 1, u >= 0, u <= 1,
       h > 0, h <= 1.5, hf0 == C * CF / Dt, hf0 >= h,
       lossF == If((1 + g) - h * (1 - dLP) / (CF * LB * (1 + u)) > 0, (1 + g) - h * (1 - dLP) / (CF * LB * (1 + u)), 0)]
loss = If(Dt * (1 + g) - C * (1 - dLP) / ((1 + u) * LB) > 0, Dt * (1 + g) - C * (1 - dLP) / ((1 + u) * LB), 0)
# MATH-ST-76 verifies: SPEC-FLR-004, Q-192, Q-236
check("MATH-ST-76",
      "an account at HF >= pauseLossStartHealthFactor loses at most debt x lossFactor over the incident window",
      pre + [loss > Dt * lossF],
      "PROVED")

# Two markets, every account counted once: sum of losses <= sum of caps x loss factors <= reserve.
C2, D2, CF2, cap1, cap2, lf2, res = Reals("C2 D2 CF2 cap1 cap2 lossFactor2 reserve")
pre2 = pre + [D2 > 0, C2 > 0, CF2 > 0, CF2 < 1, C2 * CF2 / D2 >= h,
              lf2 == If((1 + g) - h * (1 - dLP) / (CF2 * LB * (1 + u)) > 0, (1 + g) - h * (1 - dLP) / (CF2 * LB * (1 + u)), 0),
              Dt <= cap1, D2 <= cap2, cap1 * lossF + cap2 * lf2 <= res]
loss2 = If(D2 * (1 + g) - C2 * (1 - dLP) / ((1 + u) * LB) > 0, D2 * (1 + g) - C2 * (1 - dLP) / ((1 + u) * LB), 0)
# MATH-ST-76 verifies: SPEC-FLR-004
check("MATH-ST-76",
      "two markets exposed to one token: total incident loss <= sum of debtCap x lossFactor <= reserve",
      pre2 + [loss + loss2 > res],
      "PROVED")

# Tail: one pool token fails completely, so the collateral of every account in the markets holding it goes to 0
# and the loss is the debt outstanding. Accounts open at HF >= minOpeningHealthFactor, but interest and the price
# of the other leg move debt up to collateral x CF (HF = 1) before they become liquidatable.
bk, cft, ho, debt, tail = Reals("booked CF_t minOpeningHealthFactor debt tail")
tpre = [bk > 0, cft > 0, cft < 1, ho > 1, ho <= 2, debt > 0, debt * ho <= bk * cft * 2]   # bounded search space
# MATH-ST-77 verifies: SPEC-FLR-005, SPEC-CAP-007
check("MATH-ST-77",
      "deliberate wrong reading (the tail term before the fix): booked x CF_t / minOpeningHealthFactor does not bound "
      "the debt of a non-liquidatable account; SPEC-FLR-005 and SPEC-CAP-007 use booked x CF_t (MATH-ST-78)",
      tpre + [debt <= bk * cft, tail == bk * cft / ho, debt > tail],
      "COUNTEREXAMPLE", show=[bk, cft, ho, debt, tail])
# MATH-ST-78 verifies: SPEC-FLR-005, SPEC-CAP-007
check("MATH-ST-78",
      "corrected tail term booked x CF_t covers the debt of every non-liquidatable account",
      tpre + [debt <= bk * cft, tail == bk * cft, debt > tail],
      "PROVED")

done()
