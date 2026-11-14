# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-104..112: payout split in the debt asset, the one-leg floor, the pool spot price (never a gate), the sequencer gate,
the record cap sized to one transaction, one shortfall rule for every caller with no shared settlement pool, the flash-source rules and the
flash repayment by balance delta of deleverage (Q-333..Q-358, Q-381, Q-388, Q-390, Q-397, Q-404).

All amounts are base units of the debt asset T repaid (no GHO conversion, no buy leg, no sell-back). A liquidation
takes no flash loan (Q-404): K below is the caller funding Kf, and F = phi = phiD = 0 in sections (a), (b), (f), (i).

  S   = max(0, R_f - D),  R_f = max(R, minRec),  R' = R + shortfall                    SPEC-LIQ-008
  G   = max(0, V - D)                                                                  SPEC-LIQ-009
  A   = min(floor(G feeBps / 1e4), S)                                                  SPEC-LIQ-009
  kr  = min(S, G) - A,  B = S - A - kr                                                 SPEC-LIQ-022
  3.5 form (LIQ-031): Y = S, Kr = min(Y - A, G - A)
  keeperOut = (Kf + R') - (D + A + B)                                                  SPEC-LIQ-010
  s   = min(allow, floor(1e4 (bNet - 1e4) / bNet)) if bNet > 1e4, else 0               SPEC-LIQ-003
  listing check: minLB (1e4 - smin) >= 1e4 (1e4 + maxFlashFeeBps), which implies the 1e8 bound SPEC-LIQ-016
  spot price never reverts (REQ-SWAP-025), sequencer gate (LIQ-086), record cap G(16) <= 16,777,216 (SPEC-CHAIN-001),
  the caller's gap and top-up (SPEC-SET-001, SPEC-LIQ-019), flash lender and premium (REQ-FLASH-002, REQ-FLASH-005),
  flash repayment by balance delta (REQ-SWAP-122) and the measured conservation (SPEC-LIQ-010, REQ-SWAP-108).
"""
from fractions import Fraction as Fr
from z3 import Ints, Int, Bools, Bool, If, And, Or, Not, Implies, IntVector, Sum, Reals
from _common import check, computed, floor_div, ceil_div, done, BPS


def pos(x):
    return If(x > 0, x, 0)


def zmin(a, b):
    return If(a < b, a, b)


# ---------------- (a) A / kr / B split and conservation ----------------
R, sf, D, phiD, phi, V, fee, K, F, Au, s, U, eps, term, minR = Ints(
    "R shortfall D phiD phi V avanaFeeShareBps K F Araw s U eps term minRec")
Rp = R + sf
Rf = If(R > minR, R, minR)
S = pos(Rf - D - phiD)
G = pos(V - D - phiD)
A = zmin(Au, S)
kr = zmin(S, G) - A
B = S - A - kr
Kr35 = zmin(S - A, G - A)
keeperOut = (K + F + Rp) - (D + F + phi + A + B)
base = [R >= 0, sf >= 0, D >= 0, phiD == 0, phi == 0, V >= 0, fee >= 0, fee <= 5_000, K >= D, F == 0] \
    + floor_div(Au, G * fee, BPS)

# MATH-ST-104 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-022, LIQ-031, LIQ-POST-016, Q-337
check("MATH-ST-104",
      "split: A + kr + B = S; A, kr, B >= 0; A <= S; kr <= G - A; B = max(0, S - G); the 3.5 form "
      "Kr = min(Y - A, G - A) equals kr",
      base + [Or(A + kr + B != S, A < 0, kr < 0, B < 0, A > S, kr > G - A, B != pos(S - G), Kr35 != kr)],
      "PROVED")

floor_cons = [s >= 0, s <= 9_999, U >= 0, eps >= 0] + ceil_div(term, V * (BPS - s), BPS) \
    + [minR == pos(term - U - eps)]
# MATH-ST-104 verifies: SPEC-LIQ-019, SPEC-LIQ-022, SPEC-SET-001, LIQ-031, LIQ-076, LIQ-POST-016
check("MATH-ST-104",
      "the top-up never reaches the borrower: B = 0 whenever the floor term binds (R_f = minRec <= V), and the "
      "B <= max(0, R - V)",
      base + floor_cons
      + [minR <= V, Or(And(minR > R, B != 0), B > pos(R - V))],
      "PROVED")

# MATH-ST-104 verifies: SPEC-LIQ-010, LIQ-031, LIQ-POST-016
check("MATH-ST-104",
      "conservation: Kf + R + shortfall = D + A + B + keeperOut, and when S > 0 and the shortfall is the floor term "
      "alone keeperOut = Kf + kr",
      base + [Or(K + F + R + sf != D + (F + phi) + A + B + keeperOut,
                 And(S > 0, sf == pos(minR - R), keeperOut != K + kr - (phi - phiD)))],
      "PROVED")

# MATH-ST-104 verifies: SPEC-LIQ-022
check("MATH-ST-104",
      "wrong reading: giving the borrower S - A (no keeper reward bound) lets B > 0 while R' <= V "
      "(counterexample expected)",
      base + [S - A > 0, Rp <= V, S - A - 0 > pos(S - G)],
      "COUNTEREXAMPLE", show=[R, V, D])


def split(Rv, Dv, Vv, phiv, phiDv, feev, Kv=0, Fv=0):
    Sv = max(0, Rv - Dv - phiDv)
    Gv = max(0, Vv - Dv - phiDv)
    Av = min(Gv * feev // BPS, Sv)
    krv = min(Sv, Gv) - Av
    Bv = Sv - Av - krv
    ko = (Kv + Fv + Rv) - (Dv + Fv + phiv + Av + Bv)
    return Sv, Gv, Av, krv, Bv, ko


U6 = 10**6
S1, G1, A1, k1, B1, o1 = split(2_040_300_000, 1_950 * U6, 2_047_500_000, 0, 0, 2_000, Kv=1_950 * U6)
S2, G2, A2, k2, B2, o2 = split(2_052_000_000, 1_950 * U6, 2_047_500_000, 0, 0, 2_000, Kv=1_950 * U6)
# MATH-ST-104 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022
computed("MATH-ST-104", "SPEC-LIQ-022 examples (USDC debt, Kf = D = 1,950, no flash term)", [
    ("R = 2,040.3: S", 90_300_000, S1), ("G", 97_500_000, G1), ("A", 19_500_000, A1),
    ("kr", 70_800_000, k1), ("B", 0, B1), ("keeperOut = Kf + kr", 2_020_800_000, o1),
    ("R = 2,052: S", 102_000_000, S2), ("kr", 78_000_000, k2), ("B", 4_500_000, B2),
    ("keeperOut = Kf + kr", 2_028_000_000, o2), ("A unchanged", 19_500_000, A2),
])

# ---------------- (b) one-leg floor and listing liveness ----------------
bN, cst, al, sq, mlb, mf, sraw = Ints("bNet costsBps allow s minLB maxFlashFeeBps sraw")
for bv in (10_001, 10_050, 10_100, 10_200, 10_300, 10_500, 11_000, 12_000, 15_000):
    s_def = [bN == bv] + floor_div(sraw, BPS * (bv - BPS - cst), bv) + [sq == If(bv > BPS + cst, zmin(al, sraw), 0)]
    # MATH-ST-105 verifies: SPEC-LIQ-003, SPEC-LIQ-005, LIQ-030, Q-358
    check("MATH-ST-105",
          f"bNet {bv}, no buy-leg and no premium term: with s > 0, bNet (1e4 - s) >= 1e8 for every allowance",
          s_def + [cst == 0, al >= 0, al <= 9_999, sq > 0, bv * (BPS - sq) < BPS * (BPS + cst)],
          "PROVED")
worst = min(b_ * (BPS - (BPS * (b_ - BPS - c_)) // b_) - BPS * (BPS + c_)
            for b_ in range(10_001, 20_001) for c_ in (0,) if b_ > BPS + c_)
# MATH-ST-105 verifies: SPEC-LIQ-003
computed("MATH-ST-105", "exhaustive: every integer bNet 10,001..20,000 at the uncapped s (no premium term)",
         [("min of bNet (1e4 - s) - 1e8 is >= 0", True, worst >= 0)])
# Floor lemma for an integer smin >= 1: floor(q / bNet) >= smin iff q >= smin bNet, so s >= smin iff allow >= smin,
# bNet > 1e4 + costs and 1e4 (bNet - 1e4 - costs) >= smin bNet (linear for each fixed smin).
for smv in (1, 10, 30, 50, 100, 200):
    # MATH-ST-105 verifies: SPEC-LIQ-016, REQ-PSTORE-021, Q-335
    check("MATH-ST-105",
          f"liveness, slippageAllowanceMinBps {smv}: the listing check minLB (1e4 - smin) >= 1e4 (1e4 + maxFlashFeeBps) "
          f"and bNet >= minLB give s >= smin (no premium term) whenever the allowance is >= smin",
          [bN >= BPS, bN < 2**32, cst == 0, mlb >= BPS, mf >= 0, mf <= 10_000, bN >= mlb, cst <= mf,
           (BPS - smv) * mlb >= BPS * (BPS + mf),
           Not(And(bN > BPS + cst, BPS * (bN - BPS - cst) >= smv * bN))],
          "PROVED")
# MATH-ST-105 verifies: SPEC-LIQ-016
computed("MATH-ST-105", "SPEC-LIQ-016 example", [
    ("10,200 x 9,950", 101_490_000, 10_200 * 9_950), ("1e4 x 10,010", 100_100_000, BPS * 10_010),
    ("passes", True, 10_200 * 9_950 >= BPS * 10_010),
    ("10,050 x 9,950", 99_997_500, 10_050 * 9_950), ("fails", True, 10_050 * 9_950 < BPS * 10_010),
])

# ---------------- (c) a moved pool price never reverts a liquidation (REQ-SWAP-025, Q-350) ----------------
# Concentrated range [a, b] in sqrt-price units, liquidity L, oracle sqrt price q (token0 worth q^2 token1).
# Removing L at pool sqrt price s returns amount0 = L(1/c - 1/b), amount1 = L(c - a) with c = clamp(s, a, b).
# Oracle value in token1: W(s) = L(q^2/c - q^2/b + c - a). Fair composition values the same position at c = clamp(q).
La, Lb, Lq, Ls, LL = Reals("a b q s L")
def clampR(x):
    return If(x < La, La, If(x > Lb, Lb, x))
def W(x):
    c = clampR(x)
    return LL * (Lq * Lq / c - Lq * Lq / Lb + c - La)
cdom = [La > 0, Lb > La, Lq > 0, Ls > 0, LL > 0]
# MATH-ST-106 verifies: REQ-SWAP-025, Q-350, SPEC-ORC-007
check("MATH-ST-106",
      "an unwind at any pool spot price returns tokens whose oracle value is at least the fair composition "
      "value at the oracle price (fair composition is the minimum over spot prices)",
      cdom + [W(Ls) < W(Lq)],
      "PROVED")
# MATH-ST-106 verifies: REQ-SWAP-025, Q-350
check("MATH-ST-106",
      "wrong reading: valuing the unwound tokens at the pool spot price instead of the oracle can fall below "
      "fair value, which is why value is checked at oracle prices after the unwind (counterexample expected)",
      cdom + [Ls > La, Ls < Lb, Lq > La, Lq < Lb,
              LL * (Ls * Ls / Ls - Ls * Ls / Lb + Ls - La) < W(Lq)],
      "COUNTEREXAMPLE", show=[La, Lb, Lq, Ls])
# The liquidation decision: route mode and revert depend on caller inputs, prices and floors, never on the spot.
mode, mode2 = Ints("routeMode routeModeAfterSpotMove")
spot1, spot2 = Reals("spotBefore spotAfter")
def eff_mode(m, spot):          # REQ-SWAP-025: the pool spot is not an input of the mode decision
    return m
# MATH-ST-106 verifies: REQ-SWAP-025, LIQ-082, LIQ-POST-019, Q-350
check("MATH-ST-106",
      "a pool spot move never switches the route mode and never adds a revert: the outcome for spot s1 equals "
      "the outcome for spot s2",
      [mode >= 0, mode <= 2, spot1 > 0, spot2 > 0, eff_mode(mode, spot1) != eff_mode(mode, spot2)],
      "PROVED")
# MATH-ST-106 verifies: REQ-SWAP-025
computed("MATH-ST-106", "REQ-SWAP-025 example: one-sided unwind into USDT at a pushed pool price", [
    ("2,051.25 USDT at $0.9995 (USDC units)", Fr("2050.224375"), Fr("2051.25") * Fr("0.9995")),
    ("at least V = 2,047.5 USDC", True, Fr("2051.25") * Fr("0.9995") >= Fr("2047.5")),
])

# ---------------- (d) sequencer gate (LIQ-086) ----------------
# state: 0 Up, 1 Down, 2 Grace; Grace iff restartedAt <= now < restartedAt + grace after an Up report
st, now, rs, gr, hf, ghf = Ints("seqState now restartedAt grace HF graceHF")
up_rep = Bool("feedReportsUp")
st_def = [st == If(Not(up_rep), 1, If(And(now >= rs, now < rs + gr), 2, 0))]
liq_ok = Or(st == 0, And(st == 2, hf < ghf))
sp_ok = st != 1
sdom = [now >= 0, rs >= 0, rs <= now, gr >= 0, hf >= 0, ghf >= 0]
# MATH-ST-107 verifies: LIQ-086, LIQ-POST-018, LIQ-F-045, LIQ-F-046, REQ-SWAP-009, Q-357
check("MATH-ST-107",
      "no liquidation while Down, none in Grace with HF >= graceHealthFactor; liquidation runs in Up",
      sdom + st_def + [Or(And(liq_ok, st == 1), And(liq_ok, st == 2, hf >= ghf), And(st == 0, Not(liq_ok)))],
      "PROVED")
# MATH-ST-107 verifies: LIQ-086, Q-357
check("MATH-ST-107",
      "settlePending is refused only while Down",
      sdom + st_def + [sp_ok != (st != 1)],
      "PROVED")
t0 = 10 * 3_600
# MATH-ST-107 verifies: LIQ-086, LIQ-089
computed("MATH-ST-107", "LIQ-089 example: restart 10:00:00, grace 3,600 s, graceHealthFactor 0.95", [
    ("10:20:00 in Grace", True, t0 <= t0 + 1_200 < t0 + 3_600),
    ("HF 0.9997 >= 0.95 reverts GraceHealthFactor", True, Fr("0.9997") >= Fr("0.95")),
    ("11:00:02 after the window (Up)", True, t0 + 3_602 >= t0 + 3_600),
    ("USDC/USD age 75,600 s within 86,400 + heartbeatMargin 1,800", True, 75_600 <= 88_200),
])

# ---------------- (e) record cap sized to one transaction (SPEC-CHAIN-001, Q-381) ----------------
# No minimum debt exists on any chain (Q-381). The 16-record limit per account per market exists so one
# liquidation of the largest account fits one transaction: G(n) = 1,310,000 + 240,000 n <= 16,777,216.
nrec, gcap = Ints("records txGasCap")
G_n = 1_310_000 + 240_000 * nrec
# MATH-ST-108 verifies: SPEC-CHAIN-001, INV-096, LIQ-022, REQ-AMM-CORE-015, LIQ-087, Q-381
check("MATH-ST-108",
      "every account with at most 16 records per market is liquidated in one call of at most G(16) = 5,150,000 gas, "
      "within the per-transaction gas limit 16,777,216",
      [nrec >= 1, nrec <= 16, gcap == 16_777_216, Or(G_n > 5_150_000, G_n > gcap)],
      "PROVED")
# MATH-ST-108 verifies: SPEC-CHAIN-001, INV-096
check("MATH-ST-108",
      "boundary: the largest record count whose liquidation fits the per-transaction limit is 64, so a limit of 65 "
      "records would not fit (counterexample expected)",
      [nrec == 65, G_n > 16_777_216],
      "COUNTEREXAMPLE", show=[nrec])
G_rec = lambda n: 1_310_000 + 240_000 * n          # liquidation gas by records walked (gas units, no gas price)
# MATH-ST-108 verifies: SPEC-CHAIN-001, LIQ-087, Q-381
computed("MATH-ST-108", "record-cap gas fit with G(n) = 1,310,000 + 240,000 n (no gas price, no minimum debt)", [
    ("G(1)", 1_550_000, G_rec(1)), ("G(16)", 5_150_000, G_rec(16)),
    ("G(16) <= 16,777,216", True, G_rec(16) <= 16_777_216),
    ("headroom 16,777,216 / G(16) above 3.25x", True, Fr(16_777_216, G_rec(16)) > Fr(325, 100)),
    ("largest n with G(n) <= 16,777,216", 64, max(n for n in range(1, 200) if G_rec(n) <= 16_777_216)),
])

# ---------------- (f) one shortfall rule for every caller, no shared settlement pool ----------------
# liquidate, the one entry point, computes gap = max(0, D + A + B - Kf - R) and shortfall = max(0, minRec - R, gap)
# (modelled below with A + B folded into the amount owed, cP; MATH-ST-121 shows gap <= max(0, minRec - R) since Kf >= D)
# from the call's own amounts; no balance outside the call funds a settlement, so no market's liquidations can use up
# another market's ability to settle (SPEC-SET-001, REQ-SWAP-073, Q-397).
NC = 3
cD, cP, cK, cR, cM, cX, cS = (IntVector(n, NC) for n in ("D", "AplusB", "Kf", "R", "minRec", "maxShortfall", "shortfall"))
def _sf(k):
    g = pos(cD[k] + cP[k] - cK[k] - cR[k]); f_ = pos(cM[k] - cR[k])
    return If(f_ > g, f_, g), g, f_
pool, pool2 = Ints("sharedPool sharedPoolAfter")
cdom = [pool >= 0]
for k in range(NC):
    sfk, gk, fk = _sf(k)
    cdom += [cD[k] >= 0, cP[k] >= 0, cK[k] >= cD[k], cR[k] >= 0, cM[k] >= 0, cX[k] >= 0, cS[k] == sfk,
             cM[k] - cR[k] <= cX[k], gk <= cX[k]]
# MATH-ST-109 verifies: SPEC-SET-001, SPEC-LIQ-019, REQ-SWAP-073, INV-097, AMMN-RT-13, Q-397
check("MATH-ST-109",
      f"{NC} liquidations on different markets, in any order: each settles with Kf + R' >= D + A + B and R' >= minRec "
      f"from its own caller's funds and top-up, whatever the others did",
      cdom + [Or(*[Or(cK[k] + cR[k] + cS[k] < cD[k] + cP[k], cR[k] + cS[k] < cM[k], cS[k] > cX[k])
                   for k in range(NC)])],
      "PROVED")
# MATH-ST-109 verifies: SPEC-SET-001, AMMN-RT-13
check("MATH-ST-109",
      "wrong reading (a shared pool closing gaps): one market's gaps drain the pool and the next market's call "
      "cannot settle (counterexample expected)",
      [pool == 25, pool2 == pool - 25, cD[0] == 100, cP[0] == 0, cK[0] == 0, cR[0] == 75,
       cD[1] == 100, cP[1] == 0, cK[1] == 0, cR[1] == 99, pool2 < cD[1] - cR[1]],
      "COUNTEREXAMPLE", show=[pool, pool2])
# MATH-ST-109 verifies: REQ-SWAP-073, SPEC-SET-001
computed("MATH-ST-109", "REQ-SWAP-073 examples (USDC, 6 decimals): the dust call, any caller", [
    ("Kf = 3: shortfall", 0, max(0, 3_000_000 - 3_000_000 - 2_950_000)),
    ("Kf = 3: keeperOut (2.95 USDC)", 2_950_000, (3_000_000 + 2_950_000) - 3_000_000),
    ("through the helper, F = 3 at 5 bps: top-up (0.0515 USDC)", 51_500,
     max(0, 3_000_000 + 1_500 - ((3_000_000 + 2_950_000) - 3_000_000))),
    ("through the helper: net payout", 0, (2_950_000 + 51_500) - 3_000_000 - 1_500),
])

# ---------------- (g) flash lender and premium (LIQ-POST-020, REQ-FLASH-005, Q-388) ----------------
NH = 4
hubs = IntVector("recordedHub", NH)
lender, home, funding, Fl, ph, mfl, cb = Ints("lender homeHub fundingHub F phi maxFlashFeeBps costsBps")
notHub = And(*[lender != hubs[k] for k in range(NH)])
ok = And(notHub, ph * BPS <= mfl * Fl)
fdom = [Fl > 0, Fl < 2**128, ph >= 0, mfl >= 0, mfl <= 10_000, Or(*[home == hubs[k] for k in range(NH)]),
        Or(*[funding == hubs[k] for k in range(NH)])] + ceil_div(cb, ph * BPS, Fl)
# MATH-ST-110 verifies: LIQ-POST-020, REQ-FLASH-002, REQ-FLASH-005, REQ-FLASH-006, REQ-SWAP-013, REQ-HELPER-002, REQ-HELPER-005, SPEC-LIQ-015, INV-095, Q-388
check("MATH-ST-110",
      "a deleverage or helper loan that passes the checks draws from no recorded Hub (neither the home Hub, the funding "
      "Hub nor any other Hub of the chain) and has a premium rate <= maxFlashFeeBps",
      fdom + [ok, Or(lender == home, lender == funding, *[lender == hubs[k] for k in range(NH)], cb > mfl)],
      "PROVED")
# MATH-ST-110 verifies: REQ-FLASH-005, Q-388
check("MATH-ST-110",
      "wrong reading (N1): comparing the lender with the home Hub only admits a source that draws from another "
      "recorded Hub, for example another market's Hub (counterexample expected)",
      fdom + [lender != home, Or(*[lender == hubs[k] for k in range(NH)])],
      "COUNTEREXAMPLE", show=[lender, home])
# MATH-ST-110 verifies: SPEC-LIQ-015
check("MATH-ST-110",
      "wrong reading: a premium check against the rounded-down rate admits a premium above maxFlashFeeBps x F "
      "(counterexample expected)",
      fdom + [Int("rdown") * Fl <= ph * BPS, ph * BPS < (Int("rdown") + 1) * Fl, Int("rdown") <= mfl,
              ph * BPS > mfl * Fl],
      "COUNTEREXAMPLE", show=[Fl, ph, mfl])

# ---------------- (h) flash repayment by balance delta (REQ-SWAP-122, Q-390) ----------------
# USDT: fee(x) = min(floor(x rho / 1e4), maxFee), with rho < 20 and maxFee < 50 tokens (6 decimals).
owed, Mf = Ints("owed maxFee")
for rho in (1, 10, 19):
    nd = [owed]
    cons = [owed > 0, owed < 2**128, Mf >= 0, Mf <= 50 * 10**6]
    for k in range(4):
        fq = Int(f"feeq_{rho}_{k}")
        cons += floor_div(fq, nd[k] * rho, BPS)
        nd.append(If(fq < Mf, fq, Mf))
    delivered = Sum([nd[k] - nd[k + 1] for k in range(4)])
    # MATH-ST-111 verifies: REQ-SWAP-122, REQ-FLASH-003, Q-390
    check("MATH-ST-111",
          f"rho = {rho} bps: four top-up transfers bring the flash source's balance to exactly owed "
          "(residual 0, delivered = owed, sent P >= owed)",
          cons + [Or(nd[4] != 0, delivered != owed, Sum(nd[:4]) < owed)],
          "PROVED")
    if rho == 19:
        # MATH-ST-111 verifies: REQ-SWAP-122
        check("MATH-ST-111",
              "boundary: three transfers can leave a residual at rho = 19 bps (counterexample expected)",
              cons + [nd[3] > 0],
              "COUNTEREXAMPLE", show=[owed, Mf])
def _usdt(x, rho=10, mx=49 * 10**6):
    return x - min(x * rho // BPS, mx)
need, sent, got = 5_002_500_000, [], 0
while need > 0 and len(sent) < 4:
    sent.append(need); got += _usdt(need); need = 5_002_500_000 - got
# MATH-ST-111 verifies: REQ-SWAP-122
computed("MATH-ST-111", "REQ-SWAP-122 example: USDT at 10 bps, owed 5,002.5 USDT", [
    ("transfers", [5_002_500_000, 5_002_500, 5_002, 5], sent), ("source holds owed", 5_002_500_000, got),
    ("P (raw)", 5_007_507_507, sum(sent)),
])

# ---------------- (i) measured conservation with a transfer fee (SPEC-LIQ-010, REQ-SWAP-108, Q-390) ----------------
# Here K is the amount pulled (X) and Kr what arrived (Kf); pf is the fee on the keeperOut transfer.
# This is the general form for measured amounts. A fee on the debt asset itself never reaches it on Aave V4: the Hub
# refuses the fee-reduced repayment (InsufficientTransferred) and the liquidation reverts (REQ-SWAP-123). The form still
# covers a funding transfer that delivers less than asked and a payout that arrives short.
Kr, Fr_, P, pf = Ints("Kf_measured Fr P payoutFee")
mdom = base + [Kr >= D, Kr <= K, Fr_ == 0, P == 0, pf >= 0, pf <= (Kr + Rp) - (D + A + B)]
keeperOutM = (Kr + Rp) - (D + A + B)
tau = (K - Kr) + pf
# MATH-ST-112 verifies: SPEC-LIQ-010, REQ-SWAP-108, REQ-SWAP-123, Q-390, Q-404
check("MATH-ST-112",
      "with the measured Kf the T balance identity holds, the fee cost tau = (X - Kf) + payout fee >= 0 falls on what "
      "the caller receives alone (received = keeperOut0 - tau), and A, kr, B keep their fee-free values",
      mdom + [Or((Kr + R + sf) != (D + A + B + keeperOutM), tau < 0, keeperOutM - pf != keeperOut - tau)],
      "PROVED")
# MATH-ST-112 verifies: REQ-SWAP-108, SPEC-LIQ-010
check("MATH-ST-112",
      "wrong reading: charging the fee cost to the surplus (S - tau) lowers Avana's fee or the borrower surplus below "
      "their fee-free values (counterexample expected); the rule charges it to keeperOut only",
      mdom + [tau > 0, Or(zmin(Au, pos(Rp - D - phiD - tau)) < A,
                          pos(Rp - D - phiD - tau) - zmin(Au, pos(Rp - D - phiD - tau))
                          - (zmin(pos(Rp - D - phiD - tau), G) - zmin(Au, pos(Rp - D - phiD - tau))) < B)],
      "COUNTEREXAMPLE", show=[tau, R, D])
# MATH-ST-112 verifies: REQ-SWAP-108
computed("MATH-ST-112", "measured funding: a 10 bps fee on the funding transfer of debtToCover = 5,000 USDT", [
    ("Kf after the caller's transfer", 4_995_000_000, _usdt(5_000 * 10**6, 10)),
])

done()
