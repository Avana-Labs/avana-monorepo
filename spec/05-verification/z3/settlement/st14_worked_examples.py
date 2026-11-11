# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-80..95: every worked example of the settlement pages, recomputed in exact integers.

Pages: 2.11 LPVaultSwap (SPEC-LIQ-001..020), 2.12 settlement routes, 2.13 the caller's rounding gap (SPEC-SET-001),
2.14 First-Loss reserve (SPEC-FLR-001..005), 2.18 payout escrow, 3.5 Liquidation (LIQ-060, LIQ-068, LIQ-069),
3.7 Collect fees, 3.9 Deficit coverage. GHO amounts are wei; a stated decimal figure is converted exactly.
Figures the text marks as approximate ("about", "≈") are compared after rounding the exact value to the stated
digits. Each row prints the stated and the exact value; any difference is a MISMATCH.
"""
from decimal import Decimal
from fractions import Fraction as Fr
from _common import computed, done

E18 = 10**18
RAY = 10**27
BPS = 10_000
PG = 10**8
VV = 10**6


def g(x):
    """GHO (or 18-decimal) amount written in decimal -> wei, exact."""
    v = Decimal(str(x).replace(",", "")) * E18
    assert v == v.to_integral_value(), x
    return int(v)


def cdiv(a, b):
    return -(-a // b)


def rnd(fr, digits):
    """Round a Fraction half up to `digits` decimals, returned as a Decimal string comparable to the text."""
    q = Decimal(fr.numerator) / Decimal(fr.denominator)
    return q.quantize(Decimal(1).scaleb(-digits), rounding="ROUND_HALF_UP")


def flash_fee(x, f):
    return (x * f + 5_000) // BPS


def s_two(bnet, costs, cbuy, allow):
    num = bnet * BPS - (BPS + costs) * (BPS + cbuy)
    return 0 if num <= 0 else min(allow, (BPS * num) // (bnet * BPS))


def unit_val(p, d):
    return cdiv(p * E18, 10**d * PG)


def leg_val_up(a, p, d):
    return cdiv(a * p * E18, 10**d * PG)


def bound(X, pd, dd, cb):
    return cdiv(X * pd * E18 * (BPS + cb), 10**dd * PG * BPS)


def min_gho(V, s, U, allow=E18):
    return max(0, cdiv(V * (BPS - s), BPS) - U - allow)


# ---------------- 2.11 LPVaultSwap, GHO debt market: dv 18, Pc $2.10, legs USDC/USDT 6 decimals ----------------
PC = 210_000_000
# MATH-ST-80 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-016
computed("MATH-ST-80", "SPEC-LIQ-001/002/003/016 examples", [
    ("bNet(10,500, lf 0)", 10_500, BPS + (500 * BPS) // BPS),
    ("bNet(10,500, lf 1,000)", 10_450, BPS + (500 * 9_000) // BPS),
    ("costsBps(phi 1.8, F 2,000)", 9, cdiv(g("1.8") * BPS, g(2_000))),
    ("s at b 10,500 (uncapped)", 476, (BPS * 500) // 10_500),
    ("s at b 10,500", 100, s_two(10_500, 0, 0, 100)),
    ("10,500 x 9,900", 103_950_000, 10_500 * 9_900),
    ("s at b 10,050", 49, (BPS * 50) // 10_050),
    ("two legs, bNet 10,200, cBuy 30 (uncapped)", 166, (BPS * (102_000_000 - 100_300_000)) // 102_000_000),
    ("cBuy 150", 49, s_two(10_200, 0, 150, 100)),
    ("10,200 x 9,951 x 1e4", 1_015_002_000_000, 10_200 * 9_951 * BPS),
    ("1e4 x 1e4 x 10,150", 1_015_000_000_000, BPS * BPS * 10_150),
    ("cBuy 300 gives s = 0", 0, s_two(10_200, 0, 300, 100)),
])

c975 = 975 * E18
V975 = c975 * PC * E18 // (E18 * PG)
U2 = 2 * unit_val(PG, 6)
term975 = cdiv(V975 * 9_900, BPS)
cdust = g("1.5")
Vdust = cdust * PC * E18 // (E18 * PG)
# MATH-ST-81 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-006
computed("MATH-ST-81", "SPEC-LIQ-004/005 examples (975-unit seizure and the 3 GHO dust seizure)", [
    ("c = 1,950 x 1.05 / 2.10 vault tokens", c975, Fr(1_950) * Fr(105, 100) / Fr(210, 100) * E18),
    ("V", g("2047.5"), V975),
    ("U", 2 * 10**12, U2),
    ("slippage term", g("2027.025"), term975),
    ("minGho", g("2026.024998"), min_gho(V975, 100, U2)),
    ("dust c", cdust, Fr(3) * Fr(105, 100) / Fr(210, 100) * E18),
    ("dust V", g("3.15"), Vdust),
    ("dust slippage term", g("3.1185"), cdiv(Vdust * 9_900, BPS)),
    ("dust minGho", g("2.118498"), min_gho(Vdust, 100, U2)),
    ("R = 2.95 passes the dust floor", True, g("2.95") >= min_gho(Vdust, 100, U2)),
    ("dust gap the caller tops up", g("0.05"), g(3) - g("2.95")),
])

f9 = 9
# MATH-ST-82 verifies: SPEC-LIQ-007, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010
computed("MATH-ST-82", "SPEC-LIQ-007..010 examples", [
    ("phi(2,000) at 9 bps", g("1.8"), flash_fee(g(2_000), f9)),
    ("phiD = flashFee(1,950)", g("1.755"), flash_fee(g(1_950), f9)),
    ("caller-only difference", g("0.045"), flash_fee(g(2_000), f9) - flash_fee(g(1_950), f9)),
    ("K 950, F 1,000: phi", g("0.9"), flash_fee(g(1_000), f9)),
    ("K 950, F 1,000: phiD = flashFee(min(F, Gcov))", g("0.9"), flash_fee(min(g(1_000), g(1_950)), f9)),
    ("S (R 2,040.3)", g("90.3"), g("2040.3") - g(1_950)),
    ("S dust", 0, max(0, g("2.95") - g(3))),
    ("S USDC", g(85), g(5_085) - g(5_000)),
    ("A", g("19.5"), min((V975 - g(1_950)) * 2_000 // BPS, g("90.3"))),
    ("S after self-sandwich to 2,027", g(77), g(2_027) - g(1_950)),
    ("A after self-sandwich", g("19.5"), min((V975 - g(1_950)) * 2_000 // BPS, g(77))),
    ("A USDC", g("17.96"), min((g("5089.80") - g(5_000)) * 2_000 // BPS, g(85))),
    ("S USDC at R 5,037.902", g("37.902"), g("5037.902") - g(5_000)),
    ("A USDC at R 5,037.902", g("17.96"), min((g("5089.80") - g(5_000)) * 2_000 // BPS, g("37.902"))),
    ("keeperOut", g("70.8"), (0 + g(1_950) + g("2040.3") + 0) - (g(1_950) + g(1_950) + 0 + g("19.5"))),
    ("keeperOut dust", 0, (0 + g(3) + g("2.95") + g("0.05")) - (g(3) + g(3))),
    ("keeperOut USDC", g("67.04"), (g(5_015) + g(5_085)) - (g(5_000) + g(5_015) + g("17.96"))),
    ("USDC GHO in", g(10_110), g(5_015) + g(5_085) + g(10)),
    ("USDC GHO out", g(10_110), g(5_010) + g(5_015) + g("17.96") + g("67.04")),
])

# Payout escrow (REQ-SWAP-076, REQ-ESCROW-003, REQ-ESCROW-018): a USDC fee whose transfer the token refuses.
PAYOUT_GAS, POST_CALL_GAS = 100_000, 10_000           # LPVaultSwap's own post-call reserve (2.11 REQ-SWAP-076)
# MATH-ST-83 verifies: SPEC-LIQ-011, REQ-SWAP-076, REQ-ESCROW-003, REQ-ESCROW-018
computed("MATH-ST-83", "payout escrow example (USDC, 6 decimals): blocklisted fee recipient", [
    ("gas required per payout", 111_588, cdiv(PAYOUT_GAS * 64, 63) + POST_CALL_GAS),
    ("fee escrowed for the fee recipient (19.305 USDC)", 19_305_000, 19_305_000),
    ("keeperOut still paid (70.02 USDC)", 70_020_000,
     (0 + 1_950_000_000 + 2_040_300_000) - (1_950_000_000 + 1_950_975_000 + 19_305_000)),
    ("LPVaultSwap ends at 0: K + F + R = D + (F + phi) + A + keeperOut", 0, (0 + 1_950_000_000 + 2_040_300_000)
     - (1_950_000_000 + 1_950_975_000 + 19_305_000 + 70_020_000)),
])

# SPEC-LIQ-014: USDT at $0.9995, so U = Uleg(USDC) + Uleg(USDT) = 1e12 + 0.9995e12.
VP = leg_val_up(41_200_000, PG, 6) + leg_val_up(42_600_000, 99_950_000, 6)
U14 = unit_val(PG, 6) + unit_val(99_950_000, 6)
# MATH-ST-84 verifies: SPEC-LIQ-014
computed("MATH-ST-84", "SPEC-LIQ-014 example (pending settlement, USDT at $0.9995)", [
    ("V_P", g("83.7787"), VP),
    ("s_P", 30, min(100, 30)),
    ("slippage term", g("83.5273639"), cdiv(VP * 9_970, BPS)),
    ("U", 1_999_500_000_000, U14),
    ("minPending", g("82.5273619005"), min_gho(VP, 30, U14)),
    ("USDC leg minimum", g("40.576399"), max(1, cdiv(g("41.2") * 9_970, BPS) - unit_val(PG, 6) - E18 // 2)),
], "COMPUTED")

# MATH-ST-85 verifies: SPEC-LIQ-015, SPEC-LIQ-017, REQ-SWAP-088, REQ-ROUTE-006, Q-333, Q-334, Q-335
# Flash of the debt asset itself (Aave V3 Pool premium), no buy leg and no sell-back: the SPEC-LIQ-015/017
# examples of 2.11 and the swap-route examples of 2.12, in USDC base units (6 decimals).
U6 = 10**6
phi_5 = cdiv(1_950 * U6 * 5, BPS)            # 5 bps Pool premium on F = 1,950 USDC
phi_20 = cdiv(1_950 * U6 * 20, BPS)          # premium raised to 20 bps
F17 = 2_047_500_000                           # Lens margin: X = F = 2,047.5 USDC
phi17 = cdiv(F17 * 5, BPS)
phiD17 = cdiv(1_950 * U6 * 5, BPS)
computed("MATH-ST-85", "SPEC-LIQ-015/017 (flash of the debt asset, no buy leg) and the 2.12 route examples", [
    ("phi(1,950 USDC, 5 bps)", 975_000, phi_5),
    ("pre-loan check at 5 bps: phi x 1e4", 9_750_000_000, phi_5 * BPS),
    ("maxFlashFeeBps 10 x F", 19_500_000_000, 10 * 1_950 * U6),
    ("5 bps passes", True, phi_5 * BPS <= 10 * 1_950 * U6),
    ("phi at 20 bps", 3_900_000, phi_20),
    ("20 bps fails: 3.9e10 > 1.95e10", True, phi_20 * BPS > 10 * 1_950 * U6),
    ("s with no buy-leg term equals the one-leg formula", s_two(10_500, 5, 0, 100), min(100, (BPS * (10_500 - BPS - 5)) // 10_500)),
    ("leftover X - D", 97_500_000, F17 - 1_950 * U6),
    ("F + phi repaid", 2_048_523_750, F17 + phi17),
    ("caller-borne phi - phiD", 48_750, phi17 - phiD17),
    ("USDT issuer fee 10 bps: inRecv", 6_205_088_700, 6_211_300_000 * (BPS - 10) // BPS),
    ("LitePSM: gemAmt of 1,000.0000005 DAI", 1_000_000_000, int(Decimal("1000.0000005") * 10**18) // 10**12),
    ("LitePSM: DAI residue below one USDC unit (wei)", 500_000_000_000, int(Decimal("1000.0000005") * 10**18) % 10**12),
    ("one-sided depth: $2,000,000 position needs $2,000,000 per token route", 2_000_000, 2_000_000),
    ("not the half-leg $1,000,000", True, 2_000_000 // 2 < 2_000_000),
])

legmin = max(1, cdiv(g("6211.3") * 9_900, BPS) - unit_val(PG, 6) - E18 // 2)
Vb = g("12422.6")
mg = cdiv(Vb * 9_900, BPS) - U2 - E18
s260 = min(9_999, 100 + min(1_000, (g(200) * BPS) // Vb))
s180 = min(9_999, 100 + min(1_000, (g(100) * BPS) // Vb))
legs180 = Fr(Vb) * Fr(BPS - s180, BPS) - U2 - E18
# MATH-ST-86 verifies: SPEC-LIQ-018, SPEC-LIQ-019, REQ-ROUTE-008, REQ-ROUTE-042
computed("MATH-ST-86", "SPEC-LIQ-018/019 examples and the route-leg examples of 2.12", [
    ("minOut0 (6,211.3 USDC, s 100, n 2)", g("6148.686999"), legmin),
    ("minOut0 to two decimals", "6148.69", str(rnd(Fr(legmin, E18), 2))),
    ("minGho (V 12,422.6)", g("12297.373998"), mg),
    ("sLeg at maxShortfallGho 200", 260, s260),
    ("shortfall at R 12,174", g("123.373998"), mg - g(12_174)),
    ("sLeg at maxShortfallGho 100", 180, s180),
    ("leg minimums at sLeg 180, two decimals", "12197.99", str(rnd(legs180 / E18, 2))),
    ("R 12,174 below them", True, g(12_174) < legs180),
    ("USDT transfer fee 10 bps: inRecv", 6_205_088_700, 6_211_300_000 - 6_211_300_000 * 10 // BPS),
    ("fee", 6_211_300, 6_211_300_000 * 10 // BPS),
])

units = 1_000 * E18
Vd = units * PC * E18 // (E18 * PG)
Vnet = max(0, Vd * 9_900 // BPS - U2 - E18)       # eps = floorRoundingAllowance = 1 GHO
capd = Vnet * BPS // BPS
x = min(g(6_600), capd)
# MATH-ST-87 verifies: SPEC-LIQ-020
computed("MATH-ST-87", "SPEC-LIQ-020 example (repay with collateral, 18-decimal instance, maxFlashFeeBps 0)", [
    ("V", g(2_100), Vd),
    ("Vnet", g("2077.999998"), Vnet),
    ("x", g("2077.999998"), x),
    ("ghoOut", g("18.200002"), g("2096.2") - x),
    ("HF before, 4 decimals", "0.9927", str(rnd(Fr(21_000 * 312, 6_600 * 1_000), 4))),
    ("debt after", g("4522.000002"), g(6_600) - x),
    ("HF after, 4 decimals", "1.3040", str(rnd(Fr(18_900 * 312, 1_000) / Fr(g(6_600) - x, E18), 4))),
    ("threshold CF / (1 - s), 4 decimals", "0.3152", str(rnd(Fr(312, 1_000) / Fr(99, 100), 4))),
])

# ---------------- 2.13 the caller's rounding gap ----------------
# MATH-ST-88 verifies: SPEC-SET-001, SPEC-LIQ-019
computed("MATH-ST-88", "SPEC-SET-001 examples: gap = max(0, D + A + B - Kf - R) with Kf >= D; a recovery below D "
         "is the caller's loss in keeperOut", [
    ("dust loss D - R, Kf = 3", g("0.05"), max(0, g(3) - g("2.95"))),
    ("dust gap with Kf = 3", 0, max(0, g(3) - g("2.95") - g(3))),
    ("liquidation with surplus: gap", 0, max(0, g(5_000) - g(5_000) - g(5_085))),
    ("USDC dust: G for 3 USDC at 0.20 %", g("3.006"), g(3) * 10_020 // BPS),
    ("USDC dust: keeperOut for Kf = 3", g("2.95"), g(3) + g("2.95") - g(3)),
])

# ---------------- 2.14 First-Loss reserve and 3.9 deficit coverage ----------------
A, S = g(2_100_000), g(2_000_000)
defRay = 475_250_000_000_000_000_000 * RAY + 4 * 10**26
amt = min(g(1_000), cdiv(defRay, RAY), g(100_000))
amt300 = min(g(300), cdiv(defRay, RAY), g(100_000))
Aw, Sw = g(12_000), g(11_800)
A2, S2 = g(2_050_000), g(2_000_000)
# MATH-ST-89 verifies: SPEC-FLR-001, SPEC-FLR-002, SPEC-FLR-003, DEF-006
computed("MATH-ST-89", "SPEC-FLR-001..003 and DEF-006 examples (virtual offset 1e6 in the Hub's share math)", [
    ("amount", 475_250_000_000_000_000_001, amt),
    ("shares burned", 452_619_047_619_047_619_060, cdiv(amt * (S + VV), A + VV)),
    ("shares burned, maxAmount 300", 285_714_285_714_285_714_293, cdiv(amt300 * (S + VV), A + VV)),
    ("left recorded, maxAmount 300", defRay - g(300) * RAY, 175_250_000_000_000_000_000 * RAY + 4 * 10**26),
    ("WETH: 3.2 WETH deficit shares", 3_146_666_666_666_666_672, cdiv(g("3.2") * (Sw + VV), Aw + VV)),
    ("fundedBalance", 104_999_999_999_999_999_997_500, g(100_000) * (A + VV) // (S + VV)),
    ("withdrawal executable", 1_781_209_600, 1_780_000_000 + 1_209_600),
    ("withdrawal shares", 38_095_238_095_238_095_239_003, cdiv(g(40_000) * (S + VV), A + VV)),
    ("DEF-006 shares (475.3 GHO at A 2,050,000)", 463_707_317_073_170_731_713, cdiv(g("475.3") * (S2 + VV), A2 + VV)),
    ("DEF-006 left recorded with 300 GHO funded", g("175.3"), g("475.3") - g(300)),
])

h, CF, LB = Fr(95, 100), Fr(312, 1_000), Fr(105, 100)
dLP = Fr(704, 1_000)
k = h * (1 - dLP) / (CF * LB)
gG = Fr(6, 100) * Fr(2, 365)
gW = Fr(3, 100) * Fr(2, 365)
lfG = (1 + Fr(str(rnd(gG, 6)))) - Fr(str(rnd(k, 6)))
lfW = (1 + Fr(str(rnd(gW, 6)))) - Fr(str(rnd(k, 6))) / Fr(12, 10)
# MATH-ST-90 verifies: SPEC-FLR-004
computed("MATH-ST-90", "SPEC-FLR-004 example (USDT -90 %, figures to the stated digits)", [
    ("LP drop 1 - sqrt(0.10), 3 decimals", "0.684", str(rnd(Fr(1) - Fr(31_622_776_601_683_793, 10**17), 3))),
    ("CF x LB", "0.3276", str(rnd(CF * LB, 4))),
    ("0.95 x 0.296 / 0.3276", "0.858364", str(rnd(k, 6))),
    ("g GHO", "0.000329", str(rnd(gG, 6))),
    ("loss factor GHO", "0.141965", str(rnd(lfG, 6))),
    ("GHO reserve need", "99376", str(rnd(Fr(700_000) * Fr(str(rnd(lfG, 6))), 0))),
    ("within 400,000 GHO", True, Fr(700_000) * lfG <= 400_000),
    ("g WETH", "0.000164", str(rnd(gW, 6))),
    ("loss factor WETH", "0.284861", str(rnd(lfW, 6))),
    ("WETH reserve need", "11.39", str(rnd(40 * Fr(str(rnd(lfW, 6))), 2))),
    ("8 % LP drop gives 0", 0, max(Fr(0), 1 + gG - h * Fr(92, 100) / (CF * LB))),
])

factor = Fr(3_120, BPS)                                       # CF_t = 0.312 (tail term x CF_t, MATH-ST-78)
tail8 = cdiv(168_000_000_000_000 * 3_120, BPS)                  # 8-decimal USD, rounded up
tailG = tail8 * 10**18 // PG
# MATH-ST-91 verifies: SPEC-FLR-005, REQ-FLR-041, SPEC-CAP-008
computed("MATH-ST-91", "SPEC-FLR-005 / REQ-FLR-041 examples (tail term x CF_t, proved by MATH-ST-78)", [
    ("factor", "0.312", str(rnd(factor, 3))),
    ("token cap the 400,000 GHO reserve covers", 1_282_051, int(400_000 / factor)),
    ("tail_GHO, 8-decimal USD rounded up", 52_416_000_000_000, tail8),
    ("tail_GHO, whole GHO", 524_160, tail8 // PG),
    ("tailCoverageBps", 7_631, g(400_000) * BPS // tailG),
    ("lowered USDe cap", 1_202_051, int(400_000 / factor) - 80_000),
    ("raised minimum, whole GHO up", 524_160, cdiv(tailG, E18)),
    ("REQ-FLR-041 tail_GHO at $2,480,000", 773_760, cdiv(248_000_000_000_000 * 3_120, BPS) // PG),
    ("REQ-FLR-041 tailCoverageBps", 5_169, g(400_000) * BPS // (cdiv(248_000_000_000_000 * 3_120, BPS) * 10**18 // PG)),
])

# ---------------- 3.5 Liquidation worked examples ----------------
c60 = 4_998_000_000
V60 = c60 * 2 * PG * E18 // (10**6 * PG)
U60 = unit_val(PG, 6) + unit_val(99_980_000, 6)
mg60 = min_gho(V60, 100, U60)
A60 = min((V60 - g(9_800)) * 2_000 // BPS, g(150))
cd = 397_800
Vd60 = cd * 2 * PG * E18 // (10**6 * PG)
# MATH-ST-92 verifies: LIQ-060, SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-SET-001
computed("MATH-ST-92", "LIQ-060 worked example", [
    ("s uncapped", 196, (BPS * 200) // 10_200),
    ("c = 9,800 x 1.02 / 2.00 vault tokens", c60, 9_800 * 102 * 10**6 // 200),
    ("V", g(9_996), V60),
    ("U", 1_999_800_000_000, U60),
    ("slippage term", g("9896.04"), cdiv(V60 * 9_900, BPS)),
    ("minGho", g("9895.0399980002"), mg60),
    ("S", g(150), g(9_950) - g(9_800)),
    ("A", g("39.2"), A60),
    ("keeperOut", g("110.8"), g(9_800) + g(9_950) - (g(9_800) + g(9_800) + A60)),
    ("GHO in = out", g(19_750), g(9_800) + g(9_800) + A60 + g("110.8")),
    ("dust c = 0.78 x 1.02 / 2.00", cd, 78 * 102 * 10**6 // (100 * 100 * 2)),
    ("dust V", g("0.7956"), Vd60),
    ("dust slippage term", g("0.787644"), cdiv(Vd60 * 9_900, BPS)),
    ("dust minGho", 0, min_gho(Vd60, 100, U60)),
    ("dust gap the caller tops up", g("0.01"), g("0.78") - g("0.77")),
    ("dust keeperOut", 0, (g("0.78") + g("0.77") + g("0.01")) - (g("0.78") + g("0.78"))),
])

hf68 = Fr(282_464) * Fr(2_812, BPS) / Fr("79452.85")
restore68 = (Fr(110, 100) * Fr("79452.85") - Fr("79428.88")) / (Fr(110, 100) - Fr(102, 100) * Fr(2_812, BPS))
hf68b = Fr(272_468) * Fr(2_812, BPS) / Fr("69652.85")
# MATH-ST-93 verifies: LIQ-068, SPEC-HUB-005
computed("MATH-ST-93", "LIQ-068 end-to-end example, GHO debt", [
    ("collateral value", 282_464, 141_232 * 2),
    ("weighted collateral, 2 decimals", "79428.88", str(rnd(Fr(282_464) * Fr(2_812, BPS), 2))),
    ("HF, 4 decimals", "0.9997", str(rnd(hf68, 4))),
    ("bonus at HF 0.9997", 10_200, 10_200 + (300 * 3) // 1_000),
    ("restore numerator, 2 decimals", "7969.26", str(rnd(Fr(110, 100) * Fr("79452.85") - Fr("79428.88"), 2))),
    ("restore denominator", "0.813176", str(rnd(Fr(110, 100) - Fr(102, 100) * Fr(2_812, BPS), 6))),
    ("restore, 1 decimal", "9800.2", str(rnd(restore68, 1))),
    ("seized vault tokens", 4_998, 9_800 * 102 // 200),
    ("share drop", 4_998_000_000, 141_232_000_000 - 136_234_000_000),
    ("R", g(9_950), g(4_976) + g(4_974)),
    ("collateral after", 272_468, 136_234 * 2),
    ("debt after", g("69652.85"), g("79452.85") - g(9_800)),
    ("HF after, 5 decimals", "1.09999", str(Decimal(int(hf68b * 10**5)) / 10**5)),
])

hf69 = Fr("40443.98368") / Fr("40456.119927")
restore69 = (Fr(110, 100) * Fr("40456.119927") - Fr("40443.98368")) / Fr("0.813176")
c69 = 2_544_900_000                            # vault tokens, 6 decimals
V69 = c69 * 2 * PG * 10**6 // (10**6 * PG)     # USDC units, Pc $2.00, Pdebt $1.00
U69 = cdiv(PG * 10**6, 10**6 * PG) + cdiv(99_980_000 * 10**6, 10**6 * PG)
mo69 = max(0, cdiv(V69 * 9_900, BPS) - U69 - 1_000_000)
R69 = 2_544_900_000 + 2_540_100_000
D69, F69 = 4_990_000_000, 5_000_000_000
Y69 = max(0, R69 - D69)                        # phi = phiD = 0 (FLASH_BORROWER granted)
G69 = max(0, V69 - D69)
A69 = min(G69 * 2_000 // BPS, Y69)
Kr69 = min(Y69 - A69, G69 - A69)
B69 = Y69 - A69 - Kr69
ko69 = (0 + F69 + R69 + 0) - (D69 + F69 + 0 + A69 + B69)
hf69b = Fr("138736.60") * Fr(2_812, BPS) / Fr("35466.119927")
# MATH-ST-94 verifies: LIQ-069, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-022, LIQ-031
computed("MATH-ST-94", "LIQ-069 end-to-end example, USDC debt, USDC flash, payout in USDC (no buy leg)", [
    ("collateral value", Decimal("143826.40"), Decimal("71913.2") * 2),
    ("weighted collateral", Fr("40443.98368"), Fr("143826.40") * Fr(2_812, BPS)),
    ("HF, 4 decimals", "0.9997", str(rnd(hf69, 4))),
    ("restore, 2 decimals", "4990.00", str(rnd(restore69, 2))),
    ("s", 100, s_two(10_200, 0, 0, 100)),
    ("c = 4,990 x 1.02 / 2.00", c69, 4_990 * 102 * 10**6 // 200),
    ("V", 5_089_800_000, V69),
    ("slippage term", 5_038_902_000, cdiv(V69 * 9_900, BPS)),
    ("U", 2, U69),
    ("minOut", 5_037_901_998, mo69),
    ("R", 5_085_000_000, R69),
    ("unused debt asset X - D", 10_000_000, F69 - D69),
    ("Y", 95_000_000, Y69),
    ("V - D", 99_800_000, G69),
    ("A", 19_960_000, A69),
    ("Kr", 75_040_000, Kr69),
    ("B", 0, B69),
    ("A + Kr + B = Y", Y69, A69 + Kr69 + B69),
    ("keeperOut", 75_040_000, ko69),
    ("USDC conservation in = out", 10_085_000_000, D69 + F69 + A69 + ko69),
    ("vault tokens after", "69368.3", str(Decimal("71913.2") - Decimal("2544.9"))),
    ("collateral after", Decimal("138736.60"), Decimal("69368.3") * 2),
    ("debt after", "35466.119927", str(Decimal("40456.119927") - Decimal("4990"))),
    ("HF after reaches targetHealthFactor 1.10 (exact 1.1000000000085; the page prints 1.09999)", True, hf69b >= Fr(110, 100)),
])

# ---------------- 3.7 Collect fees and 3.9 pending-settlement proceeds ----------------
VP15 = leg_val_up(299_999_999, PG, 6) + leg_val_up(299_999_999, 99_980_000, 6)
# MATH-ST-95 verifies: FEE-POST-001, DEF-015, SPEC-LIQ-014
computed("MATH-ST-95", "3.7 Collect fees and DEF-015 examples", [
    ("fees collected (USD)", "81.12", str(Decimal("41.25") + Decimal("39.87"))),
    ("annualized, 2 decimals (%)", "1.97", str(rnd(Fr("81.12") / 50_000 * Fr(365, 30) * 100, 2))),
    ("DEF-015 V_P", g("599.9399980002"), VP15),
    ("DEF-015 floor, 6 decimals", "597.140176", str(rnd(Fr(min_gho(VP15, 30, U60), E18), 6))),
    ("DEF-015 funded after", g("400599.9"), g(400_000) + g("599.9")),
])

done()
