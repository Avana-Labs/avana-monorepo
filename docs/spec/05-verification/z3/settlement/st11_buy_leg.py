# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-68..70, MATH-ST-115: flash source checks, the leftover debt asset and the cap above the Pool rate
(SPEC-LIQ-015, SPEC-LIQ-007, SPEC-LIQ-017, REQ-FLASH-001, REQ-FLASH-002). The file keeps its name; the buy leg it once modelled no longer exists (Q-333).

  pre-loan:  F <= avail  and  fee(F) * 1e4 <= maxFlashFeeBps * F                      SPEC-LIQ-015
  callback:  phi * 1e4 <= maxFlashFeeBps * F                                          REQ-SWAP-013
  costsBps = ceil(phi * 1e4 / F)                                                      SPEC-LIQ-002
  fee(x) = ceil(x * p / 1e4) (the source's quote of the Aave V3 premium p bps;        SPEC-LIQ-007
           V3.4 rounds half-up; the source's ceiling quote is the binding gate)
  charge(x) = floor((x * p + 5000) / 1e4) <= fee(x) (V3.4 percentMul)                SPEC-LIQ-015
  leftover = X - D stays in the balance and repays the flash loan                    SPEC-LIQ-017
  cap above the rate: m > p  and  F (m - p) >= 1e4  =>  fee(F) * 1e4 <= m F             SPEC-LIQ-015
"""
from z3 import Ints, If, And, Or, Not
from _common import check, ceil_div, half_up, maximize, computed, mul_div_ceil, done

F, avail, p, mf, phi, cost, x1, x2, f1, f2 = Ints("F avail premiumBps maxFlashFeeBps phi costsBps x1 x2 fee1 fee2")
base = [F > 0, F < 2**128, avail >= 0, p >= 0, p <= 1_000, mf >= 0, mf <= 300]

# MATH-ST-68 verifies: SPEC-LIQ-015, SPEC-LIQ-002, REQ-FLASH-002, Q-335
check("MATH-ST-68",
      "a loan that passes the pre-loan checks has F <= idle liquidity and costsBps <= maxFlashFeeBps",
      base + ceil_div(phi, F * p, 10_000) + ceil_div(cost, phi * 10_000, F)
      + [F <= avail, phi * 10_000 <= mf * F, Or(cost > mf, F > avail)],
      "PROVED")
# MATH-ST-68 verifies: SPEC-LIQ-015, REQ-SWAP-013
check("MATH-ST-68",
      "wrong reading: checking only the quote lets a premium raised before the callback exceed the cap "
      "(counterexample expected)",
      base + [F == 1_950 * 10**6, mf == 10, p == 20] + ceil_div(phi, F * p, 10_000) + [phi * 10_000 > mf * F],
      "COUNTEREXAMPLE", show=[F, phi])

# MATH-ST-69 verifies: SPEC-LIQ-007, Q-334
check("MATH-ST-69",
      "the premium fee(x) = ceil(x p / 1e4) is non-decreasing and never below the exact premium, so phiD <= phi",
      [x1 >= 0, x2 >= x1, x2 < 2**128, p >= 0, p <= 1_000]
      + ceil_div(f1, x1 * p, 10_000) + ceil_div(f2, x2 * p, 10_000)
      + [Or(f1 > f2, f1 * 10_000 < x1 * p)],
      "PROVED")

K, X, D, R, sf, A, B, ko = Ints("K X D R shortfall A B keeperOut")
# MATH-ST-70 verifies: SPEC-LIQ-017, REQ-SWAP-089, Q-333
check("MATH-ST-70",
      "the leftover needs no swap: with D <= X <= K + F and keeperOut >= 0, the debt-asset balance before the "
      "flash repayment covers F + phi",
      [And(v >= 0, v < 2**128) for v in (K, X, D, R, sf, A, B, phi)] + [F >= 0, D <= X, X <= K + F,
       ko == (K + F + R + sf) - (D + F + phi + A + B), ko >= 0, K + F - D + R + sf < F + phi],
      "PROVED")

# MATH-ST-115: the cap must sit strictly above the Pool rate (SettlementMath review S3). The Pool charges
# V3.4 rounds half-up; the source's ceiling quote is the binding gate: the pre-loan check is fee(F) * 1e4 <= m F with
# fee(F) = ceil(F p / 1e4).
Fm, pm, mm, phim = Ints("F p m phi")
cap_base = [Fm > 0, Fm < 2**128, pm >= 0, pm <= 1_000, mm >= 0, mm <= 1_000] + ceil_div(phim, Fm * pm, 10_000)

# MATH-ST-115 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-PSTORE-024
check("MATH-ST-115",
      "with m > p every loan of F >= ceil(1e4 / (m - p)) base units passes the exact check",
      cap_base + [mm > pm, Fm * (mm - pm) >= 10_000, phim * 10_000 > mm * Fm],
      "PROVED")
# MATH-ST-115 verifies: SPEC-LIQ-015, REQ-FLASH-001
check("MATH-ST-115",
      "with m = p a loan passes exactly when 1e4 divides F p",
      cap_base + [mm == pm, Not((phim * 10_000 <= mm * Fm) == ((Fm * pm) % 10_000 == 0))],
      "PROVED")
# MATH-ST-115 verifies: SPEC-LIQ-015, REQ-FLASH-001
check("MATH-ST-115",
      "wrong reading: a cap equal to the 5 bps rate admits every loan (counterexample expected)",
      cap_base + [mm == 5, pm == 5, phim * 10_000 > mm * Fm],
      "COUNTEREXAMPLE", show=[Fm, phim])
# MATH-ST-115 verifies: SPEC-LIQ-015, REQ-FLASH-001
check("MATH-ST-115",
      "with m < p every loan fails the exact check",
      cap_base + [mm < pm, phim * 10_000 <= mm * Fm],
      "PROVED")
# MATH-ST-115 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-FLASH-007
check("MATH-ST-115",
      "with FLASH_BORROWER (p = 0) the premium is 0 and every loan passes at every cap, 0 included",
      cap_base + [pm == 0, phim * 10_000 > mm * Fm],
      "PROVED")
# MATH-ST-115 verifies: SPEC-LIQ-015, SPEC-LIQ-007, REQ-FLASH-001, REQ-FLASH-003
chg = Ints("charge")[0]
check("MATH-ST-115",
      "the V3.4 half-up charge never exceeds the ceiling quote, so a loan that passes the quote passes the callback "
      "re-check of the charged premium",
      cap_base + half_up(chg, Fm * pm, 10_000) + [phim * 10_000 <= mm * Fm, Or(chg > phim, chg * 10_000 > mm * Fm)],
      "PROVED")
# MATH-ST-115 verifies: SPEC-LIQ-015
maximize("MATH-ST-115",
         "launch m = 10, p = 5: largest loan that fails the exact check (base units)",
         cap_base + [mm == 10, pm == 5, phim * 10_000 > mm * Fm], Fm, expect_max=999)
# MATH-ST-115 verifies: SPEC-LIQ-015
computed("MATH-ST-115", "SPEC-LIQ-015 cap examples (USDC, 6 decimals)", [
    ("m = p = 5, F = 1,950,000,000: phi", 975_000, mul_div_ceil(1_950_000_000, 5, 10_000)),
    ("m = p = 5, F = 1,950,000,001: phi", 975_001, mul_div_ceil(1_950_000_001, 5, 10_000)),
    ("  phi * 1e4", 9_750_010_000, 975_001 * 10_000),
    ("  m * F", 9_750_000_005, 5 * 1_950_000_001),
    ("m = 10, p = 5: sufficient bound ceil(1e4 / (m - p))", 2_000, -(-10_000 // 5)),
    ("m = 10, p = 5, F = 1,000: phi * 1e4 <= m F", 10_000, mul_div_ceil(1_000, 5, 10_000) * 10_000),
    ("  m F at F = 1,000", 10_000, 10 * 1_000),
])

done()
