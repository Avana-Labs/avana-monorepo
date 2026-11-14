# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-51e, MATH-AR-51h..j — The loss layers of a (Hub, debt asset) and the residual beyond them (Q-410).

Aave V4 @ a3ef63e, Hub.eliminateDeficit(assetId, amount, spoke): restricted; deficitAmountRay = amount < ceil(deficitRay)
? amount x RAY : deficitRay; burns shares = toAddedSharesUp(ceil(deficitAmountRay / RAY)) of the CALLER Spoke only.
There is no write-down across suppliers: an uncovered deficit stays in totalAddedAssets = liquidity + drawn + deficit.
Spec: SPEC-FLR-006 (loss order: Avana Umbrella, then the DAO deficit offset), REQ-FLR-027 / DEF-014 (first-come residual),
SPEC-FLR-001 / SPEC-FLR-002 (coverage amount, funded balance), DEF-019 (coverage bound on the line).
Units: asset base units; A', S' the Hub's added assets and shares plus the 1e6 virtual offsets.
"""
from z3 import Ints, Bool, If, And, Or, Not
from _common import prove, witness, computed, finish, floor_div, ceil_div, BPS


def mx(a, b):
    return If(a > b, a, b)


def mn(a, b):
    return If(a < b, a, b)


cl, dec = Ints('creditLine decPow')

# Residual bound (Q-410): deficit <= line (draws stay in the line), Avana Umbrella F_A x 1e4 >= ratio x line (DEF-019),
# DAO deficit offset F_D >= 0; both layers cover first, residual r = max(0, deficit - F_A - F_D). Aave V4 has no write-down,
# so r is not shared pro rata: whoever withdraws last holds it (MATH-AR-51i).
dfc, Fc, FDc, ratio, uncov = Ints('deficit funded fundedD ratioBps uncovered')
b51e = [cl > 0, Or(dec == 10**6, dec == 10**18), dfc >= 0, dfc <= cl * dec, Fc >= 0, FDc >= 0, ratio >= 0, ratio <= BPS,
        Fc * BPS >= ratio * cl * dec, uncov == mx(0, dfc - Fc - FDc)]
# MATH-AR-51 verifies: SPEC-HUB-003, REQ-FLR-027, DEF-014, DEF-019, REQ-ARCH-211
prove('MATH-AR-51e', 'the residual beyond both loss layers is at most max(0, line x (1 - coverageRatioBps / 1e4) - F_D)',
      b51e, uncov * BPS <= mx(0, cl * dec * (BPS - ratio) - FDc * BPS))

# MATH-AR-51h  SPEC-FLR-006 loss order: the Avana Umbrella pays c_A = min(m_A, d, F_A) while it is active on the Hub
# (deactivated, its eliminateDeficit reverts SpokeNotActive, so c_A = 0); the DAO deficit offset is refused while the
# Umbrella is active with a balance after its call above 0, and otherwise pays c_D = min(m_D, d - c_A, F_D) (Q-410).
d51, fa, fd, ma, md, ca, cd, fa1 = Ints('deficitUnits fundedA fundedD maxA maxD coveredA coveredD fundedAAfter')
act = Bool('umbrellaActive')
b51h = [d51 >= 0, fa >= 0, fd >= 0, ma >= 1, md >= 1, ca == If(act, mn(mn(ma, d51), fa), 0), fa1 == fa - ca,
        cd == If(Or(fa1 == 0, Not(act)), mn(mn(md, d51 - ca), fd), 0)]
# MATH-AR-51h verifies: SPEC-FLR-006, REQ-FLR-048, INV-100
prove('MATH-AR-51h', 'while the Avana Umbrella is active the DAO offset pays only after it paid all it held; together they never exceed the deficit',
      b51h, And(Or(cd == 0, ca == fa, Not(act)), ca + cd <= d51, ca >= 0, cd >= 0))
prove('MATH-AR-51h2', 'active Umbrella, both limits at least the deficit: the residual is max(0, d - F_A - F_D)',
      b51h + [act, ma >= d51, md >= d51], d51 - ca - cd == mx(0, d51 - fa - fd))
witness('MATH-AR-51h3', 'no state in which the offset pays while the Avana Umbrella is active and keeps a balance',
        b51h + [act, cd > 0, fa1 > 0], expect='PROVED')
prove('MATH-AR-51h5', 'deactivated Umbrella (Q-410 trade-off): the offset pays min(d, F_D) and the Umbrella keeps all of F_A',
      b51h + [Not(act), md >= d51], And(ca == 0, cd == mn(d51, fd), fa1 == fa))
computed('MATH-AR-51h4', 'SPEC-FLR-006 / TEST-299 example (GHO): d 300,000, F_A 100,000, F_D 150,000',
         [('c_A', 100_000, min(300_000, 100_000)), ('c_D', 150_000, min(300_000 - 100_000, 150_000)),
          ('residual', 50_000, 300_000 - 100_000 - 150_000)])

# MATH-AR-51i  REQ-FLR-027 / DEF-014 first-come residual: after full repayment liquidity is claims - r; lenders withdraw
# in order, each paid min(claim, liquidity left). Losses sum to r and any one lender can hold all of it.
c1, c2, r51 = Ints('claim1 claim2 residual')
liq51 = c1 + c2 - r51
paid1 = mn(c1, liq51)
paid2 = mn(c2, liq51 - paid1)
b51i = [c1 >= 0, c2 >= 0, r51 >= 0, r51 <= c1 + c2]
# MATH-AR-51i verifies: REQ-FLR-027, DEF-014, ATTACK-198
prove('MATH-AR-51i', 'first-come: the two lenders lose exactly r between them, each at most min(its claim, r)',
      b51i, And((c1 - paid1) + (c2 - paid2) == r51, c1 - paid1 <= mn(c1, r51), c2 - paid2 <= mn(c2, r51),
                c1 - paid1 >= 0, c2 - paid2 >= 0))
prove('MATH-AR-51i2', 'the first lender is paid in full whenever its claim fits the liquidity; the last holds the residual',
      b51i + [c1 <= liq51], And(paid1 == c1, c2 - paid2 == r51))
computed('MATH-AR-51i3', 'DEF-014 / TEST-299 example: claims 2,000,000 GHO, residual 50,000',
         [('liquidity after full repayment', 1_950_000, 2_000_000 - 50_000),
          ('first 1,950,000 of claims paid in full', 1_950_000, min(1_950_000, 1_950_000)),
          ('last 50,000 of claims unpaid', 50_000, 50_000 - min(50_000, 1_950_000 - 1_950_000)),
          ('backed value per share x 1e3 (2,000,000 shares)', 975, (2_000_000 - 50_000) * 1000 // 2_000_000)])

# MATH-AR-51j  SPEC-FLR-006 exhausted layer keeps no share: holding s shares, covering F = floor(s A' / S') burns
# ceil(F S' / A') = s shares when A' >= S' (A' = A + 1e6, S' = S + 1e6; the share price never falls below 1).
sh51, Ap, Sp = Ints('layerShares assetsVirt sharesVirt')
F51, hF = floor_div(sh51 * Ap, Sp, 'fundedBalance')
B51, hB = ceil_div(F51 * Sp, Ap, 'burnedShares')
b51j = [sh51 >= 1, sh51 < 2**120, Sp >= 10**6, Sp < 2**120, Ap >= Sp, Ap < 2**128, sh51 <= Sp] + hF + hB
# MATH-AR-51j verifies: SPEC-FLR-006, SPEC-FLR-001, SPEC-FLR-002, INV-100
prove('MATH-AR-51j', 'covering the whole funded balance burns exactly every share the layer holds (no dust left)',
      b51j, B51 == sh51)

finish()
