# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-21..26, MATH-ST-56..60, MATH-ST-99, MATH-ST-100: the rounding loss is the caller's (SPEC-SET-001, SPEC-LIQ-019).

Avana has no settlement budget, and LPVaultSwap takes no flash loan in a liquidation (Q-404). The caller funds the
repayment: LPVaultSwap pulls X = debtToCover, measures Kf with 0 < Kf <= X and passes Kf to liquidationCall, so Aave
pulls D <= Kf. The floor of SPEC-LIQ-005 leaves a rounding rest of at most one vault unit, a few wei, U and
floorRoundingAllowance between the collateral's recovery and D; that rest lowers the caller's payout:
  R_f       = max(R, minRec);  S = max(0, R_f - D), G = max(0, V - D), A, kr, B on R_f      SPEC-LIQ-008/009/022
  gap       = max(0, D + A + B - Kf - R)                                                    SPEC-SET-001
  shortfall = max(0, minRec - R, gap); RecoveryBelowFloor if minRec - R > maxShortfall,
              InsufficientProceeds (defensive) if gap > maxShortfall; R' = R + shortfall     SPEC-LIQ-019
  keeperOut = (Kf + R') - (D + A + B), checked (defensive)                                  SPEC-LIQ-010
A helper's loan F and premium phi are repaid by the helper from keeperOut plus a bounded top-up (REQ-HELPER-007);
they appear only in ST-23 and ST-60. Amounts in 18-decimal debt units unless stated.
"""
from z3 import Int, Ints, If, And, Or, Not
from _common import check, maximize, computed, floor_div, ceil_div, done, BPS, RAY

E18 = 10**18
PG = 10**8
ALLOW = E18                     # floorRoundingAllowance (1 unit of an 18-decimal debt asset)
U2 = 2 * 10**12                 # U for two 6-decimal $1 legs


def s_final(bnet, allow=BPS):
    """SPEC-LIQ-003: no premium term."""
    num = bnet * BPS - BPS * BPS
    return 0 if num <= 0 else min(allow, (BPS * num) // (bnet * BPS))


pos = lambda x: If(x > 0, x, 0)
mx = lambda a, b: If(a > b, a, b)
MARKETS = {"USDC/USDT d6 $2": (6, 2 * 10**8), "USDC/USDT d18 $2.10": (18, 210_000_000)}

D, c, V, term, minG, R, K, loss = Ints("D c V term minRec R Kf loss")

# ---------- ST-21: the honest loss is a rounding rest ----------
for name, (dv, pc) in MARKETS.items():
    unit = -(-(pc * E18) // (10**dv * PG))
    for b in (10_200, 10_500):
        s = s_final(b, 100)
        cons = [D >= 1, D <= 10**26, K >= D, R >= 0] \
            + floor_div(c, D * PG * 10**dv * b, E18 * pc * BPS) \
            + floor_div(V, c * pc * E18, 10**dv * PG) + ceil_div(term, V * (BPS - s), BPS) \
            + [minG == pos(term - U2 - ALLOW), R >= minG, loss == pos(D - R)]
        # MATH-ST-21 verifies: SPEC-SET-001, SPEC-LIQ-005, SPEC-LIQ-010, SPEC-LIQ-019, INV-038, Q-127, Q-198, Q-397, Q-404
        check("MATH-ST-21",
              f"[{name}] bonus {b}, s={s}: a recovery at or above the floor leaves the caller a loss D - R of at most "
              f"1 unit ({unit} wei) + 2 + U + allowance",
              cons + [loss > unit + 2 + U2 + ALLOW],
              "PROVED")

# ---------- ST-22: subtractive bound, wrong reading ----------
dv, pc = MARKETS["USDC/USDT d6 $2"]
b = 10_250
cons22 = [D >= 1, D <= 10**24, K == D] + floor_div(c, D * PG * 10**dv * b, E18 * pc * BPS) \
    + floor_div(V, c * pc * E18, 10**dv * PG) + ceil_div(term, V * (BPS - 250), BPS) \
    + [minG == term - U2 - ALLOW, R == minG, loss == pos(D - R)]
# MATH-ST-22 verifies: SPEC-SET-001, SPEC-LIQ-003, Q-127
check("MATH-ST-22",
      "wrong reading s = bonus - 1e4 (250 bps at bonus 10,250): a recovery at the floor leaves the caller a loss "
      "above 100 units, no longer a rounding rest (counterexample expected)",
      cons22 + [loss > 100 * E18],
      "COUNTEREXAMPLE", show=[D, minG, loss])
maximize("MATH-ST-22", "wrong reading s = 250 bps, D = 1M, R = minRec: loss (18-decimal debt units)",
         cons22 + [D == 10**24], loss)

# ---------- ST-23: a helper's oversized flash loan with a fee ----------
F, phi, phiD, ko0 = Ints("F phi phiD keeperOut0")
f = 9
cons23 = [D == 10_000 * E18, K == F, F >= D, F <= 10**26, R >= D] \
    + floor_div(phi, F * f + 5_000, BPS) + floor_div(phiD, D * f + 5_000, BPS)
# MATH-ST-23 verifies: SPEC-LIQ-007, SPEC-LIQ-017, SPEC-SET-001, REQ-HELPER-007, Q-135, Q-267, Q-404
check("MATH-ST-23",
      "flash fee 9 bps through the helper (Kf = F >= D, R >= D, A = B = 0 for brevity): keeperOut = F + R - D does "
      "not contain phi, and the helper's net payout keeperOut - F - phi falls by exactly phi - phiD against a loan "
      "of D: the premium on the unused part is the caller's alone",
      cons23 + [ko0 == K + R - D, ko0 - F - phi != (R - D - phiD) - (phi - phiD)],
      "PROVED")
# MATH-ST-23 verifies: SPEC-LIQ-007, SPEC-SET-001, Q-135, Q-404
check("MATH-ST-23",
      "LPVaultSwap's formulas do not grow with F: the gap max(0, D + A + B - Kf - R) is 0 for every Kf = F >= D "
      "(counterexample search: a positive gap)",
      cons23 + [loss == pos(D - K - R), loss > 0],
      "PROVED")

# ---------- shared settlement model (integers) ----------
X, minR, mS, sf, S, A, Bb, G, fee, Au, ko, kr, gap = Ints(
    "X minRec maxShortfall shortfall S A B G feeShare Araw keeperOut kr gap")
Rp = R + sf
Rf = mx(R, minR)
settle = [And(v >= 0, v < 2**128) for v in (X, K, R, D, V, minR, mS)] \
    + [K >= 1, K <= X, D <= K, minR <= V, fee >= 0, fee <= BPS,
       S == pos(Rf - D), G == pos(V - D)] + floor_div(Au, G * fee, BPS) \
    + [A == If(Au < S, Au, S), kr == If(S < G, S, G) - A, Bb == S - A - kr,
       gap == pos(D + A + Bb - K - R),
       sf == mx(pos(minR - R), gap),
       minR - R <= mS,                                      # else RecoveryBelowFloor
       ko == (K + Rp) - (D + A + Bb)]

# ---------- ST-24: conservation, keeperOut >= 0, the gap never binds ----------
# MATH-ST-24 verifies: SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, INV-035, INV-037, Q-397, Q-404
check("MATH-ST-24",
      "with Kf >= D: Kf + R + shortfall = D + A + B + keeperOut exactly, keeperOut >= 0, and gap <= max(0, minRec - R), "
      "so shortfall = max(0, minRec - R) and InsufficientProceeds never fires: only the caller and the collateral fund "
      "the settlement",
      settle + [Or(K + R + sf != D + A + Bb + ko, ko < 0, gap > pos(minR - R), sf != pos(minR - R), gap > mS)],
      "PROVED")

# ---------- ST-25: without Kf >= D the gap could bind ----------
# MATH-ST-25 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-017, Q-397, Q-404
check("MATH-ST-25",
      "wrong reading: dropping D <= Kf (a funding Aave did not pull from) lets the gap exceed the floor gap "
      "(counterexample expected): the bound rests on Aave pulling D out of the caller's funding",
      [v >= 0 for v in (K, R, D, minR, V)] + [K < D, minR <= R, S == 0, A == 0, Bb == 0,
                                              gap == pos(D + A + Bb - K - R), gap > pos(minR - R)],
      "COUNTEREXAMPLE", show=[K, D, R, gap])

# ---------- ST-26: the payout identities ----------
# MATH-ST-26 verifies: SPEC-LIQ-010, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-022, INV-035, Q-397, Q-404
check("MATH-ST-26",
      "keeperOut = Kf + kr whenever R' >= D, and keeperOut = Kf - (D - R') whenever R' < D; A + kr + B = S",
      settle + [Or(And(Rp >= D, ko != K + kr), And(Rp < D, ko != K - (D - Rp)), A + kr + Bb != S)],
      "PROVED")

# ---------- ST-56: the pulled shortfall meets the floor and is the least such top-up ----------
# MATH-ST-56 verifies: SPEC-LIQ-019, SPEC-SET-001, SPEC-LIQ-005
check("MATH-ST-56",
      "shortfall = max(0, minRec - R) gives R' >= minRec and Kf + R' >= D + A + B, and is the least top-up that does "
      "both",
      settle + [Or(Rp < minR, K + Rp < D + A + Bb,
                   And(sf > 0, R + sf - 1 >= minR))],
      "PROVED")

# ---------- ST-57: the top-up never reaches the borrower ----------
# MATH-ST-57 verifies: SPEC-LIQ-019, SPEC-LIQ-022, SPEC-SET-001, LIQ-031
check("MATH-ST-57",
      "the top-up never reaches the borrower: B = 0 whenever the floor term is positive, and B <= max(0, R - V), "
      "given minRec <= V",
      settle + [Or(And(minR > R, Bb != 0), Bb > pos(R - V))],
      "PROVED")

# ---------- ST-58: non-GHO debt term ----------
# Aave prices the seizure from debtRay but pulls D rounded up: up to 2 + ceil(idx / RAY) base units more.
dv, pc = MARKETS["USDC/USDT d18 $2.10"]
unit = -(-(pc * E18) // (10**dv * PG))
idx = 3 * RAY // 2 + 7
extra = 2 + -(-idx // RAY)                 # 4 base units
dd_, PD = 6, 10**8
debtRay, Gd = Ints("debtRay Gdebt")
term_debt = -(-(extra * PD * E18) // (10**dd_ * PG))
for bnet in (10_200, 10_500):
    s = s_final(bnet, 100)
    cons58 = [D >= 1, D <= 10**14, debtRay <= D * RAY, debtRay >= (D - extra) * RAY, debtRay >= 0] \
        + floor_div(c, debtRay * PD * 10**dv * bnet, 10**dd_ * pc * BPS * RAY) \
        + floor_div(V, c * pc * E18, 10**dv * PG) + ceil_div(term, V * (BPS - s), BPS) \
        + [minG == pos(term - U2 - ALLOW)] + ceil_div(Gd, D * PD * E18, 10**dd_ * PG) \
        + [R == minG, loss == pos(Gd - R)]
    # MATH-ST-58 verifies: SPEC-SET-001, SPEC-LIQ-019, INV-038, Q-236, Q-267
    check("MATH-ST-58",
          f"USDC debt, bonus {bnet} (s={s}), idx 1.5 RAY + 7: the caller's loss at the floor <= 1 unit + 2 + U + "
          f"allowance + {extra} debt units ({term_debt} wei)",
          cons58 + [loss > unit + 2 + U2 + ALLOW + term_debt],
          "PROVED")
    maximize("MATH-ST-58", f"bonus {bnet}: largest loss at D = 999,999,999 (18-decimal debt units)",
             cons58 + [D == 999_999_999], loss)

# ---------- ST-59: no top-up is needed above the floor ----------
# MATH-ST-59 verifies: SPEC-SET-001, SPEC-LIQ-019, REQ-SWAP-005, REQ-SWAP-073
check("MATH-ST-59",
      "R >= minRec: shortfall = 0 for every maxShortfall, including 0, and the call settles",
      settle + [R >= minR, mS == 0, Or(sf != 0, ko < 0)],
      "PROVED")
# MATH-ST-59 verifies: SPEC-SET-001, SPEC-LIQ-019, Q-404
check("MATH-ST-59",
      "boundary: a caller with Kf = D, R = D - 1 above the floor and maxShortfall = 0 settles with keeperOut = Kf - 1 "
      "(counterexample search: a revert or another payout)",
      settle + [D == 3 * 10**6, K == D, R == D - 1, minR <= R, mS == 0, ko != K - 1],
      "PROVED")

# ---------- ST-60: a helper's premium is the helper's ----------
prem, topUp, payout, mT = Ints("premium topUp payout maxTopUp")
helper = settle + [F == K, prem >= 0, mT >= 0,
                   topUp == pos(F + prem - ko), topUp <= mT, payout == ko + topUp - F - prem]
# MATH-ST-60 verifies: SPEC-LIQ-007, SPEC-LIQ-010, SPEC-SET-001, REQ-HELPER-007, REQ-HELPER-008, Q-135, Q-404
check("MATH-ST-60",
      "through the helper (Kf = F): payout = max(0, keeperOut - F - premium) >= 0, and A and B are the same as for a "
      "caller funding from its own balance: the premium never reaches Avana's fee or the borrower surplus",
      helper + [Or(payout < 0, payout != pos(ko - F - prem))],
      "PROVED")

# ---------- ST-99: funding up front or by top-up gives the same net result ----------
K2, ko2, S2 = Ints("Kf2 keeperOut2 S2")
# MATH-ST-99 verifies: SPEC-SET-001, SPEC-LIQ-019, REQ-SWAP-005, Q-397
check("MATH-ST-99",
      "funding d more (Kf2 = Kf + d) raises keeperOut by exactly d: oversizing debtToCover costs the caller nothing "
      "at LPVaultSwap",
      settle + [K2 >= K, K2 < 2**128, ko2 == (K2 + Rp) - (D + A + Bb), ko2 - ko != K2 - K],
      "PROVED")

# ---------- ST-100: worked examples of 2.11 ----------
E6 = 10**6
Dx, Rx = 3 * E6, 2_950_000
gap_d = max(0, Dx + 0 + 0 - Dx - Rx)
ko_d = (Dx + Rx + 0) - (Dx + 0 + 0)
topup_d = max(0, Dx + 1_500 - ko_d)
Rr, Dr = 2_040_300_000, 1_950 * E6
gap_r = max(0, Dr + 19_500_000 - Dr - Rr)
ko_r = (Dr + Rr) - (Dr + 19_500_000)
ko_m = (2_047_500_000 + Rr) - (Dr + 19_500_000)
# MATH-ST-100 verifies: SPEC-SET-001, SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, REQ-HELPER-007, REQ-HELPER-008
computed("MATH-ST-100", "dust and regular examples (USDC, 6 decimals)", [
    ("dust gap", 0, gap_d),
    ("dust keeperOut (2.95 USDC)", 2_950_000, ko_d),
    ("dust helper top-up at 5 bps (0.0515 USDC)", 51_500, topup_d),
    ("regular gap", 0, gap_r),
    ("regular keeperOut (2,020.8 USDC)", 2_020_800_000, ko_r),
    ("regular helper payout at 5 bps (69.825 USDC)", 69_825_000, ko_r - Dr - 975_000),
    ("Lens-margin keeperOut X = 2,047.5 (2,118.3 USDC)", 2_118_300_000, ko_m),
    ("Lens-margin helper payout at 5 bps (69.77625 USDC)", 69_776_250, ko_m - 2_047_500_000 - 1_023_750),
])

done()
