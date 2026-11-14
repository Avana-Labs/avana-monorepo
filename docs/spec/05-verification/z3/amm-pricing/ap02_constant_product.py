# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""AMM-B — fair reserves for a constant-product pair (Uniswap v2 style, 0.3% fee, MINIMUM_LIQUIDITY,
kLast / feeTo protocol fee).

    k = r0 * r1 (getReserves),   fair value  V = 2 sqrt(k p0 p1),   value per LP = V / supply
    fair reserves at the oracle price: r0* = sqrt(k p1 / p0), r1* = sqrt(k p0 / p1)
    redeemable value at the oracle price (burn all, mark at oracle): R = r0 p0 + r1 p1

Real-number checks encode the square root by a variable q >= 0 with q^2 = k p0 p1. The attack
numbers are exact-integer runs of the UniswapV2Pair port in _common.py.

Check IDs: MATH-AMM-V2-PRICE-01 .. 06.
"""
import math
import os
import sys
from fractions import Fraction as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Reals, And, RealVal
from _common import prove, witness, note, finish, V2Pair, v2_fair_value, MINIMUM_LIQUIDITY

r0, r1, p0, p1, q, q2, d, g, S, l, a0, a1, k2 = Reals('r0 r1 p0 p1 q q2 dx gamma S l a0 a1 k2')
pos = [r0 > 0, r1 > 0, p0 > 0, p1 > 0, q >= 0, q * q == r0 * r1 * p0 * p1]
V = 2 * q
R = r0 * p0 + r1 * p1
GAMMA = RealVal(F(997, 1000))

# ---------------------------------------------------------------------------------------------------
# B1  The fair quote never exceeds what the LP tokens redeem for at the oracle price
# MATH-AMM-V2-PRICE-01 verifies: SPEC-AMM-CORE-001, SPEC-AMM-V2-001, INV-078
prove('AMM-B1a', 'V = 2 sqrt(k p0 p1) <= r0 p0 + r1 p1 (AM-GM), whatever the reserves', pos, V <= R)
prove('AMM-B1b', 'equality iff the pool sits at the oracle price (r0 p0 = r1 p1)', pos + [V == R], r0 * p0 == r1 * p1)

# ---------------------------------------------------------------------------------------------------
# B2  One swap (token0 in, fee 0.3%): k grows, but by at most a factor 1/gamma
# MATH-AMM-V2-PRICE-02 verifies: SPEC-AMM-V2-001, REQ-AMM-V2-005, REQ-AMM-CORE-014, INV-078, AMMN-RT-07
out = r1 * d * GAMMA / (r0 + d * GAMMA)                  # getAmountOut, exact
kk = (r0 + d) * (r1 - out)
prove('AMM-B2a', 'k never decreases on a swap: (r0 + dx)(r1 - out) >= r0 r1', [r0 > 0, r1 > 0, d > 0], kk >= r0 * r1)
prove('AMM-B2b', 'k grows by less than 1/gamma: gamma (r0 + dx)(r1 - out) <= r0 r1 (so V grows < 1/sqrt(0.997) - 1 = 0.1503%)',
      [r0 > 0, r1 > 0, d > 0], GAMMA * kk <= r0 * r1)
prove('AMM-B2c', 'from a pool at the oracle price, the quote gain V\' - V is at most the swapper\'s loss at oracle '
      'prices (dx p0 - out p1): a 100% LP owner who swaps against itself cannot raise its quote above its cost',
      pos + [r0 * p0 == r1 * p1, d > 0, q2 >= 0, q2 * q2 == kk * p0 * p1],
      2 * q2 - 2 * q <= d * p0 - out * p1)
prove('AMM-B2d', 'after any swap the quote still lower-bounds the redeemable value (B1a with the new reserves)',
      [r0 > 0, r1 > 0, p0 > 0, p1 > 0, d > 0, q2 >= 0, q2 * q2 == kk * p0 * p1],
      2 * q2 <= (r0 + d) * p0 + (r1 - out) * p1)

# ---------------------------------------------------------------------------------------------------
# B3  Donation (transfer then sync)
# MATH-AMM-V2-PRICE-03 verifies: SPEC-AMM-V2-001, REQ-AMM-V2-003, INV-078, AMMN-RT-07
D0, D1 = Reals('D0 D1')
don = [D0 >= 0, D1 >= 0, q2 >= 0, q2 * q2 == (r0 + D0) * (r1 + D1) * p0 * p1]
prove('AMM-B3a', 'pool at the oracle price: a synced donation raises V by at most its own value D0 p0 + D1 p1',
      pos + don + [r0 * p0 == r1 * p1], 2 * q2 - 2 * q <= D0 * p0 + D1 * p1)
witness('AMM-B3b', 'deliberate: pool off the oracle price (r1 p1 = 4 r0 p0): donating 1 unit of token0 raises V by '
        '1.657 > 1 (the donation closes part of the pool\'s own mispricing)',
        pos + don + [r0 == 1, r1 == 4, p0 == 1, p1 == 1, D0 == 1, D1 == 0, 2 * q2 - 2 * q > D0 * p0 + D1 * p1])
dev = RealVal(F(1, 100))
prove('AMM-B3c', 'with the pool within 1% of the oracle price (r1 p1 <= 1.01 r0 p0 and r0 p0 <= 1.01 r1 p1), a donation '
      'raises V by at most 1.005 x its value (gradient bound sqrt(1.01) < 1.005)',
      pos + don + [r1 * p1 <= (1 + dev) * r0 * p0, r0 * p0 <= (1 + dev) * r1 * p1],
      2 * q2 - 2 * q <= RealVal(F(1005, 1000)) * (D0 * p0 + D1 * p1))
prove('AMM-B3d', 'after any donation the quote still lower-bounds the redeemable value', [p0 > 0, p1 > 0, r0 > 0, r1 > 0] + don,
      2 * q2 <= (r0 + D0) * p0 + (r1 + D1) * p1)

# ---------------------------------------------------------------------------------------------------
# B4  Mint and burn at the pool ratio: value per LP never falls, so rounding cannot be farmed
# MATH-AMM-V2-PRICE-04 verifies: SPEC-AMM-V2-001, INV-078
prove('AMM-B4a', 'mint: l <= a0 S / r0 and l <= a1 S / r1 -> V(r + a) / (S + l) >= V(r) / S',
      pos + [S > 0, l >= 0, a0 >= 0, a1 >= 0, l * r0 <= a0 * S, l * r1 <= a1 * S,
             q2 >= 0, q2 * q2 == (r0 + a0) * (r1 + a1) * p0 * p1], q2 * S >= q * (S + l))
prove('AMM-B4b', 'burn: amounts a_i <= l r_i / S -> V(r - a) / (S - l) >= V(r) / S',
      pos + [S > 0, l >= 0, l < S, a0 >= 0, a1 >= 0, a0 * S <= l * r0, a1 * S <= l * r1,
             q2 >= 0, q2 * q2 == (r0 - a0) * (r1 - a1) * p0 * p1], q2 * S >= q * (S - l))

# ---------------------------------------------------------------------------------------------------
# B5  Protocol fee on mint (kLast / feeTo): pending dilution not yet in totalSupply
# MATH-AMM-V2-PRICE-05 verifies: REQ-AMM-V2-002, INV-078, AMMN-RT-07
rk, rkl = Reals('rk rkl')
fee_liq = S * (rk - rkl) / (5 * rk + rkl)
prove('AMM-B5a', 'quote per LP with totalSupply overstates the post-_mintFee value by the factor 1 + (rk - rkl)/(5 rk + rkl) '
      '<= 1 + (rk/rkl - 1)/6 (1/6 of the sqrt(k) growth since the last mint/burn)',
      [S > 0, rkl > 0, rk >= rkl], And(fee_liq >= 0, fee_liq / S <= (rk / rkl - 1) / 6))
prove('AMM-B5b', 'with supply + pending fee liquidity the per-LP quote is <= per-LP redeemable after the fee mint',
      pos + [S > 0, rkl > 0, rk >= rkl, rk * rk == r0 * r1], V / (S + fee_liq) <= R / (S + fee_liq))


# ---------------------------------------------------------------------------------------------------
# Attack runs (exact integers). Pool: 1,000,000 USDC (6 dec, $1) / 500 WETH (18 dec, $2,000).
# MATH-AMM-V2-PRICE-06 verifies: REQ-AMM-V2-001, REQ-AMM-V2-002, REQ-AMM-V2-004, REQ-AMM-V2-005, AMMN-RT-07
def per_lp(pair, p0, p1, supply=None, use_balances=False):
    r0_, r1_ = (pair.b0, pair.b1) if use_balances else (pair.r0, pair.r1)
    return F(v2_fair_value(r0_, r1_, p0, p1), supply or pair.supply)


def spot_per_lp(pair, p0, p1, use_balances=False):
    r0_, r1_ = (pair.b0, pair.b1) if use_balances else (pair.r0, pair.r1)
    return F(r0_ * p0 + r1_ * p1, pair.supply)


P0 = 10 ** 12          # USD per raw USDC unit, scaled by 1e18 (so $1 = 1e18 per 1e6 raw)
P1 = 2000              # USD per raw WETH unit, same scale ($2,000 = 2000 * 1e18 per 1e18 raw)


def fresh(fee_on=False):
    pr = V2Pair(fee_on)
    pr.transfer_in(10 ** 12, 500 * 10 ** 18)
    pr.mint()
    return pr


def usd(x):
    return float(x) / 1e18


base_pair = fresh()
f0, s0 = per_lp(base_pair, P0, P1), spot_per_lp(base_pair, P0, P1)
pr = fresh()
pr.transfer_in(9 * 10 ** 12, 0)                       # flash-borrowed 9M USDC swapped in
out = pr.amount_out(9 * 10 ** 12, pr.r0, pr.r1)
pr.b0 -= 9 * 10 ** 12
pr.swap(True, 9 * 10 ** 12)
f1, s1 = per_lp(pr, P0, P1), spot_per_lp(pr, P0, P1)
back = pr.swap(False, out)                            # swap the WETH back in the same transaction
cost = 9 * 10 ** 12 - back
note('AMM-B6', 'deliberate: naive spot reserves x price is inflated by a flash-funded swap; the fair quote is not',
     f'pool 1,000,000 USDC / 500 WETH = $2,000,000, supply {base_pair.supply:,} LP units\n'
     f'swap 9,000,000 USDC in (flash loan), read the quote, swap the WETH back; reserves end at {pr.r0 / 1e6:,.0f} USDC / {pr.r1 / 1e18:,.4f} WETH\n'
     f'naive per-LP quote between the swaps: x{float(s1 / s0):.4f} (${float(s0 * base_pair.supply) / 1e18:,.0f} -> '
     f'${float(s1 * base_pair.supply) / 1e18:,.0f} pool value)\n'
     f'fair per-LP quote between the swaps: x{float(f1 / f0):.6f} (+{(float(f1 / f0) - 1) * 100:.4f}%, the 0.3% fee kept by the pool)\n'
     f'attacker cost of the round trip: {cost / 1e6:,.0f} USDC (two 0.3% fees); with a 31% LTV on a $2M LP pledge the naive\n'
     f'quote lets it borrow ~${0.31 * float(s1 * base_pair.supply) / 1e18 - 0.31 * 2e6:,.0f} above what the true value allows')

# donation without sync: quote from balanceOf vs from getReserves, then skim back
pr = fresh()
pr.transfer_in(10 ** 12, 500 * 10 ** 18)              # donate $2M
fb, fr = per_lp(pr, P0, P1, use_balances=True), per_lp(pr, P0, P1)
pr.skim()
note('AMM-B7', 'deliberate: a quote from balanceOf is inflated for free (donate, borrow, skim back in one transaction); '
     'a quote from getReserves is unchanged until sync',
     f'balanceOf quote x{float(fb / f0):.4f}, getReserves quote x{float(fr / f0):.4f}; skim returns the whole donation, '
     f'so the balanceOf inflation costs the attacker 0')

# donation with sync: permanent, cost = donation, gain per LP = donation / supply
pr = fresh()
pr.transfer_in(10 ** 11, 50 * 10 ** 18)               # donate 10%
pr.sync()
fs = per_lp(pr, P0, P1)
note('AMM-B8', 'transfer + sync: per-LP quote rises by donation / supply; the donation is locked in the pool (skim returns 0)',
     f'10% donation -> per-LP quote x{float(fs / f0):.6f}; skim after sync returns {pr.skim()}')

# first depositor / low supply: only MINIMUM_LIQUIDITY + 1 outstanding, then a donation
pr = V2Pair()
pr.transfer_in(1001, 1001)                            # sqrt(1001*1001) = 1001 -> 1 LP to the attacker, 1000 locked
pr.mint()
pr.transfer_in(10 ** 12, 10 ** 12)
pr.sync()
vic = V2Pair.__new__(V2Pair)
vic.__dict__ = dict(pr.__dict__)
dep = 19 * pr.r0 // (10 * pr.supply)                 # victim adds 1.9 LP units' worth per side
vic.transfer_in(dep, dep)
lp_victim = vic.mint()
loss = 2 * dep - F(lp_victim * 2 * vic.r0, vic.supply)
note('AMM-B9', 'low supply (MINIMUM_LIQUIDITY = 1000 locked, 1 LP to the attacker): a donation makes one LP unit worth '
     'donation / 1001; the per-LP quote stays backed (B1a) but rounding on mint costs a later depositor up to one LP unit',
     f'supply {pr.supply}; per-LP value after a 1e12 + 1e12 raw donation: {(pr.r0 + pr.r1) // pr.supply:,} raw units\n'
     f'victim deposits 1.9 LP units\' worth ({dep:,} raw per side) -> {lp_victim} LP, loses {float(loss):,.0f} raw units '
     f'({float(loss) / (2 * dep) * 100:.1f}% of the deposit) to the pool through mint rounding')

# fee-on-mint: wash trading raises k; quote with totalSupply vs supply + pending fee liquidity
pr = fresh(fee_on=True)
pr.transfer_in(10 ** 6, 10 ** 6)                      # tiny mint so kLast is set
pr.mint()
for _ in range(20):
    o = pr.swap(True, 5 * 10 ** 12)
    pr.swap(False, o)
pend = pr.pending_fee_liquidity()
fq = per_lp(pr, P0, P1)
fa = per_lp(pr, P0, P1, supply=pr.supply + pend)
note('AMM-B10', 'feeTo on: 20 round-trip swaps of 5M USDC; the pending _mintFee liquidity is not yet in totalSupply',
     f'k grew x{pr.r0 * pr.r1 / pr.k_last:.4f}; quote with totalSupply overstates the value per LP after the fee mint by '
     f'{(float(fq / fa) - 1) * 100:.4f}% (bound (sqrt(k/kLast) - 1)/6 = {(math.sqrt(pr.r0 * pr.r1 / pr.k_last) - 1) / 6 * 100:.4f}%)')

# per-transaction swap bound: one swap of any size raises the fair quote by < 0.1503%
gains = []
for size in (10 ** 9, 10 ** 12, 10 ** 15, 10 ** 18):
    pr = fresh()
    pr.transfer_in(size, 0)
    pr.b0 -= size
    pr.swap(True, size)
    gains.append(float(per_lp(pr, P0, P1) / f0) - 1)
note('AMM-B11', 'one swap of 1e3 .. 1e12 USDC: fair per-LP quote gain (bound 1/sqrt(0.997) - 1 = 0.15034%)',
     ', '.join(f'{x * 100:.5f}%' for x in gains))

finish()
