# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-16..19, MATH-AR-39..40 — Repay sizing against Aave V4 repay rounding
(Spoke.repay, UserPositionUtils.calculateRestoreAmount), repay-all pull and refund, the
deadline quote, interest monotonicity and accounts below the $1,000 dust threshold.

Spec: SPEC-PROXY-003 (repay sizing), SPEC-PROXY-007 (repay-all pull, refund, quoteRepayAll),
SPEC-HUB-008 (repay rounding, getUserTotalDebt). There is no minimum debt (Q-169) and any
partial repay is allowed (Q-153).
"""
from fractions import Fraction
import math
from z3 import Ints, Reals, If, And, Or
from _common import prove, witness, note, computed, finish, floor_div, ceil_div, RAY

s, i, pr, a = Ints('drawnShares idx premRay amount')
dd, h1 = ceil_div(s * i, RAY, 'drawnDebt')           # rayMulUp(drawnShares, idx)
pp, h2 = ceil_div(pr, RAY, 'premDebt')               # fromRayUp(premiumRay)
D = dd + pp                                          # Spoke.getUserTotalDebt
base = [s >= 1, s < 2**120, i >= RAY, i < 2**100, pr >= 0, pr < 2**150] + h1 + h2
x = a - pp
k, h3 = floor_div(x * RAY, i, 'restoredShares')     # rayDivDown(drawnDebtRestored, idx)
nd, h4 = ceil_div((s - k) * i, RAY, 'newDrawnDebt')
part = base + h3 + h4 + [a >= pp, a < D]
# MATH-AR-16 verifies: SPEC-PROXY-003, SPEC-HUB-008
prove('MATH-AR-16a', 'partial repay (premium cleared): debt after >= D - x (never below the pre-computed value)',
      part, nd >= D - a)
iR, h5 = ceil_div(i, RAY, 'ceilIdx')
prove('MATH-AR-16b', 'partial repay: debt after <= D - x + ceil(drawnIndex/RAY) base units',
      part + h5, nd <= D - a + iR)
np_, h6 = ceil_div(pr - a * RAY, RAY, 'newPrem')
prove('MATH-AR-16c', 'premium-only repay (x < premium debt): debt after == D - x exactly',
      base + h6 + [a >= 1, a < pp], dd + np_ == D - a)
kD, h7 = floor_div(dd * RAY, i, 'restoredAll')
prove('MATH-AR-16d', 'repaying x = D (premium first) restores every drawn share: floor(rayMulUp(s, idx) x RAY / idx) >= s',
      base + h7, kD >= s)

# MATH-AR-17  Repay-all.
D0, D1, M, recv, spent, refund = Ints('D0 D1 M received spent refund')
# MATH-AR-17 verifies: SPEC-PROXY-003, SPEC-PROXY-007
witness('MATH-AR-17a', 'wrong reading: repay-all signed as a fixed amount = debt at signing leaves debt after one block of interest',
        [D0 >= 1, D1 > D0, D1 - D0 < 10**15, M == D0, D1 - M > 0])
rule = [D1 >= 0, M >= D1, recv == M, spent == If(recv < D1, recv, D1), refund == recv - spent]
prove('MATH-AR-17b', 'SPEC-PROXY-007: D_e <= M, received = M  =>  spent = D_e, debt after 0, refund = M - D_e >= 0, pulled <= M',
      rule, And(spent == D1, D1 - spent == 0, refund == M - D1, refund >= 0, recv <= M))
prove('MATH-AR-17c', 'fee-on-transfer token (received <= M): spent <= min(received, D_e), refund >= 0, nothing above M is pulled',
      [D1 >= 0, M >= D1, recv >= 0, recv <= M, spent == If(recv < D1, recv, D1), refund == recv - spent],
      And(spent <= recv, spent <= D1, refund >= 0, recv <= M))
xp = Ints('xpartial')[0]
prove('MATH-AR-17d', 'partial repay x = min(maxRepaySpend, D): x <= maxRepaySpend and x <= D',
      [M > 0, D1 >= 0, xp == If(M < D1, M, D1)], And(xp <= M, xp <= D1))

# MATH-AR-18  Interest never lowers debt.
rate, dt, i0 = Ints('rate dt idx0')
YEAR = 365 * 24 * 3600
lin, h8 = floor_div(rate * dt, YEAR, 'lin')
i1, h9 = ceil_div(i0 * (RAY + lin), RAY, 'idx1')
acc = [rate >= 0, rate < 2**96, dt >= 0, dt < 2**40, i0 >= RAY, i0 < 2**100] + h8 + h9
# MATH-AR-18 verifies: SPEC-PROXY-003, SPEC-HUB-007
prove('MATH-AR-18a', 'drawn index after accrual >= before (rayMulUp of a factor >= RAY)', acc, i1 >= i0)
ps, off = Ints('premiumShares premiumOffsetRay')
prove('MATH-AR-18b', 'premium debt ray = premiumShares*idx - offset is non-decreasing as idx grows',
      acc + [ps >= 0, ps * i0 - off >= 0], ps * i1 - off >= ps * i0 - off)
prove('MATH-AR-18c', 'drawn debt rayMulUp(shares, idx) is non-decreasing as idx grows',
      acc + [s >= 0, s < 2**120], s * i1 >= s * i0)

# MATH-AR-19  Total debt below $1,000 (GHO): any liquidation that does not exhaust the seized
# collateral reserve takes all drawn shares (dust rule); no minimum debt exists (Q-169).
tot, remr = Ints('totalDebtRay remainingRay')
# MATH-AR-19 verifies: SPEC-HUB-008, Q-169
prove('MATH-AR-19', 'total GHO debt < 1,000  =>  every remaining amount is below the dust threshold (full liquidation)',
      [tot >= 0, tot < 1000 * 10**18 * RAY, remr >= 0, remr <= tot],
      remr * 10**8 < 1000 * 10**26 * RAY)
note('MATH-AR-19b', 'accounts with 0 < debt < $1,000',
     "Reachable by borrowing a small amount (no minimum debt, Q-169), by partial repay (Q-153) or by a liquidation\n"
     "that exhausts one collateral reserve while others remain (MATH-AR-15b). Such an account repays partially or in\n"
     "full, tops up, or is liquidated in full by the dust rule.")

# ---------------------------------------------------------------------------
# MATH-AR-39  quoteRepayAll = ceil(D_s x (1 + rho x (t_d - t_s)/yr) x 1.001) covers the live debt at
# every inclusion time up to the deadline. Live debt: D_e <= D_s x g + 2 (ceil of drawn and premium),
# with g <= 1 + rho x (t_d - t_s)/yr + 0.0009 (accrual compounding and a rate rise inside the window,
# 9 bps of debt, i.e. 4,730 percentage points of APR over 600 s), D_s >= 20,000 base units.
Ds, De, rho, tau, Q, g = Reals('Ds De rho tau Q g')
# MATH-AR-39 verifies: SPEC-PROXY-007
prove('MATH-AR-39', 'quote >= D_s(1 + rho tau)(1.001), D_e <= D_s g + 2, g <= 1 + rho tau + 0.0009  =>  D_e <= quote',
      [Ds >= 20_000, rho >= 0, tau >= 0, Q >= Ds * (1 + rho * tau) * 1.001, g >= 1, g <= 1 + rho * tau + 0.0009,
       De <= Ds * g + 2], De <= Q)

# ---------------------------------------------------------------------------
# MATH-AR-40  Repay worked examples (SPEC-PROXY-003, SPEC-PROXY-007, 3.3 Repay, 2.6 Adapter).
YR = 31_536_000
DU = math.ceil(Fraction(5000 * 10**6) * (1 + Fraction(6, 100) * 30 * 86400 / YR))
DG = math.ceil(Fraction(8000 * 10**18) * (1 + Fraction(5, 100) * 30 * 86400 / YR))
quote = math.ceil(Fraction(DU) * (1 + Fraction(6, 100) * 600 / YR) * Fraction(1001, 1000))
De24 = math.ceil(Fraction(DU) * (1 + Fraction(6, 100) * 24 / YR))
tdv = Fraction(DG, 10**18) + Fraction(DU, 10**6) * Fraction(9999, 10000)
# MATH-AR-40 verifies: SPEC-PROXY-003, SPEC-PROXY-007, REP-004, REP-010
computed('MATH-AR-40', 'repay sizing figures',
         [('D_USDC after 30 days at 6.00%', 5_024_657_535, DU),
          ('D_GHO after 30 days at 5.00%', 8_032_876_712_328_767_123_288, DG),
          ('repay-all USDC refund with M = 5,030e6', 5_342_465, 5030 * 10**6 - DU),
          ('repay-all GHO refund with M = 8,040e18', 7_123_287_671_232_876_712, 8040 * 10**18 - DG),
          ('M = 5,020e6 is below D_USDC (RepayExceedsMax)', True, DU > 5020 * 10**6),
          ('partial repay 2,000e6: D - x', 3_024_657_535, DU - 2000 * 10**6),
          ('quoteRepayAll to a 600 s deadline', 5_029_687_935, quote),
          ('D_e 24 s later', 5_024_657_765, De24),
          ('refund at inclusion', 5_030_170, quote - De24),
          ('total debt value $13,057.03 (cents, down)', 1_305_703, math.floor(tdv * 100)),
          ('HF 1.8840 (4 decimals)', 18840, round(Fraction(24600) / tdv * 10**4)),
          ('GHO debt after a 3,000 GHO repay by a rescue service', 5_032_876_712_328_767_123_288, DG - 3000 * 10**18),
          ('refund of the later repay-all with cap 8,040e18', 3_007_123_287_671_232_876_712,
           8040 * 10**18 - (DG - 3000 * 10**18))])

finish()
