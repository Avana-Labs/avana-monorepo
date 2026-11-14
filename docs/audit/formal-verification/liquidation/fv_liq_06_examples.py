"""FV-LIQ-06: exact-integer recomputation of every liquidation worked example in 2.11, 2.12,
2.13, 2.14, 2.17, 2.18, 3.5 and 3.9, and the counterexamples of the earlier findings re-run
against the final rules.

Every amount is an integer in base units (debt-asset or token base units, vault-token units);
every settlement amount is in the debt asset of the repaid reserve, which the caller funds and
every leg swaps into; every rounding follows the spec text. A liquidation is funded by its caller
only (Q-404): LPVaultSwap takes no flash loan in `liquidate`, and a flash liquidation helper's loan
and premium appear only in the helper's own top-up and payout. The 2.11 examples are the
Ethereum Uniswap v3 USDC/USDT market with a USDC debt reserve; examples on a GHO debt reserve
keep 18-decimal GHO units. Aave's sizing and seizure come from the exact port
in aave_ref.py. A check passes when every number the text states recomputes digit for digit.
Text that does not recompute is recorded with `replay(..., violated=True)` under a title that
starts with "NEW FINDING:", showing the stated and the computed value. A check whose id ends in
"m" re-runs a superseded rule (the text before the fix) and passes when that rule still fails on
the counterexample, so it shows what the fix changed.
"""
from decimal import Decimal, getcontext

import aave_ref as A
from _lib import (BPS, RAY, RESULTS, WAD, ceil_div, check, finish, mul_div_down, mul_div_up, percent_mul_half_up,
                  replay, sat_sub)

getcontext().prec = 90
E18 = 10**18
P8 = 10**8


def W(s, dec=18):
    """Exact base units of a decimal string such as "2,026.024998"."""
    v = Decimal(s.replace(",", "")) * (Decimal(10) ** dec)
    assert v == v.to_integral_value(), s
    return int(v)


def U6(s):
    return W(s, 6)


def fmt(x, dec=18):
    return str(Decimal(x) / (Decimal(10) ** dec))


def mutant(check_id, title, violated, detail=""):
    """The superseded rule fails on the counterexample (the fix is what removes the failure)."""
    RESULTS.append((check_id, "Mutant caught" if violated else "Unexpectedly holds", f"{title} {detail}".strip()))
    print(f"[{'PASS' if violated else 'FAIL'}] {check_id} {title}: "
          f"{'old rule fails' if violated else 'old rule holds'} {detail}".rstrip())
    return violated


# ---------------------------------------------------------------- SettlementMath reference (2.11, 2.13)
def net_bonus(b, lf):                                          # SPEC-LIQ-001
    return BPS + (b - BPS) * (BPS - lf) // BPS


def eff_slip(bnet, allow):                                     # SPEC-LIQ-003 (no premium term, SPEC-LIQ-002)
    if bnet > BPS:
        return min(allow, BPS * (bnet - BPS) // bnet)
    return 0


def seized_value(c, pc, dv, pg=P8, dd=18):                     # SPEC-LIQ-004, debt units of dd decimals
    return mul_div_down(c * pc, 10**dd, 10**dv * pg)


def unit_value(p, d, pg=P8, dd=18):                            # one raw unit of a leg, SPEC-LIQ-005
    return ceil_div(p * 10**dd, 10**d * pg)


def leg_value_up(a, p, d, pg=P8, dd=18):                       # SPEC-LIQ-012 term
    return mul_div_up(a * p, 10**dd, 10**d * pg)


def recovery_floor(V, s, U, fra=E18):                          # SPEC-LIQ-005 / SPEC-LIQ-014
    return sat_sub(ceil_div(V * (BPS - s), BPS), U + fra)


def leg_min_out(a, p, d, s_leg, n, fra=E18, pg=P8, dd=18):     # SPEC-LIQ-018
    vleg = mul_div_down(a * p, 10**dd, 10**d * pg)
    return max(1, ceil_div(vleg * (BPS - s_leg), BPS) - unit_value(p, d, pg, dd) - fra // n)


def flash_fee(amount, fee_bps):                                # Aave V3 Pool flash premium (percentMul, half up)
    return percent_mul_half_up(amount, fee_bps) if amount > 0 else 0


def flash_quote(amount, fee_bps):                              # helper / source quote, REQ-HELPER-009 (ceiling)
    return ceil_div(amount * fee_bps, BPS) if amount > 0 else 0


def waterfall(Kf, R, D, V, share=2000, min_rec=0, max_shortfall=None, F=None, fee_bps=0):
    """SPEC-LIQ-008..010, SPEC-LIQ-019, SPEC-LIQ-022, SPEC-SET-001 (final text, Q-397, Q-404), all in the debt asset.
    The caller funds Kf (0 < D <= Kf); no flash principal or premium enters any term: R_f = max(R, minRec),
    S = max(0, R_f - D), G = max(0, V - D), A = min(floor(G x share / 1e4), S), kr = min(S, G) - A, B = S - A - kr,
    g = max(0, D + A + B - Kf - R), shortfall = max(0, minRec - R, g), keeperOut = Kf + R + shortfall - D - A - B.
    `max_shortfall` None = no limit. With `F` set, a flash liquidation helper funded the call with a loan of F at
    `fee_bps` (Kf = X): it pulls topUp = max(0, F + phi - keeperOut) from its caller, repays F + phi and pays its
    caller payout = keeperOut + topUp - F - phi (REQ-HELPER-007, REQ-HELPER-008)."""
    floor_gap = sat_sub(min_rec, R)
    Rf = R + floor_gap
    S = sat_sub(Rf, D)
    G = sat_sub(V, D)
    fee = G * share // BPS
    A_ = min(fee, S)
    kr = min(S, G) - A_
    B = S - A_ - kr
    gap = sat_sub(D + A_ + B, Kf + R)
    sh = max(floor_gap, gap)
    kout = (Kf + R + sh) - (D + A_ + B)
    err = None
    if max_shortfall is not None and floor_gap > max_shortfall:
        err = "RecoveryBelowFloor"
    elif (max_shortfall is not None and gap > max_shortfall) or kout < 0:
        err = "InsufficientProceeds"
    out = dict(Rf=Rf, S=S, G=G, fee=fee, A=A_, kr=kr, B=B, gap=gap, floor_gap=floor_gap, shortfall=sh,
               keeperOut=kout, err=err)
    if F is not None:
        phi = flash_fee(F, fee_bps)
        top = sat_sub(F + phi, kout)
        out.update(phi=phi, topUp=top, payout=kout + top - F - phi)
    return out


def aave_account(coll_units, dv, pc, debt, dd, pdebt, x, cf=2812, idx=RAY, prem=0):
    """Borrow Spoke account with one collateral reserve and one debt reserve (launch LiquidationConfig)."""
    coll_val = A.to_value(coll_units, dv, pc)
    debt_val_ray = (debt * idx + prem) * pdebt * 10**(18 - dd)
    hf = mul_div_down(coll_val * cf, WAD * RAY, BPS * debt_val_ray)
    p = A.Params(supplied_shares=coll_units, coll_A=10**30, coll_S=10**30, coll_decimals=dv, coll_price=pc,
                 drawn_shares=debt, premium_debt_ray=prem, drawn_index=idx, total_debt_value_ray=debt_val_ray,
                 debt_decimals=dd, debt_price=pdebt, debt_to_cover=x, collateral_factor=cf,
                 hf_for_max_bonus=9 * 10**17, bonus_factor=4000, max_lb=10_500, target_hf=11 * 10**17, hf=hf)
    return p, hf


U2 = 2 * unit_value(P8, 6)                                     # two 6-decimal legs at $1.00
U_usdt = unit_value(P8, 6) + unit_value(99_980_000, 6)         # USDC $1.00 + USDT $0.9998


# ================================================================ 2.11 SettlementMath (USDC debt reserve, dd = 6)
EPS6 = 10**6                                                   # floorRoundingAllowance: 1 USDC
U_usdc = unit_value(P8, 6, dd=6) + unit_value(99_950_000, 6, dd=6)   # USDC $1.00 + USDT $0.9995, one unit each
# FV-LIQ-06 verifies: SPEC-LIQ-001
check("FV-LIQ-06a", "2.11 SPEC-LIQ-001: bNet(10,500, 0) = 10,500; bNet(10,500, 1,000) = 10,450",
      net_bonus(10_500, 0) == 10_500 and net_bonus(10_500, 1_000) == 10_450)
# The 2.11 liquidation: D = Kf = 1,950 USDC, b = 10,500, c = 975 vault tokens (dv = 18) at Pc = 2.10.
c975 = 975 * E18
V975 = seized_value(c975, 210_000_000, 18, dd=6)
min975 = recovery_floor(V975, 100, U_usdc, EPS6)
D975 = 1_950 * 10**6
w975 = waterfall(D975, U6("2040.3"), D975, V975, min_rec=min975)
w975s = waterfall(D975, U6("2027"), D975, V975, min_rec=min975)
w975h = waterfall(D975, U6("2040.3"), D975, V975, min_rec=min975, F=D975, fee_bps=5)
# FV-LIQ-06 verifies: SPEC-LIQ-002, REQ-HELPER-009, REQ-HELPER-008
check("FV-LIQ-06b", "2.11 SPEC-LIQ-002 / REQ-HELPER-009: no cost term in LPVaultSwap; a helper that flash-borrows "
      "F = 1,950 USDC at the 5 bps Pool premium quotes and pays phi = ceil(1,950e6 x 5 / 1e4) = 975,000 (0.975 USDC) out "
      "of its 2,020.8 USDC payout; with FLASH_BORROWER it quotes 0; LPVaultSwap's s, minRec, A and kr are the same for "
      "a caller funding from its own balance",
      flash_quote(D975, 5) == 975_000 == flash_fee(D975, 5) and flash_quote(D975, 0) == 0
      and w975h["phi"] == 975_000 and w975["keeperOut"] == U6("2020.8")
      and all(w975h[k] == w975[k] for k in ("S", "G", "A", "kr", "B", "shortfall", "keeperOut")))

# FV-LIQ-06 verifies: SPEC-LIQ-003, SPEC-LIQ-016
check("FV-LIQ-06c", "2.11 SPEC-LIQ-003/016: s = min(100, floor(1e4 x 500 / 10,500) = 476) = 100 and 10,500 x 9,900 = "
      "103,950,000 >= 1e8; bonus 10,050 caps it at 49 (10,050 x 9,951 = 100,007,550 >= 1e8); listing liveness: "
      "10,200 x 9,950 = 101,490,000 >= 1e4 x 10,010 = 100,100,000 passes, 10,060 x 9,950 = 100,097,000 meets 1e8 but "
      "not 100,100,000, 10,050 x 9,950 = 99,997,500 fails both",
      BPS * 500 // 10_500 == 476 and eff_slip(10_500, 100) == 100 and 10_500 * 9_900 == 103_950_000 >= 10**8
      and eff_slip(10_050, 100) == 49 and 10_050 * (BPS - 49) == 100_007_550 >= 10**8
      and 10_050 * (BPS - 50) < 10**8
      and 10_200 * 9_950 == 101_490_000 >= BPS * 10_010 == 100_100_000
      and 10**8 <= 10_060 * 9_950 == 100_097_000 < 100_100_000 and 10_050 * 9_950 == 99_997_500 < 10**8)

# FV-LIQ-06 verifies: SPEC-LIQ-004, SPEC-LIQ-005
check("FV-LIQ-06d", "2.11 SPEC-LIQ-004/005: V = 2,047,500,000 (2,047.5 USDC), U = 1 + 1 = 2, slippage term 2,027,025,000, "
      "minRec = 2,026,024,998 (2,026.024998 USDC)",
      V975 == 2_047_500_000 and U_usdc == 2 and ceil_div(V975 * 9_900, BPS) == 2_027_025_000
      and min975 == 2_026_024_998, f"minRec={min975}")

t_in = D975 + U6("2040.3") + w975["shortfall"]
t_out = D975 + w975["A"] + w975["B"] + w975["keeperOut"]
# FV-LIQ-06 verifies: SPEC-LIQ-006, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022
check("FV-LIQ-06e", "2.11 SPEC-LIQ-006/008/009/010/022: Kf = D = 1,950 USDC, R = 2,040.3 USDC (a 5 USDC donation in both "
      "readings leaves it), S = 90.3, G = 97.5, A = min(19.5, 90.3) = 19.5, kr = 70.8, B = 0, keeperOut = 2,020.8 = "
      "Kf + kr, 3,990.3 USDC in = out; sandwiched to R = 2,027 >= minRec: S = 77 and A = 19.5",
      (U6("2040.3") + U6("5")) - U6("5") == U6("2040.3")
      and w975["S"] == U6("90.3") and w975["G"] == U6("97.5") and w975["A"] == U6("19.5")
      and w975["kr"] == U6("70.8") and w975["B"] == 0 and w975["shortfall"] == 0
      and w975["keeperOut"] == U6("2020.8") == D975 + w975["kr"] and w975["err"] is None
      and t_in == t_out == U6("3990.3") and U6("2027") >= min975 and w975s["S"] == U6("77")
      and w975s["A"] == U6("19.5"), f"keeperOut={w975['keeperOut']}")

# SPEC-LIQ-009 best-effort share: b = 10,100, lf = 0, Kf = D = 1,000,000 USDC, V = D x 10,100 / 1e4.
D9 = U6("1000000")
s9 = eff_slip(10_100, 100)
V9 = D9 * 10_100 // BPS
m9 = recovery_floor(V9, s9, U_usdc, EPS6)
w9r = waterfall(D9, V9 * 9_995 // BPS, D9, V9, min_rec=m9)
w9f = waterfall(D9, m9, D9, V9, min_rec=m9)
# FV-LIQ-06 verifies: SPEC-LIQ-009, SPEC-LIQ-003, SPEC-LIQ-010
check("FV-LIQ-06bh", "2.11 SPEC-LIQ-009 best effort: b = 10,100 gives s = min(100, 99) = 99, V = 1,010,000 USDC, minRec = "
      "ceil(1,010,000 x 0.9901) - 0.000002 - 1 = 999,999.999998 < D; routes at 0.9995 V = 1,009,495 pay A = 2,000 and "
      "kr = 7,495; routes at the floor pay A = 0, kr = 0 and keeperOut = Kf - 0.000002; the 2.11 market keeps the share "
      "exact (minRec 2,026.024998 >= D + A = 1,969.5)",
      s9 == 99 and V9 == U6("1010000") and m9 == U6("999999.999998") and m9 < D9
      and V9 * 9_995 // BPS == U6("1009495") and w9r["A"] == U6("2000") and w9r["kr"] == U6("7495")
      and w9f["A"] == 0 and w9f["kr"] == 0 and w9f["shortfall"] == 0 and w9f["keeperOut"] == D9 - 2
      and min975 >= D975 + w975["A"] == U6("1969.5"))

# Dust: D = Kf = 3 USDC, c = 1.5 vault tokens, R = 2.95 USDC.
Vd = seized_value(15 * E18 // 10, 210_000_000, 18, dd=6)
md = recovery_floor(Vd, 100, U_usdc, EPS6)
wd = waterfall(U6("3"), U6("2.95"), U6("3"), Vd, min_rec=md)
wd0 = waterfall(U6("3"), U6("2.95"), U6("3"), Vd, min_rec=md, max_shortfall=0)
wdh = waterfall(U6("3"), U6("2.95"), U6("3"), Vd, min_rec=md, max_shortfall=0, F=U6("3"), fee_bps=5)
# FV-LIQ-06 verifies: SPEC-LIQ-005, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-073, REQ-HELPER-007
check("FV-LIQ-06f", "2.11/2.13 dust: V = 3.15 USDC, slippage term 3.1185, minRec = 2.118498 <= R = 2.95; Kf = D = 3: "
      "S = A = B = 0, g = max(0, 3 + 0 + 0 - 3 - 2.95) = 0, shortfall 0, keeperOut = 3 + 2.95 - 3 = 2.95 (a 0.05 USDC "
      "loss), and the call settles with maxShortfall = 0; through the helper with F = 3 at 5 bps: phi = 0.0015, top-up "
      "0.0515, repays 3.0015, pays its caller 0",
      Vd == 3_150_000 and ceil_div(Vd * 9_900, BPS) == 3_118_500 and md == 2_118_498 and U6("2.95") >= md
      and wd["S"] == 0 and wd["A"] == 0 and wd["B"] == 0 and wd["gap"] == 0 and wd["shortfall"] == 0
      and wd["keeperOut"] == U6("2.95") and U6("3") - wd["keeperOut"] == U6("0.05") and wd["err"] is None
      and wd0["err"] is None and wdh["phi"] == 1_500 and wdh["topUp"] == 51_500 and U6("3") + wdh["phi"] == 3_001_500
      and wdh["payout"] == 0)

wlh = waterfall(U6("2047.5"), U6("2040.3"), D975, V975, min_rec=min975, F=U6("2047.5"), fee_bps=5)
# FV-LIQ-06 verifies: SPEC-LIQ-007, SPEC-LIQ-017, REQ-HELPER-007, REQ-HELPER-008, Q-404
check("FV-LIQ-06g", "2.11 SPEC-LIQ-007 (no phiD): the Lens margin X = 2,047.5 USDC borrowed whole through the helper at "
      "5 bps: phi = 1.02375; LPVaultSwap keeps S = 90.3, A = 19.5, kr = 70.8 and pays keeperOut = 2,118.3; the helper "
      "repays 2,048.52375 and pays its caller 69.77625, so the 0.04875 premium on the unused 97.5 USDC falls on the "
      "caller alone (69.825 - 69.77625)",
      wlh["phi"] == 1_023_750 and flash_quote(U6("2047.5"), 5) == 1_023_750 and wlh["S"] == w975["S"]
      and wlh["A"] == w975["A"] and wlh["kr"] == w975["kr"] and wlh["keeperOut"] == U6("2118.3")
      and U6("2047.5") + wlh["phi"] == U6("2048.52375") and wlh["topUp"] == 0 and wlh["payout"] == U6("69.77625")
      and w975h["payout"] - wlh["payout"] == 48_750 == wlh["phi"] - w975h["phi"])

# Partial helper loan: X = 1,950 USDC, F = 1,000 at 5 bps, the helper pulls X - F = 950 from its caller (REQ-HELPER-004).
wf3 = waterfall(D975, U6("2040.3"), D975, V975, min_rec=min975, F=U6("1000"), fee_bps=5)
# FV-LIQ-06 verifies: SPEC-LIQ-007, SPEC-LIQ-010, REQ-SWAP-012, REQ-HELPER-008, Q-404
check("FV-LIQ-06ab", "SPEC-LIQ-007 / REQ-SWAP-012 (no premium term in the waterfall): X = Kf = 1,950 USDC of which a "
      "helper borrows F = 1,000 at 5 bps (phi = 0.5) and pulls 950 from its caller; LPVaultSwap computes the same "
      "S = 90.3, A = 19.5, kr = 70.8, keeperOut = 2,020.8 as for the self-funded call; the helper repays 1,000.5 and pays "
      "its caller 1,020.3 = 950 + 70.8 - 0.5",
      wf3["phi"] == 500_000 and all(wf3[k] == w975[k] for k in ("S", "G", "A", "kr", "B", "shortfall", "keeperOut"))
      and wf3["topUp"] == 0 and wf3["payout"] == U6("1020.3") == U6("950") + w975["kr"] - wf3["phi"], f"{wf3}")
phiD_old = flash_fee(D975, 5)
G_old = sat_sub(V975, D975 + phiD_old)
S_old3 = sat_sub(U6("2040.3"), D975 + phiD_old)
A_old3 = min(G_old * 2000 // BPS, S_old3)
mutant("FV-LIQ-06abm", "a helper's premium charged inside LPVaultSwap (the former D + phiD terms at 5 bps): on the 2.11 "
       "liquidation G = 96.525 and A = 19.305, so Avana's fee would pay 0.195 USDC of the caller's loan cost",
       G_old == U6("96.525") and A_old3 == U6("19.305") and A_old3 < w975["A"], f"A={A_old3} vs {w975['A']}")

# Q-401: no in-kind split. The unwind of the 2.11 example (1,030.25 USDC and 1,021 USDT) is settled over the routes.
a0, a1 = 1_030_250_000, 1_021_000_000
val = leg_value_up(a0, P8, 6, dd=6) + leg_value_up(a1, 99_950_000, 6, dd=6)
# FV-LIQ-06 verifies: SPEC-LIQ-011, SPEC-LIQ-012, SPEC-LIQ-013, SPEC-LIQ-018
check("FV-LIQ-06h", "Q-401 (in-kind removed): the unwind 1,030.25 USDC + 1,021 USDT is worth 1,030.25 + 1,020.4895 = "
      "2,050.7395 USDC at the oracle, above minRec = 2,026.024998, so both legs settle over the swap routes; "
      "SPEC-LIQ-011: kr <= G - A = 97.5 - 19.5 = 78",
      leg_value_up(a1, 99_950_000, 6, dd=6) == 1_020_489_500 and val == 2_050_739_500 and val >= min975
      and w975["G"] - w975["A"] == U6("78") and w975["kr"] <= U6("78"))
# FV-LIQ-06 verifies: SPEC-LIQ-011, SPEC-LIQ-017, REQ-SWAP-094
w94 = waterfall(U6("1000"), U6("990"), U6("950"), U6("969"))
check("FV-LIQ-06i", "REQ-SWAP-094: Kf = 1,000 USDC and D = 950 USDC: the unused 50 USDC returns inside keeperOut; with "
      "R = 990 USDC and V = 969 USDC: S = 40, G = 19, A = 3.8, kr = 15.2, B = 21, keeperOut = 1,000 + 15.2 = 1,015.2 USDC",
      U6("1000") - U6("950") == U6("50") and w94["shortfall"] == 0 and w94["A"] == U6("3.8")
      and w94["kr"] == U6("15.2") and w94["keeperOut"] == U6("1015.2") and w94["B"] == U6("21"), f"{w94}")

# SPEC-LIQ-014 pending floor on the Ethereum market's GHO pending-settlement reserve (dp = 18), s_P = min(allow, 30)
Vp0, Vp1 = leg_value_up(41_200_000, P8, 6), leg_value_up(42_600_000, 99_950_000, 6)
Vp = Vp0 + Vp1
sP = min(100, 30)
Up = unit_value(P8, 6) + unit_value(99_950_000, 6)
mp = recovery_floor(Vp, sP, Up)
leg0 = leg_min_out(41_200_000, P8, 6, sP, 2)
# FV-LIQ-06 verifies: SPEC-LIQ-014, SPEC-LIQ-018, REQ-SWAP-066
check("FV-LIQ-06j", "2.11 SPEC-LIQ-014: V_P = 41.2 + 42.5787 = 83.7787 GHO, s_P = 30, slippage term 83.5273639, "
      "U = 1.9995e12 wei, minPending = 82.5273619005 GHO; USDC leg minimum 40.576399 at n = 2",
      Vp1 == W("42.5787") and Vp == W("83.7787") and sP == 30 and ceil_div(Vp * (BPS - sP), BPS) == W("83.5273639")
      and Up == 1_999_500_000_000 and mp == W("82.5273619005") and leg0 == W("40.576399"),
      f"minPending={fmt(mp)} leg0={fmt(leg0)}")

# SPEC-LIQ-022 borrower surplus; SPEC-LIQ-017 leftover; SPEC-LIQ-015 flash bound
w52 = waterfall(D975, U6("2052"), D975, V975, min_rec=min975)
# FV-LIQ-06 verifies: SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027
check("FV-LIQ-06k", "2.11 SPEC-LIQ-022: routes returning R = 2,052 USDC give S = 102 > G = 97.5, kr = 97.5 - 19.5 = 78, "
      "B = 4.5 USDC = R_f - max(V, D) to the borrower, keeperOut = Kf + 78 = 2,028; A + kr + B = S",
      w52["S"] == U6("102") and w52["kr"] == U6("78") and w52["B"] == U6("4.5")
      and w52["B"] == U6("2052") - max(V975, D975) and w52["keeperOut"] == U6("2028") == D975 + w52["kr"]
      and w52["A"] + w52["kr"] + w52["B"] == w52["S"])
wl = waterfall(U6("2047.5"), U6("2040.3"), D975, V975, min_rec=min975)
# FV-LIQ-06 verifies: SPEC-LIQ-017, REQ-SWAP-011, REQ-SWAP-017, REQ-SWAP-089
check("FV-LIQ-06l", "2.11 SPEC-LIQ-017 / REQ-SWAP-011: debtToCover = 2,047.5 USDC pulls Kf = 2,047,500,000, Aave pulls "
      "D = 1,950, the leftover 97.5 USDC returns inside keeperOut = 2,047.5 + 2,040.3 - 1,950 - 19.5 = 2,118.3 USDC; "
      "S = 90.3, A = 19.5, B = 0 unchanged",
      U6("2047.5") - D975 == U6("97.5") and wl["keeperOut"] == U6("2118.3") == U6("2047.5") + wl["kr"]
      and wl["S"] == U6("90.3") and wl["A"] == U6("19.5") and wl["B"] == 0 and wl["shortfall"] == 0)
# FV-LIQ-06 verifies: SPEC-LIQ-015, REQ-FLASH-002, REQ-HELPER-005
check("FV-LIQ-06m", "2.11 SPEC-LIQ-015: F = 1,950 USDC at 5 bps: 975,000 x 1e4 = 9,750,000,000 <= 10 x 1,950,000,000; a "
      "premium raised to 20 bps (3,900,000) gives 39,000,000,000 > 19,500,000,000 and reverts FlashFeeTooHigh; at "
      "m = p = 5, F = 1,950,000,000 passes and F = 1,950,000,001 (quote 975,001) fails",
      975_000 * BPS == 9_750_000_000 <= 10 * D975 == 19_500_000_000 and flash_fee(D975, 20) == 3_900_000
      and 3_900_000 * BPS == 39_000_000_000 > 19_500_000_000
      and flash_quote(D975, 5) * BPS <= 5 * D975 and flash_quote(D975 + 1, 5) == 975_001
      and 975_001 * BPS == 9_750_010_000 > 5 * (D975 + 1) == 9_750_000_005)

# SPEC-LIQ-018 per-leg minimum (USDC debt: only the USDT leg is swapped, n' = 1)
m018 = leg_min_out(6_211_300_000, 99_950_000, 6, 100, 1, fra=EPS6, dd=6)
# FV-LIQ-06 verifies: SPEC-LIQ-018, LIQ-075
check("FV-LIQ-06ac", "2.11 SPEC-LIQ-018: a2 = 6,211.3 USDT at $0.9995: Vleg = 6,208,194,350, Uleg = 1, minOut = "
      "ceil(6,208,194,350 x 0.99) - 1 - 1,000,000 = 6,145,112,406; a route returning 6,100 USDC fails MinOutNotMet",
      mul_div_down(6_211_300_000 * 99_950_000, 10**6, 10**6 * P8) == 6_208_194_350
      and unit_value(99_950_000, 6, dd=6) == 1 and m018 == 6_145_112_406 and U6("6100") < m018, f"minOut={m018}")

# SPEC-LIQ-019 shortfall top-up, V = 12,422.6 USDC
V19 = U6("12422.6")
m19 = recovery_floor(V19, 100, U_usdc, EPS6)
s260 = min(9_999, 100 + min(1_000, U6("200") * BPS // V19))
s180 = min(9_999, 100 + min(1_000, U6("100") * BPS // V19))
short = sat_sub(m19, U6("12174"))
# FV-LIQ-06 verifies: SPEC-LIQ-019, REQ-SWAP-101, LIQ-076
check("FV-LIQ-06ad", "2.11 SPEC-LIQ-019: minRec = 12,297.373998 USDC; maxShortfall 200: sLeg = 100 + 160 = 260, routes "
      "return 12,174, shortfall 123.373998 <= 200 is pulled and R' = minRec; maxShortfall 100: sLeg = 100 + 80 = 180",
      m19 == U6("12297.373998") and U6("200") * BPS // V19 == 160 and s260 == 260 and short == U6("123.373998")
      and short <= U6("200") and U6("12174") + short == m19 and U6("100") * BPS // V19 == 80 and s180 == 180)

# SPEC-LIQ-020 deleverage; REQ-SWAP-106 (USDC debt, 5 bps premium, maxFlashFeeBps 10). deleverage keeps its premium.
V20 = seized_value(1000 * E18, 210_000_000, 18, dd=6)
Vnet20 = sat_sub(V20 * (BPS - 100) // BPS, U_usdc + EPS6)
cap20 = Vnet20 * BPS // (BPS + 10)
x20 = min(U6("6600"), cap20)
phi20 = flash_fee(x20, 5)                                     # the premium the Pool charges (half up)
out20 = U6("2096.2") - x20 - phi20
debt_after = U6("6600") - x20
hf_after = Decimal(18_900) * Decimal("0.312") / (Decimal(debt_after) / Decimal(10**6))
legs20 = 2 * (ceil_div(U6("1050") * 9_900, BPS) - 1 - EPS6 // 2)
# FV-LIQ-06 verifies: SPEC-LIQ-020, REQ-SWAP-106
check("FV-LIQ-06ae", "2.11 SPEC-LIQ-020 / REQ-SWAP-106: V = 2,100,000,000, Vnet = 2,079,000,000 - 2 - 1,000,000 = "
      "2,077,999,998, cap = x = 2,075,924,073, the Pool charges phi = floor((x 5 + 5,000) / 1e4) = 1,037,962 at 5 bps "
      "(ceiling quote 1,037,963); R = 2,096.2 USDC gives assetOut = 19,237,965 (19.237965 USDC); debt 6,600 -> "
      "4,524.075927 USDC, HF 1.3034; two legs of 1,050 USDC at their minimums return 2 x (1,039,500,000 - 1 - 500,000) "
      "= 2,077,999,998 >= x + phi = 2,077,792,405 at 9 bps (charged and quoted alike)",
      V20 == 2_100_000_000 and Vnet20 == 2_077_999_998 and cap20 == 2_075_924_073 and x20 == cap20
      and phi20 == 1_037_962 and flash_quote(x20, 5) == 1_037_963 and out20 == 19_237_965 and debt_after == 4_524_075_927
      and round(hf_after, 4) == Decimal("1.3034") and legs20 == 2_077_999_998
      and x20 + flash_quote(x20, 9) == 2_077_792_405 == x20 + flash_fee(x20, 9) and legs20 >= 2_077_792_405,
      f"HF after {hf_after:.6f}")
replay("FV-LIQ-06ae2", "mutant (the SPEC-LIQ-020 example before 2026-11-11): the ceiling quote phi = 1,037,963 gives "
       "assetOut = 19,237,964, one unit below what the wallet receives; the Pool charges premiums[0] half up, "
       "2,075,924,073 x 5 / 1e4 = 1,037,962.0365 -> 1,037,962, so the repayment is x + 1,037,962 and assetOut = 19,237,965",
       flash_quote(x20, 5) == 1_037_963 != phi20 and U6("2096.2") - x20 - flash_quote(x20, 5) == 19_237_964 != out20,
       f"charged={phi20} quoted={flash_quote(x20, 5)}")

# s = 0 (SPEC-LIQ-016 / SPEC-LIQ-019 / REQ-SWAP-029): a bonus of 10,000 after an Aave configuration change.
D1 = 2500 * 10**6
s1 = eff_slip(10_000, 100)
V1 = D1                                                        # c x Pc = D x 10,000 / 1e4
R1 = recovery_floor(V1, s1, U_usdc, EPS6)
w1 = waterfall(D1, R1, D1, V1, min_rec=R1, max_shortfall=0)
w1b = waterfall(D1, R1 - U6("1"), D1, V1, min_rec=R1, max_shortfall=0)
w1t = waterfall(D1, R1 - U6("1"), D1, V1, min_rec=R1, max_shortfall=U6("2"))
# FV-LIQ-06 verifies: SPEC-LIQ-016, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-029, INV-038
check("FV-LIQ-06v", "s = 0 (SPEC-LIQ-016/019, REQ-SWAP-029): bonus 10,000 gives bNet = 1e4 and s = 0 (10,005 gives 4, "
      "no premium term); Kf = D = 2,500 USDC, V = 2,500, R = minRec = 2,498.999998: g = 0, no top-up, the call settles "
      "with maxShortfall = 0 and keeperOut = 2,498.999998 (the caller bears U + eps = 1.000002); routes 1 USDC below "
      "minRec revert RecoveryBelowFloor at maxShortfall 0 and, at maxShortfall 2 USDC, pull exactly the 1 USDC floor gap",
      s1 == 0 and eff_slip(10_001, 100) == 0 and eff_slip(10_005, 100) == 4 and R1 == 2_498_999_998
      and w1["gap"] == 0 and w1["shortfall"] == 0 and w1["err"] is None and w1["keeperOut"] == R1
      and D1 - w1["keeperOut"] == U_usdc + EPS6 and w1b["err"] == "RecoveryBelowFloor"
      and w1t["err"] is None and w1t["shortfall"] == U6("1") and w1t["gap"] == 0 and w1t["keeperOut"] == R1,
      f"keeperOut={w1['keeperOut']}")
phiD1 = flash_fee(D1, 5)
old_gap1 = sat_sub(D1 + phiD1, R1)                            # flash-funded inside LPVaultSwap: K = 0, F = D
mutant("FV-LIQ-06vm", "old rule (LPVaultSwap flash-borrowed D and owed D + phiD): the same s = 0 call at 5 bps had a gap "
       "D + phiD - R = 2.250002 USDC that maxShortfall = 0 refused (InsufficientProceeds); the caller-funded call settles",
       phiD1 == 1_250_000 and old_gap1 == 2_250_002 and old_gap1 > 0 and w1["err"] is None, f"gap={old_gap1}")

# REQ-SWAP-072 / REQ-SWAP-075 payouts
w975b = waterfall(D975, U6("2035"), D975, V975, min_rec=min975)
# FV-LIQ-06 verifies: REQ-SWAP-072, REQ-SWAP-075, REQ-SWAP-005, Q-404
check("FV-LIQ-06aa", "2.11 REQ-SWAP-072 (one entry point): an unregistered address funding 1,950 USDC with BackupOnly and "
      "minPayout 2,019 = 1,950 + 69 (<= 1,950 + floor(0.99 x 70.8)): R = 2,040.3 >= 2,026.024998, A = 19.5 to "
      "feeRecipient, keeperOut = 2,020.8, net 70.8; REQ-SWAP-075: R = 2,035 gives S = 85, A = 19.5, kr = 65.5, "
      "keeperOut = 2,015.5 < 2,019, PayoutTooLow(2,015,500,000, 2,019,000,000)",
      w975["err"] is None and w975["A"] == U6("19.5") and w975["keeperOut"] == U6("2020.8") >= U6("2019")
      and w975["keeperOut"] - D975 == U6("70.8") and U6("2019") == D975 + U6("69")
      and U6("2019") <= D975 + (99 * (w975["keeperOut"] - D975)) // 100
      and U6("2035") >= min975 and w975b["S"] == U6("85") and w975b["A"] == U6("19.5") and w975b["kr"] == U6("65.5")
      and w975b["keeperOut"] == 2_015_500_000 < 2_019_000_000)

# FV-LIQ-06 verifies: REQ-SWAP-008, REQ-SWAP-091
check("FV-LIQ-06af", "2.11 REQ-SWAP-008/091: liquidationPriceMaxAge is the feed's own heartbeat plus its margin: USDT/USD "
      "86,400 + 1,800 = 88,200 s, so a call 88,300 s after the last update reverts StalePrice and one at 88,200 s runs",
      86_400 + 1_800 == 88_200 and 88_300 > 88_200 and not 88_200 > 88_200)

# FV-LIQ-06 verifies: REQ-SWAP-076, REQ-SWAP-083, REQ-SWAP-104, REQ-SWAP-114
check("FV-LIQ-06ah", "2.11 REQ-SWAP-076 gas guard (gasleft >= ceil(64 G / 63) + POST_CALL_GAS, LPVaultSwap's POST_CALL_GAS = "
      "10,000): payout transfer 101,588 + 10,000 = 111,588; no breaker report exists (Q-399), so the payouts are the only "
      "gas-limited calls",
      ceil_div(100_000 * 64, 63) == 101_588 and 101_588 + 10_000 == 111_588)

# FV-LIQ-06 verifies: REQ-SWAP-089, REQ-SWAP-111, SPEC-LIQ-017
check("FV-LIQ-06ai", "2.11 REQ-SWAP-089: no sell-back leg: the 97.5 USDC leftover of Kf = 2,047.5 over D = 1,950 is the "
      "debt asset itself and returns inside keeperOut = 97.5 + 2,020.8 = 2,118.3; no route is called for it",
      U6("2047.5") - D975 == U6("97.5") and U6("97.5") + w975["keeperOut"] == wl["keeperOut"]
      and wl["S"] == w975["S"])

# Q-399 price-drop alert (REQ-ORACLE-088 checkpoint): alert only, no on-chain trip
# FV-LIQ-06 verifies: REQ-SWAP-103, REQ-ORACLE-088
check("FV-LIQ-06ak", "Q-399: a served price of 193,900,000 against the checkpoint 199,950,000 is 3.03 % lower "
      "(193,900,000 x 1e4 < 199,950,000 x 9,700) and raises the 3 % in 2 hours alert; no breaker trips and liquidation "
      "never reads it; a temporary gate clears after 30 minutes = 1,800 s of healthy observations",
      193_900_000 * BPS < 199_950_000 * 9_700 and 30 * 60 == 1_800)

# REQ-SWAP-108 fee-on-transfer; REQ-ESCROW-003
Kf108 = 5000 * 10**6 - 5000 * 10**6 * 10 // BPS
# FV-LIQ-06 verifies: REQ-SWAP-108, REQ-SWAP-011, REQ-ESCROW-003
check("FV-LIQ-06al", "2.11 REQ-SWAP-108: with a 10 bps USDT fee, debtToCover = 5,000 USDT delivers Kf = 4,995 USDT "
      "(0 < Kf <= X), which LPVaultSwap approves and passes as Aave's bound, so D <= 4,995; 2.18 REQ-ESCROW-003: "
      "1,612,848 arrives as 1,611,236",
      Kf108 == 4_995 * 10**6 and 0 < Kf108 <= 5000 * 10**6
      and 1_612_848 - 1_612_848 * 10 // BPS == 1_611_236)

# REQ-SWAP-035 / REQ-SWAP-107 keeper counts; REQ-SWAP-074 deadline; LIQ-065 addKeeper delay


def active_after(approved, frozen, removing_frozen, floor=1):
    active = approved - frozen
    after = active - (0 if removing_frozen else 1)
    return after, after >= floor


# FV-LIQ-06 verifies: REQ-SWAP-035, REQ-SWAP-107, REQ-SWAP-074, LIQ-065
check("FV-LIQ-06am", "2.11 REQ-SWAP-035/107 (keeperFloor = 1, MAX_KEEPERS = 32): 2 keepers: removing one gives 1 "
      "(passes), then 0 < 1 (KeeperFloor); 2 with one frozen: activeKeeperCount 1, removing the active one gives 0 "
      "(reverts), the frozen one 1 (passes); a 33rd addKeeper reverts; "
      "REQ-SWAP-074: deadline t + 36 (three blocks), t + 24 runs, t + 48 reverts; LIQ-065: 2 to 7 March = 432,000 s",
      active_after(2, 0, False) == (1, True) and active_after(1, 0, False) == (0, False)
      and active_after(2, 1, False) == (0, False) and active_after(2, 1, True) == (1, True) and 32 + 1 > 32
      and 1_762_700_000 + 3 * 12 == 1_762_700_036 and not 1_762_700_024 > 1_762_700_036
      and 1_762_700_048 > 1_762_700_036 and 5 * 86_400 == 432_000)

# REQ-SWAP-104 / SPEC-BRK-005 seizure surge; REQ-LENS-037
# FV-LIQ-06 verifies: REQ-SWAP-104, SPEC-BRK-005, REQ-LENS-037
check("FV-LIQ-06be", "Q-399 seizure alert (monitoring, no on-chain latch): 2,000,001 of 10,000,000 units in the hour "
      "exceeds 2,000 bps and raises the alert, 2,000,000 does not; 2,000,000,000 of 10,000,000,000 does not, "
      "2,000,000,001 does; 20.0001 % alerts",
      2_000_001 * BPS > 2_000 * 10_000_000 and not 2_000_000 * BPS > 2_000 * 10_000_000
      and 1_200_000_000 + 800_000_000 == 2_000_000_000 and not 2_000_000_000 * BPS > 2_000 * 10**10
      and 2_000_000_001 * BPS > 2_000 * 10**10 and Decimal("20.0001") * 100 > 2_000)

# ================================================================ 2.12 Settlement routes
dai = W("1000.0000005")
gem = dai // 10**12
# FV-LIQ-06 verifies: REQ-ROUTE-012, REQ-ROUTE-031, REQ-ROUTE-039
check("FV-LIQ-06as", "2.12 REQ-ROUTE-012: tout = 0 and 1,000.0000005 DAI give gemAmt = 1,000,000,000, 0.0000005 DAI back; "
      "REQ-ROUTE-039: "
      "2,000,000 USDC for 2,004,000 GHO is 20 bps <= 30",
      gem == 1_000_000_000 and (gem + 1) * 10**12 > dai and dai - gem * 10**12 == W("0.0000005")
      and 2_000_000 * 10_020 // BPS == 2_004_000 and (2_004_000 - 2_000_000) * BPS // 2_000_000 == 20 <= 30)

# ================================================================ 2.13 SettlementBudget removed (Q-397)
w2000 = waterfall(D975, U6("2000"), D975, V975, min_rec=min975)
# FV-LIQ-06 verifies: SPEC-SET-001, SPEC-LIQ-019, Q-404
check("FV-LIQ-06p", "2.13 SPEC-SET-001 (the caller's gap, no flash term): dust Kf = D = 3, R = 2.95 >= minRec: A = B = 0, "
      "g = max(0, 3 - 3 - 2.95) = 0, shortfall 0, keeperOut 2.95; routes returning R = 2,000 USDC against minRec = "
      "2,026.024998 with Kf = D = 1,950: A + B = 19.5 <= 76.024998, g = max(0, 1,950 + 19.5 - 1,950 - 2,000) = 0, and "
      "the floor gap 26.024998 USDC is the whole shortfall",
      wd["gap"] == 0 and wd["shortfall"] == 0 and wd["keeperOut"] == U6("2.95")
      and w2000["S"] == U6("76.024998") and w2000["A"] + w2000["B"] == U6("19.5") <= U6("76.024998")
      and w2000["gap"] == 0 and w2000["floor_gap"] == U6("26.024998") == w2000["shortfall"]
      and w2000["gap"] <= w2000["floor_gap"])
seq24 = [waterfall(U6("3"), U6("2.95"), U6("3"), Vd, min_rec=md) for _ in range(24)]
# FV-LIQ-06 verifies: SPEC-SET-003, REQ-BUDGET-010
check("FV-LIQ-06q", "2.13 SPEC-SET-003 (no window): 24 dust liquidations in one day each settle with no top-up, each "
      "caller bearing its own 0.05 USDC loss in keeperOut (1.2 USDC in all), and LPVaultSwap's balance change is 0 on "
      "every call; nothing caps or spends a shared window",
      sum(w["shortfall"] for w in seq24) == 0 and sum(U6("3") - w["keeperOut"] for w in seq24) == U6("1.2")
      and all(U6("3") + U6("2.95") + w["shortfall"] == U6("3") + w["A"] + w["B"] + w["keeperOut"] for w in seq24))
# FV-LIQ-06 verifies: SPEC-SET-004
check("FV-LIQ-06ar", "2.13 SPEC-SET-004 (no budget setter): a keeper added at 1,763,000,000 with the normal delay "
      "d = 432,000 is ready at 1,763,432,000 (5 days) and expires 1,764,641,600 (14 days later)",
      1_763_000_000 + 432_000 == 1_763_432_000 and 432_000 == 5 * 86_400
      and 1_763_432_000 + 1_209_600 == 1_764_641_600 and 1_209_600 == 14 * 86_400)
loss_d = sat_sub(U6("3"), U6("2.95"))                          # expectedCallerLoss = max(0, D - Rv), Rv = 2.95
# FV-LIQ-06 verifies: SPEC-SET-005, REQ-LENS-029, REQ-HELPER-007
check("FV-LIQ-06r", "2.13 SPEC-SET-005 (the Lens previews expectedCallerLoss): the dust call has expectedCallerLoss = "
      "0.05 USDC and expectedNetPayout 0, so a helper loan of 3 USDC at 5 bps needs a top-up bound of at least "
      "0.0015 + 0.05 - 0 = 0.0515 USDC, exactly the top-up the helper pulls",
      loss_d == U6("0.05") and sat_sub(wd["keeperOut"], U6("3")) == 0
      and flash_quote(U6("3"), 5) + loss_d - 0 == 51_500 == wdh["topUp"], f"{wdh}")
# FV-LIQ-06 verifies: SPEC-SET-006, REQ-BUDGET-024, REQ-BUDGET-025
check("FV-LIQ-06aq", "2.13 SPEC-SET-006 (no per-market window): a dust call on one market (no top-up, keeperOut 2.95) and "
      "the 2.11 liquidation on another (no top-up, keeperOut 2,020.8) settle the same whichever runs first",
      wd["shortfall"] == 0 and wd["keeperOut"] == U6("2.95") and w975["shortfall"] == 0
      and w975["keeperOut"] == U6("2020.8") and waterfall(U6("3"), U6("2.95"), U6("3"), Vd, min_rec=md) == wd)

# SPEC-SET-001 / INV-038 loss bound (old finding F-02), D from the Aave port with drawnIndex = 1.5 RAY + 7.
idx = 3 * RAY // 2 + 7


def f02_draw(fee_bps):
    """A seizure on a USDC reserve from the Aave port (drawnIndex 1.5 RAY + 7) recovering exactly minRec; with
    fee_bps > 0 a helper funds it with F = D at that premium. The caller's loss is D - R' at the floor."""
    p2 = A.Params(supplied_shares=10**24, coll_A=10**30, coll_S=10**30, coll_decimals=18, coll_price=2 * P8,
                  drawn_shares=10**16, premium_debt_ray=1, drawn_index=idx,
                  total_debt_value_ray=(10**16 * idx + 1) * P8 * 10**12, debt_decimals=6, debt_price=P8,
                  debt_to_cover=1000 * 10**6, collateral_factor=2812, hf_for_max_bonus=9 * 10**17, bonus_factor=4000,
                  max_lb=10_500, target_hf=11 * 10**17, hf=9999 * 10**14)
    r = A.liquidation_call(p2)
    s = eff_slip(r["lb"], 100)
    V = seized_value(r["c"], 2 * P8, 18, dd=6)
    R = recovery_floor(V, s, U_usdc, EPS6)
    w = waterfall(r["D"], R, r["D"], V, min_rec=R, max_shortfall=0, F=r["D"] if fee_bps else None, fee_bps=fee_bps)
    unit_up = ceil_div(2 * P8 * 10**6, E18 * P8)               # one vault unit at $2.00, rounded up (INV-038)
    debt_term = 2 + ceil_div(idx, RAY)
    phiD = flash_fee(r["D"], fee_bps)                          # the former in-core premium term, for the mutant
    A_old = min(sat_sub(V, r["D"] + phiD) * 2000 // BPS, sat_sub(R, r["D"] + phiD))
    return dict(D=r["D"], lb=r["lb"], s=s, V=V, R=R, w=w, loss=sat_sub(r["D"], R + w["shortfall"]), unit_up=unit_up,
                debt_term=debt_term, new_bound=unit_up + 2 + U_usdc + EPS6 + debt_term,
                old_bound=seized_value(1, 2 * P8, 18, dd=6) + 1 + U_usdc + EPS6, A_old=A_old)


f0 = f02_draw(0)
f5 = f02_draw(5)
# FV-LIQ-06 verifies: SPEC-SET-001, INV-038, REQ-BUDGET-027
check("FV-LIQ-06w", "SPEC-SET-001 / INV-038 on a USDC seizure from the Aave port (drawnIndex 1.5 RAY + 7): at R = minRec "
      "the call settles with maxShortfall = 0 (g = 0) and the caller's loss below D is within one vault unit + 2 + U + "
      "floorRoundingAllowance + (2 + ceil(index/RAY)) debt units, and within 2 x the 1 USDC allowance",
      f0["s"] == 100 and f0["w"]["err"] is None and f0["w"]["gap"] == 0 and f0["loss"] <= f0["new_bound"]
      and f0["loss"] <= 2 * EPS6, f"D={f0['D']} loss={f0['loss']} bound={f0['new_bound']}")
mutant("FV-LIQ-06wm", "F-02 old bound 'one vault unit + 1 unit + U + fra' leaves no room for Aave's debt rounding of up "
       "to 2 + ceil(index/RAY) units", f0["new_bound"] - f0["old_bound"] >= 2,
       f"room={f0['new_bound'] - f0['old_bound']}")
mutant("FV-LIQ-06w2", "former D + phiD terms on the same seizure at 5 bps: G and S lose phiD = 0.5 USDC and Avana's fee "
       "falls from 3.999999 to 3.899999 USDC; under Q-404 the helper's premium never reaches the waterfall",
       f5["A_old"] < f5["w"]["A"] == f0["w"]["A"] == 3_999_999 and f5["A_old"] == 3_899_999,
       f"A(old)={f5['A_old']} A={f5['w']['A']}")
# FV-LIQ-06 verifies: SPEC-SET-001, SPEC-LIQ-016, REQ-HELPER-007, Q-404
check("FV-LIQ-06w3", "the same seizure funded through a helper at 5 bps: LPVaultSwap computes the same s = 100, floor, "
      "A, kr and keeperOut as for a self-funded caller; the helper's top-up is max(0, F + phi - keeperOut) = 0 and its "
      "caller nets kr - phi",
      f5["s"] == 100 and f5["R"] == f0["R"]
      and all(f5["w"][k] == f0["w"][k] for k in ("S", "A", "kr", "B", "shortfall", "keeperOut"))
      and f5["w"]["topUp"] == 0 and f5["w"]["payout"] == f0["w"]["kr"] - f5["w"]["phi"], f"{f5['w']}")
# FV-LIQ-06 verifies: REQ-BUDGET-005, REQ-BUDGET-014, REQ-SWAP-101, SPEC-SET-002
check("FV-LIQ-06ap", "REQ-BUDGET-005/014 (keeper sizing): a keeper with maxShortfall = 0 settles the Aave-port seizure at "
      "the floor with and without a 5 bps helper loan, because the gap never exceeds the floor gap (0 here); its "
      "rounding loss stays within 2 x the 1 USDC floorRoundingAllowance",
      f0["w"]["err"] is None and f5["w"]["err"] is None and f0["w"]["gap"] <= f0["w"]["floor_gap"]
      and f0["loss"] <= 2 * EPS6 and f5["loss"] <= 2 * EPS6, f"losses {f0['loss']}, {f5['loss']}")
# FV-LIQ-06 verifies: INV-038, SPEC-SET-001, SPEC-LIQ-005
check("FV-LIQ-06w4", "INV-038 bound terms in USDC: one vault unit at $2.00 rounds up to 1 unit, U = 2, the debt term "
      "2 + ceil(1.5 RAY + 7 / RAY) = 4 units, so the bound is 1 + 2 + 2 + 1,000,000 + 4 = 1,000,009 units",
      f5["unit_up"] == 1 and f5["debt_term"] == 4 and f5["new_bound"] == 1_000_009)

# ================================================================ 2.14 First-Loss Reserve
Ah, Sh = 2_100_000 * E18, 2_000_000 * E18
dr = 475_250_000_000_000_000_000 * RAY + 4 * 10**26
amt = min(W("1000"), ceil_div(dr, RAY), W("100000"))
# FV-LIQ-06 verifies: SPEC-FLR-001
check("FV-LIQ-06at", "2.14 SPEC-FLR-001: amount = 475,250,000,000,000,000,001, burns 452,619,047,619,047,619,060 shares; "
      "maxAmount 300: 285,714,285,714,285,714,293 shares, 175.25 GHO + 0.4 wei left; WETH 3.2 at A 12,000, S 11,800: "
      "3,146,666,666,666,666,672 shares",
      amt == 475_250_000_000_000_000_001 and A.to_shares_up(amt, Ah, Sh) == 452_619_047_619_047_619_060
      and A.to_shares_up(W("300"), Ah, Sh) == 285_714_285_714_285_714_293
      and dr - W("300") * RAY == W("175.25") * RAY + 4 * 10**26
      and A.to_shares_up(W("3.2"), 12_000 * E18, 11_800 * E18) == 3_146_666_666_666_666_672)

sh = 100_000 * E18
fb = A.to_assets_down(sh, Ah, Sh)
minted = A.to_shares_down(W("83.8"), Ah, Sh)
fb2 = A.to_assets_down(sh + minted, Ah + W("83.8"), Sh + minted)
# FV-LIQ-06 verifies: REQ-FLR-038, SPEC-FLR-002, REQ-SWAP-070
check("FV-LIQ-06s", "2.14 SPEC-FLR-002 / REQ-FLR-038 / REQ-SWAP-070: fundedBalance 104,999,999,999,999,999,997,500 "
      "(2,500 wei below 105,000); fund(83.8) mints 79,809,523,809,523,809,525 shares and gives "
      "105,083,799,999,999,999,997,499, 1 wei short of 83.8",
      fb == 104_999_999_999_999_999_997_500 and W("105000") - fb == 2_500 and minted == 79_809_523_809_523_809_525
      and fb2 == 105_083_799_999_999_999_997_499 and fb + W("83.8") - fb2 == 1)
# FV-LIQ-06 verifies: SPEC-FLR-003
check("FV-LIQ-06au", "2.14 SPEC-FLR-003: request at 1,780,000,000 executable from 1,781,209,600; 40,000 GHO burns "
      "38,095,238,095,238,095,239,003 share wei",
      1_780_000_000 + 1_209_600 == 1_781_209_600 and A.to_shares_up(W("40000"), Ah, Sh) == 38_095_238_095_238_095_239_003)

D_ = Decimal
dlp = D_(1) - D_("0.1").sqrt()
x4 = D_("0.95") * D_("0.296") / (D_("0.312") * D_("1.05"))
g_gho, g_weth = D_("0.06") * 2 / 365, D_("0.03") * 2 / 365
lf_gho = 1 + g_gho - x4
lf_weth = 1 + g_weth - x4 / D_("1.2")
lf_mild = max(D_(0), 1 - D_("0.95") * D_("0.92") / (D_("0.312") * D_("1.05")))
# FV-LIQ-06 verifies: SPEC-FLR-004
check("FV-LIQ-06av", "2.14 SPEC-FLR-004: 1 - sqrt(0.10) = 68.4 %, dLP 0.704; 0.95 x 0.296 / 0.3276 = 0.858364; GHO g = "
      "0.000329, lossFactor 0.141965, 700,000 x it = 99,375.44 needs 99,376 (< 100,000); WETH g = 0.000164, lossFactor "
      "0.284861, 40 x it = 11.39 WETH; an 8 % drop gives 0",
      round(dlp * 100, 1) == D_("68.4") and D_("0.684") + D_("0.02") == D_("0.704")
      and D_("0.312") * D_("1.05") == D_("0.3276") and round(x4, 6) == D_("0.858364") and round(g_gho, 6) == D_("0.000329")
      and round(lf_gho, 6) == D_("0.141965") and int((700_000 * lf_gho).to_integral_value(rounding="ROUND_CEILING"))
      == 99_376 and 99_376 <= 100_000 and round(g_weth, 6) == D_("0.000164") and round(lf_weth, 6) == D_("0.284861")
      and round(40 * lf_weth, 2) == D_("11.39") and lf_mild == 0)

tail5 = ceil_div(420_000 * P8 * 3_120, BPS)          # USD 8 decimals, SPEC-FLR-005 (tail term x CF_t, MATH-ST-77)
tail5_gho = tail5 * E18 // P8
tail41 = ceil_div(620_000 * P8 * 3_120, BPS)
tu = min(ceil_div(330_000 * P8 * 3_120, BPS), 600_000 * P8)
tc = min(ceil_div(275_000 * P8 * 3_120, BPS), 600_000 * P8)
cover = D_(100_000) / D_("0.312")
# FV-LIQ-06 verifies: SPEC-FLR-005, REQ-FLR-041, REQ-LENS-034
check("FV-LIQ-06aw", "2.14 SPEC-FLR-005: factor 0.312, 100,000 GHO covers a $320,512 cap; tail(420,000) = 131,040, "
      "ratio 7,631, cap $300,512 or minimum 131,040; REQ-FLR-041: tail(620,000) = 193,440, ratio 5,169; REQ-LENS-034: "
      "tail USDT $102,960, USDC $85,800, tailUsd 10,296,000,000,000, ratio 9,712",
      int(cover) == 320_512 and tail5 == 131_040 * P8 and 100_000 * E18 * BPS // tail5_gho == 7_631
      and int(cover) - 20_000 == 300_512 and tail41 == 193_440 * P8 and 100_000 * P8 * BPS // tail41 == 5_169
      and tu == 102_960 * P8 and tc == 85_800 * P8 and tu > tc
      and tu == 10_296_000_000_000 and 100_000 * P8 * BPS // tu == 9_712)
old_tail5 = ceil_div(420_000 * P8 * 3_120 * 10**14, 11 * 10**17)
mutant("FV-LIQ-06awm", "old SPEC-FLR-005 tail term (x CF_t / minOpeningHealthFactor): 119,127.27 GHO understates the "
       "131,040 GHO an account at health factor 1 can owe against the same cap",
       old_tail5 < tail5 and old_tail5 == 11_912_727_272_728, f"old={old_tail5} final={tail5}")
# FV-LIQ-06 verifies: REQ-FLR-014, DEF-018, DEF-017
check("FV-LIQ-06ax", "2.14 REQ-FLR-014: 100,000 - 5,200 = 94,800 < 100,000; 3.9 DEF-018: 100,000 - 1,250 = 98,750; "
      "DEF-017: 0.05 WETH deficit with 0.03 held leaves 0.02",
      100_000 - 5_200 == 94_800 < 100_000 and 100_000 - 1_250 == 98_750 and W("0.05") - min(W("0.05"), W("0.03"))
      == W("0.02"))

# ================================================================ 3.9 Deficit coverage
def006 = A.to_shares_up(W("475.3"), 2_050_000 * E18, 2_000_000 * E18)
def006_text_expr = ceil_div(W("475.3") * 2_000_000, 2_050_000)
# FV-LIQ-06 verifies: DEF-006, SPEC-FLR-001
check("FV-LIQ-06ay", "3.9 DEF-006: deficitRay = 475.3 x 1e45, amount 475.3, Hub burns 463.707317073170731713 shares "
      "(with the 1e6 virtual offset); a 300 GHO balance covers 300 and leaves 175.3",
      W("475.3") * RAY == W("475.3", 45) and min(W("1000"), W("475.3"), W("100000")) == W("475.3")
      and def006 == W("463.707317073170731713") and W("475.3") - min(W("475.3"), W("300")) == W("175.3"))
def006_final_expr = ceil_div(W("475.3") * (2_000_000 * E18 + 10**6), 2_050_000 * E18 + 10**6)
# FV-LIQ-06 verifies: DEF-006, SPEC-FLR-001
check("FV-LIQ-06ay2", "3.9 DEF-006 (final): ceil(475.3e18 x (2,000,000e18 + 1e6) / (2,050,000e18 + 1e6)) = "
      "463.707317073170731713, the SPEC-FLR-001 burn",
      def006_final_expr == def006 == W("463.707317073170731713"), f"{fmt(def006_final_expr)}")
mutant("FV-LIQ-06ay2m", "old DEF-006 expression ceil(475.3e18 x 2,000,000 / 2,050,000) gives 463.707317073170731708, "
       "not the stated burn", def006_text_expr != def006, f"expression {fmt(def006_text_expr)} vs {fmt(def006)}")

# 3.9 DEF-015 / 3.5 LIQ-057 / LIQ-058 pending settlement
Vp58 = leg_value_up(299_999_999, P8, 6) + leg_value_up(299_999_999, 99_980_000, 6)
m58 = recovery_floor(Vp58, min(100, 30), U_usdt)
# FV-LIQ-06 verifies: LIQ-057, LIQ-058, DEF-015, SPEC-LIQ-014
check("FV-LIQ-06bc", "3.5 LIQ-057/058 / 3.9 DEF-015: records 600M + 400M, sharesBefore 700M, reconcile 300M, c = 200M: "
      "500M = sharesAfter, supply 800M = 500M + 300M; V_P = 299.999999 + 299.9399990002 = 599.9399980002, s_P = 30, "
      "slippage term 598.1401780061994, minPending 597.1401760063994 (about 597.140176) <= 599.9; funded 100,599.9",
      600_000_000 + 400_000_000 == 1_000_000_000 and 1_000_000_000 - 300_000_000 == 700_000_000
      and 600_000_000 - 300_000_000 - 200_000_000 == 100_000_000 and 100_000_000 + 400_000_000 == 500_000_000
      and 1_000_000_000 - 200_000_000 == 800_000_000 == 500_000_000 + 300_000_000
      and leg_value_up(299_999_999, 99_980_000, 6) == W("299.9399990002") and Vp58 == W("599.9399980002")
      and ceil_div(Vp58 * 9_970, BPS) == W("598.1401780061994") and m58 == W("597.1401760063994")
      and round(D_(m58) / E18, 6) == D_("597.140176") and W("599.9") >= m58 and W("100000") + W("599.9") == W("100599.9"))
# FV-LIQ-06 verifies: LIQ-024, REQ-LENS-026, REQ-LENS-027
check("FV-LIQ-06bd", "3.5 LIQ-024: ceil(1,200e8 x 400e6 / 600e6) = 800e8, 400 USD released; 2.17 REQ-LENS-026: "
      "610.25 + 598.40 = 1,208.65 GHO",
      ceil_div(1_200 * P8 * 400_000_000, 600_000_000) == 800 * P8 and 1_200 - 800 == 400
      and W("610.25") + W("598.40") == W("1208.65"))

# ================================================================ 2.17 Lens
U_lens = unit_value(P8, 6) + 1
m_lens = recovery_floor(seized_value(E18, 125_000_000_000, 18), 100, U_lens)
# FV-LIQ-06 verifies: REQ-LENS-016
check("FV-LIQ-06t", "2.17 REQ-LENS-016 (GHO reserve): slippageBps = min(100, 476) = 100; V = 1,250; U = 1e12 + 1; recovery floor per "
      "whole token 1,237.5 - 0.000001000000000001 - 1 = 1,236.499998999999999999 GHO",
      eff_slip(10_500, 100) == 100 and seized_value(E18, 125_000_000_000, 18) == W("1250")
      and U_lens == 10**12 + 1 and m_lens == W("1236.499998999999999999"), f"{fmt(m_lens)}")

# REQ-LENS-028/029 expected amounts for Alice's call, D = 4,990 USDC as stated
D29 = 4_990 * 10**6
p29, _ = aave_account(71_913_200_000, 6, 2 * P8, 40_456_119_927, 6, P8, D29)
c29 = A.collateral_to_liquidate(p29, D29, 0, 10_200, 10**6, 10**6)
V29 = seized_value(c29, 2 * P8, 6, dd=6)
mg29 = recovery_floor(V29, eff_slip(10_200, 100), U_usdc, EPS6)
w29 = waterfall(D29, V29, D29, V29, min_rec=mg29)               # Kf = params.debtToCover, R = V, no top-up
w29h = waterfall(D29, V29, D29, V29, min_rec=mg29, F=D29, fee_bps=5)
Rv29 = U6("2544.9") + mul_div_down(U6("2545.4") * 99_980_000, 10**6, 10**6 * P8)   # expectedUnwound at the oracle


def lens_debt_to_cover(total, expected, is_gho, dd, pdebt, all_collateral=False):
    """Final REQ-LENS-028: the whole debt plus LENS_DUST_MARGIN_BPS (rounded up) for a GHO reserve, a whole-debt
    repayment, a sizing that seizes all the supplied shares, or a remainder inside the margin; D otherwise."""
    rem = (total - expected) * pdebt * 10**26 // (10**dd * P8)
    if is_gho or expected == total or all_collateral or rem * BPS < 1_000 * 10**26 * (BPS + 500):
        return ceil_div(total * (BPS + 500), BPS)
    return expected


dtc_a = lens_debt_to_cover(40_456_119_927, D29, False, 6, P8)
dtc_b = lens_debt_to_cover(1_060 * 10**6, 25 * 10**6, False, 6, P8)
dtc_g = lens_debt_to_cover(W("40456.12"), W("4990"), True, 18, P8)
dtc_900 = lens_debt_to_cover(900 * E18, 900 * E18, True, 18, P8)
dtc_cl = lens_debt_to_cover(20_000 * 10**6, 761_904_762, False, 6, P8, all_collateral=True)
# FV-LIQ-06 verifies: REQ-LENS-028, REQ-LENS-029, REQ-HELPER-008
check("FV-LIQ-06u", "2.17 REQ-LENS-028/029: remainder 35,466.119927 > $1,050 so debtToCover = 4,990 USDC (params carry no "
      "funding field; Kf = debtToCover); c = 2,544,900,000 from Aave's seizure, V = 5,089.80 USDC, s = 100 (196), "
      "G = S = 99.8, A = 19.96, B = 0, expectedPayout = 4,990 + 99.8 - 19.96 = 5,069.84, expectedNetPayout = 79.84, "
      "Rv >= D so expectedCallerLoss = 0; through the helper with F = 4,990 at 5 bps (phi = 2.495) the net is 77.345 "
      "with no top-up; minPayout near 4,990 + 72 = 5,062; 1,060 USDC owed with 25 sized leaves 1,035 < 1,050: "
      "debtToCover = ceil(1,060 x 1.05) = 1,113,000,000; GHO variant 42,478.926; 900 GHO whole debt quoted 945; "
      "20,000 USDC collateral-limited quoted 21,000",
      dtc_a == D29 and c29 == 2_544_900_000 and V29 == U6("5089.8") and eff_slip(10_200, 100) == 100
      and BPS * 200 // 10_200 == 196 and w29["S"] == U6("99.8") == w29["G"]
      and w29["A"] == U6("19.96") and w29["kr"] == U6("79.84") and w29["B"] == 0 and w29["shortfall"] == 0
      and w29["keeperOut"] == U6("5069.84") == D29 + V29 - D29 - w29["A"]
      and sat_sub(w29["keeperOut"], D29) == U6("79.84") and Rv29 >= D29 and sat_sub(D29, Rv29) == 0
      and w29h["phi"] == U6("2.495") == flash_quote(D29, 5) and w29h["topUp"] == 0 and w29h["payout"] == U6("77.345")
      and D29 + U6("72") == U6("5062") and dtc_b == 1_113 * 10**6
      and dtc_g == W("42478.926") and dtc_900 == W("945") and dtc_cl == 21_000 * 10**6,
      f"c={c29} payout={fmt(w29['keeperOut'], 6)}")
replay("FV-LIQ-06u2", "NEW FINDING: 2.17 REQ-LENS-029 states recoveryFloor = ceil(5,089.80 x 0.99) - 0.000002 - 1 = "
       "5,037.900198 USDC; the expression gives 5,038.902 - 1.000002 = 5,037.901998 (digits transposed)",
       mg29 == U6("5037.901998") != U6("5037.900198") and ceil_div(V29 * 9_900, BPS) == U6("5038.902"),
       f"computed={fmt(mg29, 6)} stated=5037.900198")

# Old finding F-04: the Lens seizure is Aave's own _calculateCollateralToLiquidate (drawnShares x index + premium).
idx4 = 3 * RAY // 2 + 1
p4, _ = aave_account(3_555_120_000, 6, 2 * P8, 2_000 * E18 * RAY // idx4, 18, P8, 100 * E18, idx=idx4)
r4 = A.liquidation_call(p4)
lens_c4 = A.collateral_to_liquidate(p4, r4["drawn"], r4["prem"], r4["lb"], 10**6, E18)
old_c4 = r4["D"] * P8 * 10**6 * r4["lb"] // (E18 * 2 * P8 * BPS)
# FV-LIQ-06 verifies: REQ-LENS-029, REQ-LENS-017
check("FV-LIQ-06bf", "F-04 under the final REQ-LENS-029: drawnIndex 1.5 RAY + 1, debtToCover 100 GHO, Pc 2.00, dv 6: "
      "Aave pulls D = 100 GHO and seizes 50,999,999 units; the Lens formula on drawnShares and premium returns the same",
      r4["D"] == W("100") and r4["c"] == 50_999_999 and lens_c4 == r4["c"], f"lens={lens_c4} aave={r4['c']}")
mutant("FV-LIQ-06bfm", "F-04 old REQ-LENS-029 (seizure from D) returns 51,000,000, one unit above Aave",
       old_c4 != r4["c"] and old_c4 == 51_000_000, f"old={old_c4}")

# Old finding F-05: the Lens quotes the whole GHO debt, so a 1-wei repay cannot trip MustNotLeaveDust.


def f05_account(debt, x, dd=18):
    return aave_account(186_726 * 10**16, 18, 2 * P8, debt, dd, P8, x)[0]


T = 1_500 * E18
lens_x = lens_debt_to_cover(T, A.liquidation_call(f05_account(T, T))["D"], True, 18, P8)
after = A.liquidation_call(f05_account(T - 1, lens_x))
Tu = 1_500 * 10**6
lens_xu = lens_debt_to_cover(Tu, A.liquidation_call(f05_account(Tu, Tu, 6))["D"], False, 6, P8)
after_u = A.liquidation_call(f05_account(Tu - 1, lens_xu, 6))
# FV-LIQ-06 verifies: REQ-LENS-028, REQ-SWAP-005
check("FV-LIQ-06x", "F-05 under the final REQ-LENS-028 / REQ-SWAP-005: 1,500 GHO debt at HF 0.70: the preview quotes "
      "debtToCover = ceil(1,500 x 1.05) = 1,575 GHO; after a 1-wei repay Aave takes the whole 1,500 GHO - 1 wei and "
      "the call succeeds; with the debt in USDC Aave's sizing already takes the whole debt, the preview quotes it with "
      "the margin and the call survives a 1-unit repay",
      lens_x == W("1575") and after["D"] == T - 1 and lens_xu == 1_575 * 10**6 and after_u["D"] == Tu - 1)
try:
    A.liquidation_call(f05_account(T - 1, 500 * E18))
    old_reverts = False
except Exception as e:  # the port signals an Aave revert with its error name
    old_reverts = str(e) == "MustNotLeaveDust"
mutant("FV-LIQ-06xm", "F-05 old sizing at debtToCover = 500 GHO: after a 1-wei repay the remainder falls below $1,000 "
       "and Aave reverts MustNotLeaveDust",
       A.liquidation_call(f05_account(T, 500 * E18))["D"] == 500 * E18 and old_reverts)

# ================================================================ 3.5 end-to-end examples
# LIQ-060 (USDC debt, dd = 6) and LIQ-068 (GHO debt, dd = 18): dv = 6, Pc = 2.00, b = 10,200, Kf = D = 9,800.
U_usdt6 = unit_value(P8, 6, dd=6) + unit_value(99_980_000, 6, dd=6)
V60u = seized_value(4_998_000_000, 2 * P8, 6, dd=6)
m60u = recovery_floor(V60u, eff_slip(10_200, 100), U_usdt6, EPS6)
leg60 = leg_min_out(4_998_000_000, 99_980_000, 6, 100, 1, fra=EPS6, dd=6)
D60u = U6("9800")
w60u = waterfall(D60u, U6("9950"), D60u, V60u, min_rec=m60u, F=D60u, fee_bps=0)
w60b = waterfall(D60u, U6("9935"), D60u, V60u, min_rec=m60u)
w60x = waterfall(D60u, U6("10010"), D60u, V60u, min_rec=m60u)
V60 = seized_value(4_998_000_000, 2 * P8, 6)
m60 = recovery_floor(V60, eff_slip(10_200, 100), U_usdt)
w60 = waterfall(W("9800"), W("9950"), W("9800"), V60, min_rec=m60, F=W("9800"), fee_bps=0)
w60f = waterfall(W("9800"), m60, W("9800"), V60, min_rec=m60)
# FV-LIQ-06 verifies: LIQ-060, LIQ-068, LIQ-031a, LIQ-061, LIQ-040, LIQ-POST-016
check("FV-LIQ-06n", "3.5 LIQ-060 (USDC): c = 4,998,000,000, s = 100 (196), V = 9,996,000,000, U = 2, minOut = "
      "9,895,039,998, USDT leg minOut 4,946,030,395, R = 4,998 + 4,952 = 9,950: G = 196, Y = 150, A = 39.2, Kr = 110.8, "
      "B = 0, keeperOut = 9,910.8 = Kf + Kr, 19,750 in = out; helper F = 9,800 at phi = 0 pays its caller 110.8; "
      "R = 10,010: Y = 210, Kr = 156.8, B = 14, keeperOut 9,956.8; LIQ-031a: minPayout 9,909, R = 9,935 gives Y = 135, "
      "A = 39.2, Kr = 95.8, keeperOut 9,895.8 -> PayoutTooLow(9,895,800,000, 9,909,000,000); LIQ-061: keeperOut 9,910.8; "
      "LIQ-068 (GHO): U = 1,999,800,000,000, slippage term 9,896.04, minOut 9,895.0399980002 GHO, keeperOut 9,910.8 "
      "GHO, the helper sends 110.8 GHO; at minRec A = 39.2",
      9_800 * 10_200 * 10**6 * P8 // (BPS * 2 * P8) == 4_998_000_000 and BPS * 200 // 10_200 == 196
      and V60u == 9_996_000_000 and U_usdt6 == 2 and m60u == 9_895_039_998 and leg60 == 4_946_030_395
      and U6("4998") + U6("4952") == U6("9950") and U6("4952") >= leg60
      and w60u["G"] == U6("196") and w60u["S"] == U6("150") and w60u["A"] == U6("39.2") and w60u["kr"] == U6("110.8")
      and w60u["B"] == 0 and w60u["shortfall"] == 0 and w60u["keeperOut"] == U6("9910.8") == D60u + w60u["kr"]
      and D60u + U6("9950") == U6("19750") == D60u + w60u["A"] + w60u["keeperOut"]
      and w60u["topUp"] == 0 and w60u["payout"] == U6("110.8")
      and w60x["S"] == U6("210") and w60x["A"] == U6("39.2") and w60x["kr"] == U6("156.8") and w60x["B"] == U6("14")
      and w60x["keeperOut"] == U6("9956.8")
      and U6("9909") == D60u + U6("109") and w60u["keeperOut"] >= U6("9909")
      and w60b["S"] == U6("135") and w60b["A"] == U6("39.2") and w60b["kr"] == U6("95.8")
      and w60b["keeperOut"] == 9_895_800_000 < 9_909_000_000
      and V60 == W("9996") and U_usdt == 1_999_800_000_000 and ceil_div(V60 * 9_900, BPS) == W("9896.04")
      and m60 == W("9895.0399980002") and W("4976") + W("4974") == W("9950") and w60["S"] == W("150")
      and w60["A"] == W("39.2") and w60["keeperOut"] == W("9910.8") and w60["payout"] == W("110.8")
      and w60f["A"] == W("39.2"))

c_dust, D_dust = 397_800, 780_000
V_dust = seized_value(c_dust, 2 * P8, 6, dd=6)
m_d = recovery_floor(V_dust, 100, U_usdt6, EPS6)
w_d = waterfall(D_dust, 770_000, D_dust, V_dust, min_rec=m_d, max_shortfall=0)
w_dh = waterfall(D_dust, 770_000, D_dust, V_dust, min_rec=m_d, max_shortfall=0, F=D_dust, fee_bps=0)
# FV-LIQ-06 verifies: LIQ-060, LIQ-062, LIQ-039, LIQ-041, SPEC-LIQ-005, SPEC-LIQ-019
check("FV-LIQ-06o", "3.5 LIQ-060 dust (USDC): 397,800 units = 0.78 x 1.02 / 2.00, V = 795,600 = D x LB, slippage term "
      "787,644, minOut = max(0, 787,644 - 2 - 1,000,000) = 0; Kf = D = 780,000, R = 770,000: shortfall 0, Y = A = Kr = "
      "B = 0, keeperOut = 770,000 (the caller bears 0.01 USDC) with maxShortfall 0; LIQ-062: through the helper with "
      "X = F = 780,000 and phi = 0 it pulls 10,000 and pays its caller 0",
      780_000 * 10_200 // BPS * 10**6 // (2 * 10**6) == c_dust and V_dust == 795_600
      and V_dust * BPS == D_dust * 10_200 and ceil_div(V_dust * 9_900, BPS) == 787_644 > 770_000
      and m_d == 0 and w_d["shortfall"] == 0 and w_d["S"] == 0 and w_d["A"] == 0 and w_d["kr"] == 0 and w_d["B"] == 0
      and w_d["keeperOut"] == 770_000 and w_d["err"] is None and D_dust - w_d["keeperOut"] == 10_000
      and w_dh["topUp"] == 10_000 and w_dh["payout"] == 0)

# LIQ-069 (helper at 5 bps, 2.11 numbers) and LIQ-089 (Base, Slipstream, c = 1,020 vault tokens, dv = 6, Pc = 2.00)
V89 = seized_value(1_020_000_000, 2 * P8, 6, dd=6)
m89 = recovery_floor(V89, eff_slip(10_200, 100), U_usdc, EPS6)
D89 = U6("2000")
w89 = waterfall(D89, U6("1020") + U6("1018.5"), D89, V89, min_rec=m89, F=D89, fee_bps=5)
# FV-LIQ-06 verifies: LIQ-069, LIQ-089, LIQ-039, LIQ-040, REQ-HELPER-008
check("FV-LIQ-06bg", "3.5 LIQ-069 step 8: the helper receives 2,020.8 USDC, repays 1,950.975 and pays K1 69.825 = Kr - "
      "phi; LIQ-089: c = 2,000 x 1.02 / 2.00 = 1,020 tokens, s = 100, V = 2,040,000,000, minOut = 2,019,600,000 - 2 - "
      "1,000,000 = 2,018,599,998, R = 2,038,500,000: Y = 38.5, G = 40, A = 8, Kr = 30.5, B = 0, keeperOut = 2,030.5 >= "
      "2,025, 4,038.5 in = out; phi = 1 USDC, the helper repays 2,001 and pays K2 29.5",
      w975h["keeperOut"] == U6("2020.8") and D975 + w975h["phi"] == U6("1950.975")
      and w975h["payout"] == U6("69.825") == w975h["kr"] - w975h["phi"] and w975h["payout"] >= U6("69")
      and 2_000 * 10_200 * 10**6 // (BPS * 2) == 1_020_000_000 and V89 == 2_040_000_000
      and ceil_div(V89 * 9_900, BPS) == 2_019_600_000 and m89 == 2_018_599_998
      and w89["S"] == U6("38.5") and w89["G"] == U6("40") and w89["A"] == U6("8") and w89["kr"] == U6("30.5")
      and w89["B"] == 0 and w89["keeperOut"] == U6("2030.5") >= U6("2025")
      and D89 + U6("2038.5") == U6("4038.5") == D89 + w89["A"] + w89["keeperOut"]
      and w89["phi"] == U6("1") and D89 + w89["phi"] == U6("2001") and w89["payout"] == U6("29.5"))

# LIQ-068 Aave sizing on Alice's GHO account (141,232 vault tokens at 2.00, 79,452.85 GHO)
p68, hf68 = aave_account(141_232_000_000, 6, 2 * P8, W("79452.85"), 18, P8, W("9800"))
r68 = A.liquidation_call(p68)
tgt68 = A.debt_to_target_hf(p68, r68["lb"], E18)
hf68_after = D_(272_468) * D_("0.2812") / D_("69652.85")
# FV-LIQ-06 verifies: LIQ-068
check("FV-LIQ-06ba", "3.5 LIQ-068 through the Aave port: HF 0.999698 (79,428.88 / 79,452.85), bonus 10,200, target "
      "(87,398.135 - 79,428.8768) / 0.813176 = 9,800.16 (about 9,800.2), D = min(target, 9,800) = 9,800 GHO, c = "
      "4,998,000,000; 141,232,000,000 - 136,234,000,000 = c; after: 136,234 tokens (272,468 USD), 69,652.85 GHO, HF 1.09999",
      round(D_(282_464) * D_("0.2812"), 2) == D_("79428.88") and r68["lb"] == 10_200
      and round(D_(tgt68) / RAY / E18, 1) == D_("9800.2") and r68["D"] == W("9800") and r68["c"] == 4_998_000_000
      and 141_232_000_000 - 136_234_000_000 == r68["c"] and 136_234 * 2 == 272_468
      and W("79452.85") - W("9800") == W("69652.85") and str(hf68_after)[:7] == "1.09999"
      and round(D_("1.10") - D_("1.02") * D_("0.2812"), 6) == D_("0.813176"), f"hf={hf68} target={tgt68 // RAY}")
# FV-LIQ-06 verifies: LIQ-068
check("FV-LIQ-06ba2", "3.5 LIQ-068 step 1 (final): 282,464 x 0.2812 / 79,452.85 = 0.999698... ~ 0.9997",
      round(D_(hf68) / WAD, 4) == D_("0.9997"), f"computed {D_(hf68) / WAD:.6f}")
mutant("FV-LIQ-06ba2m", "old LIQ-068 text floor(282,464 x 0.2812 / 79,452.85) = 0.9997: the floor is 0.9996",
       hf68 // 10**14 != 9_997, f"floor {hf68 // 10**14}")

# REQ-LENS-009/017 Aave sizing on the 71,913.2-token account: the final text (40,456.119927 USDC) and the
# text before FV-LIQ-F-17 (40,456.12 USDC, kept as a mutant).
p69f, hf69f = aave_account(71_913_200_000, 6, 2 * P8, 40_456_119_927, 6, P8, 5_000 * 10**6)
r69f = A.liquidation_call(p69f)
# FV-LIQ-06 verifies: REQ-LENS-009, REQ-LENS-017, REQ-SWAP-089
check("FV-LIQ-06bb", "2.17 REQ-LENS-009/017 inputs (final): 143,826.40 x 0.2812 = 40,443.98368, HF 0.9997, "
      "bonus 10,200, (1.10 x 40,456.119927 - 40,443.98368) = 4,057.7482397, / 0.813176 = 4,989.9999996 ~ 4,990.00; Aave "
      "pulls 4,990,000,000 < a 5,000 USDC debtToCover and the 10 USDC it did not pull returns inside keeperOut, unswapped",
      71_913_200_000 * 2 == 143_826_400_000 and D_("143826.40") * D_("0.2812") == D_("40443.98368")
      and round(D_(hf69f) / WAD, 4) == D_("0.9997") and r69f["lb"] == 10_200
      and D_("1.10") * D_("40456.119927") - D_("40443.98368") == D_("4057.7482397")
      and round(D_("4057.7482397") / D_("0.813176"), 7) == D_("4989.9999996") and r69f["D"] == 4_990 * 10**6,
      f"hf={hf69f}")
p69, hf69 = aave_account(71_913_200_000, 6, 2 * P8, 40_456_120_000, 6, P8, 5_000 * 10**6)
r69 = A.liquidation_call(p69)
hf69_after = A.to_value(71_913_200_000 - r69["c"], 6, 2 * P8) * 2812 * 10**12 * WAD // (
    BPS * (40_456_120_000 - r69["D"]) * P8 * 10**12 * 10**12)
mutant("FV-LIQ-06bb2", "old REQ-LENS-009 / REQ-LENS-017 account (40,456.12 USDC): Aave pulls D = 4,990,000,099 "
       "USDC base units (target 4,990.0000984 rounded up) and seizes 2,544,900,050 units, leaving HF at or above 1.10; the "
       "text states D = expectedDebtRepaid = 4,990,000,000, c = 2,544,900,000 and HF after 1.09999",
       r69["D"] != 4_990 * 10**6 and r69["c"] != 2_544_900_000 and hf69_after >= 11 * 10**17,
       f"computed D={r69['D']} c={r69['c']} HFafter={hf69_after}")
p69g, _ = aave_account(71_913_200_000, 6, 2 * P8, W("40456.12"), 18, P8, W("40456.12"))
r69g = A.liquidation_call(p69g)
# FV-LIQ-06 verifies: REQ-LENS-028, REQ-LENS-029
check("FV-LIQ-06bb3", "REQ-LENS-028/029 GHO variant (final, 40,456.12 GHO owed): expectedDebtRepaid = "
      "4,990.000098... ~ 4,990 GHO and the seizure 2,544,900,050 units, about 2,544.9 vault tokens",
      round(D_(r69g["D"]) / E18, 3) == D_("4990.000") and round(D_(r69g["c"]) / 10**6, 1) == D_("2544.9"),
      f"computed D={fmt(r69g['D'])} c={r69g['c']}")
p69c, _ = aave_account(71_913_200_000, 6, 2 * P8, 40_456_119_927, 6, P8, 5_000 * 10**6)
r69c = A.liquidation_call(p69c)
hf69c = A.to_value(71_913_200_000 - r69c["c"], 6, 2 * P8) * 2812 * 10**12 * WAD // (
    BPS * (40_456_119_927 - r69c["D"]) * P8 * 10**12 * 10**12)
# FV-LIQ-06 verifies: REQ-LENS-009, REQ-LENS-017
check("FV-LIQ-06bb4", "Corrected REQ-LENS-009 / REQ-LENS-017 account: owing 40,456.119927 USDC, HF 0.9997, Aave pulls exactly "
      "D = 4,990,000,000 and seizes 2,544,900,000 units; after: 69,368.3 tokens against 35,466.119927 USDC, HF 1.10",
      r69c["D"] == 4_990 * 10**6 and r69c["c"] == 2_544_900_000 and 71_913_200_000 - r69c["c"] == 69_368_300_000
      and 40_456_119_927 - r69c["D"] == 35_466_119_927 and round(D_(hf69c) / WAD, 2) == D_("1.10"),
      f"HFafter={hf69c}")

# ================================================================ old finding F-06 against the final rules
fl = waterfall(D975, min975, D975, V975, min_rec=min975)
caller_total = fl["keeperOut"] + (U6("2040.3") - min975)
# FV-LIQ-06 verifies: SPEC-LIQ-009, SPEC-LIQ-008, LIQ-POST-016
check("FV-LIQ-06y", "F-06 floor conversion under the final SPEC-LIQ-009: the 2.11 liquidation converted at minRec = "
      "2,026.024998 USDC (S = 76.024998): A stays 19.5, keeperOut = 2,006.524998, and the caller's total (payout plus the "
      "14.275002 kept outside R) stays 2,020.8, so diverting gains nothing",
      fl["A"] == U6("19.5") and fl["S"] == U6("76.024998") and fl["keeperOut"] == U6("2006.524998")
      and caller_total == w975["keeperOut"] == U6("2020.8") and fl["B"] == 0, f"A={fl['A']} caller={caller_total}")
old_A = fl["S"] * 2000 // BPS
mutant("FV-LIQ-06ym", "F-06 old SPEC-LIQ-009 (A = floor(S x 20 %)): the same floor conversion cuts A from 19.5 to "
       "15.204999 USDC", old_A == U6("15.204999") and old_A < U6("19.5"), f"A={old_A}")

# Oversized debtToCover: Kf = X = 2,047.5 USDC, D = 1,950. Counting the 97.5 USDC leftover in R (R measured from before
# funding) would move the caller's own leftover into S and pay it out as borrower surplus.
S_old = sat_sub(U6("2040.3") + U6("97.5"), D975)
kr_old = min(S_old, w975["G"]) - min(w975["fee"], S_old)
B_old = S_old - min(w975["fee"], S_old) - kr_old
# FV-LIQ-06 verifies: SPEC-LIQ-006, SPEC-LIQ-017, SPEC-LIQ-022
mutant("FV-LIQ-06z", "R measured from before funding: the 97.5 USDC leftover of an oversized debtToCover enters R, so "
       "S = 187.8, kr = 78 and B = 90.3: the caller's own leftover would be paid to the borrower",
       S_old == U6("187.8") and kr_old == U6("78") and B_old == U6("90.3"), f"S={S_old} kr={kr_old} B={B_old}")
# FV-LIQ-06 verifies: SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-017
check("FV-LIQ-06z2", "SPEC-LIQ-006/017 (final): the leftover stays outside R, so the oversized call keeps S = 90.3, "
      "A = 19.5, B = 0 and pays keeperOut = Kf + kr = 2,047.5 + 70.8 = 2,118.3; LPVaultSwap's balance change is 0",
      wl["S"] == U6("90.3") and wl["A"] == U6("19.5") and wl["B"] == 0 and wl["keeperOut"] == U6("2118.3")
      and U6("2047.5") + U6("2040.3") + wl["shortfall"] == D975 + wl["A"] + wl["B"] + wl["keeperOut"])

# ================================================================ 2.18 PayoutEscrow (payout escrow, Q-401)
# FV-LIQ-06 verifies: REQ-ESCROW-006, REQ-ESCROW-004, REQ-SWAP-076, REQ-SWAP-026
check("FV-LIQ-06az", "2.11 REQ-SWAP-076: Avana's fee A = 19.5 USDC fails to reach a blocklisted feeRecipient and is "
      "escrowed (19,500,000 units) while keeperOut 2,020.8 is paid to the caller by plain transfer, never escrowed; "
      "2.18 REQ-ESCROW-006: 1,627,460 + 3,100,000 = 4,727,460, balance 14,727,460 after a 10 USDC transfer, both fall "
      "by 1,627,460 on b1's claim",
      w975["A"] == 19_500_000 and w975["keeperOut"] == U6("2020.8") and 1_627_460 + 3_100_000 == 4_727_460
      and 4_727_460 + 10 * 10**6 == 14_727_460 and 4_727_460 - 1_627_460 == 3_100_000
      and 14_727_460 - 1_627_460 == 13_100_000)

finish()
