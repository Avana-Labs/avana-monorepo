# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-06..08, MATH-AR-36..37 — Post-action health gate, recommended borrow and opening debt bound.

Spec: SPEC-PROXY-001 (pass <=> hfEx >= max(1.00, hardHealthFloor, minHealthFactor); Q-398 removed
the on-chain opening floors, the per-market hard floor is optional and 0 (off) by default, and the Lens
previews a recommended borrow at HF 1.10 beside the maximum at Aave's HF 1.00), SPEC-CF-005 (hfEx = hf - ceil(E x WAD x RAY / totalDebtValueRay), saturating
at 0, E = sum_m ceil(u_m p_m CF_m 1e18 / (10^d_m 1e4))), SPEC-CF-003 (opening debt bound).

Model: after Spoke.borrow / withdraw-with-debt / removal-with-debt returns, the RiskModule reads
Spoke.getUserAccountData(proxy) in the same call (same index, prices and refreshed dynamic keys)
and Collateralization's rescue units left on the account.
W = sum_m CF_m x V_m (bps x Aave Value), dv = totalDebtValueRay (Aave Value x RAY).
"""
import math
from z3 import Ints, If, And
from _common import prove, witness, note, computed, finish, floor_div, ceil_div, WAD, RAY, BPS

FLOOR = WAD                   # Aave's liquidation threshold, HF 1.00: the only floor always applied (Q-398)
MIN_OPEN = 110 * 10**16       # recommended HF 1.10 of the Lens preview (not enforced on-chain)

W, dv, E, pol, mhf = Ints('W dv E hardFloor minHF')
hf, h = floor_div(W * (WAD // BPS) * RAY, dv, 'hf')
sub, hs = ceil_div(E * WAD * RAY, dv, 'sub')
hfEx = If(hf > sub, hf - sub, 0)
base = [W >= 0, dv > 0, E >= 0, pol >= 0, mhf >= 0] + h + hs
req = If(If(pol > FLOOR, pol, FLOOR) > mhf, If(pol > FLOOR, pol, FLOOR), mhf)
gate = hfEx >= req
exact_ex = (W * (WAD // BPS) - E * WAD) * RAY       # exact (CF-weighted collateral - E) x WAD x RAY

# MATH-AR-06 verifies: SPEC-PROXY-001, SPEC-CF-003, SPEC-CF-005, Q-161, Q-229, Q-398
prove('MATH-AR-06a', 'gate passes with a hard floor set to 1.10  =>  exact (collateral - rescue)/debt >= 1.10',
      base + [pol == MIN_OPEN, gate], exact_ex >= MIN_OPEN * dv)
prove('MATH-AR-06b', 'hard floor off (0, default) and minHealthFactor 0: gate passes  =>  exact ratio >= 1.00',
      base + [gate], exact_ex >= FLOOR * dv)
witness('MATH-AR-06c', 'search: hfEx >= 1.10 while the exact rescue-excluded ratio is below 1.10',
        base + [hfEx >= MIN_OPEN, exact_ex < MIN_OPEN * dv], expect='PROVED')
prove('MATH-AR-06d', 'gate passes  =>  exact ratio >= max(1.00, hardFloor, minHealthFactor) (SPEC-CF-003 bound sum DV <= B / max)',
      base + [gate], exact_ex >= req * dv)

# MATH-AR-07  The debt used in hf includes the full draw rounding.
a, idx = Ints('a idx')
ds, hd = ceil_div(a * RAY, idx, 'ds')
# MATH-AR-07 verifies: SPEC-HUB-008, SPEC-PROXY-004, SPEC-CF-003
prove('MATH-AR-07', 'debt recorded for a borrow of `amount` >= amount (drawnShares*index >= amount*RAY)',
      [a > 0, idx >= RAY, idx < 2**120] + hd, ds * idx >= a * RAY)

# MATH-AR-08  Interest moves an account across the gate after opening (point-in-time check).
rate, dt = Ints('rate dt')
YEAR = 365 * 24 * 3600
lin, hl = floor_div(rate * dt, YEAR, 'lin')
idx2, hi = ceil_div(RAY * (RAY + lin), RAY, 'idx2')
# MATH-AR-08 verifies: SPEC-CF-003, SPEC-HUB-007
prove('MATH-AR-08a', 'drawn index never decreases on accrual (debt cannot fall from interest)',
      [rate >= 0, dt >= 0] + hl + hi, idx2 >= RAY)
witness('MATH-AR-08b', 'an account opened at hf >= 1.10 can be below 1.10 one accrual later at unchanged prices',
        [rate == 9 * RAY // 100, dt == 3600] + hl + hi +
        [W * (WAD // BPS) * RAY >= MIN_OPEN * (10**21 * RAY),
         W * (WAD // BPS) * RAY < MIN_OPEN * (10**21 * idx2), W > 0])
rows = []
for r in (0.045, 0.055, 0.09, 0.20):
    for start in (1.10, 1.05):
        days = math.log(start) / math.log(1 + r / 365)
        rows.append(f"rate {r*100:4.1f}%  hf {start:.2f} -> 1.00 in {days:7.1f} days (daily accrual, prices fixed)")
note('MATH-AR-08c', 'time for interest alone to take an account from the recommended HF 1.10 (or 1.05) to liquidation',
     '\n'.join(rows))

# ---------------------------------------------------------------------------
# MATH-AR-36  Rescue units excluded (SPEC-CF-005).
u, p, cfm, dpow = Ints('u p cfm dpow')
Em, he = ceil_div(u * p * cfm * 10**18, dpow * BPS, 'Em')
# MATH-AR-36 verifies: SPEC-CF-005, INV-082
prove('MATH-AR-36a', 'E_m >= exact CF-weighted value of the rescue units (u x p x 10^(18-d) x CF / 1e4)',
      [u >= 0, u < 2**128, p > 0, p < 2**64, cfm > 0, cfm < BPS, dpow >= 10**6, dpow <= 10**18] + he,
      Em * dpow * BPS >= u * p * cfm * 10**18)
prove('MATH-AR-36b', 'hfEx <= hf (excluding rescue units never raises the health factor)', base, hfEx <= hf)
prove('MATH-AR-36c', 'E = 0  =>  hfEx = hf', base + [E == 0], hfEx == hf)
E2 = Ints('E2')[0]
sub2, hs2 = ceil_div(E2 * WAD * RAY, dv, 'sub2')
hfEx2 = If(hf > sub2, hf - sub2, 0)
prove('MATH-AR-36d', 'more rescue value never raises hfEx (E2 >= E  =>  hfEx(E2) <= hfEx(E))',
      base + hs2 + [E2 >= E], hfEx2 <= hfEx)
prove('MATH-AR-36e', 'hfEx >= k > 0  =>  sum DV x k <= (CF-weighted collateral - E): rescue units carry no new debt',
      base + [hfEx >= MIN_OPEN], exact_ex >= MIN_OPEN * dv)


def hf_ex(Wv, Ev, debt_value):
    d = debt_value * RAY
    h_ = Wv * (WAD // BPS) * RAY // d
    s_ = -(-(Ev * WAD * RAY) // d)
    return h_, max(0, h_ - s_)


Ex = -(-(5 * 10**8 * 200_000_000 * 3120 * 10**18) // (10**6 * BPS))
W12k = 12_000 * 10**26 * BPS
hf0, hx0 = hf_ex(W12k, Ex, 10_000 * 10**26)
_, hx1 = hf_ex(W12k, Ex, 1_090_909 * 10**24)
hf2, hx2 = hf_ex(W12k, Ex, 1_062_545 * 10**24)
_, hx3 = hf_ex(W12k, Ex, 1_062_546 * 10**24)
computed('MATH-AR-36f', 'SPEC-CF-005 / INV-082 / 3.2 Borrow rescue example (hf 1.2000, debt $10,000, $1,000 rescue at CF 3,120)',
         [('E = 3.12e28 ($312)', 312 * 10**26, Ex),
          ('subtracted term 0.0312e18', 312 * 10**14, -(-(Ex * WAD * RAY) // (10**57))),
          ('hfEx = 1.1688e18', 11688 * 10**14, hx0),
          ('borrow to debt 10,909.09: hfEx < 1.10e18 (above the recommended borrow)', True, hx1 < MIN_OPEN),
          ('hfEx at 10,909.09 is 1.0714 (4 decimals)', 10714, round(hx1 / 10**14)),
          ('borrow to debt 10,625.45: hfEx >= 1.10e18 (within the recommended borrow)', True, hx2 >= MIN_OPEN),
          ('Aave hf at 10,625.45 is 1.1294 (4 decimals)', 11294, round(hf2 / 10**14)),
          ('debt 10,625.46 is above it (10,625.45 is the largest recommended in cents)', True, hx3 < MIN_OPEN)])

# ---------------------------------------------------------------------------
# MATH-AR-37  SPEC-CF-003 opening-bound figures and the borrow-flow "largest borrow" figures.
collA_W = 25_000_000_000 * 200_000_000 * 10**12 * 3120               # $15,600 of CF-weighted value
collAB_W = collA_W + 15 * 10**15 * 200_000_000 * 10**6 * 3000         # $24,600


def passes(Wv, gho_wei, usdc_units):
    dvv = gho_wei * 10**8 + usdc_units * 99_990_000 * 10**12
    return Wv * (WAD // BPS) * RAY // (dvv * RAY) >= MIN_OPEN


Ht = 1.10 * (1 + 0.05 * 600 / 31_536_000) * 1.005
# MATH-AR-37 verifies: SPEC-CF-003, SPEC-PROXY-001, BOR-011, Q-398
computed('MATH-AR-37', 'Lens recommended borrow at HF 1.10 and maximum at HF 1.00 (SPEC-CF-003; 2.6 and 3.2 worked examples)',
         [('Q-398: $100,000 at CF 70%: recommended 63,636 (HF 1.10, dollars down)', 63_636, 100_000 * 7000 * 10 // (BPS * 11)),
          ('Q-398: $100,000 at CF 70%: maximum 70,000 (HF 1.00)', 70_000, 100_000 * 7000 // BPS),
          ('$22,363.63 = 24,600 / 1.10 rounded down (cents)', 2_236_363, 24_600 * 100 * 10 // 11),
          ('8,000 GHO + 14,365.07 USDC passes', True, passes(collAB_W, 8000 * 10**18, 14_365_070_000)),
          ('8,000 GHO + 14,365.08 USDC fails', False, passes(collAB_W, 8000 * 10**18, 14_365_080_000)),
          ('15,600 / 1.10 / 0.9999 = 14,183.2365 (4 decimals, down)', 141_832_365,
           15_600 * 10**9 // (11 * 9_999)),
          ('largest single-market USDC borrow 14,183.23 meets the recommended HF 1.10', True,
           passes(collA_W, 0, 14_183_230_000)),
          ('14,183.24 USDC is above the recommended borrow', False, passes(collA_W, 0, 14_183_240_000)),
          ('previewBorrowMax target 1.105501 (6 decimals)', 1_105_501, round(Ht * 10**6)),
          ('previewBorrowMax room 572.58 GHO (cents, down)', 57_258, math.floor((11_688 / Ht - 10_000) * 100))],
         )  # F-AR-1 resolved: the spec states 14,183.2365, so 14,183.23 (rounded down; 14,183.24 reverts)

finish()
