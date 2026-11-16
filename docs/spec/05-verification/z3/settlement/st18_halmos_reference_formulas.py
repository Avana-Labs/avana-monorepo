# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-140..146: the reference formulas of the SettlementMath Halmos checks (SPEC-LIQ-005, -009, -014, -018).

The Halmos checks below assert that SettlementMath returns a reference formula built from the same terms the code
computes, so no Halmos query needs the semantics of a product of two symbolic values, of a division or of mulmod
(the earlier checks, which asserted the inequalities directly, ran out of a 5-hour budget). These scripts prove the
inequalities of the earlier checks for those formulas, in exact integers, and show that every uint256 operation of a
formula equals its exact integer value on the checks' bounds.

EVM semantics: MUL(x, y) = x*y mod 2^256, DIV(x, d) = floor(x / d), MULMOD(x, y, n) = (x*y) mod n with no wrap.

  recovery floor  check_PROP_018_minRecoveryRoundingFormula, check_PROP_048_floorWithRoundingTermsFormula
                  (V <= 1e26, s <= 1e4, any U, eps):
                    P      = V * (1e4 - s)
                    gross  = Math.ceilDiv(P, 1e4) = toUint(P > 0) * ((P - 1) / 1e4 + 1)   (OpenZeppelin 5.1.0,
                             unchecked: P - 1 wraps only at P = 0, where the factor toUint(P > 0) is 0)
                    minRec = subFloor(gross, U, eps), subFloor(a, b, c) = 0 if a <= b, else a - b - c if a - b > c,
                             else 0
  fee             check_PROP_069_feeMonotoneInValueFormula (V, R', D < 2^128, share <= 1e4):
                    G = max(0, V - D), S = max(0, R' - D), A = min(G * share / 1e4, S)
  unit and leg    check_PROP_018_unitAndPendingValuesUnit, check_PROP_018_unitAndPendingValuesLeg (6-decimal token,
  values          18-decimal debt asset at $1, a < 2^64, 1 <= p < 2^64):
                    Y  = p * 1e18, u = Y / 1e14 + toUint(mulmod(1, Y, 1e14) > 0)
                    lv = (a * Y) / 1e14, pv = (a * Y) / 1e14 + toUint(mulmod(a, Y, 1e14) > 0)
                  The checks assume mulmod(a, Y, 2^256 - 1) = a * Y (a = 1 for the unit value); MATH-ST-145 and
                  MATH-ST-146 show a * Y < 2^256 - 1, so that holds on the whole domain and excludes no input.
"""
from z3 import Ints, If, Or
from _common import check, floor_div, done, BPS

U256 = 2**256
MAX = U256 - 1


def sub_floor(a, b, c):
    """SettlementMath._subFloor(a, b, c) = max(0, a - b - c), in its own branch order."""
    return If(a <= b, 0, If(a - b > c, a - b - c, 0))


# ---------- recovery floor ----------
v, s, P, q, U, eps, R = Ints("V s P q U eps R")
gross = If(P > 0, q + 1, 0)                       # Math.ceilDiv(P, 1e4)
ceil_model = [P >= 0, P < U256] + floor_div(q, P - 1, BPS)
minRec = sub_floor(gross, U, eps)

# MATH-ST-140 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
check("MATH-ST-140",
      "P = V (1e4 - s) is at most 1e30 for V <= 1e26 and s <= 1e4, so the checked product never reverts and "
      "P + 1e4, gross * 1e4 and every uint256 term of the floor stay below 2^256",
      [v >= 0, v <= 10**26, s >= 0, s <= BPS, P == v * (BPS - s), Or(P < 0, P > 10**30)],
      "PROVED")

# MATH-ST-141 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
check("MATH-ST-141",
      "Math.ceilDiv(P, 1e4) = ceil(P / 1e4) for every uint256 P: gross * 1e4 >= P and gross * 1e4 < P + 1e4, "
      "(P - 1) / 1e4 + 1 does not wrap, and subFloor(gross, 0, 0) = gross (the recoveryFloor(V, s, 0, 0) term)",
      ceil_model + [Or(gross * BPS < P, gross * BPS >= P + BPS, q + 1 >= U256, sub_floor(gross, 0, 0) != gross)],
      "PROVED")

# MATH-ST-141 verifies: SPEC-LIQ-005, Q-198
check("MATH-ST-141",
      "wrong reading: the slippage term rounded down falls below the exact net value (counterexample expected)",
      [P >= 0, P <= 10**30] + floor_div(q, P, BPS) + [q * BPS < P],
      "COUNTEREXAMPLE", show=[P, q])

# MATH-ST-142 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
check("MATH-ST-142",
      "minRec = subFloor(gross, U, eps) has 0 <= minRec <= gross and minRec + U + eps >= gross, for every U, eps >= 0",
      ceil_model + [U >= 0, eps >= 0, Or(minRec < 0, minRec > gross, minRec + U + eps < gross)],
      "PROVED")

# MATH-ST-143 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
check("MATH-ST-143",
      "with U >= 1 and eps >= 1: minRec * 1e4 <= P (the floor never asks for more than the net oracle value), and "
      "every R with R * 1e4 + U * 1e4 >= P (an unwind losing at most U against it) has R >= minRec",
      ceil_model + [U >= 1, eps >= 1, R >= 0, R * BPS + U * BPS >= P, Or(minRec * BPS > P, R < minRec)],
      "PROVED")

# ---------- Avana fee ----------
v1, v2, rp, d, sh, f1, f2 = Ints("V1 V2 Rp D share f1 f2")
in_range = [v1 >= 0, v1 <= v2, v2 < 2**128, rp >= 0, rp < 2**128, d >= 0, d < 2**128, sh >= 0, sh <= BPS]
g1 = If(v1 > d, v1 - d, 0)
g2 = If(v2 > d, v2 - d, 0)
S = If(rp > d, rp - d, 0)
fee = floor_div(f1, g1 * sh, BPS) + floor_div(f2, g2 * sh, BPS)
A1 = If(f1 < S, f1, S)
A2 = If(f2 < S, f2, S)

# MATH-ST-144 verifies: SPEC-LIQ-009, INV-036, INV-086, Q-256
check("MATH-ST-144",
      "G * share < 2^256 for V, D < 2^128 and share <= 1e4, so the uint256 fee term is the exact integer",
      in_range + [g2 * sh >= U256],
      "PROVED")

# MATH-ST-144 verifies: SPEC-LIQ-009, INV-036, INV-086, Q-256
check("MATH-ST-144",
      "A = min(floor(max(0, V - D) * share / 1e4), max(0, R' - D)) is non-decreasing in V for every share <= 1e4",
      in_range + fee + [A1 > A2],
      "PROVED")

# ---------- unit, leg and pending values (6-decimal token, 18-decimal debt asset at $1) ----------
a, p, Y, uq, N, lq = Ints("a p Y uq N lq")
u = uq + If(Y - uq * 10**14 > 0, 1, 0)            # mulmod(1, Y, 1e14) = Y - floor(Y / 1e14) * 1e14

# MATH-ST-145 verifies: SPEC-LIQ-005, SPEC-LIQ-018
check("MATH-ST-145",
      "unit value, 1 <= p < 2^64: Y = p * 1e18 < 2^256 - 1, so MUL(1, Y) = MULMOD(1, Y, 2^256 - 1) = Y and the "
      "check's assumption excludes no price; u = Y / 1e14 + [Y mod 1e14 > 0] has u >= 1, u * 1e8 >= p * 1e12 and "
      "(u - 1) * 1e8 < p * 1e12",
      [p >= 1, p < 2**64, Y == p * 10**18] + floor_div(uq, Y, 10**14)
      + [Or(Y >= MAX, u < 1, u * 10**8 < p * 10**12, (u - 1) * 10**8 >= p * 10**12)],
      "PROVED")

# MATH-ST-146 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
check("MATH-ST-146",
      "leg values, a < 2^64, 1 <= p < 2^64: a * p * 1e18 < 2^256 - 1, so MUL(a, Y) = MULMOD(a, Y, 2^256 - 1) = a * Y "
      "and the check's assumption excludes no input",
      [a >= 0, a < 2**64, p >= 1, p < 2**64, N == a * p, N * 10**18 >= MAX],
      "PROVED")

prod = N * 10**18                                 # a * Y, exact by the check above
lv = lq
pv = lq + If(prod - lq * 10**14 > 0, 1, 0)        # mulmod(a, Y, 1e14) = a * Y mod 1e14
# MATH-ST-146 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
check("MATH-ST-146",
      "lv = a Y / 1e14 and pv = lv + [a Y mod 1e14 > 0], for every N = a p >= 0: lv * 1e8 <= a p 1e12 < (lv + 1) 1e8 "
      "(the floor), pv * 1e8 >= a p 1e12 (the ceiling) and pv <= lv + 1",
      [N >= 0] + floor_div(lq, prod, 10**14)
      + [Or(lv * 10**8 > N * 10**12, (lv + 1) * 10**8 <= N * 10**12, pv * 10**8 < N * 10**12, pv > lv + 1)],
      "PROVED")

done()
