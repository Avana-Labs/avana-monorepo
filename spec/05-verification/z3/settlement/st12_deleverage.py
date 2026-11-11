# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-71..75, MATH-ST-123: repay with collateral sizing (SPEC-LIQ-020), in base units of the debt asset (Q-333).

  V    = floor(units Pc 10^dd / (10^dv Pdebt));  s = slippageAllowanceBps;  U as SPEC-LIQ-005
  Vnet = max(0, floor(V (1e4 - s) / 1e4) - U - eps);  cap = floor(Vnet 1e4 / (1e4 + maxFlashFeeBps))
  eps = floorRoundingAllowance, the same allowance the leg minimums give up (floor(eps / n') per leg)
  x = min(debt, cap), flash-borrowed as F = x of the debt asset itself, phi = flashFee(x)
  (no buy leg and no GHO conversion for any debt asset; the 18-decimal figures below are one instance)
  legs run at sLeg = s (SPEC-LIQ-018, no shortfall allowance); assetOut = R - x - phi, else
  DeleverageShortfall.
Health factor: HF = C CF / Dt (C collateral value, Dt total debt, CF as a ratio).
"""
from z3 import Int, Ints, Reals, IntVector, If, And, Or, Not, Sum
from _common import check, maximize, floor_div, ceil_div, half_up, done, BPS

E18 = 10**18
PG = 10**8
ALLOW = E18
UL = [10**12, 10**12]
U2 = sum(UL)

# ---------- ST-71: the debt-asset repayment plus its flash fee fits inside Vnet ----------
Vn, cap, x, phi, mf, f = Ints("Vnet cap x phi maxFlashFeeBps f")
# The fee is non-decreasing in its rate, so f = maxFlashFeeBps is the worst case; each rate is checked exactly.
for mfv in (0, 1, 9, 30, 100):
    # MATH-ST-71 verifies: SPEC-LIQ-020, Q-255
    check("MATH-ST-71",
          f"maxFlashFeeBps {mfv}: x <= cap = floor(Vnet 1e4 / (1e4 + maxFlashFeeBps)) and its flash fee (half up) "
          f"give x + phi <= Vnet",
          [Vn >= 0, Vn < 2**200, x >= 0, x <= cap]
          + floor_div(cap, Vn * BPS, BPS + mfv) + half_up(phi, x * mfv, BPS) + [x + phi > Vn],
          "PROVED")

# ---------- ST-72: no buy leg; the repayment and its premium fit inside Vnet under either fee rounding ----------
xd, debt, phc = Ints("x debt phiCeil")
for mfv in (0, 5, 10, 100):
    # MATH-ST-72 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-088, Q-333
    check("MATH-ST-72",
          f"maxFlashFeeBps {mfv}: x = min(debt, cap) of the debt asset itself, premium rounded up, gives "
          f"x + phi <= Vnet + 1 (no buy leg, no conversion of the repayment)",
          [Vn >= 0, Vn < 2**200, debt >= 0, xd == If(debt < cap, debt, cap)]
          + floor_div(cap, Vn * BPS, BPS + mfv) + ceil_div(phc, xd * mfv, BPS) + [xd + phc > Vn + 1],
          "PROVED")

# ---------- ST-73: what a conversion that meets its leg minimums leaves short ----------
# Two equal-value legs (full range at the oracle price), s = 100, maxFlashFeeBps = 0, 18-decimal debt asset, x = cap.
V, term, vn0, R = Ints("V term Vnet0 R")
vl = IntVector("Vleg", 2)
mo = IntVector("minOut", 2)
legs73 = [Sum(vl) <= V + U2, Sum(vl) >= V - U2, vl[0] - vl[1] <= max(UL) + 1, vl[1] - vl[0] <= max(UL) + 1]
for i in range(2):
    t = Int(f"t{i}")
    legs73 += [vl[i] >= 0] + ceil_div(t, vl[i] * (BPS - 100), BPS) \
        + [mo[i] == If(t - UL[i] - ALLOW // 2 > 1, t - UL[i] - ALLOW // 2, 1)]
legs73 += [R >= Sum(mo)]
cons73 = [V >= 0, V < 2**200, x == cap] + floor_div(term, V * (BPS - 100), BPS) \
    + [Vn == If(term - U2 - ALLOW > 0, term - U2 - ALLOW, 0)] + floor_div(cap, Vn * BPS, BPS) + legs73
# MATH-ST-73 verifies: SPEC-LIQ-020, SPEC-LIQ-018, Q-255
check("MATH-ST-73",
      "with eps in Vnet, legs meeting their minimums leave R short of x by at most U + 2 base units (the unwind "
      "truncation); that case reverts with DeleverageShortfall and draws nothing",
      cons73 + [x - R > U2 + 2],
      "PROVED")
maximize("MATH-ST-73", "largest x - R for a conversion that meets its leg minimums (18-decimal debt units)", cons73, x - R)

# ---------- ST-123: the same with a premium strictly below the cap, and the reading without eps ----------
for mfv, pbps in ((10, 9), (10, 5), (100, 99)):
    cons123 = [V >= 0, V < 2**200, x >= 0, x <= cap] + floor_div(term, V * (BPS - 100), BPS) \
        + [Vn == If(term - U2 - ALLOW > 0, term - U2 - ALLOW, 0)] + floor_div(cap, Vn * BPS, BPS + mfv) \
        + ceil_div(phi, x * pbps, BPS) + legs73
    # MATH-ST-123 verifies: SPEC-LIQ-020, SPEC-LIQ-018, REQ-SWAP-106, INV-089
    check("MATH-ST-123",
          f"maxFlashFeeBps {mfv}, premium {pbps} bps (rounded up): legs meeting their minimums cover x + phi up to "
          f"U + 2 base units",
          cons123 + [x + phi - R > U2 + 2],
          "PROVED")
cons123w = [V >= 0, V < 2**200, x == cap] + floor_div(term, V * (BPS - 100), BPS) \
    + [Vn == If(term - U2 > 0, term - U2, 0)] + floor_div(cap, Vn * BPS, BPS + 10) \
    + ceil_div(phi, x * 9, BPS) + legs73
# MATH-ST-123 verifies: SPEC-LIQ-020, SPEC-LIQ-018
check("MATH-ST-123",
      "wrong reading (Vnet without eps): legs meeting their minimums can leave R short of x + phi by more than "
      "half the allowance at a 9 bps premium (counterexample expected)",
      cons123w + [x + phi - R > ALLOW // 2],
      "COUNTEREXAMPLE", show=[V, x, phi, R])

# ---------- ST-74: health factor does not fall when x HF >= V CF ----------
C, Dt, CF, Vr, xr = Reals("C Dt CF V x")
hf_pre = [C > 0, Dt > 0, CF > 0, CF < 1, Vr > 0, Vr < C, xr > 0, xr < Dt]
# MATH-ST-74 verifies: SPEC-LIQ-020, SPEC-PROXY-009
check("MATH-ST-74",
      "while debt remains, (C - V) CF / (Dt - x) >= C CF / Dt  <=>  x C CF / Dt >= V CF",
      hf_pre + [Not(((C - Vr) * CF * Dt >= C * CF * (Dt - xr)) == (xr * C * CF / Dt >= Vr * CF))],
      "PROVED")

# ---------- ST-75: the stated health-factor threshold ----------
# SPEC-LIQ-020: the sizing meets x HF >= V CF "for every account with HF >= CF (1e4 + maxFlashFeeBps) / (1e4 - s)".
# Exact integer sizing at s = 100, maxFlashFeeBps = 0, CF = 0.312, HF at that threshold (0.31515...), V in 18-decimal debt units.
HFn, HFd = 3_120 * BPS, BPS * (BPS - 100)          # HF = CF / (1 - s) = 31,200,000 / 99,000,000
CFn = 3_120
cons75 = [V >= E18, V < 2**200, x == cap] + floor_div(term, V * (BPS - 100), BPS) \
    + [Vn == If(term - U2 - ALLOW > 0, term - U2 - ALLOW, 0)] + floor_div(cap, Vn * BPS, BPS)
# x HF >= V CF  <=>  x HFn / HFd >= V CFn / 1e4  <=>  x HFn 1e4 >= V CFn HFd
# MATH-ST-75 verifies: SPEC-LIQ-020
check("MATH-ST-75",
      "deliberate wrong reading (the threshold before the fix): at HF = CF (1e4 + maxFlashFeeBps) / (1e4 - s) exactly "
      "the sizing can miss x HF >= V CF by the U and rounding terms; SPEC-LIQ-020 states the corrected threshold below",
      cons75 + [x * HFn * BPS < V * CFn * HFd],
      "COUNTEREXAMPLE", show=[V, term, Vn, x])
# Corrected threshold: HF >= CF (1e4 + maxFlashFeeBps) V / ((1e4 - s) V - E), E = 1e4 (U + eps + 2) + maxFlashFeeBps,
# for (1e4 - s) V > E. Then x HF >= V CF  <=>  x (1e4 + maxFlashFeeBps) >= (1e4 - s) V - E.
hs = BPS - 100
for mfv in (0, 9, 100):
    E = BPS * (U2 + ALLOW + 2) + mfv
    cons75b = [V >= 1, V < 2**200, hs * V > E] + floor_div(term, V * hs, BPS) \
        + [Vn == If(term - U2 - ALLOW > 0, term - U2 - ALLOW, 0)] + floor_div(cap, Vn * BPS, BPS + mfv) + [x == cap]
    # MATH-ST-75 verifies: SPEC-LIQ-020
    check("MATH-ST-75",
          f"maxFlashFeeBps {mfv}: with HF >= CF (1e4 + maxFlashFeeBps) V / ((1e4 - s) V - 1e4 (U + eps + 2) - maxFlashFeeBps) "
          f"the sizing meets x HF >= V CF",
          cons75b + [x * (BPS + mfv) < hs * V - E],
          "PROVED")

done()
