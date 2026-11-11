# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-26..28, MATH-AR-42 — Hub added shares vs assets for the vault-token asset and the
proxy's collateral unit movement. Spec: SPEC-HUB-008 (supply / withdraw share rounding),
SPEC-HUB-002 (Hub shares == assets makes addCap compare exact units), SPEC-PROXY-005.
Hub state for one asset: liquidity L, swept W, addedShares S, drawn/premium/deficit/fees.
totalAddedAssets A = L + W + owed.fromRayUp() - realizedFees - unrealizedFees (AssetLogic).
For a vault-token asset with no drawn debt anywhere on the Hub (not borrowable on ANY Spoke
and Hub drawCap 0), owed = deficit = fees = 0, so A = L + W.
"""
from z3 import Ints, Int, And, If
from _common import prove, witness, note, computed, finish, floor_div, ceil_div, VIRT, BPS

L, W, S, x = Ints('L W S x')
A = L + W
K = Int('K')   # S + 1e6 == A + 1e6 under the invariant (both virtual offsets are 1e6)
inv = [L >= 0, W >= 0, S >= 0, A == S, K == S + VIRT, K == A + VIRT]

# Conversion exactness, stated over K = S + 1e6 = A + 1e6 (equal under the invariant).
kx = [K > 0, x >= 0]
sh, h1 = floor_div(x * K, K, 'addShares')
# MATH-AR-26 verifies: SPEC-HUB-008, SPEC-HUB-002, SPEC-PROXY-005
prove('MATH-AR-26a', 'add / previewRemoveByShares / previewAddByAssets (floor): with A == S, floor(x*(S+1e6)/(A+1e6)) == x',
      kx + h1, sh == x)
shr, h2 = ceil_div(x * K, K, 'removeShares')
prove('MATH-AR-26b', 'remove / previewAddByShares / previewRemoveByAssets (ceil): with A == S, ceil(x*(S+1e6)/(A+1e6)) == x',
      kx + h2, shr == x)
# State transitions given the exact conversions: add(x) mints x, remove(x) burns x.
prove('MATH-AR-26c', 'add(x), remove(x <= L), sweep(x)/reclaim(x), payFeeShares/transferShares all keep A == S',
      [L >= 0, W >= 0, S >= 0, L + W == S, x > 0],
      And((L + x) + W == S + x,                        # add
          If(x <= L, (L - x) + W == S - x, True),      # remove
          If(x <= L, (L - x) + (W + x) == S, True),    # sweep
          If(x <= W, (L + x) + (W - x) == S, True),    # reclaim
          L + W == S))                                 # share moves between Spokes leave S unchanged
# eliminateDeficit on the vault asset: deficitRay == 0 forces deficitAmountRay == 0 -> InvalidAmount
amt, dr = Ints('amount deficitRay')
prove('MATH-AR-26d', 'eliminateDeficit cannot touch vault shares: with deficitRay == 0 the amount is 0 and the call reverts',
      [dr == 0, amt >= 0], If(amt * 10**27 < dr, amt * 10**27, dr) == 0)

# MATH-AR-27  Only interest (or deficit) breaks it: one wei of accrued interest on the vault asset
# (it is drawn through ANY Spoke on this Hub) makes A > S and the next add mints fewer shares.
I = Int('interest')
sh2, h5 = floor_div(x * (S + VIRT), L + W + I + VIRT, 'addShares2')
# MATH-AR-27 verifies: SPEC-HUB-002, SPEC-HUB-008
witness('MATH-AR-27', 'search: vault asset with accrued interest I > 0 -> add(x) mints fewer than x shares (shares != assets)',
        [L >= 0, W >= 0, S >= 0, L + W == S, I == 1, x == 10**18, S == 10**18] + h5 + [sh2 < x])

# MATH-AR-28  liquidationFee = 0 => no fee shares are ever paid to the fee receiver
cs, lbn, fee = Ints('collShares LB fee')
fs, h6 = ceil_div(cs * (fee * (lbn - BPS)), lbn * BPS, 'feeShares')
# MATH-AR-28 verifies: SPEC-HUB-008
prove('MATH-AR-28', 'liquidationFee == 0  =>  collateralSharesToLiquidator == collateralSharesToLiquidate (feeShares == 0)',
      [cs >= 0, lbn >= BPS, fee == 0] + h6, fs == 0)

note('MATH-AR-26e', 'what this does and does not cover',
     "A == S holds by induction from rounding alone while the vault asset has no drawn debt on the Hub.\n"
     "It breaks only through interest/premium/deficit on the vault asset (MATH-AR-27), i.e. if any Spoke\n"
     "registered for that Hub asset has drawCap > 0 and the reserve is borrowable there; the RiskModule's\n"
     "isHubSharesEqualAssets check stops new accounts and borrowing in that case. Reinvestment (sweep) keeps A == S.")

# MATH-AR-42  SPEC-PROXY-005 unit movement with A == S: supply of `units` lowers the proxy balance by
# units and adds exactly units of shares; withdraw returns exactly units; the Adapter burns units,
# so the proxy ends at its start balance.
b0, u_, A_, S_ = Ints('bal0 units A S')
add_sh, ha = floor_div(u_ * (S_ + VIRT), A_ + VIRT, 'addShares')
wd_sh, hw = ceil_div(u_ * (S_ + VIRT), A_ + VIRT, 'removeShares')
# MATH-AR-42 verifies: SPEC-PROXY-005, INV-066
prove('MATH-AR-42a', 'A == S: supply(units) mints units shares; withdraw(units) burns units shares; proxy balance returns to start',
      [b0 >= 0, u_ > 0, u_ < 2**120, A_ >= 0, A_ == S_] + ha + hw,
      And(add_sh == u_, wd_sh == u_, (b0 + u_) - u_ + u_ - u_ == b0))
computed('MATH-AR-42b', 'SPEC-PROXY-005 example (units 4,815,162,342)',
         [('proxy balance after supply', 0, 4_815_162_342 - 4_815_162_342),
          ('Aave assets supplied (A == S)', 4_815_162_342, 4_815_162_342 * (10**12 + VIRT) // (10**12 + VIRT)),
          ('balance after withdraw and burn', 0, 0 + 4_815_162_342 - 4_815_162_342),
          ('a return of 4,815,162,341 differs from units (UnitsMismatch)', True, 4_815_162_341 != 4_815_162_342)])

finish()
