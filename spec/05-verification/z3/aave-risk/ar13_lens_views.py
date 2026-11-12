# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-71..73 — The Lens's account and reserve views: the supply rate derived from the Hub's accounting
(REQ-LENS-046), the exact liquidation price of a one-collateral account (REQ-LENS-047) and the health factor after a
withdrawal (REQ-LENS-049), against Aave V4's health factor (Spoke._processUserAccountData at a3ef63e).
"""
from z3 import Ints
from _common import prove, computed, finish, floor_div, ceil_div, RAY, WAD, BPS

# MATH-AR-71  Supply rate: floor(r x owed x (1e4 - fee) / (added x 1e4)).
r, owed, added, fee = Ints('rate owed added fee')
sr, h1 = floor_div(r * owed * (BPS - fee), added * BPS, 'supplyRate')
base = [r >= 0, r < 2**96, owed >= 0, owed < 2**128, added >= 1, added < 2**128, fee >= 0, fee <= BPS] + h1
# MATH-AR-71 verifies: REQ-LENS-046
prove('MATH-AR-71a', 'owed <= added  =>  supplyRate <= drawnRate (suppliers never earn more than borrowers pay)',
      base + [owed <= added], sr <= r)
prove('MATH-AR-71b', 'supplyRate x added x 1e4 <= drawnRate x owed x (1e4 - fee) (rounded down, never overstated)',
      base, sr * added * BPS <= r * owed * (BPS - fee))
computed('MATH-AR-71c', 'REQ-LENS-046 example', [
    ('utilizationBps of 600 owed / 1,000 added', 6000, 600 * BPS // 1000),
    ('supplyRateRay at 8 %, fee 10 %', 432 * 10**23, (8 * 10**25) * 600 * (BPS - 1000) // (1000 * BPS))])

# MATH-AR-72  Liquidation price: P = ceil(debtRay x 1e4 / (CF x assets x 10^(18-d) x RAY)).
D, cf, a, s = Ints('debtRay cf assets scale')
den = cf * a * s * RAY
P, h2 = ceil_div(D * BPS, den, 'liqPrice')
hyp = [D >= 1, D < 2**200, cf >= 1, cf <= BPS, a >= 1, a < 2**96, s >= 1, s <= 10**18] + h2


def hf_ok(price):
    # Aave: HF = floor(cf x val x 1e14 x RAY / debtRay) >= 1e18  <=>  cf x val x RAY >= 1e4 x debtRay
    return cf * (a * price * s) * RAY >= BPS * D


# MATH-AR-72 verifies: REQ-LENS-047
prove('MATH-AR-72a', 'at liquidationPrice Aave health factor >= 1.00', hyp, hf_ok(P))
prove('MATH-AR-72b', 'one 8-decimal unit below it the health factor is < 1.00', hyp + [P >= 1], hf_ok(P - 1) == False)
computed('MATH-AR-72c', 'REQ-LENS-047 example: 10,000 vault tokens (d = 6), CF 80 %, 15,000 GHO', [
    ('liquidationPrice', 187_500_000,
     -((-(15_000 * 10**26 * RAY) * BPS) // (8000 * 10_000 * 10**6 * 10**12 * RAY)))])

# MATH-AR-73  Health factor after removing units: W' = W - ceil(units x Pc x 10^(18-d) x CF / 1e4).
W, u, pc, sc, cf3, debt = Ints('weighted units price scale cf3 debtRay')
rem, h3 = ceil_div(u * pc * sc * cf3, BPS, 'removed')
hfb, h4 = floor_div(W * WAD * RAY, debt, 'hfBefore')
hfa, h5 = floor_div((W - rem) * WAD * RAY, debt, 'hfAfter')
hyp3 = [W >= 0, W < 2**200, u >= 0, u < 2**128, pc >= 1, pc < 2**64, sc >= 1, sc <= 10**18, cf3 >= 0, cf3 <= BPS,
        debt >= 1, debt < 2**250, rem <= W] + h3 + h4 + h5
# MATH-AR-73 verifies: REQ-LENS-049
prove('MATH-AR-73a', 'removing collateral never raises the health factor', hyp3, hfa <= hfb)
computed('MATH-AR-73b', 'REQ-LENS-049 example: $20,000 at CF 80 % against 8,000 GHO', [
    ('HF before', 2 * WAD, (16_000 * 10**26) * WAD * RAY // (8_000 * 10**26 * RAY)),
    ('HF after 5,000 tokens', WAD, (16_000 * 10**26 - 5000 * 10**6 * 2 * 10**8 * 10**12 * 8000 // BPS) * WAD * RAY
     // (8_000 * 10**26 * RAY)),
    ('HF after 5,001 tokens', 999_800_000_000_000_000,
     (16_000 * 10**26 - 5001 * 10**6 * 2 * 10**8 * 10**12 * 8000 // BPS) * WAD * RAY // (8_000 * 10**26 * RAY))])

finish()
