# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-01..04: where the recovery floor is measured and what it protects (SPEC-LIQ-005, -006, -009, -019).

All amounts are base units of the debt asset T, unbounded non-negative integers (Q-333). Order inside LPVaultSwap:
  start balance        b_s = K + F                K caller funding Kf; F any other T held at the start (0 in a
                                                  liquidation, which takes no flash loan, Q-404)
  debt leg             pulls G                    G = D, the debt asset Aave pulls (no buy leg)
  leftover             + g'                       Kf - D Aave did not pull; outside the window (SPEC-LIQ-006,
                                                  SPEC-LIQ-017); never swapped
  window opens         b_0                        immediately before burnSeized
  burn + release +     b_1 = b_0 + Rt + X         Rt = T produced by the seized collateral itself
  route calls                                     X  = any other T landing inside the window
  window closes        R = b_1 - b_0              SPEC-LIQ-006
  shortfall top-up     shortfall = max(0, minRec - R), <= maxShortfall, pulled from the caller
                       after the window; R' = R + shortfall (SPEC-LIQ-019)
  floor                R' >= minRec                (RecoveryBelowFloor otherwise)
Avana fee (SPEC-LIQ-009): A = min(floor(max(0, V - D) * feeShare / 1e4), S), S = max(0, R' - D) (SPEC-LIQ-008); the
  models keep a term phiD >= 0, which is 0 in a liquidation (SPEC-LIQ-007). The models keep two names for the debt term, Gcov (fee side) and
  Gnet (surplus side) with Gnet >= Gcov; the current design is the instance Gcov = Gnet = D.
"""
from z3 import Ints, And, Or, Not, If
from _common import check, floor_div, done

K, F, G, gb, Rt, X, minG, maxSF, sf = Ints("K F G gprime Rt X minGho maxShortfallGho shortfall")
base = [K >= 0, F >= 0, G > 0, gb >= 0, Rt >= 0, X >= 0, minG >= 0, maxSF >= 0,
        K + F >= G]                                  # the debt leg is funded, else the call reverts
b0 = K + F - G + gb
b1 = b0 + Rt + X
R = b1 - b0
topup = [sf == If(minG > R, minG - R, 0), sf <= maxSF]   # RecoveryBelowFloor if sf > maxShortfall
Rp = R + sf

# MATH-ST-01 verifies: SPEC-LIQ-005, SPEC-LIQ-006, SPEC-LIQ-014, SPEC-LIQ-019, LIQ-030, Q-085, Q-124, Q-148
check("MATH-ST-01",
      "window measurement: with nothing else landing in the window (X = 0) and no top-up allowed, "
      "passing the floor means the collateral itself returned >= minRec, for every K, F, G, g'",
      base + topup + [X == 0, maxSF == 0, Rp >= minG, Rt < minG],
      "PROVED")

# MATH-ST-02 verifies: SPEC-LIQ-006, Q-085
check("MATH-ST-02",
      "wrong reading: floor tested on the whole balance before repayment lets a poor recovery pass "
      "(counterexample expected)",
      base + [X == 0, b1 >= minG, Rt < minG, G == 10**24, minG == 1_020_000 * 10**18, 2 * Rt <= G],
      "COUNTEREXAMPLE", show=[K, F, G, Rt, minG])

# MATH-ST-03 verifies: SPEC-LIQ-006, Q-085
check("MATH-ST-03",
      "wrong reading: floor tested on the balance net of flash principal still counts caller funds K "
      "(counterexample expected)",
      base + [X == 0, gb == 0, b1 - F + G >= minG, Rt < minG, G == 10**24,
              minG == 1_020_000 * 10**18, 2 * Rt <= G],
      "COUNTEREXAMPLE", show=[K, F, G, Rt, minG])

# MATH-ST-04: Avana's fee is set by the oracle value, not by the conversion. Two runs of the same
# seizure (same V, Gcov, Gnet, phiD) with recoveries R1 <= R2 (a self-sandwich, a bad route or debt asset
# injected into the window) pay the same fee whenever the realized surplus covers it, and a
# lower recovery never raises it.
V, Gcov, Gnet, phiD, phi, R1, R2, A1, A2, Au = Ints("V Gcov Gnet phiD avanaFeeShareBps R1 R2 A1 A2 Au")
fee_base = [V >= 0, Gcov >= 0, Gnet >= Gcov, phiD >= 0, phi >= 0, phi <= 5_000, R1 >= 0, R2 >= R1]
gain = If(V > Gcov + phiD, V - Gcov - phiD, 0)
S1 = If(R1 > Gnet + phiD, R1 - Gnet - phiD, 0)
S2 = If(R2 > Gnet + phiD, R2 - Gnet - phiD, 0)
fee = floor_div(Au, gain * phi, 10_000) + [A1 == If(Au < S1, Au, S1), A2 == If(Au < S2, Au, S2)]
# MATH-ST-04 verifies: SPEC-LIQ-009, SPEC-LIQ-006, SPEC-LIQ-008, Q-256, Q-097
check("MATH-ST-04",
      "fee from oracle value: A(R1) <= A(R2) for R1 <= R2, and A(R1) == A(R2) whenever S(R1) >= the uncapped fee",
      fee_base + fee + [Or(A1 > A2, And(S1 >= Au, A1 != A2))],
      "PROVED")

done()
