# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-71..73, 76, 77 — The Lens's account and reserve views: the supply rate derived from the Hub's accounting
(REQ-LENS-046), the exact liquidation price of a one-collateral account (REQ-LENS-047), the health factor after a
withdrawal (REQ-LENS-049), against Aave V4's health factor (Spoke._processUserAccountData at a3ef63e); the largest
removal that keeps a target health factor (REQ-LENS-054) and the uncollected fees of a concentrated-liquidity position
in wrapping arithmetic (REQ-LENS-050).
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

# MATH-AR-76  Largest removal: u* = floor((W - E - need) x 1e4 / per), with need = ceil(target x debtRay / (WAD x RAY)),
# removal ceil(u x per / 1e4), per = served value per unit x CF (bps).
W6, E6, nd, per, u6, tgt, D6 = Ints('W6 E6 need per u6 target debtRay6')
us, h6 = floor_div((W6 - E6 - nd) * BPS, per, 'uStar')
rm1, h7 = ceil_div(us * per, BPS, 'removedStar')
rm2, h8 = ceil_div((us + 1) * per, BPS, 'removedNext')
hyp6 = [W6 >= 0, W6 < 2**200, E6 >= 0, nd >= 0, W6 >= E6 + nd, per >= 1, per < 2**100] + h6 + h7 + h8
# MATH-AR-76 verifies: REQ-LENS-054
prove('MATH-AR-76a', 'u* keeps W - E - removal(u*) >= need', hyp6, W6 - E6 - rm1 >= nd)
prove('MATH-AR-76b', 'u* + 1 does not: u* is the largest such removal', hyp6, W6 - E6 - rm2 < nd)
need6, h9 = ceil_div(tgt * D6, WAD * RAY, 'need6')
hf6, h10 = floor_div(u6 * WAD * RAY, D6, 'hf6')
hyp7 = [tgt >= 0, tgt < 2**128, D6 >= 1, D6 < 2**250, u6 >= 0, u6 < 2**200] + h9 + h10
prove('MATH-AR-76c', 'left >= need  <=>  floor(left x WAD x RAY / debtRay) >= target', hyp7,
      (u6 >= need6) == (hf6 >= tgt))
A6, Wa, ua = Ints('assets6 Wfloor uBound')
Wd, h11 = floor_div(A6 * per, BPS, 'Wfromassets')
ub, h12 = floor_div((Wd - E6 - nd) * BPS, per, 'uFromW')
prove('MATH-AR-76e', 'the bound never exceeds the assets: floor((floor(assets x per / 1e4) - E - need) x 1e4 / per) <= assets',
      [A6 >= 0, A6 < 2**128, per >= 1, per < 2**100, E6 >= 0, nd >= 0, Wd >= E6 + nd] + h11 + h12, ub <= A6)
computed('MATH-AR-76d', 'REQ-LENS-054 example: 16,000 vault tokens at $2, CF 80 %, 10,000 GHO, target 1.25', [
    ('maxUnits', 8_187_500_000,
     (8000 * 16_000 * 10**6 * 2 * 10**20 // BPS - (125 * 10**16 * (10_000 * 10**26 * RAY) + WAD * RAY - 1)
      // (WAD * RAY)) * BPS // (2 * 10**20 * 8000))])

# MATH-AR-77  Uncollected fees in wrapping arithmetic. True accumulators are unbounded naturals; the pool stores them
# mod 2^256 and the position manager's owed amount mod 2^128.
M = 2**256


def stored(x, name):
    """The uint256 a pool stores for the unbounded accumulator x: x mod 2^256, as x = q x 2^256 + r, 0 <= r < 2^256."""
    q, r = Ints(name + '_q ' + name + '_r')
    return r, [x == q * M + r, r >= 0, r < M]


def wrap(expr, name, mod=M):
    """The result of a wrapping uint operation: expr mod `mod`."""
    k, r = Ints(name + '_k ' + name + '_r')
    return r, [r == expr + k * mod, r >= 0, r < mod]


g, b, a7, last, nowi = Ints('global below above lastInside nowInside')
gs, hg = stored(g, 'g')
bs, hb = stored(b, 'b')
as_, ha = stored(a7, 'a')
ins, hi = wrap(gs - bs - as_, 'inside')
# MATH-AR-77 verifies: REQ-LENS-050
prove('MATH-AR-77a', 'feeGrowthInside computed mod 2^256 equals the true inside growth when it is in [0, 2^256)',
      [g >= 0, b >= 0, a7 >= 0, g - b - a7 >= 0, g - b - a7 < M] + hg + hb + ha + hi, ins == g - b - a7)
ls, hl = stored(last, 'last')
ns, hn = stored(nowi, 'now')
dg, hd = wrap(ns - ls, 'growth')
prove('MATH-AR-77b', 'growth since the snapshot mod 2^256 equals the true growth when it is in [0, 2^256)',
      [last >= 0, nowi >= last, nowi - last < M] + hl + hn + hd, dg == nowi - last)
own, gr = Ints('owed growth')
ow, ho = wrap(own + gr, 'owedSum', 2**128)
prove('MATH-AR-77c', 'owed + growth mod 2^128 equals the true owed amount while it fits uint128',
      [own >= 0, own < 2**128, gr >= 0, gr < 2**128, own + gr < 2**128] + ho, ow == own + gr)
computed('MATH-AR-77d', 'REQ-LENS-050 examples (L = 2e12)', [
    ('in range, global 3, outside(lower) 1: 2 x L', 4 * 10**12, ((3 - 1 - 0) * 2**128) * (2 * 10**12) // 2**128),
    ('wrap: snapshot 2^256 - 2^129, now 2^128: 3 x L', 6 * 10**12,
     ((2**128 - (M - 2**129)) % M) * (2 * 10**12) // 2**128)])

finish()
