# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-45..53 — Cap math of the RiskModule and the Hub caps it relies on.

Spec: SPEC-CAP-001 (stress-floor booking, minimum pledge value), SPEC-CAP-002 (cap tests and
counter booking), SPEC-CAP-003 (top-up slice restore amount), SPEC-CAP-004 (exit release),
SPEC-CAP-005 (pool-share cap), SPEC-CAP-006 / SPEC-HUB-002 (Hub addCap sizing), SPEC-HUB-003
(credit-line caps), SPEC-CAP-008 (tail coverage ratio).
Units: USD with 8 decimals; L, u in vault-token base units; d the vault-token decimals.
"""
import math
from z3 import Ints, Int, Real, ToReal, If, And, Or, Not
from _common import prove, witness, computed, finish, floor_div, ceil_div, WAD, RAY, BPS


def mx(a, b):
    return If(a > b, a, b)


def mn(a, b):
    return If(a < b, a, b)


def cdiv(a, b):
    return -(-a // b)


# ---------------------------------------------------------------------------
# MATH-AR-45  SPEC-CAP-001 booking and minimum.
L, p, fl, dp, minp = Ints('L price8 floor dpow minPledge')
chg, hc = ceil_div(L * mx(p, fl), dp, 'usdCharge')
pv, hp = floor_div(L * p, dp, 'pledgeUsd')
b45 = [L > 0, L < 2**120, p > 0, p < 2**64, fl > 0, fl < 2**64,
       Or(*[dp == 10**d for d in range(6, 19)]), minp >= 0] + hc + hp
# MATH-AR-45 verifies: SPEC-CAP-001, INV-069
prove('MATH-AR-45a', 'usdCharge >= value at the booking price max(price8, floor) and >= value at the floor',
      b45, And(chg * dp >= L * mx(p, fl), chg * dp >= L * fl))
prove('MATH-AR-45b', 'usdCharge >= 1 for every L > 0', b45, chg >= 1)
prove('MATH-AR-45c', 'pledgeUsd >= minPledgeUsd  <=>  exact L x price8 >= minPledgeUsd x 10^d (passes only if the exact value reaches it)',
      b45, (pv >= minp) == (L * p >= minp * dp))
prove('MATH-AR-45d', 'L < 2^120, price8 and floor < 2^64: both products < 2^184', b45,
      And(L * mx(p, fl) < 2**184, L * p < 2**184))
computed('MATH-AR-45e', 'SPEC-CAP-001 example (d = 6)',
         [('usdCharge, L 5e10 at 199,990,000', 9_999_500_000_000, cdiv(5 * 10**10 * 199_990_000, 10**6)),
          ('pledgeUsd, same', 9_999_500_000_000, 5 * 10**10 * 199_990_000 // 10**6),
          ('usdCharge at 80,000,000 (floor 1e8 applies)', 5_000_000_000_000, cdiv(5 * 10**10 * max(80_000_000, 10**8), 10**6)),
          ('pledgeUsd, L 5,000,000', 999_950_000, 5_000_000 * 199_990_000 // 10**6),
          ('L 5,000,000 is below $10 (BelowMinPledge)', True, 5_000_000 * 199_990_000 // 10**6 < 10 * 10**8),
          ('pledgeUsd, L 5,001,000', 1_000_149_990, 5_001_000 * 199_990_000 // 10**6),
          ('L 5,001,000 passes', True, 5_001_000 * 199_990_000 // 10**6 >= 10 * 10**8)])

# ---------------------------------------------------------------------------
# MATH-AR-46  SPEC-CAP-002 cap tests and booking.
R, S, T0, P, K, Z, c, tc, dc, Sall = Ints('R S T0 P K Z c tokenCap depCap sliceAllMarkets')
room = If(K > R, K - R, 0)
sl_e = If(c > room, c - room, 0)
b46 = [R >= 0, S >= 0, T0 >= 0, P >= 0, K > 0, Z >= 0, c >= 1, tc > 0, dc > 0, Sall >= S]
new_ok = And(c <= room, T0 + c <= tc, P + c <= dc)
top_ok = And(S + sl_e <= Z, T0 + (c - sl_e) <= tc, P + (c - sl_e) <= dc)
# MATH-AR-46 verifies: SPEC-CAP-002, INV-028
prove('MATH-AR-46a', 'new-account pledge passes  =>  R + c <= K (regular budget never exceeded)',
      b46 + [new_ok], R + c <= K)
prove('MATH-AR-46b', 'eligible top-up passes  =>  regular part c - slice <= room, S + slice <= Z, slice <= c',
      b46 + [top_ok], And(c - sl_e <= room, S + sl_e <= Z, sl_e <= c, sl_e >= 0))
prove('MATH-AR-46c', 'R <= K and S <= Z are kept by every booking (new pledge or eligible top-up)',
      b46 + [R <= K, S <= Z, Or(new_ok, top_ok)],
      And(R + (c - If(new_ok, 0, sl_e)) <= K, S + If(new_ok, 0, sl_e) <= Z))
prove('MATH-AR-46d', 'token counter exceeds its cap by at most the slice booked: T0 <= cap + slices before  =>  after too',
      b46 + [T0 <= tc + Sall, top_ok], T0 + c <= tc + Sall + sl_e)
r_ex = 99_000_000_000_000; c_ex = 2_000_000_000_000
room_ex = max(100_000_000_000_000 - r_ex, 0)
sl_ex = c_ex - room_ex if c_ex > room_ex else 0
computed('MATH-AR-46e', 'SPEC-CAP-002 example (K $1,000,000, Z $100,000, R $990,000, c $20,000)',
         [('room $10,000', 1_000_000_000_000, room_ex), ('sliceUsd $10,000', 1_000_000_000_000, sl_ex),
          ('S + slice <= Z', True, sl_ex <= 10_000_000_000_000),
          ('R after = $1,000,000', 100_000_000_000_000, r_ex + c_ex - sl_ex),
          ('as a new-account pledge c > room (CapExceeded)', True, c_ex > room_ex)])

# ---------------------------------------------------------------------------
# MATH-AR-47  SPEC-CAP-003 restore amount: restoreBooked = ceil(usdToRestore x M / sv), with
# M = max(price8, floor) (price8 the accepted price) and sv = served8 = latestAnswer() <= price8
# (equal while Live; min(fresh, accepted) while Drifting, SPEC-ORC-017).
hf, ho, Dv, cf, x, u, rb, M, Ae, sv = Ints('hf h_o Dray CF x usdToRestore restoreBooked bookPrice Aexact served8')
hx = [x * WAD * RAY >= (ho - hf) * Dv, x * WAD * RAY < (ho - hf) * Dv + WAD * RAY]
hu = [u * cf * 10**18 >= x * BPS, u * cf * 10**18 < x * BPS + cf * 10**18]
hr = [rb * sv >= u * M, rb * sv < u * M + sv]
b47 = [hf >= 0, ho > hf, Dv > 0, cf > 0, cf < BPS, p > 0, M >= p, sv > 0, sv <= p] + hx + hu + hr
# MATH-AR-47 verifies: SPEC-CAP-003, REQ-RISK-066
prove('MATH-AR-47a', 'adding usdToRestore of collateral at CF_m restores h_o: (A + CF u 1e14) x WAD x RAY >= h_o x D (A x WAD x RAY >= hf x D)',
      b47 + [Ae * WAD * RAY >= hf * Dv], (Ae + cf * u * 10**14) * WAD * RAY >= ho * Dv)
Lr, dpw, chr_ = Ints('Lr dpw chargeR')
prove('MATH-AR-47b', 'a slice top-up charged <= restoreBooked has served value < usdToRestore + 1 (it cannot grow the position)',
      b47 + [Lr > 0, dpw > 0, chr_ * dpw >= Lr * M, chr_ <= rb], Lr * sv < (u + 1) * dpw)
# SIM-GAP-14: a top-up worth usdToRestore at the served price (the collateral that restores h_o
# in Aave's health factor) is charged at most restoreBooked, whatever the gap between the prices.
prove('MATH-AR-47f', 'a top-up worth <= usdToRestore at served8, charged ceil(L x M) at the accepted basis, fits under restoreBooked',
      b47 + [Lr > 0, dpw > 0, Lr * sv <= u * dpw, chr_ * dpw >= Lr * M, chr_ * dpw < Lr * M + dpw], chr_ <= rb)
# Spec rounding claim: restoreBooked exceeds the exact value by less than max(price8, floor)/served8 + 2 units
# of 1e-8 USD (MATH-AR-47d), so by less than 3 units while served8 = price8 >= floor (book price M = price8).
# exact = (h_o - hf) D / (WAD RAY) x 1e4 / (CF 1e18) x M / served8; scaled by served8 CF 1e18 WAD RAY.
claim = rb * p * cf * 10**18 * WAD * RAY - M * (ho - hf) * Dv * BPS < 3 * p * cf * 10**18 * WAD * RAY
prove('MATH-AR-47c', 'SPEC-CAP-003 rounding: restoreBooked - exact < 3 units while price8 >= floor (launch floor $1, M = price8)',
      b47 + [M == p, sv == p, p >= 10**8, p < 2**64, Dv == 10**57, cf == 3000, ho == 11 * 10**17, hf >= 10**17], claim)  # F-AR-3 resolved
prove('MATH-AR-47d', 'bound that holds: restoreBooked - exact < max(price8, floor)/served8 + 2 units',
      b47 + [M == 10**8, Dv == 10**57, cf == 3000, ho == 11 * 10**17, hf >= 10**17, sv >= 10**6],
      rb * sv * cf * 10**18 * WAD * RAY - M * (ho - hf) * Dv * BPS < (M + 2 * sv) * cf * 10**18 * WAD * RAY)
x_e = cdiv((11 * 10**17 - 102 * 10**16) * 10**57, WAD * RAY)
u_e = cdiv(x_e * BPS, 3000 * 10**18)
computed('MATH-AR-47e', 'SPEC-CAP-003 / REQ-RISK-066 example (D $10,000, hf 1.02, h_o 1.10, CF 3,000)',
         [('x = 8e28', 8 * 10**28, x_e), ('usdToRestore', 266_666_666_667, u_e),
          ('restoreBooked at 199,990,000', 266_666_666_667, cdiv(u_e * max(199_990_000, 10**8), 199_990_000)),
          ('restoreBooked at 80,000,000', 333_333_333_334, cdiv(u_e * max(80_000_000, 10**8), 80_000_000)),
          ('Drifting: accepted 198,950,000, served 154,800,000', 342_721_791_560, cdiv(u_e * 198_950_000, 154_800_000)),
          ('old divisor admitted 77.8% of the gap', 778, round(1000 * 154_800_000 / 198_950_000)),
          ('debt 7,000.30 GHO + 3,000 USDC at 0.9999 = $10,000.00', 10**57,
           (700_030 * 10**16 * 10**8 + 3000 * 10**6 * 99_990_000 * 10**12) * RAY),
          ('a $3,000 top-up exceeds restoreBooked (NotRescueTopUp)', True, 300_000_000_000 > u_e),
          ('a $2,000 top-up fits', True, 200_000_000_000 <= u_e)])

# ---------------------------------------------------------------------------
# MATH-AR-48  SPEC-CAP-004 exit release.
C0, U0, ub, xa, xb = Ints('C0 U0 ub xa xb')


def charge(uu, tag):
    q, hq = ceil_div(C0 * uu, U0, tag)
    return q, hq


cb, h1 = charge(ub, 'chg_b')
ca, h2 = charge(ub - xa, 'chg_a')
cc, h3 = charge(ub - xa - xb, 'chg_c')
cx, h4 = charge(xa, 'chg_x')
b48 = [C0 >= 1, C0 < 2**184, U0 >= 1, U0 < 2**120, ub >= 0, ub <= U0, xa >= 0, xb >= 0, xa + xb <= ub] + h1 + h2 + h3 + h4
c_full, h5 = charge(U0, 'chg_full')
c_zero, h6 = charge(Int('zero_u'), 'chg_zero')
# MATH-AR-48 verifies: SPEC-CAP-004
prove('MATH-AR-48a', 'charge(U0) = C0 and charge(0) = 0', [C0 >= 1, U0 >= 1, Int('zero_u') == 0] + h5 + h6,
      And(c_full == C0, c_zero == 0))
prove('MATH-AR-48b', 'release = charge(u_b) - charge(u_a) is >= 0 and <= ceil(C0 x / U0) (never more than the exited units carried)',
      b48, And(cb - ca >= 0, cb - ca <= cx))
prove('MATH-AR-48c', 'two exits release exactly charge(u_b) - charge(u_b - x1 - x2): splitting never changes the total',
      b48, (cb - ca) + (ca - cc) == cb - cc)
rel, R2, S2 = Ints('release R2 S2')
fs = mn(rel, S)
prove('MATH-AR-48d', 'slice first: S -= min(release, S), R -= release - that; with release <= R + S, R + S falls by exactly release',
      [rel >= 0, R >= 0, S >= 0, rel <= R + S, S2 == S - fs, R2 == R - (rel - fs)],
      And(S2 >= 0, R2 >= 0, R2 + S2 == R + S - rel))
C0e, U0e = 9_999_500_000_000, 5 * 10**10
rel_e = C0e - cdiv(C0e * 4 * 10**10, U0e)
computed('MATH-AR-48e', 'SPEC-CAP-004 example (U0 5e10, C0 9,999,500,000,000, exit 1e10, S $5,000)',
         [('charge(4e10)', 7_999_600_000_000, cdiv(C0e * 4 * 10**10, U0e)), ('release $19,999', 1_999_900_000_000, rel_e),
          ('S after', 0, 500_000_000_000 - min(rel_e, 500_000_000_000)),
          ('R lowered by $14,999', 1_499_900_000_000, rel_e - min(rel_e, 500_000_000_000))])

# ---------------------------------------------------------------------------
# MATH-AR-49  SPEC-CAP-005 pool-share cap.
sup, Lp, mbps, lhm = Ints('supply L maxBps liqHM')
lex = Real('liqExact')
b49 = [sup >= 0, Lp > 0, mbps > 0, mbps <= BPS, lhm >= 0, lex >= ToReal(lhm), lex < ToReal(lhm) + 1]
# MATH-AR-49 verifies: SPEC-CAP-005, REQ-RISK-023
prove('MATH-AR-49a', 'passes with the floored liqHM  =>  passes with the exact time-weighted liquidity (floor only tightens)',
      b49 + [(sup + Lp) * BPS <= mbps * lhm], ToReal((sup + Lp) * BPS) <= ToReal(mbps) * lex)
prove('MATH-AR-49b', 'left side < 2^134 and right side < 2^142 (supply + L < 2^120, liqHM < 2^128)',
      b49 + [sup + Lp < 2**120, lhm < 2**128], And((sup + Lp) * BPS < 2**134, mbps * lhm < 2**142))
computed('MATH-AR-49c', 'SPEC-CAP-005 example (1,000 bps, liqHM 2e13, supply 1.5e12)',
         [('L 4e11 passes (1.9e16 <= 2e16)', True, (15 * 10**11 + 4 * 10**11) * BPS <= 1000 * 2 * 10**13),
          ('L 6e11 fails (2.1e16)', False, (15 * 10**11 + 6 * 10**11) * BPS <= 1000 * 2 * 10**13)])

# ---------------------------------------------------------------------------
# MATH-AR-50  SPEC-CAP-006 / SPEC-HUB-002: credited units stay within addCap x 10^d.
u1, u2, u3, U1, U2, U3, C1, C2, C3, ad = Ints('u1 u2 u3 U1 U2 U3 C1 C2 C3 addCap')
recs, rh = [], []
for j, (uu, UU, CC) in enumerate(((u1, U1, C1), (u2, U2, C2), (u3, U3, C3))):
    q, hq = ceil_div(CC * uu, UU, f'rem{j}')
    recs.append(q)
    rh += hq + [UU >= 1, uu >= 0, uu <= UU, CC * dp >= UU * fl]       # C0 booked at >= floor
b50 = [fl > 0, Or(*[dp == 10**d for d in range(6, 19)])] + rh
# MATH-AR-50 verifies: SPEC-CAP-006, SPEC-HUB-002
prove('MATH-AR-50a', 'remaining charge of every record >= u x floor / 10^d', b50, recs[0] * dp >= u1 * fl)
prove('MATH-AR-50b', 'three records, sum of remaining charges <= K + Z, addCap >= ceil((K+Z)/floor)  =>  sum u <= addCap x 10^d',
      b50 + [K >= 0, Z >= 0, recs[0] + recs[1] + recs[2] <= K + Z, ad * fl >= K + Z],
      u1 + u2 + u3 <= ad * dp)
Rc, Sc, Lt, cht, creg, csl = Ints('Rcur Scur Ltop chargeTop chargeRegular chargeSlice')
mxK = If(K >= Rc, K, Rc)
mxZ = If(Z >= Sc, Z, Sc)
prove('MATH-AR-50c', 'SPEC-CAP-006: with addCap >= ceilDiv(max(K, R) + max(Z, S), floor), every pledge or top-up within the '
      'Avana budget fits under addCap, also after a cap tightening (R > K or S > Z allowed)',
      [fl == 10**8, dp == 10**6, K > 0, Z >= 0, Rc >= 0, Sc >= 0,             # counters may exceed tightened caps
       ad * fl >= mxK + mxZ, ad * fl < mxK + mxZ + fl,                       # addCap at the rule's minimum
       Lt > 0, cht * dp >= Lt * fl, cht == creg + csl, creg >= 0, csl >= 0,  # charge booked at >= floor
       Rc + creg <= mxK, creg <= If(K > Rc, K - Rc, 0), Sc + csl <= Z,      # regular room, then the slice
       u1 * fl <= (Rc + Sc) * dp, u1 >= 0],                                  # credited units booked so far
      u1 + Lt <= ad * dp)   # F-AR-5 resolved in the spec text
computed('MATH-AR-50d', 'SPEC-HUB-002 / SPEC-CAP-006 examples',
         [('addCap $5,000,000 + $500,000 at $1.00', 5_500_000, cdiv(5_500_000 * 10**8, 10**8)),
          ('addCap at a $1.30 floor', 4_230_770, cdiv(5_500_000 * 10**8, 130_000_000)),
          ('addCap $1,000,000 + $100,000 at $1.00', 1_100_000, cdiv(110_000_000_000_000, 10**8)),
          ('after K lowered to $500,000 with R $900,000: ceil((900,000 + 100,000) / 1.00)', 1_000_000,
           cdiv((max(500_000, 900_000) + max(100_000, 0)) * 10**8, 10**8)),
          ('a $10,000 rescue top-up needs 910,000 tokens of Hub room', 910_000, (900_000 + 10_000) * 10**8 // 10**8),
          ('910,000 > 600,000 (addCap sized on the new caps rejects it)', True, 910_000 > cdiv((500_000 + 100_000) * 10**8, 10**8)),
          ('(2^40 - 1) x 1e18 < 2^120', True, (2**40 - 1) * 10**18 < 2**120)])

# ---------------------------------------------------------------------------
# MATH-AR-51  SPEC-HUB-003 credit-line caps.
dcap1, dcap2, cl, o1, o2, amt, dec = Ints('drawCap1 drawCap2 creditLine owed1 owed2 amount decPow')
b51 = [dcap1 >= 0, dcap2 >= 0, dcap1 + dcap2 <= cl, o1 >= 0, o2 >= 0, amt > 0, Or(dec == 10**6, dec == 10**18),
       o1 <= dcap1 * dec, o2 <= dcap2 * dec]
# MATH-AR-51 verifies: SPEC-HUB-003
prove('MATH-AR-51a', 'a draw admitted by drawCap x 10^dec >= owed + amount keeps both Spokes within the credit line',
      b51 + [dcap1 * dec >= o1 + amt], o1 + amt + o2 <= cl * dec)
computed('MATH-AR-51b', 'SPEC-HUB-003 example (creditLineGho 2,000,000)',
         [('owed + 100,000 GHO borrow', 2_003_475, 1_900_000 + 3_000 + 475 + 100_000),
          ('reverts DrawCapExceeded', True, 1_900_000 + 3_000 + 475 + 100_000 > 2_000_000),
          ('largest borrow that passes', 96_525, 2_000_000 - (1_900_000 + 3_000 + 475))])

# ---------------------------------------------------------------------------
# MATH-AR-52  SPEC-CAP-008 tail coverage ratio never overstates coverage.
num, den, fund, tail, ratio = Ints('num den funded tail ratio')
b52 = [num > 0, den > 0, fund >= 0, tail * den >= num, tail * den < num + den,
       ratio * tail <= fund * BPS, fund * BPS < (ratio + 1) * tail]
# MATH-AR-52 verifies: SPEC-CAP-008
prove('MATH-AR-52a', 'tail rounds up and the ratio down  =>  ratio x exact tail <= funded x 1e4 (never overstates)',
      b52, ratio * num <= fund * BPS * den)
tail_e = cdiv(1_800_000 * 10**8 * 3120, BPS)
computed('MATH-AR-52b', 'SPEC-CAP-008 example (tokenUsdCap $1,600,000 + $200,000 slices, CF 3,120)',
         [('tail in 8 decimals', 56_160_000_000_000, tail_e),
          ('tail below the $2,000,000 draw-cap total', True, tail_e < 2_000_000 * 10**8),
          ('tailCoverageBps with 400,000 GHO funded', 7_122, 400_000 * 10**8 * BPS // tail_e)])

finish()
