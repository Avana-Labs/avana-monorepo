# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-124..129: how a flash liquidation helper call is funded (2.11 REQ-HELPER-003, -004, -006, -007, -008, -011).

The helper pulls the prefund X - F + mS from its payer (inventory and the SPEC-LIQ-019 shortfall budget), borrows F,
approves LPVaultSwap for X + mS, which pulls X and then the floor shortfall sh <= mS, and pays keeperOut back:
  keeperOut = Kf + R + sh - D - A - B,  Kf = X                                  SPEC-LIQ-010 (no transfer fee)
  u         = mS - sh            (allowance left, still held)                  REQ-HELPER-006
  owed      = F + phi;  held = keeperOut + u;  topUp = max(0, owed - held)     REQ-HELPER-007
  payout    = rise of the helper's balance over the call = held + topUp - owed REQ-HELPER-008
  outlay    = X - F + mS + topUp     (everything pulled from the payer)
The operator variant also requires F <= need = ceil(D (1e4 + 500) / 1e4) and outlay - payout <= floor(D b / 1e4),
b = MAX_TOP_UP_BPS (REQ-HELPER-011). The operator variant also accepts F = 0 (REQ-HELPER-003): no loan is taken, so
phi = 0 and owed = 0; every check below covers 0 <= F <= X. Amounts in debt-asset base units.
"""
from z3 import Ints, If, And, Or, Not
from _common import check, computed, done, BPS

LENS_MARGIN = 500
pos = lambda x: If(x > 0, x, 0)

X, F, mS, sh, D, A, B, R, phi, ko, u, held, owed, topUp, payout, outlay = Ints(
    "X F maxShortfall shortfall D A B R phi keeperOut u held owed topUp payout outlay")
minRec = Ints("minRec")[0]

flow = [
    X >= 1, X < 2**128, F >= 0, F <= X, Or(F > 0, phi == 0), mS >= 0, mS < 2**128, D >= 0, D <= X, A >= 0, B >= 0, R >= 0, phi >= 0,
    minRec >= 0,
    # SPEC-LIQ-019: shortfall = max(0, minRec - R) within the budget; the floor top-up makes R_f = minRec, and
    # A + B <= max(0, R_f - D) (SPEC-LIQ-008/009/022)
    sh == pos(minRec - R), sh <= mS,
    A + B <= pos(If(R > minRec, R, minRec) - D),
    ko == X + R + sh - D - A - B,
    u == mS - sh, held == ko + u, owed == F + phi, topUp == pos(owed - held),
    payout == held + topUp - owed, outlay == X - F + mS + topUp,
]

# ---------- ST-124: the helper always holds what LPVaultSwap pulls, and the payout is well defined ----------
# MATH-ST-124 verifies: REQ-HELPER-004, REQ-HELPER-006, SPEC-LIQ-019
check("MATH-ST-124",
      "with the prefund X - F + mS and the loan F the helper holds X + mS >= X + shortfall when LPVaultSwap pulls, "
      "the allowance X + mS covers both pulls, keeperOut >= 0 and u >= 0",
      flow + [Or(X - F + mS + F < X + sh, X + mS < X + sh, ko < 0, u < 0)],
      "PROVED")

# ---------- ST-125: payout and top-up ----------
# MATH-ST-125 verifies: REQ-HELPER-007, REQ-HELPER-008, SPEC-LIQ-019
check("MATH-ST-125",
      "payout = max(0, keeperOut + u - F - phi) >= 0, and a top-up and a payout are never both positive (the unused "
      "shortfall budget pays toward the loan before any top-up)",
      flow + [Or(payout < 0, payout != pos(ko + u - F - phi), And(topUp > 0, payout > 0))],
      "PROVED")

# ---------- ST-126: the payer's net outlay ----------
# MATH-ST-126 verifies: REQ-HELPER-011, REQ-HELPER-008, SPEC-LIQ-010, SPEC-LIQ-019
check("MATH-ST-126",
      "outlay - payout = D + A + B - R + phi: the shortfall pulled cancels, so the payer's net cost depends only on "
      "the seizure's recovery against the debt, the waterfall and the premium",
      flow + [outlay - payout != D + A + B - R + phi],
      "PROVED")

# ---------- ST-127: the operator bounds ----------
bps, need, bound, before, after = Ints("MAX_TOP_UP_BPS need bound safeBefore safeAfter")
op = flow + [bps >= 0, bps <= BPS,
             need * BPS >= D * (BPS + LENS_MARGIN), need * BPS < D * (BPS + LENS_MARGIN) + BPS,
             bound * BPS <= D * bps, bound * BPS > D * bps - BPS,
             before >= outlay, after == before - outlay + payout]
completes = [F <= need, topUp <= bound, outlay - payout <= bound]
# MATH-ST-127 verifies: REQ-HELPER-011, REQ-HELPER-007
check("MATH-ST-127a",
      "a completed operator call leaves the Safe at least floor(D b / 1e4) below its start at worst, whatever X, F, "
      "maxShortfall and maxTopUp the signer sends",
      op + completes + [after < before - bound],
      "PROVED")
# MATH-ST-127 verifies: REQ-HELPER-011
check("MATH-ST-127b",
      "a call that gains for the Safe (R >= D + A + B + phi) is never refused by the outlay bound",
      op + [R >= D + A + B + phi, outlay - payout > bound],
      "PROVED")
# MATH-ST-127 verifies: REQ-HELPER-011, SPEC-LIQ-015
pr = Ints("premiumRate")[0]
check("MATH-ST-127c",
      "a loan within the need pays a premium of at most ceil(need p / 1e4) <= ceil(ceil(1.05 D) p / 1e4): the premium "
      "the Safe can be charged is bounded by the debt repaid",
      op + [pr >= 0, pr <= 100, F <= need, phi * BPS < F * pr + BPS, phi * BPS >= F * pr,
            phi * BPS >= need * pr + BPS],
      "PROVED")
# Wrong reading: a bound on the signer's X, not on D (review FL-02).
xb = Ints("xBound")[0]
# MATH-ST-127 verifies: REQ-HELPER-011
check("MATH-ST-127d",
      "wrong reading: with the top-up bounded by floor(X b / 1e4) and no loan or outlay bound, a signer sizing X and "
      "F makes the Safe pay a 5 bps premium on an oversized loan and lose more than floor(D b / 1e4), even when the "
      "routes recover above the debt (counterexample expected)",
      flow + [bps == 100, xb * BPS <= X * bps, xb * BPS > X * bps - BPS, topUp <= xb,
              D == 1950 * 10**6, R >= D + A + B, minRec <= R, phi * BPS >= F * 5, phi * BPS < F * 5 + BPS,
              bound * BPS <= D * bps, bound * BPS > D * bps - BPS, outlay - payout > bound],
      "COUNTEREXAMPLE")

# ---------- ST-129: the operator's zero loan ----------
# MATH-ST-129 verifies: REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-008, REQ-HELPER-011
check("MATH-ST-129a",
      "F = 0: nothing is owed, so no top-up is pulled, the payout is keeperOut + u, and the Safe's net outlay is "
      "D + A + B - R (the premium term vanishes, the shortfall still cancels)",
      flow + [F == 0, Or(topUp != 0, payout != ko + u, outlay - payout != D + A + B - R)],
      "PROVED")
# MATH-ST-129 verifies: REQ-HELPER-011
check("MATH-ST-129b",
      "F = 0: a completed operator call leaves the Safe at most floor(D b / 1e4) poorer, and the loan bound F <= need "
      "holds for every D >= 0",
      op + [F == 0, outlay - payout <= bound, Or(after < before - bound, F > need)],
      "PROVED")

# ---------- ST-128: worked examples of 2.11 ----------
E6, E18 = 10**6, 10**18


def run(X_, F_, mS_, D_, R_, A_, minRec_, phi_):
    sh_ = max(0, minRec_ - R_)
    ko_ = X_ + R_ + sh_ - D_ - A_
    u_ = mS_ - sh_
    owed_ = F_ + phi_
    top_ = max(0, owed_ - (ko_ + u_))
    pay_ = ko_ + u_ + top_ - owed_
    out_ = X_ - F_ + mS_ + top_
    return sh_, ko_, u_, top_, pay_, out_


ceil_div = lambda a, b: -(-a // b)
prem = lambda f: ceil_div(f * 5, BPS)
fl = run(12_000 * E6, 12_000 * E6, 200 * E6, 12_000 * E6, 12_174 * E6, 0, 12_297_373_998, prem(12_000 * E6))
fl_inv = run(12_000 * E6, E6, 200 * E6, 12_000 * E6, 12_174 * E6, 0, 12_297_373_998, prem(E6))
need_bob = ceil_div(1_950 * E6 * (BPS + LENS_MARGIN), BPS)
poc_x = 10_000_000 * E6
poc = run(poc_x, poc_x - 5_000 * E6, 0, 1_950 * E6, 2_040_300_000, 19_500_000, 0, prem(poc_x - 5_000 * E6))
r1900 = run(2_047_500_000, 1_950 * E6, 0, 1_950 * E6, 1_900 * E6, 0, 0, 975_000)
r1940 = run(2_047_500_000, 1_950 * E6, 0, 1_950 * E6, 1_940 * E6, 0, 0, 975_000)
r1850 = run(2_047_500_000, 2_047_500_000, 0, 1_950 * E6, 1_850 * E6, 0, 0, prem(2_047_500_000))
gho = run(1_950 * E18, 1_950 * E18, 0, 1_950 * E18, 2_040_300_000_000_000_000_000, 19_500_000_000_000_000_000, 0,
          (1_950 * E18 * 5 + 5_000) // BPS)
inv = run(2_047_500_000, 1_950 * E6, 0, 1_950 * E6, 2_040_300_000, 19_500_000, 0, 975_000)
# MATH-ST-128 verifies: REQ-HELPER-006, REQ-HELPER-008, REQ-HELPER-011, REQ-HELPER-015, SPEC-LIQ-019
computed("MATH-ST-128", "2.11 helper examples (USDC 6 decimals, GHO 18)", [
    ("SPEC-LIQ-019 through the helper: shortfall 123.373998 USDC", 123_373_998, fl[0]),
    ("keeperOut 12,297.373998 USDC", 12_297_373_998, fl[1]),
    ("unused budget u = 76.626002 USDC", 76_626_002, fl[2]),
    ("payout 368 USDC (net 168 after the 200 budget)", 368 * E6, fl[4]),
    ("with F = 1 USDC: payout = 12,199 + 174 - 0.0005 USDC", 12_372_999_500, fl_inv[4]),
    ("operator need for D = 1,950 USDC: 2,047.5 USDC", 2_047_500_000, need_bob),
    ("review PoC: Safe loss 4,926.7 USDC without the bounds", 4_926_700_000, poc[5] - poc[4]),
    ("outlay bound for D = 1,950 at 100 bps: 19.5 USDC", 19_500_000, 1_950 * E6 * 100 // BPS),
    ("R = 1,900: Safe loss 50.975 USDC (refused)", 50_975_000, r1900[5] - r1900[4]),
    ("R = 1,940: Safe loss 10.975 USDC (settles)", 10_975_000, r1940[5] - r1940[4]),
    ("R = 1,940: payout 86.525 USDC", 86_525_000, r1940[4]),
    ("X = F = 2,047.5 against D = 1,950, R = 1,850: top-up 101.02375 USDC", 101_023_750, r1850[3]),
    ("GHO from the Pool at its 5 bps premium (half up): 0.975 GHO", 975 * 10**15, (1_950 * E18 * 5 + 5_000) // BPS),
    ("GHO payout 69.825 GHO", 69_825 * 10**15, gho[4]),
    ("F < X example: payout 167.325 USDC", 167_325_000, inv[4]),
    ("net minimum of 69 USDC with F < X: minPayout 166.5 USDC", 166_500_000, 2_047_500_000 - 1_950 * E6 + 69 * E6),
    ("D = 9,800 at 100 bps: top-up bound 98 USDC", 98 * E6, 9_800 * E6 * 100 // BPS),
])

z_bob = run(1_950 * E6, 0, 0, 1_950 * E6, 2_040_300_000, 19_500_000, 0, 0)
z1900 = run(1_950 * E6, 0, 0, 1_950 * E6, 1_900 * E6, 0, 0, 0)
z1940 = run(1_950 * E6, 0, 0, 1_950 * E6, 1_940 * E6, 0, 0, 0)
z_fl = run(12_000 * E6, 0, 200 * E6, 12_000 * E6, 12_174 * E6, 0, 12_297_373_998, 0)
# MATH-ST-129 verifies: REQ-HELPER-004, REQ-HELPER-008, REQ-HELPER-011, SPEC-LIQ-019
computed("MATH-ST-129c", "2.11 operator examples with F = 0 (USDC 6 decimals)", [
    ("Bob with F = 0: payout = keeperOut = 2,020.8 USDC", 2_020_800_000, z_bob[4]),
    ("Bob with F = 0: no top-up", 0, z_bob[3]),
    ("Bob with F = 0: the Safe gains 70.8 USDC", 70_800_000, z_bob[4] - z_bob[5]),
    ("R = 1,900, A = 0: Safe net outlay 50 USDC (refused at 19.5)", 50 * E6, z1900[5] - z1900[4]),
    ("R = 1,940, A = 0: Safe net outlay 10 USDC (settles)", 10 * E6, z1940[5] - z1940[4]),
    ("floor case with F = 0: payout 12,374 USDC", 12_374 * E6, z_fl[4]),
    ("floor case with F = 0: the Safe nets 174 USDC", 174 * E6, z_fl[4] - z_fl[5]),
])

done()
