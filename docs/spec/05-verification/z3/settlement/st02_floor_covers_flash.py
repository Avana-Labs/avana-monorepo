# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-05..13, MATH-ST-113: does the recovery floor cover the debt repaid? (SPEC-LIQ-001..005, SPEC-LIQ-016)

Aave V4 sizing (LiquidationLogic._calculateCollateralToLiquidate, pinned a3ef63e), GHO debt, premium 0,
drawnIndex = RAY:  c = floor(D * Pd * Uc * b / (1e18 * Pc * 1e4))           vault-token units, down
Collateral-driven branch (all collateral seized):
  debtRay = ceil(c * Pc * 1e18 * 1e4 * RAY / (Pd * Uc * b)); shares = ceil(debtRay / idx); D = ceil(shares * idx / RAY)
Avana (text of 2026-11-10, option C, Q-404): LPVaultSwap takes no flash loan in a liquidation, so no premium term.
  bNet     = 1e4 + floor((b - 1e4) * (1e4 - lf) / 1e4)                       SPEC-LIQ-001
  s        = min(allow, floor(1e4 * (bNet - 1e4) / bNet)) if bNet > 1e4, else 0   SPEC-LIQ-002, SPEC-LIQ-003
  V        = floor(c * Pc * 1e18 / (Uc * Pgho))                               SPEC-LIQ-004
  term     = ceil(V * (1e4 - s) / 1e4);  minRec = max(0, term - U - allowance)  SPEC-LIQ-005
Gap = D - term: what the slippage term does not cover. The rounding terms U + allowance add at most U + allowance
to it, which comes out of the caller's payout (SPEC-LIQ-010, SPEC-SET-001). SPEC-LIQ-016: the listing check keeps
maxFlashFeeBps on its right side; ST-13 proves it implies the bound a liquidation needs and keeps the floor's slippage
term above D plus a helper premium of up to maxFlashFeeBps (Aave V3 Pool premium, percentMul half up:
phi = floor((F * f + 5000) / 1e4)).
"""
from z3 import Ints, Reals, And, Or, Not, If
from _common import check, maximize, floor_div, ceil_div, half_up, done, RAY, BPS

E18 = 10**18
PD = 10**8                      # GHO price, 8 decimals ($1, Aave's fixed source)

MARKETS = {                     # name: (vault-token decimals, LPOracle price per whole token, 8 dec)
    "USDC/USDT d6 $2": (6, 2 * 10**8),
    "GHO/USDC d12 $2": (12, 2 * 10**8),
    "USDC/USDT d18 $2.10": (18, 210_000_000),
    "volatile d6 $10": (6, 10 * 10**8),
}


def s_final(bnet, costs, cbuy=0, allow=BPS):
    """SPEC-LIQ-016 / SPEC-LIQ-003 in Python integers."""
    num = bnet * BPS - (BPS + costs) * (BPS + cbuy)
    if num <= 0:
        return 0
    return min(allow, (BPS * num) // (bnet * BPS))


def unit_value(dv, pc):
    """GHO wei value of one vault-token unit, rounded up."""
    return -(-(pc * E18) // (10**dv * PD))


def sizing(D, c, V, term, fee, dv, pc, b, s, f, F=None):
    uc = 10**dv
    F = D if F is None else F
    return (floor_div(c, D * PD * uc * b, E18 * pc * BPS)
            + floor_div(V, c * pc * E18, uc * PD)
            + ceil_div(term, V * (BPS - s), BPS)
            + half_up(fee, F * f, BPS))


D, c, V, term, fee = Ints("D c V term fee")
dom = [D >= 1, D <= 10**26]     # up to 100M GHO repaid in one call

# ---------- ST-05: subtractive bound (bonus - costs), generic reals: wrong reading ----------
beta, s, f, g, Dr = Reals("beta s f g Dr")
gen = [beta > 0, beta <= 0.25, f >= 0, f <= 0.01, g >= 0, g <= 0.01, Dr > 0]
# MATH-ST-05 verifies: SPEC-LIQ-003, Q-159
check("MATH-ST-05",
      "wrong reading: subtractive bound s = bonus lets the slippage term fall below D "
      "(counterexample expected)",
      gen + [f == 0, g == 0, s == beta, s >= 0, (1 + beta) * (1 - s) < 1],
      "COUNTEREXAMPLE", show=[beta, s])

# ---------- ST-06: multiplicative bound, generic reals, rounding as error terms ----------
e1, u, feeR, termR, cb = Reals("e1 u feeR termR cBuy")
# MATH-ST-06 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-016, LIQ-060, Q-159, Q-085
check("MATH-ST-06",
      "(1+bNet)(1-s) >= (1+f)(1+cBuy) => G + fee - term <= u + 1/2 for G <= D(1+cBuy), V >= D(1+bNet) - u "
      "(f = cBuy = 0: the liquidation bound of SPEC-LIQ-003; f > 0: a helper premium at the listing bound, SPEC-LIQ-016)",
      [beta > 0, beta <= 1, f >= 0, f <= 0.05, cb >= 0, cb <= 0.03, Dr > 0, u >= 0, e1 >= 0, e1 <= u,
       s >= 0, s < 1, (1 + beta) * (1 - s) >= (1 + f) * (1 + cb),
       feeR <= Dr * (1 + cb) * f + 0.5, termR >= (Dr * (1 + beta) - e1) * (1 - s),
       Dr * (1 + cb) + feeR - termR > u + 0.5],
      "PROVED")

# ---------- ST-07 / ST-08: exact integer gap per market, final s vs subtractive s ----------
for name, (dv, pc) in MARKETS.items():
    for (b, fbps) in [(10_200, 0), (10_250, 0), (10_500, 0), (10_100, 0), (10_050, 0)]:
        uv = unit_value(dv, pc)
        # no premium in a liquidation (Q-404): fee = 0 and s has no cost term
        cases = [(s_final(b, 0, 0, 100), [fee == 0])]
        for ss, side in cases:
            cons = dom + sizing(D, c, V, term, fee, dv, pc, b, ss, fbps) + side
            # MATH-ST-07 verifies: SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, Q-159, Q-085, Q-404
            check("MATH-ST-07",
                  f"[{name}] bonus {b}: s={ss}bps => D - term <= 1 unit ({uv} wei) + 1",
                  cons + [D + fee - term > uv + 1],
                  "PROVED")
        ss = cases[-1][0]
        sq = b - BPS
        if sq > ss:
            consq = dom + sizing(D, c, V, term, fee, dv, pc, b, sq, fbps)
            # MATH-ST-08 verifies: SPEC-LIQ-003, Q-159
            check("MATH-ST-08",
                  f"[{name}] bonus {b}: wrong reading s = bonus = {sq}bps leaves "
                  f"gap > 1 GHO at D <= 1M GHO (counterexample expected)",
                  consq + [D <= 10**24, D + fee - term > E18],
                  "COUNTEREXAMPLE", show=[D, c, term, fee])
            maximize("MATH-ST-08",
                     f"[{name}] bonus {b}: max gap (18-decimal debt units) at D = 1M GHO, s={sq}",
                     consq + [D == 10**24], D + fee - term)

# ---------- ST-09: collateral-driven branch (all collateral seized), drawnIndex != RAY ----------
idx = RAY + RAY // 20 + 12_345          # 1.05 RAY plus odd remainder
for name, (dv, pc) in MARKETS.items():
    b = 10_250
    ss = s_final(b, 0, 0, 100)
    uc = 10**dv
    debtRay, shares = Ints("debtRay shares")
    cons = [c >= 1, c <= 10**32] \
        + ceil_div(debtRay, c * pc * E18 * BPS * RAY, PD * uc * b) \
        + ceil_div(shares, debtRay, idx) + ceil_div(D, shares * idx, RAY) \
        + floor_div(V, c * pc * E18, uc * PD) + ceil_div(term, V * (BPS - ss), BPS) + [fee == 0]
    # MATH-ST-09 verifies: SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, Q-159, Q-085
    check("MATH-ST-09",
          f"[{name}] collateral-driven branch, idx 1.05 RAY, s={ss}: gap <= 3 wei",
          cons + [D + fee - term > 3],
          "PROVED")

# ---------- ST-10: bonus at HF just below 1 is never below the on-chain minBonus ----------
maxB, factor, hf, hfMax, minB, bon, interp = Ints("maxB factor hf hfMax minB bon interp")
curve = [maxB > BPS, maxB <= 2 * BPS, factor >= 0, factor <= BPS,
         hfMax >= 0, hfMax < E18, hf > hfMax, hf < E18] \
    + floor_div(minB - BPS, (maxB - BPS) * factor, BPS) \
    + floor_div(interp, (maxB - minB) * (E18 - hf), E18 - hfMax) + [bon == minB + interp]
# MATH-ST-10 verifies: SPEC-LIQ-003, SPEC-LIQ-016, SPEC-HUB-005, Q-159
check("MATH-ST-10",
      "for every liquidatable HF (< 1), bonus(HF) >= minBonus = floor((maxB-1e4)*factor/1e4)+1e4",
      curve + [bon < minB],
      "PROVED")

# ---------- ST-11: rounding direction of SPEC-LIQ-016 ----------
bq, fq, cq, sF, sN = Ints("bNet costsBps cBuy sF sN")
q = [bq > BPS, bq <= 2 * BPS, fq == 0, cq == 0,
     bq * BPS > (BPS + fq) * (BPS + cq)]
num = bq * BPS - (BPS + fq) * (BPS + cq)
# MATH-ST-11 verifies: SPEC-LIQ-003, SPEC-LIQ-016, Q-159, Q-235
check("MATH-ST-11",
      "s rounded down: bNet * (1e4 - s) >= 1e8 for every bNet > 1e4 (no premium term)",
      q + floor_div(sF, BPS * num, bq * BPS) + [bq * (BPS - sF) * BPS < BPS * (BPS + fq) * (BPS + cq)],
      "PROVED")
# MATH-ST-11 verifies: SPEC-LIQ-003, SPEC-LIQ-016, Q-159
check("MATH-ST-11",
      "wrong reading: s rounded to nearest breaks the guarantee (counterexample expected)",
      q + floor_div(sN, 2 * BPS * num + bq * BPS, 2 * bq * BPS)
      + [bq * (BPS - sN) * BPS < BPS * (BPS + fq) * (BPS + cq)],
      "COUNTEREXAMPLE", show=[bq, fq, cq, sN])

# ---------- ST-12: net bonus (SPEC-LIQ-001) under a non-zero liquidation fee ----------
# With lf > 0 LPVaultSwap receives c - ceil(c*lf*(b-1e4)/(b*1e4)) units. s from bNet keeps the gap at
# one unit; s from the gross bonus does not.
lf, cr, cut, bnet = Ints("lf cr cut bNet")
dv, pc = MARKETS["USDC/USDT d6 $2"]
b = 10_500


def lf_case(sv):
    return (dom + [D <= 10**24, lf == 1_000]
            + floor_div(c, D * PD * 10**dv * b, E18 * pc * BPS)
            + ceil_div(cut, c * lf * (b - BPS), b * BPS) + [cr == c - cut]
            + floor_div(V, cr * pc * E18, 10**dv * PD) + ceil_div(term, V * (BPS - sv), BPS) + [fee == 0])


bnet_v = BPS + ((b - BPS) * (BPS - 1_000)) // BPS            # 10,450
uv = unit_value(dv, pc)
# MATH-ST-12 verifies: SPEC-LIQ-001, SPEC-LIQ-003, Q-190, Q-068
check("MATH-ST-12",
      f"lf = 10%: uncapped s from bNet = {bnet_v} ({s_final(bnet_v, 0)}bps) keeps gap <= 2 units + 1 "
      f"for D <= 1M GHO (the fee cut rounds up by one more unit)",
      lf_case(s_final(bnet_v, 0)) + [D - term > 2 * uv + 1],
      "PROVED")
# MATH-ST-12 verifies: SPEC-LIQ-001, Q-068
check("MATH-ST-12",
      "wrong reading: s from the gross bonus under lf = 10% leaves gap > 1 GHO (counterexample expected)",
      lf_case(s_final(b, 0)) + [D - term > E18],
      "COUNTEREXAMPLE", show=[D, c, cr, term])
# integer net bonus is never above the exact net bonus, and equals b when lf = 0
bb, ll, nb, pr = Ints("b lf2 nb prod")
# prod = (b - 1e4) * (1e4 - lf), kept linear: 0 <= prod <= (b - 1e4) * 1e4, and prod = (b - 1e4) * 1e4 at lf = 0
# MATH-ST-12 verifies: SPEC-LIQ-001
check("MATH-ST-12",
      "bNet rounded down: 1e4 <= bNet <= exact net bonus, and bNet = b when lf = 0",
      [bb >= BPS, bb < 2**32, ll >= 0, ll <= BPS, pr >= 0, pr <= (bb - BPS) * BPS,
       If(ll == 0, pr == (bb - BPS) * BPS, True)] + floor_div(nb - BPS, pr, BPS)
      + [Or(nb < BPS, nb * BPS > BPS * BPS + pr, And(ll == 0, nb != bb))],
      "PROVED")

# ---------- ST-13: premium bound (deleverage and helper) and the listing liveness bound ----------
phi_, F_, mf, cbps = Ints("phi F maxFlashFeeBps rateBps")
t = Reals("t")[0]                      # t = phi * 1e4 / F, exact
# MATH-ST-13 verifies: SPEC-LIQ-015, REQ-HELPER-005, Q-135
check("MATH-ST-13",
      "a premium that passes phi*1e4 <= maxFlashFeeBps*F has a rate ceil(phi*1e4/F) <= maxFlashFeeBps "
      "(deleverage and the helper; a liquidation carries no premium)",
      [mf >= 0, mf <= BPS, t >= 0, t <= mf, cbps >= t, cbps - 1 < t, cbps > mf],
      "PROVED")
# REQ-PSTORE-021 listing check: minLB*(1e4 - smin) >= 1e4*(1e4 + maxFlash). SPEC-LIQ-016: a liquidation needs only
# minLB*(1e4 - smin) >= 1e8, i.e. floor(1e4*(bNet - 1e4)/bNet) >= smin at every bonus Aave can pay (bNet >= minLB,
# lf = 0), so s >= min(allow, smin); the listing check implies it for every maxFlash >= 0 and also keeps the
# slippage term at smin above D*(1e4 + maxFlash)/1e4 (a helper's premium at the cap), up to the rounding terms.
minLB = Ints("minLB")[0]
sv = Ints("sv")[0]
n_live = 0
for mfv in (0, 9, 10, 100):
    for sminv in (0, 30, 50, 100):
        lst = [minLB > BPS, minLB <= 2 * BPS, bq >= minLB, bq <= 2 * BPS,
               minLB * (BPS - sminv) >= BPS * (BPS + mfv)]
        # MATH-ST-13 verifies: SPEC-LIQ-016, SPEC-LIQ-003, REQ-PSTORE-021, Q-261, Q-404
        check("MATH-ST-13",
              f"listing check maxFlash={mfv} smin={sminv}: s >= smin at every bonus >= minLB (no premium term), "
              f"and bNet*(1e4 - smin) >= 1e4*(1e4 + maxFlash)",
              lst + floor_div(sv, BPS * (bq - BPS), bq)
              + [Or(sv < sminv, bq * (BPS - sminv) < BPS * (BPS + mfv), bq * (BPS - sminv) < BPS * BPS)],
              "PROVED")
        n_live += 1
# MATH-ST-13 verifies: SPEC-LIQ-016, REQ-PSTORE-021, Q-404
check("MATH-ST-13",
      "2.11 example: minLB 10,060 with smin 50 meets the liquidation bound 1e8 but not the listing check at "
      "maxFlash 10; 10,200 meets both; 10,050 meets neither",
      [Not(And(10_060 * (BPS - 50) >= BPS * BPS, 10_060 * (BPS - 50) < BPS * (BPS + 10),
               10_200 * (BPS - 50) >= BPS * (BPS + 10), 10_050 * (BPS - 50) < BPS * BPS))],
      "PROVED")

# REQ-PSTORE-021 worked example (2.9): minLB = 10,200, floor 30 admits maxFlashFeeBps up to 169 (above the hard bound
# of 100); floor 100 gives 10,200 x 9,900 = 100,980,000 = 1e4 x 10,098, so 98 passes with equality and 99 fails.
# MATH-ST-13 verifies: REQ-PSTORE-021, REQ-PSTORE-024
check("MATH-ST-13",
      "2.9 example: with minLB 10,200 and floor 30 the largest admitted flash ceiling is 169; with floor 100 it is 98",
      [Not(And(10_200 * (BPS - 30) >= BPS * (BPS + 169), 10_200 * (BPS - 30) < BPS * (BPS + 170),
               10_200 * (BPS - 100) >= BPS * (BPS + 98), 10_200 * (BPS - 100) < BPS * (BPS + 99)))],
      "PROVED")

# ---------- ST-113: net bonus outside Aave's bounds (SPEC-LIQ-001) ----------
# The formula's product (b - 1e4)(1e4 - lf) is linearised by its sign: with one factor <= 0 and the other >= 0 the
# product is <= 0, so floor(product / 1e4) <= 0 and the raw bNet <= 1e4, which is what the saturation gives.
bo, lo, po, no_ = Ints("b_out lf_out prod_out nb_out")
sign_le0 = [Or(And(bo <= BPS, lo <= BPS, po <= 0), And(bo >= BPS, lo >= BPS, po <= 0))]
# MATH-ST-113 verifies: SPEC-LIQ-001, SPEC-LIQ-003
check("MATH-ST-113",
      "b <= 1e4 with lf <= 1e4, or lf >= 1e4 with b >= 1e4: the raw formula gives bNet <= 1e4, so bNet = 1e4 "
      "(saturated) leaves s = 0 exactly as the formula does",
      [bo >= 0, bo < 2**32, lo >= 0, lo < 2**16] + sign_le0 + floor_div(no_ - BPS, po, BPS) + [no_ > BPS],
      "PROVED")
# MATH-ST-113 verifies: SPEC-LIQ-001
check("MATH-ST-113",
      "wrong reading (no saturation): b < 1e4 and lf > 1e4 multiply two negative terms into bNet > 1e4 + 100 "
      "(counterexample expected)",
      [bo >= 0, bo < BPS, lo > BPS, lo < 2**16, po == (bo - BPS) * (BPS - lo)] + floor_div(no_ - BPS, po, BPS)
      + [no_ > BPS + 100],
      "COUNTEREXAMPLE", show=[bo, lo, no_])

done()
