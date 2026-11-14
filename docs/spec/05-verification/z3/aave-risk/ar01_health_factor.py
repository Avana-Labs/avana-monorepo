# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-01..05, MATH-AR-32..35 — LP collateral factor, account health factor over several
collateral markets and debt reserves, and borrowing capacity, in Aave V4's exact units and
rounding (Spoke._processUserAccountData, Spoke._validateDynamicReserveConfig).

Spec: SPEC-HUB-001 / SPEC-CF-001 (CF_LP = floor(min(CF0, CF1) x poolRiskFactor / 1e4) and
capacity B), SPEC-HUB-005(a) / SPEC-CF-002 (bonus bound), SPEC-HUB-008 (rounding of the Aave
calls), SPEC-PROXY-006 (health factor over several reserves).
"""
from z3 import Int, Ints, Reals, And, Or, If
from _common import (prove, computed, finish, floor_div, ceil_div, WAD, RAY, BPS)
import _v4ref as v4

# ---------------------------------------------------------------------------
# MATH-AR-01  CF = floor(min(CF0, CF1) x poolRiskFactor / 1e4) never exceeds the exact product
#             and is at most 1 bps below it.
cf0, cf1, prf = Ints('cf0 cf1 prf')
m = If(cf0 < cf1, cf0, cf1)
cf, h = floor_div(m * prf, BPS, 'cf')
hyps = [cf0 > 0, cf0 < BPS, cf1 > 0, cf1 < BPS, prf > 0, prf <= BPS] + h
# MATH-AR-01 verifies: SPEC-HUB-001, SPEC-CF-001, Q-020, Q-186
prove('MATH-AR-01a', 'CF_bps * 1e4 <= min(CF0,CF1) * prf  (rounded down, never above the formula)',
      hyps, cf * BPS <= m * prf)
prove('MATH-AR-01b', 'CF_bps is at most 1 bps below the exact product',
      hyps, m * prf - cf * BPS < BPS)
prove('MATH-AR-01c', 'CF_bps <= min(CF0, CF1) (the pool risk factor never raises CF)',
      hyps, cf <= m)
prove('MATH-AR-01d', 'min(CF0,CF1) x prf < 1e8: the product fits, and CF_bps < 1e4',
      hyps, And(m * prf < BPS * BPS, cf < BPS))

# ---------------------------------------------------------------------------
# MATH-AR-02  Listing bound: percentMulUp(maxLB, CF) < 1e4  <=>  maxLB*CF <= 99,990,000.
#             With it, at HF >= 1 the collateral covers debt x maxLB.
lb, cfv = Ints('lb cfv')
pm, hp = ceil_div(lb * cfv, BPS, 'pm')
hyps2 = [lb >= BPS, lb <= 2 * BPS, cfv > 0, cfv < BPS] + hp
# MATH-AR-02 verifies: SPEC-HUB-005, SPEC-CF-002, Q-060
prove('MATH-AR-02a', 'percentMulUp(maxLB, CF) < 1e4  <=>  maxLB*CF <= 99,990,000',
      hyps2, (pm < BPS) == (lb * cfv <= (BPS - 1) * BPS))
Cr, Dr, lbr, cfr = Reals('Cr Dr lbr cfr')
prove('MATH-AR-02b', 'bound holds (maxLB*CF <= 0.9999) and HF >= 1  =>  collateral value >= debt x maxLB x 1.0001',
      [lbr >= 1, cfr > 0, cfr < 1, lbr * cfr <= 0.9999, Cr > 0, Dr > 0, Cr * cfr >= Dr],
      Cr >= Dr * lbr * 1.0001)
best = max(c for c in range(1, BPS) if v4.percent_mul_up(10500, c) < BPS)
best110 = max(c for c in range(1, BPS) if v4.percent_mul_up(11000, c) < BPS)
computed('MATH-AR-02c', 'SPEC-CF-002 / SPEC-HUB-005(a) figures and the largest listable CF',
         [('ceil(10,500 x 3,000 / 1e4) (SPEC-CF-002)', 3150, v4.percent_mul_up(10500, 3000)),
          ('ceil(10,500 x 3,120 / 1e4) (SPEC-HUB-005)', 3276, v4.percent_mul_up(10500, 3120)),
          ('largest CF with maxLB 10,500', 9522, best),
          ('largest CF with maxLB 11,000', 9090, best110)])

# ---------------------------------------------------------------------------
# MATH-AR-03  Health factor: hf = floor(W*1e14*RAY / totalDebtValueRay), W = sum_m CF_m * V_m,
#             totalDebtValueRay = sum_r DV_r * RAY over every debt reserve (SPEC-PROXY-006).
#             hf >= k (any WAD threshold k)  <=>  W*1e14*RAY >= k*totalDebtValueRay exactly.
W, dv, k = Ints('W dv k')
hf, hh = floor_div(W * (WAD // BPS) * RAY, dv, 'hf')
hyps3 = [W >= 0, dv > 0, k >= 0] + hh
# MATH-AR-03 verifies: SPEC-HUB-008, SPEC-PROXY-006, SPEC-PROXY-001, SPEC-CF-003
prove('MATH-AR-03a', 'hf >= k  <=>  sum(CF*value)*1e14*RAY >= k*debtValueRay (the floor loses nothing at integer thresholds)',
      hyps3, (hf >= k) == (W * (WAD // BPS) * RAY >= k * dv))
prove('MATH-AR-03b', 'reported hf never exceeds the exact ratio (rounded against the user)',
      hyps3, hf * dv <= W * (WAD // BPS) * RAY)
s_, A, S = Ints('s A S')
amt, ha = floor_div(s_ * (A + 10**6), S + 10**6, 'amt')
prove('MATH-AR-03c', 'collateral amount = previewRemoveByShares(shares) <= exact shares*(A+1e6)/(S+1e6)',
      [s_ >= 0, A >= 0, S >= 0] + ha, amt * (S + 10**6) <= s_ * (A + 10**6))
a_, idx = Ints('a idx')
ds, hd = ceil_div(a_ * RAY, idx, 'ds')
prove('MATH-AR-03d', 'borrowed amount is fully counted as debt: drawnShares*index >= amount*RAY',
      [a_ > 0, idx >= RAY] + hd, ds * idx >= a_ * RAY)

# ---------------------------------------------------------------------------
# MATH-AR-04  Capacity B = sum_m V_m x CF_m / 1e4 is the total debt value (every reserve) at which
#             hf reaches 1 (SPEC-CF-001), for two collateral markets and two debt reserves of
#             different decimals; and the SPEC-CF-001 example.
VA_, VB_, cA, cB, qG, qU, PU = Ints('VA VB cfA cfB qGHO qUSDC pUSDC')
DVG = qG * 10**8                    # GHO: 18 decimals, $1.00 fixed source
DVU = qU * PU * 10**12              # USDC: 6 decimals
hf4, h4 = floor_div((VA_ * cA + VB_ * cB) * (WAD // BPS) * RAY, (DVG + DVU) * RAY, 'hf4')
# MATH-AR-04 verifies: SPEC-CF-001, SPEC-PROXY-006
prove('MATH-AR-04a', 'two markets, GHO + USDC debt: hf >= 1e18  <=>  DV_GHO + DV_USDC <= B (B = sum V_m CF_m / 1e4)',
      [VA_ >= 0, VB_ >= 0, cA > 0, cA < BPS, cB > 0, cB < BPS, qG >= 0, qU >= 0, PU > 0,
       DVG + DVU > 0] + h4,
      (hf4 >= WAD) == ((DVG + DVU) * BPS <= VA_ * cA + VB_ * cB))
VA = 25_000_000_000 * 200_000_000 * 10**12          # market A, d = 6, $2.00
VB = 15 * 10**15 * 200_000_000 * 10**6              # market B, d = 12, $2.00
Bv = (VA * 3120 + VB * 3000) // BPS
usdc_room = 1660166 * 10**4                         # 16,601.66 USDC
computed('MATH-AR-04b', 'SPEC-CF-001 example: B = $24,600; 8,000 GHO + 16,601.66 USDC at $0.9999 exhaust it',
         [('B in Aave Value (1e26 = $1)', 24_600 * 10**26, Bv),
          ('hf >= 1 with 8,000 GHO + 16,601.66 USDC', True,
           v4.health_factor([(25_000_000_000, 6, 200_000_000, 3120), (15 * 10**15, 12, 200_000_000, 3000)],
                            [(8000 * 10**18 * RAY, 18, 10**8), (usdc_room * RAY, 6, 99_990_000)])[0] >= WAD),
          ('one more cent of USDC passes hf 1', False,
           v4.health_factor([(25_000_000_000, 6, 200_000_000, 3120), (15 * 10**15, 12, 200_000_000, 3000)],
                            [(8000 * 10**18 * RAY, 18, 10**8), ((usdc_room + 10**4) * RAY, 6, 99_990_000)])[0] >= WAD)])

# ---------------------------------------------------------------------------
# MATH-AR-05  No overflow on the HF path: account collateral <= $1e15, debt <= 1e15 units at
#             18 decimals, index <= 1000 RAY, vault decimals 6..18, price <= $1e6 per whole token.
amt5, price5, dec_pow, cf5, dshares, idx5 = Ints('amt5 price5 dec_pow cf5 dshares idx5')
val = amt5 * price5 * dec_pow
U256 = 2**256
hyps5 = [amt5 >= 0, price5 > 0, price5 <= 10**14, Or(*[dec_pow == 10**(18 - d) for d in range(6, 19)]),
         val <= 10**15 * 10**26, cf5 > 0, cf5 < BPS, dshares >= 0, dshares <= 10**15 * 10**18,
         idx5 >= RAY, idx5 <= 1000 * RAY]
# MATH-AR-05 verifies: SPEC-PROXY-006, SPEC-HUB-008
prove('MATH-AR-05a', 'CF*value*1e14 (bpsToWad) < 2^256 for collateral <= $1e15',
      hyps5, cf5 * val * (WAD // BPS) < U256)
prove('MATH-AR-05b', 'debtRay*price (toValue of debt) < 2^256 for debt <= 1e15 units, index <= 1000x',
      hyps5, dshares * idx5 * 10**8 < U256)

# ---------------------------------------------------------------------------
# MATH-AR-32  SPEC-HUB-001 / SPEC-CF-001 worked figures.
# MATH-AR-32 verifies: SPEC-HUB-001, SPEC-CF-001
computed('MATH-AR-32', 'LP collateral factor examples',
         [('USDC 7,800 / USDT 7,500, prf 3,750 -> 2,812 (2,812.5 floored)', 2812, min(7800, 7500) * 3750 // BPS),
          ('both legs 7,800, prf 4,000 (registry ceiling) -> 3,120', 3120, 7800 * 4000 // BPS),
          ('7,800 / 7,500, prf 4,000 -> 3,000', 3000, min(7800, 7500) * 4000 // BPS)])

# ---------------------------------------------------------------------------
# MATH-AR-33  SPEC-PROXY-006 and the Adapter / borrow-flow worked examples, in V4 integers.
collA = (25_000_000_000, 6, 200_000_000, 3120)
collB = (15 * 10**15, 12, 200_000_000, 3000)


def usdc(units):
    return (units * RAY, 6, 99_990_000)


gho8k = (8000 * 10**18 * RAY, 18, 10**8)
# MATH-AR-33 verifies: SPEC-PROXY-006, SPEC-PROXY-001, BOR-011
computed('MATH-AR-33', 'multi-reserve and single-market health factors (SPEC-PROXY-006, SPEC-PROXY-001, 3.2 Borrow)',
         [('V_A', 5 * 10**30, VA), ('V_B', 3 * 10**30, VB),
          ('GHO debt value 8,000e18 x 1e8', 8 * 10**29, 8000 * 10**18 * 10**8),
          ('USDC debt value 5,000e6 x 99,990,000 x 1e12', 49995 * 10**25, 5000 * 10**6 * 99_990_000 * 10**12),
          ('hf after 8,000 GHO', 3_075_000_000_000_000_000, v4.health_factor([collA, collB], [gho8k])[0]),
          ('hf after 8,000 GHO + 5,000 USDC', 1_892_380_476_172_160_467,
           v4.health_factor([collA, collB], [gho8k, usdc(5000 * 10**6)])[0]),
          ('hf with 15,000 USDC instead', 1_069_634_976_194_099_615,
           v4.health_factor([collA, collB], [gho8k, usdc(15000 * 10**6)])[0]),
          ('single market A, 10,000 USDC', 1_560_156_015_601_560_156,
           v4.health_factor([collA], [usdc(10_000 * 10**6)])[0]),
          ('single market A, 14,500 USDC', 1_075_969_665_932_110_452,
           v4.health_factor([collA], [usdc(14_500 * 10**6)])[0])])

# ---------------------------------------------------------------------------
# MATH-AR-34  A debt-asset price rise lowers hf with no collateral move (SPEC-PROXY-006 Why).
P1, P2 = Ints('P1 P2')
hA, hA_ = floor_div(W * (WAD // BPS) * RAY, (qG * 10**8 + qU * P1 * 10**12) * RAY, 'hfP1')
hB, hB_ = floor_div(W * (WAD // BPS) * RAY, (qG * 10**8 + qU * P2 * 10**12) * RAY, 'hfP2')
# MATH-AR-34 verifies: SPEC-PROXY-006
prove('MATH-AR-34', 'USDC price P2 >= P1 (same units, same collateral)  =>  hf(P2) <= hf(P1)',
      [W >= 0, qG >= 0, qU >= 0, P1 > 0, P2 >= P1, qG + qU > 0] + hA_ + hB_, hB <= hA)

# ---------------------------------------------------------------------------
# MATH-AR-35  SPEC-HUB-008 example: 10,000 GHO at drawnIndex 1.05 RAY.
shares = v4.ray_div_up(10_000 * 10**18, 105 * 10**25)
# MATH-AR-35 verifies: SPEC-HUB-008
computed('MATH-AR-35', 'borrow rounding example (drawn shares up, getUserTotalDebt up)',
         [('drawn shares ceil(1e22 / 1.05)', 9_523_809_523_809_523_809_524, shares),
          ('getUserTotalDebt = rayMulUp(shares, 1.05 RAY)', 10_000_000_000_000_000_000_001,
           v4.ray_mul_up(shares, 105 * 10**25))])

finish()
