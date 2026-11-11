# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-101..103: worked examples of debt-asset settlement (2.11 SPEC-LIQ-002..010, -015, -017..022,
2.13 SPEC-SET-001), liquidation throughput (SPEC-LIQ-021) and the one-sided route stress (REQ-ROUTE-006).
MATH-ST-120: the LitePSM gem amount of a PegModule swap route (REQ-ROUTE-012).
Exact integer evaluation of every stated figure. USDC debt (dd = 6, Pdebt = 1e8), vault token dv = 18 at $2.10,
USDC $1.00 and USDT $0.9995 legs (6 decimals), bonus 10,500, lf = 0. A liquidation takes no flash loan (Q-404): the
caller funds Kf, and a helper's loan carries the 5 bps premium (maxFlashFeeBps 10), as does deleverage.
"""
from fractions import Fraction as Fr
from z3 import Int, And, Or, Not, If
from _common import computed, check, done

E = 10**6
cdiv = lambda a, b: -(-a // b)
prem = lambda x, p=5: cdiv(x * p, 10**4)              # the flash source's ceiling quote
charged = lambda x, p=5: (x * p + 5_000) // 10**4    # the Aave V3 Pool's half-up premium (percentMul)
PC, PD, PUSDT = 210_000_000, 10**8, 99_950_000


def V_of(c):
    return c * PC * E // (10**18 * PD)


# regular case
c = 975 * 10**18
V = V_of(c)
D = 1_950 * E
F = D                              # a helper's loan of the whole debt
phi = prem(F)
s_raw = 10**4 * (10_500 - 10**4) // 10_500
s = min(100, s_raw)
U = cdiv(10**8 * E, E * PD) + cdiv(PUSDT * E, E * PD)
eps = E
term = cdiv(V * (10**4 - s), 10**4)
minRec = term - U - eps


def split(R, D, V, Kf, sf=0):
    Rp = R + sf
    S = max(0, Rp - D)
    G = max(0, V - D)
    A = min(G * 2_000 // 10**4, S)
    kr = min(S, G) - A
    B = S - A - kr
    ko = (Kf + Rp) - (D + A + B)
    return S, G, A, kr, B, ko


S, G, A, kr, B, ko = split(2_040_300_000, D, V, D)
S2, G2, A2, kr2, B2, ko2 = split(2_052_000_000, D, V, D)
S3, _, A3, _, _, ko3 = split(2_027_000_000, D, V, D)
_, _, _, _, _, ko4 = split(2_035_000_000, D, V, D)
# dust
Vd = V_of(15 * 10**17)
Dd = 3 * E
phid = prem(Dd)
minRec_d = cdiv(Vd * (10**4 - s), 10**4) - U - eps
gap_d = max(0, Dd + 0 + 0 - Dd - 2_950_000)
sf_d = max(0, minRec_d - 2_950_000, gap_d)
ko_d = (Dd + 2_950_000 + sf_d) - (Dd + 0 + 0)
# leg minimum (USDT into USDC, one swapped leg)
Vleg = 6_211_300_000 * PUSDT * E // (E * PD)
minOut = max(1, cdiv(Vleg * 9_900, 10**4) - 1 - eps // 1)
# shortfall
Vs = 12_422_600_000
minRec_s = cdiv(Vs * 9_900, 10**4) - U - eps
sLeg200 = 100 + min(1_000, 200 * E * 10**4 // Vs)
sLeg100 = 100 + min(1_000, 100 * E * 10**4 // Vs)
# deleverage
Vdl = V_of(1_000 * 10**18)
Vnet = max(0, Vdl * 9_900 // 10**4 - U - eps)
capd = Vnet * 10**4 // (10**4 + 10)
x = min(6_600 * E, capd)
phix = charged(x)
out = 2_096_200_000 - x - phix
hf_after = Fr(18_900 * 312, 1000) / Fr(6_600 * E - x, E)
# flash check
fee_ok = prem(F) * 10**4 <= 10 * F
fee_bad = prem(F, 20) * 10**4 > 10 * F
lens_F = cdiv(1_950 * E * 10_500, 10**4)

rows = [
    ("helper premium on 1,950 USDC", 975_000, phi), ("s raw (no premium term)", 476, s_raw), ("s", 100, s),
    ("V (2,047.5 USDC)", 2_047_500_000, V), ("U", 2, U), ("slippage term", 2_027_025_000, term),
    ("minRec", 2_026_024_998, minRec), ("S", 90_300_000, S), ("oracle gain G", 97_500_000, G), ("A", 19_500_000, A),
    ("kr", 70_800_000, kr), ("B", 0, B), ("keeperOut = Kf + kr", 2_020_800_000, ko),
    ("helper repays 1,950.975 and pays its caller", 69_825_000, ko - F - phi),
    ("surplus case S", 102_000_000, S2), ("surplus case kr", 78_000_000, kr2), ("surplus case B", 4_500_000, B2),
    ("surplus case keeperOut", 2_028_000_000, ko2), ("sandwich S", 77_000_000, S3), ("sandwich A", 19_500_000, A3),
    ("R = 2,035 keeperOut", 2_015_500_000, ko4), ("minPayout 1,950 + 69", 2_019_000_000, 1_950 * E + 69 * E),
    ("dust V", 3_150_000, Vd), ("dust helper premium", 1_500, phid), ("dust minRec", 2_118_498, minRec_d),
    ("dust gap", 0, gap_d), ("dust shortfall", 0, sf_d), ("dust keeperOut", 2_950_000, ko_d),
    ("dust helper top-up", 51_500, max(0, Dd + phid - ko_d)),
    ("Vleg USDT", 6_208_194_350, Vleg), ("minOut USDT", 6_145_112_406, minOut),
    ("shortfall minRec", 12_297_373_998, minRec_s), ("sLeg 200", 260, sLeg200), ("sLeg 100", 180, sLeg100),
    ("shortfall pulled", 123_373_998, minRec_s - 12_174_000_000),
    ("deleverage V", 2_100 * E, Vdl), ("Vnet", 2_077_999_998, Vnet), ("cap", 2_075_924_073, capd),
    ("x", 2_075_924_073, x), ("phi x charged (half up)", 1_037_962, phix), ("phi x quoted (ceiling)", 1_037_963, prem(x)),
    ("assetOut", 19_237_965, out),
    ("debt after", 4_524_075_927, 6_600 * E - x), ("HF after (4 dp)", Fr(13034, 10_000), Fr(round(hf_after * 10_000), 10_000)),
    ("two legs at their minimums (1,050 USDC each)", 2_077_999_998, 2 * max(1, cdiv(1_050 * E * 9_900, 10**4) - 1 - eps // 2)),
    ("x + phi at a 9 bps premium (charged)", 2_077_792_405, x + charged(x, 9)),
    ("x + phi at a 9 bps premium (quoted)", 2_077_792_405, x + cdiv(x * 9, 10**4)),
    ("dust keeperOut with the Lens margin Kf = 3.15", 3_100_000, (3_150_000 + 2_950_000) - Dd),
    ("fee best-effort: s at b 10,100", 99, min(100, 10**4 * (10_100 - 10**4) // 10_100)),
    ("fee best-effort: minRec", 999_999_999_998, cdiv(1_010_000 * E * (10**4 - 99), 10**4) - 2 - eps),
    ("fee best-effort: A at 0.9995 V", 2_000 * E, min(10_000 * E * 2_000 // 10**4, 1_009_495 * E - 1_000_000 * E)),
    ("fee best-effort: kr at 0.9995 V", 7_495 * E, min(9_495 * E, 10_000 * E) - 2_000 * E),
    ("fee best-effort: A at the floor", 0, min(10_000 * E * 2_000 // 10**4, max(0, 999_999_999_998 - 1_000_000 * E))),
    ("fee check 5 bps passes", True, fee_ok), ("fee check 20 bps fails", True, fee_bad),
    ("Lens debtToCover 2,047.5", 2_047_500_000, lens_F),
    ("Lens-margin helper premium", 1_023_750, prem(lens_F)), ("caller-borne premium", 48_750, prem(lens_F) - phi),
    ("F + phi with Lens margin", 2_048_523_750, lens_F + prem(lens_F)),
    ("Lens-margin keeperOut (leftover 97.5 inside)", 2_118_300_000, split(2_040_300_000, D, V, lens_F)[5]),
    ("Lens-margin helper payout", 69_776_250, split(2_040_300_000, D, V, lens_F)[5] - lens_F - prem(lens_F)),
    ("listing check 10,060 x 9,950 >= 1e8", True, 10_060 * 9_950 >= 10**8),
    ("listing check 10,060 x 9,950 < 1e4 x 10,010", True, 10_060 * 9_950 < 10**4 * 10_010),
]
# MATH-ST-101 verifies: REQ-HELPER-008, SPEC-LIQ-016, SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-007, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-015, SPEC-LIQ-017, SPEC-LIQ-018, SPEC-LIQ-019, SPEC-LIQ-020, SPEC-LIQ-022, SPEC-SET-001, Q-333, Q-337
computed("MATH-ST-101", "2.11 worked examples in USDC debt units", rows)

# throughput
cpb_eth = 3 * 60_000_000 // (10 * 1_500_000)
blocks_eth = max(cdiv(300, cpb_eth), cdiv(3_000_000, 500_000), cdiv(3_000_000, 200_000_000))
cpb_base = 3 * 150_000_000 // (10 * 1_500_000)
blocks_base = max(cdiv(300, cpb_base), cdiv(3_000_000, 500_000), 1)
rows2 = [("Ethereum calls per block", 12, cpb_eth), ("Ethereum gas blocks", 25, cdiv(300, cpb_eth)),
         ("route blocks", 6, cdiv(3_000_000, 500_000)), ("Ethereum T_drain s", 300, 12 * blocks_eth),
         ("Base calls per block", 30, cpb_base), ("Base gas blocks", 10, cdiv(300, cpb_base)),
         ("Base T_drain s", 20, 2 * blocks_base), ("12 calls of 1.3M fit 16.78M", True, 12 * 1_300_000 <= 16_777_216)]
# MATH-ST-102 verifies: SPEC-LIQ-021, REQ-SWAP-118, Q-344
computed("MATH-ST-102", "liquidation throughput examples", rows2)

# one-sided stress: constant product, depth 10 V in value; selling x loses x / (x + depth).
# Half legs: x = V/2 -> loss(1, 20) = 1/21; full leg: x = V -> loss(1, 10) = 1/11.
loss = lambda x, Y: Fr(x, x + Y)
rows3 = [("two half legs, each (bps, floor)", 476, int(loss(1, 20) * 10**4)),
         ("one full leg (bps, floor)", 909, int(loss(1, 10) * 10**4)),
         ("half-leg stress passes 500 bps", True, loss(1, 20) * 10**4 <= 500),
         ("one-sided unwind fails 500 bps", True, loss(1, 10) * 10**4 > 500)]
# MATH-ST-103 verifies: REQ-ROUTE-006, Q-340
computed("MATH-ST-103", "one-sided unwind against the half-leg stress", rows3)

# LitePSM gem amount (REQ-ROUTE-012). cost(g) = g*c + floor(g*c*tout/W) (DssLitePsm.buyGem); the route takes
# g0 = floor(D*W/((W + tout)*c)) and g0 + 1 when cost(g0 + 1) <= D. Products are fresh variables tied by linear facts:
# Q0 = g0*c, CT = c*tout (below 10^18 * 10^36), P0 = g0*c*tout, so (g0 + k)*c = Q0 + k*c and (g0 + k)*c*tout = P0 + k*CT. Dropping the
# product definitions only weakens the premises, so PROVED here is PROVED for the real products.
W = 10**18
Dv, t, cv, Q0, CT, P0 = Int("D"), Int("tout"), Int("c"), Int("Q0"), Int("CT"), Int("P0")
f0, f1, f2 = Int("fee0"), Int("fee1"), Int("fee2")
base = [Dv >= 0, Dv < 2**128, t >= 0, t < 10**36, cv >= 1, cv <= 10**18, Q0 >= 0, CT >= 0, CT < 10**54, P0 >= 0,
        # g0 = floor(D*W / ((W + tout)*c)): g0*(W + tout)*c <= D*W < (g0 + 1)*(W + tout)*c
        Q0 * W + P0 <= Dv * W, Dv * W < Q0 * W + P0 + cv * W + CT]
for k, f in ((0, f0), (1, f1), (2, f2)):
    base += [f * W <= P0 + k * CT, P0 + k * CT < (f + 1) * W]   # fee_k = floor((g0 + k)*c*tout / W)
cost = lambda k, f: Q0 + k * cv + f
take1 = cost(1, f1) <= Dv
r_cost = If(take1, cost(1, f1), cost(0, f0))        # cost(r)
r_next = If(take1, cost(2, f2), cost(1, f1))        # cost(r + 1)
# MATH-ST-120 verifies: REQ-ROUTE-012, Q-062
check("MATH-ST-120", "LitePSM gemAmt r: cost(r) <= D and cost(r + 1) > D (r is the largest gem amount D buys)",
      base + [Not(And(r_cost <= Dv, r_next > Dv))], "PROVED")
# MATH-ST-120 verifies: REQ-ROUTE-012
check("MATH-ST-120", "wrong reading: g0 alone is not always the largest (the fee floor admits g0 + 1)",
      base + [cost(1, f1) <= Dv, t > 0], "COUNTEREXAMPLE", show=[Dv, t, cv])
# MATH-ST-120 verifies: REQ-ROUTE-012
check("MATH-ST-120", "never g0 + 2: cost(g0 + 2) > D", base + [cost(2, f2) <= Dv], "PROVED")
# MATH-ST-120 verifies: REQ-ROUTE-012
check("MATH-ST-120", "no overflow: (g0 + 1)*c <= D + c and fee(g0 + 1) < D + 10^36 for D < 2^128",
      base + [Or(Q0 + cv > Dv + cv, f1 >= Dv + 10**36)], "PROVED")


def gem(Dd, tt, cc):
    g0 = Dd * W // ((W + tt) * cc)
    cst = lambda g: g * cc + g * cc * tt // W
    return g0 + 1 if cst(g0 + 1) <= Dd else g0


def gcost(g, tt, cc):
    return g * cc + g * cc * tt // W


d1 = 1_000 * 10**18 + 5 * 10**11
# MATH-ST-120 verifies: REQ-ROUTE-012
computed("MATH-ST-120", "REQ-ROUTE-012 examples", [
    ("tout 0, 1,000.0000005 DAI: gemAmt", 1_000_000_000, gem(d1, 0, 10**12)),
    ("DAI residue (wei)", 500_000_000_000, d1 - gcost(gem(d1, 0, 10**12), 0, 10**12)),
    ("tout 0.1 %, 1,001 DAI: gemAmt", 1_000_000_000, gem(1_001 * 10**18, 10**15, 10**12)),
    ("its cost is all 1,001 DAI", 1_001 * 10**18, gcost(1_000_000_000, 10**15, 10**12)),
    ("g0 + 1 does not fit", True, gcost(1_000_000_001, 10**15, 10**12) > 1_001 * 10**18),
])

done()
