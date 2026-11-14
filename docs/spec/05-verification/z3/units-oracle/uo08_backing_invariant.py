# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-30..33 — mint and burn exactness, live liquidity covering credit, the debit equality
and the supply bound ([2.4] SPEC-UNIT-002, SPEC-UNIT-006, [2.3] SPEC-BACK-002, SPEC-BACK-007,
SPEC-BACK-009, SPEC-BACK-010).

State (one record r, all other records aggregated as 'rest'):
  supply      vault-token totalSupply (uint256)
  c_r, c_rest credited units (uint128 each; c_rest is a sum, kept in 256 bits)
  l_r         live liquidity of record r's NFT (uint128, Uniswap)
Invariants:  I1  supply == c_r + c_rest      I2  l_r >= c_r
Operations:
  pledge     c_r = l_r = L (NFT liquidity read after custody), mint exactly L
  donate     anyone calls NFPM.increaseLiquidity on the NFT: l_r += x (Uniswap reverts on overflow)
  seize u    the Adapter burns the u units LPVaultSwap received; c_r -= u (u <= c_r) and
             decreaseLiquidity(u) on the NFT (l_r -= u)
  partial removal / deleverage release of u < c_r (resp. u <= c_r): burn u from the proxy, c_r -= u, l_r -= u
  re-credit  added = l_r - c_r; mint added; c_r = l_r
  withdraw   burn c_r, close the record, NFT (l_r, donations included) returned
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import (Real, Reals, BitVec, BitVecVal, ZeroExt, ULE, ULT, UGE, And, Or, Not, Implies, Int, Ints,
                BVAddNoOverflow, BVSubNoUnderflow)
from _common import prove, witness, note, finish, max_liquidity_per_tick, TICK_SPACINGS, U120

W = 256
supply, crest = BitVec('supply', W), BitVec('c_rest', W)
cr, lr = BitVec('c_r', 128), BitVec('l_r', 128)
CR, LR = ZeroExt(W - 128, cr), ZeroExt(W - 128, lr)
MAXL = BitVecVal(max_liquidity_per_tick(1), 128)      # every full-range position shares these ticks
inv = [supply == CR + crest, ULE(cr, lr), ULE(lr, MAXL), ULE(crest, BitVecVal(2 ** 128, W))]
inv_ok = lambda s, c, l, rest: And(s == ZeroExt(W - 128, c) + rest, ULE(c, l))

# ---------------------------------------------------------------------------
# MATH-UO-30  Each operation preserves I1 and I2 (bit-precise, uint128 liquidity, uint256 supply).
L = BitVec('L', 128)
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30a', 'pledge: mint exactly L (no conversion) keeps supply == sum credited and l >= c; no overflow',
      [supply == crest, ULE(crest, BitVecVal(2 ** 128, W)), ULE(L, MAXL), UGE(L, BitVecVal(1, 128))],
      And(BVAddNoOverflow(supply, ZeroExt(W - 128, L), False),
          inv_ok(supply + ZeroExt(W - 128, L), L, L, crest)))
x = BitVec('donation', 128)
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30b', 'donation (any amount Uniswap accepts) raises l only; credited and supply unchanged; never collateral',
      inv + [ULE(x, MAXL - lr)], inv_ok(supply, cr, lr + x, crest))
us = BitVec('u', 128)
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30c', 'partial seizure: burn u == debit u == liquidity removed u (u <= c_r) keeps both invariants; no underflow',
      inv + [ULE(us, cr)],
      And(BVSubNoUnderflow(supply, ZeroExt(W - 128, us), False), BVSubNoUnderflow(lr, us, False),
          inv_ok(supply - ZeroExt(W - 128, us), cr - us, lr - us, crest)))
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30d', 'full seizure leaves the record open with c_r = 0 and l_r >= 0 (donations stay with the NFT)',
      inv + [us == cr], And(cr - us == 0, inv_ok(supply - CR, cr - us, lr - us, crest)))
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30e', 'withdraw: burning exactly c_r and closing the record keeps supply == sum credited of the rest',
      inv, supply - CR == crest)
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010
prove('MATH-UO-30f', 'partial removal or deleverage release of u <= c_r: burn u == debit u == liquidity removed u keeps both invariants',
      inv + [ULE(us, cr)],
      And(BVSubNoUnderflow(supply, ZeroExt(W - 128, us), False),
          inv_ok(supply - ZeroExt(W - 128, us), cr - us, lr - us, crest)))
# MATH-UO-30 verifies: SPEC-UNIT-002, SPEC-BACK-009, SPEC-BACK-010, SPEC-BACK-013
prove('MATH-UO-30g', 're-credit: mint added = l_r - c_r and set c_r = l_r keeps supply == sum credited and l_r >= c_r',
      inv, And(BVAddNoOverflow(supply, ZeroExt(W - 128, lr - cr), False),
               inv_ok(supply + ZeroExt(W - 128, lr - cr), lr, lr, crest)))

# ---------------------------------------------------------------------------
# MATH-UO-31  The equalities are load-bearing: any mismatch breaks the invariants.
ub, ud = BitVec('u_burned', 128), BitVec('u_debited', 128)
# MATH-UO-31 verifies: SPEC-BACK-007, SPEC-UNIT-002
witness('MATH-UO-31a', 'why the equality is checked: burn != debit (e.g. burn what was received, debit what Aave reported) breaks supply == sum credited',
        inv + [ULE(ub, cr), ULE(ud, cr), ub != ud,
               Not(inv_ok(supply - ZeroExt(W - 128, ub), cr - ud, lr - ud, crest))])
ul = BitVec('u_liquidity_removed', 128)
# MATH-UO-31 verifies: SPEC-BACK-007, SPEC-BACK-010
witness('MATH-UO-31b', 'why the equality is checked: removing more liquidity than debited (u_liq > u_debit) breaks l_r >= c_r when no donation covers it',
        inv + [lr == cr, ULE(ud, cr), ULE(ul, lr), UGE(ul, ud + 1), Not(ULE(cr - ud, lr - ul))])

# ---------------------------------------------------------------------------
# MATH-UO-32  Debit check vs Hub share rounding (VIRTUAL_ASSETS = VIRTUAL_SHARES = 1e6).
#   seized shares k come off the proxy; LPVaultSwap receives previewRemoveByShares(k) = floor(k*(A+1e6)/(S+1e6)).
#   SPEC-BACK-007 requires sharesBefore - sharesAfter == u and checks getAddedAssets == getAddedShares
#   at beginSeizure.
s, k, rcv, bef, aft = Ints('proxyShares seizedShares received assetsBefore assetsAfter')
VA = 10 ** 6


def fl(qv, num, den):
    """qv == floor(num / den) for a positive constant or term den."""
    return [qv * den <= num, num < qv * den + den]


# (a) shares == assets: the conversion factor (A+1e6)/(S+1e6) is exactly 1. Two steps, each decidable:
M, kr, qr = Reals('M k q')
# MATH-UO-32 verifies: SPEC-BACK-007
prove('MATH-UO-32a-i', 'lemma: q*M <= k*M < (q+1)*M with M > 0  =>  q <= k < q+1',
      [M > 0, qr * M <= kr * M, kr * M < (qr + 1) * M], And(qr <= kr, kr < qr + 1))
# MATH-UO-32 verifies: SPEC-BACK-007
prove('MATH-UO-32a', 'shares == assets (checked at beginSeizure): received == shares removed and the proxy asset drop == received, so the exact debit check passes',
      [s >= 1, k >= 1, k <= s, rcv <= k, k < rcv + 1, bef <= s, s < bef + 1, aft <= s - k, s - k < aft + 1],
      And(rcv == k, bef - aft == k))
# (b), (c) shares != assets: 0.1% drift on a reserve with 1e18 shares (A = 1.001 * S)
SH = 10 ** 18
AS = SH + 10 ** 15
hub = [s >= 1, k >= 1, k <= s, s <= SH]
conv = fl(rcv, k * (AS + VA), SH + VA) + fl(bef, s * (AS + VA), SH + VA) + fl(aft, (s - k) * (AS + VA), SH + VA)
# MATH-UO-32 verifies: SPEC-BACK-007
witness('MATH-UO-32b', "why beginSeizure requires shares == assets: with 0.1% drift the received units differ from the proxy's asset drop",
        hub + conv + [rcv != bef - aft])
# MATH-UO-32 verifies: SPEC-BACK-007
witness('MATH-UO-32c', 'why beginSeizure requires shares == assets: received units differ from the shares removed (a check in shares also fails)',
        hub + conv + [rcv != k])

# ---------------------------------------------------------------------------
# MATH-UO-33  Supply bound: sum credited <= sum live full-range liquidity <= maxLiquidityPerTick(s) < 2^120.
lines = [f'spacing {sp:3d}: total credited units <= {max_liquidity_per_tick(sp):.3e} < 2^120 = {U120:.3e}'
         for sp in TICK_SPACINGS]
# MATH-UO-33 verifies: SPEC-UNIT-006, SPEC-BACK-009
note('MATH-UO-33', 'vault-token supply and Hub uint120 shares cannot overflow for standard fee tiers', '\n'.join(lines))

finish()
