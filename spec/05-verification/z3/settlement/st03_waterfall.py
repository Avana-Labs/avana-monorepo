# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-14..20, MATH-ST-51..55, MATH-ST-96..97, MATH-ST-121..122: settlement waterfall in the debt asset
(SPEC-LIQ-007..010, SPEC-LIQ-017, SPEC-LIQ-019, SPEC-LIQ-022, SPEC-SET-001). No settlement budget exists and
LPVaultSwap takes no flash loan in a liquidation (Q-404): the caller funds the repayment, and its top-up closes only a
floor gap.

Solidity 0.8 checked uint256 arithmetic, modelled exactly with range-checked Ints. All amounts are base units
of the debt asset T (any decimals), inputs below 2^128. One liquidation in LPVaultSwap:

  bal  = Kf                             caller funding measured by balance delta, 0 < Kf <= X (SPEC-LIQ-010)
  bal -= D                              Aave pulls D <= Kf (it was approved for Kf); the leftover stays in bal
  bal += R                              recovery window (SPEC-LIQ-006)
  fl   = max(0, minRec - R);  R_f = R + fl = max(R, minRec)      floor part of the top-up
  S    = max(0, R_f - D)                                         SPEC-LIQ-008
  G    = max(0, V - D)                                           oracle gain
  A    = min(floor(G * share / 1e4), S)                          SPEC-LIQ-009
  kr   = min(S, G) - A ;  B = S - A - kr                         SPEC-LIQ-022
  gap  = max(0, D + A + B - Kf - R)                              SPEC-SET-001
  bal += shortfall                      shortfall = max(fl, gap); fl <= maxShortfall (else RecoveryBelowFloor),
                                        gap <= maxShortfall (else InsufficientProceeds, defensive)   SPEC-LIQ-019
  R'   = R + shortfall
  keeperOut = (Kf + R') - (D + A + B)                            SPEC-LIQ-010 (InsufficientProceeds if < 0)
  bal -= A; bal -= B; bal -= keeperOut -> 0
"""
from z3 import Ints, If, And, Or, Not
from _common import check, floor_div, done

U256 = 2**256
LIM = 2**128
(K, X, D, R, V, share, A_u, A, sl, minR, maxSF) = Ints(
    "Kf X D R V avanaFeeShareBps A_uncapped A s minRec maxShortfall")


def in_range(x):
    return And(x >= 0, x < U256)


def mn(a, b):
    return If(a < b, a, b)


def mx(a, b):
    return If(a > b, a, b)


def pos(a):
    return If(a > 0, a, 0)


inputs = [And(x >= 0, x < LIM) for x in (K, X, D, R, V, minR, maxSF)] + \
    [share >= 0, share <= 5_000, sl >= 0, sl <= 9_999, K >= 1, K <= X, D <= K]
pre = []
bal = K
bal = bal - D;              pre.append(in_range(bal))
bal = bal + R;              pre.append(in_range(bal))
fl = pos(minR - R)
Rf = R + fl
S = pos(Rf - D)
G = pos(V - D)
feeA = floor_div(A_u, G * share, 10_000) + [A == mn(A_u, S)]
kr = mn(S, G) - A
B = S - A - kr
gap = pos(D + A + B - K - R)
sf = mx(fl, gap)
Rp = R + sf
bal = bal + sf;             pre.append(in_range(bal))
keeperOut = (K + Rp) - (D + A + B)
bal = bal - A;              pre.append(in_range(bal))
bal = bal - B;              pre.append(in_range(bal))
pre.append(in_range(G * share))
end_bal = bal - keeperOut

reach = inputs + [fl <= maxSF] + feeA

# MATH-ST-14 verifies: SPEC-LIQ-009, SPEC-LIQ-010, SPEC-SET-001, LIQ-031, Q-097, Q-117, Q-404
check("MATH-ST-14",
      "once 0 < Kf <= X, D <= Kf and the floor gap is within maxShortfall, no checked operation reverts (fee and "
      "borrower transfers included)",
      reach + [Not(And(*pre))],
      "PROVED")

# MATH-ST-121 verifies: SPEC-SET-001, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-007, REQ-SWAP-029, REQ-SWAP-061, REQ-SWAP-062, INV-034, Q-397, Q-404
check("MATH-ST-121",
      "a call within its maxShortfall always settles: keeperOut >= 0 and gap <= max(0, minRec - R), so neither "
      "InsufficientProceeds check fires",
      reach + [Or(keeperOut < 0, gap > fl, gap > maxSF)],
      "PROVED")

# MATH-ST-15 verifies: SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, INV-035, LIQ-060, LIQ-069, Q-097, Q-124, Q-337, Q-404
check("MATH-ST-15",
      "debt-asset conservation: Kf + R + shortfall = D + A + B + keeperOut; LPVaultSwap ends at 0",
      reach + [Or(K + R + sf != D + A + B + keeperOut, end_bal != 0)],
      "PROVED")

# MATH-ST-16 verifies: SPEC-LIQ-008, SPEC-LIQ-009, INV-036, Q-097, Q-135
check("MATH-ST-16",
      "A <= S, and A = 0 whenever R_f <= D",
      reach + [Or(A > S, And(Rf <= D, A != 0))],
      "PROVED")

# MATH-ST-17 verifies: SPEC-LIQ-010, SPEC-SET-001, SPEC-LIQ-022, Q-127, Q-117, Q-404
check("MATH-ST-17",
      "the gap never binds beyond the floor gap: gap > minRec - R with gap > 0 is unreachable",
      reach + [gap > fl],
      "PROVED")

# MATH-ST-18 verifies: SPEC-SET-001, SPEC-LIQ-019, SPEC-LIQ-010, INV-038, Q-127, Q-117, Q-404
check("MATH-ST-18",
      "a recovery below D is the caller's: R' < D gives keeperOut = Kf - (D - R') with A = B = 0, and nothing is drawn "
      "from any other source",
      reach + [Rp < D, Or(keeperOut != K - (D - Rp), A != 0, B != 0)],
      "PROVED")

shortN = If(R < D, D - R, 0)
# MATH-ST-19 verifies: SPEC-SET-001, Q-127
check("MATH-ST-19",
      "wrong reading: a gap of D - R that ignores the caller funding Kf pulls a top-up the funding already covers "
      "(counterexample expected)",
      inputs + feeA + [shortN > 0, K + R >= D, D == 10**12, X == D, K == D, R == 999_000 * 10**6],
      "COUNTEREXAMPLE", show=[K, D, R])

A_old, A_old2, R2 = Ints("A_old A_old2 R2")
S2 = pos(mx(R2, minR) - D)
# MATH-ST-20 verifies: SPEC-LIQ-008, SPEC-LIQ-009, Q-256, Q-097
check("MATH-ST-20",
      "wrong reading: fee = floor(S * share / 1e4) falls when the caller swaps worse, though V is unchanged "
      "(counterexample expected)",
      reach + floor_div(A_old, S * share, 10_000) + floor_div(A_old2, S2 * share, 10_000)
      + [R2 < R, A_old2 < A_old, share == 2_000, X == D, K == D,
         D == 1_950 * 10**6, V == 2_047_500_000, R == 2_040_300_000, R2 == 2_027 * 10**6, minR == R2],
      "COUNTEREXAMPLE", show=[D, V, R, R2, A_old, A_old2, A])

K2 = Ints("Kf2")[0]
S_2 = pos(Rf - D)
# MATH-ST-51 verifies: SPEC-LIQ-007, SPEC-LIQ-002, Q-135, Q-267, Q-404
check("MATH-ST-51",
      "no premium term: S, G, A, kr and B are functions of R, minRec, V and D only, so two callers funding Kf and "
      "Kf2 >= D (from their balance or a helper's loan of any size and premium) get the same split",
      reach + [K2 >= D, K2 < LIM, S_2 != S],
      "PROVED")

# MATH-ST-52 verifies: SPEC-LIQ-007, SPEC-LIQ-017, SPEC-SET-001, LIQ-041, Q-135, Q-267
check("MATH-ST-52",
      "oversized debtToCover: the leftover Kf - D returns inside keeperOut unswapped: keeperOut - (Kf - D) = R' - A - B",
      reach + [keeperOut - (K - D) != Rp - A - B],
      "PROVED")

# MATH-ST-53 verifies: SPEC-LIQ-010, SPEC-SET-001, REQ-SWAP-108, Q-333, Q-390
check("MATH-ST-53",
      "a transfer fee on the caller's funding (Kf < X) lowers keeperOut by exactly the fee, and A and B not at all",
      reach + [K2 >= D, K2 <= X, K2 < K,
               (K2 + Rp) - (D + A + B) != keeperOut - (K - K2)],
      "PROVED")

# MATH-ST-54 verifies: SPEC-SET-001, SPEC-LIQ-016, Q-261
check("MATH-ST-54",
      "s = 0: the loss is still the caller's; a call that settles has keeperOut >= 0 and Kf + R' >= D, whatever s",
      reach + [sl == 0, Or(keeperOut < 0, K + Rp < D)],
      "PROVED")

# MATH-ST-55 verifies: SPEC-LIQ-019, SPEC-LIQ-005, Q-251
check("MATH-ST-55",
      "top-up: a call that settles has R' >= minRec, and the caller pays exactly max(0, minRec - R) <= maxShortfall",
      reach + [Or(Rp < minR, sf > maxSF, sf < 0, sf != fl)],
      "PROVED")

# MATH-ST-96 verifies: SPEC-LIQ-022, SPEC-LIQ-010, INV-035, Q-337
check("MATH-ST-96",
      "payout split: A + kr + B = S, 0 <= kr <= G - A, B = max(0, S - G), and keeperOut = Kf + kr whenever R' >= D",
      reach + [Or(A + kr + B != S, kr < 0, kr > G - A, B != pos(S - G), And(Rp >= D, keeperOut != K + kr))],
      "PROVED")

# MATH-ST-97 verifies: SPEC-LIQ-022, SPEC-LIQ-019, Q-337
check("MATH-ST-97",
      "the caller's top-up never reaches the borrower: B = 0 whenever the floor part of the top-up is positive "
      "(given minRec <= V), and B <= max(0, R - V) always",
      reach + [minR <= V, Or(And(fl > 0, B != 0), B > pos(R - V))],
      "PROVED")

# ---- MATH-ST-122: the earlier rule reduces to this one, and the reading the funding rule replaces ----
phi, tau, Kr = Ints("phi tau Kr")
gap_sm = pos(D + phi + tau + A + B - Kr - R)
# MATH-ST-122 verifies: SPEC-SET-001, SPEC-LIQ-019, Q-397, Q-404
check("MATH-ST-122",
      "the SettlementMath gap max(0, D + phi + tau + A + B - Kr - R) with phi = tau = 0 and Kr = Kf is the gap of "
      "SPEC-SET-001, so SettlementMath serves the liquidation path with those terms at 0",
      reach + [phi == 0, tau == 0, Kr == K, gap_sm != gap],
      "PROVED")
ko_ext = (0 + Rp) - (D + A + B)
# MATH-ST-122 verifies: SPEC-SET-001, SPEC-LIQ-010, REQ-SWAP-011, Q-404
check("MATH-ST-122",
      "wrong reading: a repayment funded from outside the measured Kf (Kf = 0, as if a loan were not routed through "
      "the caller's funding) leaves keeperOut < 0 at a recovery below D (counterexample expected): every unit Aave "
      "pulls must come from the measured caller funding",
      [D == 3_000_000, R == 2_950_000, minR == 2_118_498, V == 3_150_000, share == 2_000, maxSF == 0] + feeA
      + [ko_ext < 0],
      "COUNTEREXAMPLE", show=[D, R])

done()
