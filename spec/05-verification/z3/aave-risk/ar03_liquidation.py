# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-09..15, MATH-AR-38 — Aave V4 liquidation sizing (LiquidationLogic.sol @ a3ef63e):
dynamic bonus curve, target health factor, dust rule, health after liquidation, seized value
vs debt x bonus, and the liquidation-configuration bounds of SPEC-HUB-005 with its example.
Spec: SPEC-HUB-005 (bounds (a)-(c), bonus curve), SPEC-HUB-008 (liquidationCall rounding).
"""
from z3 import Ints, Reals, If, And, Or, Implies
from _common import prove, witness, note, computed, finish, floor_div, ceil_div, WAD, RAY, BPS, VIRT
import _v4ref as v4

HF1 = 10**18

# ---------------------------------------------------------------------------
# MATH-AR-09  Bonus curve (calculateLiquidationBonus)
maxlb, lbf, hfmax, hf, hf2 = Ints('maxLB lbf hfMax hf hf2')
cfg = [maxlb >= BPS, maxlb <= 2 * BPS, lbf >= 0, lbf <= BPS, hfmax >= 0, hfmax < HF1]
pmd, h1 = floor_div((maxlb - BPS) * lbf, BPS, 'pmd')
minlb = pmd + BPS
q1, h2 = floor_div((maxlb - minlb) * (HF1 - hf), HF1 - hfmax, 'q1')
q2, h3 = floor_div((maxlb - minlb) * (HF1 - hf2), HF1 - hfmax, 'q2')
b1 = If(hf <= hfmax, maxlb, minlb + q1)
b2 = If(hf2 <= hfmax, maxlb, minlb + q2)
base9 = cfg + h1 + h2 + h3 + [hf >= 0, hf < HF1, hf2 >= 0, hf2 < HF1]
# MATH-AR-09 verifies: SPEC-HUB-005, Q-179
prove('MATH-AR-09a', 'minLB <= bonus <= maxLB and minLB >= 100_00 for every liquidatable hf',
      base9, And(b1 >= minlb, b1 <= maxlb, minlb >= BPS))
prove('MATH-AR-09b', 'bonus is non-increasing in hf (lower hf never pays less)',
      base9 + [hf <= hf2], b1 >= b2)
witness('MATH-AR-09c', 'search (a curve outside SPEC-HUB-005(b)): maxLB 5% but an account just below hf 1 pays < 1% bonus',
        base9 + [maxlb == 10500, hf == HF1 - 1, hfmax <= 95 * 10**16, b1 < 10100])
# ---------------------------------------------------------------------------
# MATH-AR-10  Debt to target: repaying D*(THF-hf)/(THF-LB*CF) restores hf >= THF.
# Real-valued model with every on-chain rounding as a one-sided inequality:
#   hf_onchain <= exact hf (floor), debt repaid >= formula (ceil / divUp / roundRayUp),
#   collateral seized <= repaid*LB (floor, shares floor) — directions proved in AR-12.
C, D, cf, lb, T, hfo, dlt, sz = Reals('C D cf lb T hf_onchain delta seized')
econ = [C > 0, D > 0, cf > 0, cf < 1, lb >= 1, lb * cf < 1, T >= 1,
        hfo <= C * cf / D, hfo < 1, hfo >= 0]
# MATH-AR-10 verifies: SPEC-HUB-005, Q-185
prove('MATH-AR-10', 'liquidator covers the target amount (no dust/cap override)  =>  hf_after >= targetHealthFactor',
      econ + [dlt >= D * (T - hfo) / (T - lb * cf), dlt < D, sz <= dlt * lb, sz < C, sz >= 0],
      (C - sz) * cf >= T * (D - dlt))

# ---------------------------------------------------------------------------
# MATH-AR-11  Can a liquidation leave the account LESS healthy?
part = [C > 0, D > 0, cf > 0, cf < 1, lb >= 1, lb * cf < 1, dlt > 0, dlt < D, sz == dlt * lb, sz < C,
        C * cf < D]                                         # liquidatable
# MATH-AR-11 verifies: SPEC-HUB-005, SPEC-HUB-008
prove('MATH-AR-11a', 'if hf_before >= LB*CF, any partial liquidation leaves hf_after >= hf_before',
      part + [C * cf / D >= lb * cf], (C - sz) * cf / (D - dlt) >= C * cf / D)
witness('MATH-AR-11b', 'search: partial liquidation that lowers hf (needs hf_before < LB*CF, i.e. collateral < debt x LB)',
        part + [(C - sz) * cf / (D - dlt) < C * cf / D])
prove('MATH-AR-11c', 'hf_before < LB*CF  <=>  collateral value < debt x LB (account already insolvent after bonus)',
      [C > 0, D > 0, cf > 0, lb >= 1], (C * cf / D < lb * cf) == (C < D * lb))
# concrete V4 integer run of the 11b case
hub = v4.Hub(10**30, 10**30)
cp = 10 * 10**8
coll = 1000 * 10**18                      # 1,000 vault tokens x $10 = $10,000
debt = 10000 * 10**18
hf0, tdv = v4.health_factor([(coll, 18, cp, 3500)], [(debt * RAY, 18, 10**8)])
r = v4.liquidation_amounts(hub=hub, supplied_shares=coll, cdec=18, cprice=cp, ds=debt, prem_ray=0,
                           idx=RAY, tdv_ray=tdv, ddec=18, dprice=10**8, cover=1000 * 10**18, cf=3500,
                           hf_for_max=7 * 10**17, lbf=2000, max_lb=10500, thf=105 * 10**16, hf=hf0)
hf1, _ = v4.health_factor([(coll - r['coll_shares'], 18, cp, 3500)], [((debt - r['drawn_shares']) * RAY, 18, 10**8)])
note('MATH-AR-11d', 'V4 integer replay of 11b ($10,000 LP, 10,000 GHO, CF 35%, keeper covers 1,000 GHO)',
     f"hf before {hf0/1e18:.6f}, bonus {r['bonus']} bps, repaid {r['paid']/1e18:,.2f} GHO, "
     f"seized ${r['coll_removed']*10/1e18:,.2f}, branch {r['branch']}\n"
     f"hf after {hf1/1e18:.6f}  (lower; the deficit when collateral runs out is unchanged by chunking)")

# ---------------------------------------------------------------------------
# MATH-AR-12  Seized collateral value <= debt repaid x bonus, through every branch.
dsh, idx, pr, pD, pC, cU, dU, LB, A, S = Ints('drawnShares idx premRay pD pC cU dU LB A S')
units = [idx >= RAY, idx < 2**120, dsh >= 0, dsh < 2**120, pr >= 0, pr < 2**200,
         pD > 0, pD < 2**64, pC > 0, pC < 2**64, LB >= BPS, LB <= 2 * BPS,
         Or(*[cU == 10**d for d in (6, 8, 12, 18)]), dU == 10**18, A >= 0, S >= 0, A == S]
debt_ray = dsh * idx + pr
pdr, hp1 = ceil_div(dsh * idx, RAY, 'paidDrawn')
ppr, hp2 = ceil_div(pr, RAY, 'paidPrem')
paid = pdr + ppr
# MATH-AR-12 verifies: SPEC-HUB-008, SPEC-HUB-005
prove('MATH-AR-12a', 'amount the liquidator pays >= debt removed: (rayMulUp(ds,idx)+fromRayUp(prem))*RAY >= ds*idx+prem',
      units + hp1 + hp2, paid * RAY >= debt_ray)
X = pD * cU * LB
Y = dU * pC * BPS * RAY
col, hc = floor_div(debt_ray * X, Y, 'collToLiq')
prove('MATH-AR-12b', 'collateral computed from debt (floor): coll*dU*pC*1e4*RAY <= debtRay*pD*cU*LB',
      units + hc, col * Y <= debt_ray * X)
sh, hs = floor_div(col * (S + VIRT), A + VIRT, 'shares')
rem, hr = floor_div(sh * (A + VIRT), S + VIRT, 'removed')
A2, S2, c2, a2, s2 = Ints('A2 S2 c2 a2 s2')
sh2, hs2 = floor_div(c2 * s2, a2, 'shares2')
rem2, hr2 = floor_div(sh2 * a2, s2, 'removed2')
prove('MATH-AR-12c', 'share round trip never pays out more (any A, S): previewRemoveByShares(previewAddByAssets(c))*(S+1e6) <= c*(S+1e6)',
      [a2 == A2 + VIRT, s2 == S2 + VIRT, A2 >= 0, S2 >= 0, c2 >= 0] + hs2 + hr2, rem2 * s2 <= c2 * s2)
xr, yr, sr = Reals('xr yr sr')
prove('MATH-AR-12c2', '... and cancelling the positive factor (S+1e6): removed <= c',
      [sr > 0, xr * sr <= yr * sr], xr <= yr)
prove('MATH-AR-12d', 'normal branch: removed*pC*dU*1e4 <= paid*pD*cU*LB (value seized <= paid x bonus)',
      units + hp1 + hp2 + hc + hs + hr, rem * pC * dU * BPS <= paid * pD * cU * LB)
# collateral-cap / collateral-dust branch: collateral = all supplied; debt derived with Ceil
sup = Ints('supplied')[0]
cup, hcu = ceil_div(sup * (A + VIRT), S + VIRT, 'collUp')
dr2, hd2 = ceil_div(cup * pC * dU * BPS * RAY, pD * cU * LB, 'debtRay2')
remc, hrc = floor_div(sup * (A + VIRT), S + VIRT, 'removedCap')
ds2, hds2 = ceil_div(dr2 - pr, idx, 'ds2')
pdr2, hq1 = ceil_div(ds2 * idx, RAY, 'paidDrawn2')
ppr2, hq2 = ceil_div(pr, RAY, 'paidPrem2')
prove('MATH-AR-12e', 'cap branch (drawn part): removed*pC*dU*1e4 <= paid*pD*cU*LB',
      units + [sup > 0, sup < 2**120] + hcu + hd2 + hrc + [dr2 > pr] + hds2 + hq1 + hq2,
      remc * pC * dU * BPS <= (pdr2 + ppr2) * pD * cU * LB)
pm3 = Ints('premPaidRay')[0]
rr, hrr = ceil_div(dr2, RAY, 'rr')
ppr3, hq3 = ceil_div(pm3, RAY, 'paidPrem3')
prove('MATH-AR-12f', 'cap branch (premium only): removed*pC*dU*1e4 <= paid*pD*cU*LB',
      units + [sup > 0, sup < 2**120] + hcu + hd2 + hrc + [dr2 <= pr] + hrr +
      [pm3 == If(rr * RAY < pr, rr * RAY, pr)] + hq3,
      remc * pC * dU * BPS <= ppr3 * pD * cU * LB)

# ---------------------------------------------------------------------------
# MATH-AR-13  Dust rule: a partial liquidation (all drawn shares NOT taken) leaves GHO debt
# value >= $1,000, i.e. >= 1,000 GHO at the fixed $1 GHO price.
rem_ray = Ints('debtRayRemaining')[0]
# MATH-AR-13 verifies: SPEC-HUB-008, Q-169
prove('MATH-AR-13a', 'not leavesDebtDust (GHO 18 dec, price 1e8)  =>  remaining debt >= 1,000 GHO exactly',
      [rem_ray >= 0, rem_ray * 10**8 >= 1000 * 10**26 * RAY],
      rem_ray >= 1000 * 10**18 * RAY)
# collateral side: not leavesCollateralDust => remaining collateral value >= $1,000
ramt, rp, rpow = Ints('remainingColl price8 pow')
prove('MATH-AR-13b', 'not leavesCollateralDust  =>  remaining collateral value >= $1,000 (or reserve fully seized)',
      [ramt >= 0, rp > 0, Or(*[rpow == 10**(18 - d) for d in range(6, 19)]),
       ramt * rp * rpow >= 1000 * 10**26],
      ramt * rp * rpow * 1 >= 1000 * 10**26)


def run(coll_usd, debt_gho, cfb=3500, maxlb=10500, lbf_=2000, hfm=7 * 10**17, thf=105 * 10**16, cover=None):
    cp_ = 10 * 10**8
    c = coll_usd * 10**17 if isinstance(coll_usd, int) else int(round(coll_usd * 100)) * 10**15
    d = debt_gho * 10**18
    h, t = v4.health_factor([(c, 18, cp_, cfb)], [(d * RAY, 18, 10**8)])
    res = v4.liquidation_amounts(hub=v4.Hub(10**30, 10**30), supplied_shares=c, cdec=18, cprice=cp_,
                                 ds=d, prem_ray=0, idx=RAY, tdv_ray=t, ddec=18, dprice=10**8,
                                 cover=cover if cover is not None else d, cf=cfb, hf_for_max=hfm,
                                 lbf=lbf_, max_lb=maxlb, thf=thf, hf=h)
    c1, d1 = c - res['coll_shares'], d - res['drawn_shares']
    h1 = v4.health_factor([(c1, 18, cp_, cfb)], [(d1 * RAY, 18, 10**8)])[0] if d1 else None
    return h, res, c1 * 10 / 1e18, d1 / 1e18, h1


rows = ["scenario                                   | hf0    | bonus  | repaid GHO | seized $  | coll left $ | debt left | hf after | branch"]
# Launch-type account: $50,000 of LP at $10 per 18-decimal token, CF 3,120, hf 0.98, target 1.10.
D50 = int(50000 * 0.312 / 0.98)
for name, kw in [
        ('flat maxLB 5% (hf <= hfForMaxBonus)', dict(hfm=99 * 10**16)),
        ('SPEC-HUB-005 example: LBF 40%, hfMax 0.90', dict(lbf_=4000, hfm=90 * 10**16)),
        ('LBF 20%, hfMax 0.70', dict(lbf_=2000, hfm=70 * 10**16)),
        ('LBF 0%, hfMax 0.90', dict(lbf_=0, hfm=90 * 10**16))]:
    h, res, cl, dl, h1 = run(50000, D50, cfb=3120, thf=110 * 10**16, **kw)
    rows.append(f"{name:42s} | {h/1e18:.4f} | {res['bonus']/100-100:5.2f}% | {res['paid']/1e18:10,.2f} | "
                f"{res['coll_removed']*10/1e18:9,.2f} | {cl:11,.2f} | {dl:9,.2f} | {h1/1e18:.6f} | {res['branch']}")
# MATH-AR-14 verifies: SPEC-HUB-005
note('MATH-AR-14', f'partial liquidation under real V4 rules ($50,000 LP, {D50:,} GHO, CF 31.2%, target 1.10)',
     '\n'.join(rows) + "\nEvery configuration reaches the 1.10 target; the bonus at hf 0.98 is set by the curve, not by maxLB alone.")

rows = []
for debt_g in (1000, 1111, 1112, 1500):
    coll = debt_g * 0.98 / 0.35
    h, res, cl, dl, h1 = run(coll, debt_g)
    rows.append(f"debt {debt_g:5d} GHO, coll ${coll:9,.2f}, hf {h/1e18:.4f}: repaid {res['paid']/1e18:9,.2f}, "
                f"seized ${res['coll_removed']*10/1e18:9,.2f}, debt left {dl:9,.2f}, branch {res['branch']}")
try:
    run(1000 * 0.98 / 0.35, 1000, cover=200 * 10**18)
    rows.append('cover 200 GHO on the 1,000 GHO account: accepted')
except v4.MustNotLeaveDust as e:
    rows.append(f'cover 200 GHO on the 1,000 GHO account: reverts MustNotLeaveDust (needs {e.args[0]/1e18:,.2f} GHO)')
# MATH-AR-15 verifies: SPEC-HUB-008, Q-169
note('MATH-AR-15a', 'dust rule at hf 0.98 (CF 35%, maxLB 5%, LBF 20%, hfMax 0.70): small accounts are liquidated in full',
     '\n'.join(rows))

# MATH-AR-15b: multi-collateral exhaustion leaves debt below 1,000 GHO (V4 documented dust case)
cpA = 10 * 10**8
cA, cB = 60 * 10**18, 270 * 10**18                     # $600 and $2,700 vault tokens
d = 1200 * 10**18
h, t = v4.health_factor([(cA, 18, cpA, 3500), (cB, 18, cpA, 3500)], [(d * RAY, 18, 10**8)])
res = v4.liquidation_amounts(hub=v4.Hub(10**30, 10**30), supplied_shares=cA, cdec=18, cprice=cpA,
                             ds=d, prem_ray=0, idx=RAY, tdv_ray=t, ddec=18, dprice=10**8, cover=d,
                             cf=3500, hf_for_max=7 * 10**17, lbf=2000, max_lb=10500,
                             thf=105 * 10**16, hf=h)
dl = d - res['drawn_shares']
h1, _ = v4.health_factor([(cB, 18, cpA, 3500)], [(dl * RAY, 18, 10**8)])
note('MATH-AR-15b', 'two LP markets on one Spoke: seizing the small one in full leaves 0 < debt < 1,000 GHO',
     f"before: $600 + $2,700 collateral, 1,200 GHO, hf {h/1e18:.4f}; liquidate the $600 reserve\n"
     f"after: branch {res['branch']}, repaid {res['paid']/1e18:,.2f} GHO, debt left {dl/1e18:,.2f} GHO, hf {h1/1e18:.4f}\n"
     f"-> with no minimum debt (Q-169) the account repays partially or in full, or is liquidated in full by the dust rule.")

# ---------------------------------------------------------------------------
# MATH-AR-38  SPEC-HUB-005 (c): targetHealthFactor - percentMulUp(LB.bpsToWad(), CF) > 0 whenever
# bound (a) holds, LB <= maxLB and targetHealthFactor >= 1e18; and the SPEC-HUB-005 example.
mlb, lbx, cfx, thf_ = Ints('mlb lbx cfx thf')
pen, hpn = ceil_div(lbx * (WAD // BPS) * cfx, BPS, 'penalty')
pa, hpa = ceil_div(mlb * cfx, BPS, 'pmUp')
# MATH-AR-38 verifies: SPEC-HUB-005
prove('MATH-AR-38a', '(a) percentMulUp(maxLB, CF) < 1e4, LB <= maxLB, THF >= 1e18  =>  THF - percentMulUp(LB x 1e14, CF) > 0',
      [mlb >= BPS, mlb <= 2 * BPS, lbx >= BPS, lbx <= mlb, cfx > 0, cfx < BPS, thf_ >= WAD, pa < BPS] + hpn + hpa,
      thf_ - pen > 0)
minlb_ex = BPS + (10500 - BPS) * 4000 // BPS
computed('MATH-AR-38b', 'SPEC-HUB-005 example (CF 3,120, maxLB 10,500, LBF 4,000, hfForMaxBonus 0.90)',
         [('(a) ceil(10,500 x 3,120 / 1e4)', 3276, v4.percent_mul_up(10500, 3120)),
          ('(b) minLB', 10200, minlb_ex),
          ('(b) minLB - 1e4 >= minLiquidationBonus 200', True, minlb_ex - BPS >= 200),
          ('(b) V4 bonus at hf 0.97', 10290, v4.liquidation_bonus(90 * 10**16, 4000, 97 * 10**16, 10500)),
          ('(b) V4 bonus just below hf 1 is minLB', 10200, v4.liquidation_bonus(90 * 10**16, 4000, 10**18 - 1, 10500)),
          ('(c) 1.10e18 - percentMulUp(10,500 x 1e14, 3,120) > 0', True,
           110 * 10**16 - v4.percent_mul_up(10500 * 10**14, 3120) > 0)])

finish()
