# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-63..67: per-leg minimum output and the caller shortfall top-up (SPEC-LIQ-018, SPEC-LIQ-019, SPEC-LIQ-014).

Per leg i of n (1 or 2) converted legs, all in base units of an 18-decimal debt asset (Pgho reads as Pdebt):
  Vleg_i  = floor(a_i p_i 1e18 / (10^d_i Pgho))           leg value, down
  Uleg_i  = ceil(p_i 1e18 / (10^d_i Pgho))                 one raw unit, up;  U = sum_i Uleg_i
  minOut_i = max(1, ceil(Vleg_i (1e4 - sLeg) / 1e4) - Uleg_i - floor(allowance / n))      SPEC-LIQ-018
Liquidation: sLeg = min(9999, s + min(maxShortfallBps, floor(maxShortfall 1e4 / V)))    SPEC-LIQ-019
  minRec = max(0, ceil(V (1e4 - s) / 1e4) - U - allowance); shortfall = max(0, minRec - R) <= maxShortfall
settlePending: s_P = min(slippageAllowanceBps, 30), V_P = sum_i ceil(a_i p_i 1e18 / (10^d_i Pgho)),
  minPending = max(0, ceil(V_P (1e4 - s_P) / 1e4) - U - allowance)                          SPEC-LIQ-014
"""
from z3 import Int, Ints, IntVector, If, And, Or, Not, Sum
from _common import check, maximize, floor_div, ceil_div, done, BPS

E18 = 10**18
ALLOW = E18
UL = [10**12, 999_800_000_000]          # USDC at $1.00, USDT at $0.9998 (6 decimals)


def leg_min(m, vleg, uleg, sleg, n, allow=ALLOW):
    t = Int(f"t_{m}")
    return t, ceil_div(t, vleg * (BPS - sleg), BPS) + [
        m == If(t - uleg - allow // n > 1, t - uleg - allow // n, 1)]


# ---------- ST-63: each leg is protected ----------
vl, ul, sl, mo, out = Ints("Vleg Uleg sLeg minOut out")
for n in (1, 2):
    t, cons = leg_min(mo, vl, ul, sl, n)
    lossb = Int("lossBound")
    # MATH-ST-63 verifies: SPEC-LIQ-018, REQ-SWAP-100, LIQ-075, Q-250
    check("MATH-ST-63",
          f"n = {n}: minOut >= 1, and a leg that meets it loses at most floor(Vleg sLeg / 1e4) + Uleg + "
          f"floor(allowance / n) against its oracle value",
          [vl >= 0, vl < 2**200, ul >= 1, ul < 2**64, sl >= 0, sl <= 9_999] + cons
          + floor_div(lossb, vl * sl, BPS)
          + [out >= mo, Or(mo < 1, And(mo > 1, vl - out > lossb + ul + ALLOW // n))],
          "PROVED")

# ---------- ST-64: at the oracle-implied pool price the leg minimums add only rounding to the floor ----------
V, minG, term, U = Ints("V minGho term U")
vlv = IntVector("Vl", 2)
mos = IntVector("mo", 2)
for s in (0, 30, 49, 100):
    for n in (1, 2):
        cons = [V >= 0, V < 2**200] + ceil_div(term, V * (BPS - s), BPS)
        legs = []
        for i in range(n):
            t, c = leg_min(mos[i], vlv[i], UL[i], s, n)
            cons += c + [vlv[i] >= 0]
            legs.append(i)
        Uv = sum(UL[:n])
        cons += [minG == If(term - Uv - ALLOW > 0, term - Uv - ALLOW, 0),
                 Sum([vlv[i] for i in legs]) <= V + Uv, Sum([vlv[i] for i in legs]) >= V - Uv]
        # At the oracle-implied price a full-range position holds equal value in both tokens, so the two legs
        # differ only by the unwind truncation: |Vleg0 - Vleg1| <= max Uleg + 1.
        bal = [vlv[0] - vlv[1] <= max(UL) + 1, vlv[1] - vlv[0] <= max(UL) + 1] if n == 2 else []
        # MATH-ST-64 verifies: SPEC-LIQ-018, SPEC-LIQ-005, Q-250
        check("MATH-ST-64",
              f"s = {s}, n = {n}: at the oracle-implied price (|sum Vleg - V| <= U, legs of equal value) "
              f"sum minOut <= minRec + n + U",
              cons + bal + [Sum([mos[i] for i in legs]) > minG + n + Uv],
              "PROVED")
        if n == 2:
            # MATH-ST-64 verifies: SPEC-LIQ-018
            check("MATH-ST-64",
                  f"s = {s}: boundary, pool away from the oracle price with one leg near 0: that leg's minimum is clamped "
                  f"at 1, its share of the allowance is unused, and the sum exceeds minRec + n + U (counterexample expected)",
                  cons + [Sum(mos[:2]) > minG + n + Uv],
                  "COUNTEREXAMPLE", show=[V, vlv[0], vlv[1], minG, mos[0], mos[1]])
            maximize("MATH-ST-64", f"s = {s}: largest sum minOut - (minRec + n + U) without the equal-value "
                     f"condition (18-decimal debt units)", cons, Sum(mos[:2]) - minG - n - Uv,
                     timeout_ms=600_000)

# ---------- ST-65: shape of the relaxed leg slippage ----------
mSF, mSB, sv, add, sleg, q = Ints("maxShortfallGho maxShortfallBps s added sLeg q")
cons65 = [V >= 0, V < 2**200, mSF >= 0, mSF < 2**128, mSB >= 0, mSB <= 5_000, sv >= 0, sv <= 9_999,
          If(V > 0, And(q * V <= mSF * BPS, mSF * BPS < (q + 1) * V), q == 0),
          add == If(mSB < q, mSB, q), sleg == If(sv + add < 9_999, sv + add, 9_999)]
# MATH-ST-65 verifies: SPEC-LIQ-019, LIQ-076, Q-251
check("MATH-ST-65",
      "s <= sLeg <= min(9999, s + maxShortfallBps); the relaxation is 0 when maxShortfall = 0 or V = 0",
      cons65 + [Or(sleg < sv, sleg > 9_999, sleg > sv + mSB, And(Or(mSF == 0, V == 0), sleg != sv))],
      "PROVED", timeout_ms=60_000)

# ---------- ST-66: the top-up covers the relaxation it bought, up to rounding ----------
# Concrete grid (V, maxShortfall, s); the two legs' values split V within U. A call whose legs all meet
# their relaxed minimums needs a shortfall of at most maxShortfall + excess; [MAX] reports the excess.
R, sf = Ints("R shortfall")
for (Vg, mSFg, s) in ((12_422_600 * 10**15, 200 * E18, 100), (12_422_600 * 10**15, 100 * E18, 100),
                      (2_047_500 * 10**15, 50 * E18, 100), (3_150 * 10**15, 1 * E18, 100)):
    addv = min(1_000, (mSFg * BPS) // Vg)
    slegv = min(9_999, s + addv)
    cons = [V == Vg] + ceil_div(term, V * (BPS - s), BPS)
    for i in range(2):
        t, c = leg_min(mos[i], vlv[i], UL[i], slegv, 2)
        cons += c + [vlv[i] >= 0]
    Uv = sum(UL)
    cons += [minG == If(term - Uv - ALLOW > 0, term - Uv - ALLOW, 0),
             Sum(vlv) <= V + Uv, Sum(vlv) >= V - Uv, R >= Sum(mos),
             sf == If(minG > R, minG - R, 0)]
    # MATH-ST-66 verifies: SPEC-LIQ-019, SPEC-LIQ-018, Q-251
    check("MATH-ST-66",
          f"V = {Vg / E18:g} GHO, maxShortfall = {mSFg // E18}, sLeg = {slegv}: legs meeting their minimums "
          f"need a shortfall <= maxShortfall + U + 2 wei",
          cons + [sf > mSFg + Uv + 2],
          "PROVED")
    maximize("MATH-ST-66", f"V = {Vg / E18:g} GHO, maxShortfall = {mSFg // E18}: largest shortfall - maxShortfall "
             f"(18-decimal debt units; positive only by rounding)", cons, sf - mSFg)

# ---------- ST-67: settlePending floor and legs ----------
sP, alw = Ints("s_P slippageAllowanceBps")
# MATH-ST-67 verifies: SPEC-LIQ-014, Q-250
check("MATH-ST-67",
      "s_P = min(slippageAllowanceBps, 30) <= 30: a searcher sandwiching settlePending takes at most 0.3 % "
      "of each leg plus its rounding terms",
      [alw >= 0, alw <= BPS, sP == If(alw < 30, alw, 30), sP > 30],
      "PROVED")
VP = Int("V_P")
for n in (1, 2):
    cons = [VP >= 0, VP < 2**200] + ceil_div(term, VP * (BPS - 30), BPS)
    for i in range(n):
        t, c = leg_min(mos[i], vlv[i], UL[i], 30, n)
        cons += c + [vlv[i] >= 0]
    Uv = sum(UL[:n])
    # V_P sums the leg values rounded up, Vleg rounds them down: V_P - n <= sum Vleg <= V_P
    cons += [minG == If(term - Uv - ALLOW > 0, term - Uv - ALLOW, 0),
             Sum(vlv[:n]) <= VP, Sum(vlv[:n]) >= VP - n]
    if n == 1:
        # MATH-ST-67 verifies: SPEC-LIQ-014, SPEC-LIQ-018, DEF-015
        check("MATH-ST-67",
              "settlePending, one leg: its minimum never exceeds minPending + 1",
              cons + [Sum(mos[:n]) > minG + n],
              "PROVED")
    else:
        # MATH-ST-67 verifies: SPEC-LIQ-014, SPEC-LIQ-018
        maximize("MATH-ST-67", "settlePending, two legs of any split: largest sum minOut - (minPending + 2) "
                 "(18-decimal debt units; at most floor(allowance / 2), reached when one leg is near 0)", cons, Sum(mos[:2]) - minG - 2)

# ---------- ST-111: a dust leg (Vleg <= Uleg) is skipped without lowering what the floor counts ----------
# REQ-SWAP-121: a leg with Vleg <= Uleg is not swapped and goes to the caller. Its own floor term is at most 0, so
# the floor already allows for it through U; the tokens handed over are worth less than Uleg + 1 debt units.
dv, du, ds, dterm = Ints("dVleg dUleg dsLeg dterm")
# MATH-ST-111 verifies: REQ-SWAP-121, SPEC-LIQ-018, SPEC-LIQ-005, LIQ-090
check("MATH-ST-111",
      "dust leg: ceil(Vleg (1e4 - sLeg) / 1e4) - Uleg <= 0 whenever 0 <= Vleg <= Uleg",
      [dv >= 0, du >= 1, du < 2**64, dv <= du, ds >= 0, ds <= 9_999] + ceil_div(dterm, dv * (BPS - ds), BPS)
      + [dterm - du > 0],
      "PROVED")
da, dp, dP = Ints("da dp dP")
# value of the leg a*p/(10^d_i Pdebt) in debt units at 10^dd; with Vleg = floor(a p 10^dd / (10^d_i Pdebt)) <= Uleg the
# exact value is below Uleg + 1: a p 10^dd < (Uleg + 1) 10^d_i Pdebt
for d_i, dd in ((18, 6), (6, 6), (6, 18), (18, 18)):
    num = da * dp * 10**dd
    den = 10**d_i * dP
    # MATH-ST-111 verifies: REQ-SWAP-121, LIQ-090
    check("MATH-ST-111",
          f"d_i = {d_i}, dd = {dd}: a dust leg is worth less than Uleg + 1 debt units at the capped leg price",
          [da >= 1, da < 2**128, dp >= 1, dp <= 10**8, dP >= 1, dP < 2**64] + floor_div(dv, num, den)
          + ceil_div(du, dp * 10**dd, den)
          + [dv <= du, num >= (du + 1) * den],
          "PROVED")

done()
