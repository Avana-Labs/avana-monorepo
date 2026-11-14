"""FV-LIQ-01: SettlementMath (2.11 SPEC-LIQ-001..022) and the caller's rounding-gap top-up that replaced the
settlement budget (2.13 SPEC-SET-001, 002; Q-397).

Encoding. Every rounding is kept as the two inequalities that define it. Claims that
need only those inequalities are decided over the reals with nlsat (`real=True`,
complete for nonlinear real arithmetic, so the result covers every integer input too).
Where a claim needs integrality (a floor is unique, a ceiling of a positive value is
at least 1) the real step proves `x < y + 1` and the comment states the integer step
`x <= y`. Waterfall claims are linear integer arithmetic. Concrete counterexamples of
findings are replayed with exact integers in fv_liq_06_examples.py.

Every settlement amount is in base units of the debt asset T of the repaid reserve: the caller
funds T itself (Kf, with D <= Kf; LPVaultSwap takes no flash loan in a liquidation, Q-404), every
leg swaps into T, and the fee, the keeper reward and the borrower surplus are paid in T. A flash
liquidation helper's premium appears only in the premium-bound checks (SPEC-LIQ-015, -016). There is no buy leg and no sell-back, so
the covered cost of the debt is the debt repaid D.

Ranges (report.md, General Assumptions): b in [1e4, 2^32), lf in [0, 1e4], costsBps in
[0, 1e4], maxFlashFeeBps in [0, 100], slippageAllowanceBps in [0, 1e4], amounts below 2^128
base units, prices positive, decimals 6..18.
"""
import z3

from _lib import BPS, check, expect_violation, finish, prove, z_max, z_min

R_ = z3.Reals
I_ = z3.Ints

# The per-leg block runs first: its nonlinear-real proofs are decided fastest in a fresh solver context.
# ---------------------------------------------------------------- per-leg minimum output (SPEC-LIQ-018)
# Two legs (n = 2), exact integers: Vleg_i = floor(e_i) of the leg's exact oracle value e_i, u_i one raw unit of the
# leg in the debt asset (ceil, >= 1), U = u_0 + u_1, V = floor(W) of the seizure's exact value W. "The pool trades at the
# oracle-implied price" means Sum e_i <= W + U (one raw unit per leg of unwind truncation), hence Vleg_0 + Vleg_1 <= V + U.
v0, v1, u0, u1, mo0, mo1, cs0, cs1, sl, fq0, frI = I_("Vleg0 Vleg1 Uleg0 Uleg1 minOut0 minOut1 slipTerm0 slipTerm1 "
                                                     "sLeg fraOverN fraI")
legs = [v0 >= 0, v1 >= 0, u0 >= 1, u1 >= 1, sl >= 0, sl < BPS, frI >= 0, fq0 * 2 <= frI, (fq0 + 1) * 2 > frI,
        cs0 * BPS >= v0 * (BPS - sl), (cs0 - 1) * BPS < v0 * (BPS - sl),
        cs1 * BPS >= v1 * (BPS - sl), (cs1 - 1) * BPS < v1 * (BPS - sl),
        mo0 == z_max(1, cs0 - u0 - fq0), mo1 == z_max(1, cs1 - u1 - fq0)]
Vf, sg, mgf = I_("Vfloor slipTermV minRecV")
agg = [Vf >= 0, sg * BPS >= Vf * (BPS - sl), (sg - 1) * BPS < Vf * (BPS - sl),
       mgf == z_max(0, sg - (u0 + u1) - frI), v0 + v1 <= Vf + u0 + u1]
# FV-LIQ-01 verifies: SPEC-LIQ-018, REQ-SWAP-100, REQ-SWAP-022, INV-083
prove("FV-LIQ-01af", "SPEC-LIQ-018: every leg minimum is >= 1 and at most max(1, Vleg_i): no leg is ever asked for more "
      "than its oracle value, and no leg runs with a zero minimum", legs,
      z3.And(mo0 >= 1, mo1 >= 1, mo0 <= z_max(1, v0), mo1 <= z_max(1, v1)))
# The aggregate claims are decided over the reals (nlsat), with the integer facts the floors give stated as axioms
# (2 x floor(fra / 2) >= fra - 1) and the integer step stated in the title (x < y + 1 implies x <= y).
# rLp = ceil(2 c 1e10 / 10^d): V comes from the 8-decimal LP price, up to 2 units of 1e-8 USD per whole vault token
# below the exact value (HYP-85), so Sum Vleg_i <= V + U + rLp at the oracle-implied pool price.
rv0, rv1, ru0, ru1, rm0, rm1, rc0, rc1, rsl, rfq, rfr, rVf, rsg, rmg, rLp = R_(
    "rVleg0 rVleg1 rUleg0 rUleg1 rMinOut0 rMinOut1 rSlip0 rSlip1 rsLeg rFraOverN rFra rV rSlipV rMinRec rLpRound")
rlegs = [rv0 >= 0, rv1 >= 0, ru0 >= 1, ru1 >= 1, rsl >= 0, rsl < BPS, rfr >= 0, rfq * 2 <= rfr, rfq * 2 >= rfr - 1,
         rfq >= 0, rc0 * BPS >= rv0 * (BPS - rsl), (rc0 - 1) * BPS < rv0 * (BPS - rsl),
         rc1 * BPS >= rv1 * (BPS - rsl), (rc1 - 1) * BPS < rv1 * (BPS - rsl),
         rm0 == z_max(1, rc0 - ru0 - rfq), rm1 == z_max(1, rc1 - ru1 - rfq),
         rVf >= 0, rsg * BPS >= rVf * (BPS - rsl), (rsg - 1) * BPS < rVf * (BPS - rsl),
         rmg == z_max(0, rsg - (ru0 + ru1) - rfr), rLp >= 0, rv0 + rv1 <= rVf + ru0 + ru1 + rLp]
prove("FV-LIQ-01ag", "SPEC-LIQ-018 / INV-083 (final): when the pool trades at the oracle-implied price and neither leg "
      "minimum is clamped at 1, Sum minOut_i < minRec + n + U + ceil(2 c 1e10 / 10^d) + 1 (integer: <= minRec + n + U + "
      "the LP-price term), so the leg minimums add only rounding to the floor",
      rlegs + [rc0 - ru0 - rfq >= 1, rc1 - ru1 - rfq >= 1],
      rm0 + rm1 < rmg + 2 + ru0 + ru1 + rLp + 1, real=True)
expect_violation("FV-LIQ-01ag2", "mutation (the SPEC-LIQ-018 text before FV-LIQ-F-12): Sum minOut_i <= minRec + n + U whenever the "
                 "pool trades at the oracle-implied price; when one leg is worth less than its unit plus half the "
                 "allowance, its minimum is clamped at 1 while the other leg keeps only half of floorRoundingAllowance, "
                 "so the leg minimums exceed the floor by up to floorRoundingAllowance / 2",
                 legs + agg + [frI == 10**18, u0 == 10**12, u1 == 10**12, sl == 100], mo0 + mo1 <= mgf + 2 + u0 + u1,
                 show=[v0, v1, sl, mo0, mo1, mgf], label="mutant")
prove("FV-LIQ-01ag3", "SPEC-LIQ-018 / INV-083 (final): in every case Sum minOut_i < minRec + n + 2U + "
      "floor(floorRoundingAllowance / n) + ceil(2 c 1e10 / 10^d) + 1 (integer: <= minRec + n + 2U + floor(fra / n) + "
      "the LP-price term)",
      rlegs, rm0 + rm1 < rmg + 2 + 2 * (ru0 + ru1) + rfq + rLp + 1, real=True)


# ---------------------------------------------------------------- SPEC-LIQ-001 net bonus
b, lf, q = R_("b lf q")
rng_b = [b >= BPS, b < 2**32, lf >= 0, lf <= BPS]
p = (b - BPS) * (BPS - lf)
bnet_def = [q * BPS <= p, (q + 1) * BPS > p]
# FV-LIQ-01 verifies: SPEC-LIQ-001, REQ-SWAP-016, Q-222
prove("FV-LIQ-01a", "SPEC-LIQ-001: q = floor((b-1e4)(1e4-lf)/1e4) satisfies q > -1 (so q >= 0 and bNet >= 1e4), "
      "q <= b - 1e4 (bNet <= b), and lf = 0 gives b-1e4-1 < q <= b-1e4 (so bNet = b)",
      rng_b + bnet_def, z3.And(q > -1, q <= b - BPS, z3.Implies(lf == 0, q > b - BPS - 1)), real=True)

# ---------------------------------------------------------------- SPEC-LIQ-003 / 016 effective slippage (T-35)
bnet, costs, allow, r16, s = R_("bNet costsBps slippageAllowanceBps r16 s")
rng_s = [bnet >= BPS, bnet < 2**32, costs >= 0, costs <= BPS, allow >= 0, allow <= BPS]
prod = BPS * (BPS + costs)
s_def = [r16 * (bnet * BPS) <= BPS * (bnet * BPS - prod), (r16 + 1) * (bnet * BPS) > BPS * (bnet * BPS - prod),
         s == z3.If(bnet * BPS > prod, z3.If(allow <= r16, allow, r16), 0)]
rng_s0 = rng_s + [costs == 0]                     # a liquidation has no premium term (SPEC-LIQ-002, Q-404)
# FV-LIQ-01 verifies: SPEC-LIQ-003, SPEC-LIQ-002, SPEC-LIQ-016, INV-034
# Integrality of the floor: r16 > -1 implies r16 >= 0 (r16 is an integer).
prove("FV-LIQ-01b", "T-35: if bNet > 1e4 then 0 <= s <= allowance and bNet(1e4-s) >= 1e8 "
      "(the slippage term alone repays the debt; no premium and no buy-leg term exist)",
      rng_s0 + s_def + [bnet * BPS > prod, z3.Implies(r16 > -1, r16 >= 0)],
      z3.And(s >= 0, s <= allow, bnet * (BPS - s) * BPS >= BPS * prod), real=True)

# SPEC-LIQ-003 written as floor(1e4 (bNet - 1e4 - costs) / bNet) equals the multiplicative floor used in 01b.
bi, ci, r16i, r03i = I_("bNetI costsI r16I r03I")
num = BPS * (bi - BPS - ci)
prove("FV-LIQ-01c", "SPEC-LIQ-003: floor(1e4(bNet - 1e4 - costs)/bNet) equals floor(1e4(bNet 1e4 - 1e4(1e4 + costs))/(bNet 1e4)) "
      "(the two floors coincide)",
      [bi >= BPS, ci >= 0, bi > BPS + ci,
       r16i * (bi * BPS) <= BPS * (bi * BPS - BPS * (BPS + ci)), (r16i + 1) * (bi * BPS) > BPS * (bi * BPS - BPS * (BPS + ci)),
       r03i * bi <= num, (r03i + 1) * bi > num], r16i == r03i)

# One-leg liveness (SPEC-LIQ-016, REQ-PSTORE-021): the listing keeps minLB x (1e4 - slipMin) >= 1e4 x (1e4 + maxFlashFeeBps)
# for every market of the Spoke, and the market's slippageAllowanceBps stays >= slipMin; Aave's bonus at HF just below 1 is
# minLB (lf = 0 on the standard Spoke's Avana reserves, so bNet = b >= minLB).
minLB, slipMin, maxFee = R_("minLB slippageAllowanceMinBps maxFlashFeeBps")
live = [minLB >= BPS, slipMin >= 0, slipMin <= allow, maxFee >= 0, costs <= maxFee, bnet >= minLB,
        minLB * (BPS - slipMin) >= BPS * (BPS + maxFee),
        z3.Implies(r16 > -1, r16 >= 0)]
# FV-LIQ-01 verifies: SPEC-LIQ-016, REQ-PSTORE-021, REQ-CONFIG-052, REQ-MREG-032, REQ-SWAP-029
# Integrality of the floor: r16 > slipMin - 1 implies r16 >= slipMin (both integers).
prove("FV-LIQ-01d", "One-leg liveness: when the listing check minLB(1e4 - slipMin) >= 1e4(1e4 + maxFlashFeeBps) holds and "
      "the bonus is at least minLB, s >= slippageAllowanceMinBps and bNet(1e4-s) >= 1e8 at every bonus Aave can pay (no "
      "premium term); with slippageAllowanceMinBps >= 1 the call is never in the s = 0 branch",
      rng_s0 + s_def + live + [z3.Implies(r16 > slipMin - 1, r16 >= slipMin)],
      z3.And(s >= slipMin, bnet * (BPS - s) * BPS >= BPS * prod, z3.Implies(slipMin >= 1, bnet * BPS > prod)),
      real=True)
expect_violation("FV-LIQ-01dm", "mutation (no listing check, a premium counted as a cost as before Q-404): a bonus below "
                 "1e4 + costs reaches s = 0 with the slippage term below the debt plus that premium; FV-LIQ-01d catches it",
                 rng_s + s_def + [costs <= 10],
                 bnet * (BPS - s) * BPS >= BPS * prod, show=[bnet, costs, s], real=True, label="mutant")

# ---------------------------------------------------------------- SPEC-LIQ-015 premium rate (deleverage, helper)
phi, F, mf, cb = R_("phi F maxFlashFeeBps rateBps")
# FV-LIQ-01 verifies: SPEC-LIQ-015, REQ-HELPER-005
prove("FV-LIQ-01e", "SPEC-LIQ-015: a premium that passes phi*1e4 <= maxFlashFeeBps*F has rate ceil(phi*1e4/F) with "
      "rate*F >= phi*1e4 and rate < maxFlashFeeBps + 1 (integer: rate <= maxFlashFeeBps); deleverage and the helper only",
      [F > 0, phi >= 0, mf >= 0, mf <= BPS, phi * BPS <= mf * F, cb * F >= phi * BPS, (cb - 1) * F < phi * BPS],
      z3.And(cb < mf + 1, cb * F >= phi * BPS), real=True)

# ---------------------------------------------------------------- V, U, minRec (T-34)
c, Pc, Pg, Uv, V, U, fra, slip, minG, sl = R_("c Pc Pdebt tenPowDv V U fra slipTerm minRec s_")
vdef = [c >= 0, Pc > 0, Pg > 0, Uv >= 10**6, Uv <= 10**18,
        V * (Uv * Pg) <= c * Pc * 10**18, (V + 1) * (Uv * Pg) > c * Pc * 10**18]
floor_def = vdef + [z3.Implies(V > -1, V >= 0),  # integrality of the floor V
                    sl >= 0, sl < BPS, U >= 1, fra >= 0,
                    slip * BPS >= V * (BPS - sl), (slip - 1) * BPS < V * (BPS - sl),
                    minG == z3.If(slip - U - fra > 0, slip - U - fra, 0)]
# FV-LIQ-01 verifies: SPEC-LIQ-004, SPEC-LIQ-005, INV-034, REQ-SWAP-025, REQ-SWAP-060
prove("FV-LIQ-01f", "T-34: V rounds down (V <= exact oracle value of c) and minRec <= V(1-s) <= exact value x (1-s): "
      "the floor never asks for more than the seizure is worth after the allowed slippage",
      floor_def, z3.And(V * (Uv * Pg) <= c * Pc * 10**18, minG * BPS <= V * (BPS - sl),
                        minG * BPS * (Uv * Pg) <= c * Pc * 10**18 * (BPS - sl)), real=True)
pi_, Ui, ui = R_("legPrice tenPowDi legUnitValue")
prove("FV-LIQ-01g", "SPEC-LIQ-005: each leg term ceil(p*10^dd/(10^d*Pdebt)) is > 0 (integer: >= 1, so U >= 1) and covers "
      "the exact debt-asset value of one raw unit of the leg",
      [pi_ > 0, Pg > 0, Ui >= 10**6, Ui <= 10**18, ui * (Ui * Pg) >= pi_ * 10**18, (ui - 1) * (Ui * Pg) < pi_ * 10**18],
      z3.And(ui > 0, ui * Ui * Pg >= pi_ * 10**18), real=True)

# ---------------------------------------------------------------- caller funding (REQ-SWAP-011, -016, -088), no buy leg
Kf, Ff, Xf, Df, phf, qf, mff, avl, slm = R_("Kf Ff Xf Df phiF quoteF maxFlashFeeF availableF slipMinF")
flash_ok = [Kf > 0, Xf > 0, Kf <= Xf, Df >= 0, Df <= Kf, Ff >= 0, phf >= 0, qf >= 0, mff >= 0, slm >= mff,
            slm <= BPS, Ff <= avl, qf * BPS <= mff * Ff, phf * BPS <= mff * Ff]
# FV-LIQ-01 verifies: SPEC-LIQ-015, REQ-SWAP-011, REQ-SWAP-016, REQ-SWAP-088, REQ-SWAP-098, REQ-HELPER-005
prove("FV-LIQ-01h", "REQ-SWAP-011/016/088: the repayment is funded by the caller in the debt asset itself (0 < Kf <= X, "
      "D <= Kf, no buy leg), so the leftover Kf - D is >= 0 and already in the debt asset; a helper's loan is at most the "
      "Pool's idle liquidity and its quoted and charged premiums are at most maxFlashFeeBps (<= slippageAllowanceMinBps) of F",
      flash_ok,
      z3.And(Kf - Df >= 0, Ff <= avl, phf * BPS <= slm * Ff, qf * BPS <= slm * Ff), real=True)

# ---------------------------------------------------------------- covered cost and the waterfall (linear integer)
G, gp, Gnet, Gcov, bD, K, Fm, R, phiI, phiD, S, A, kout, Dd, Xi, mrw = I_(
    "G gSellBack Gnet Gcov boundD K F R phi phiD S A keeperOut D X_ minRecW")
sh, Rp, Aor, s0 = z3.Int("shortfall"), z3.Int("Rprime"), z3.Int("feeOnOracleValue"), z3.Bool("sIsZero")
Vo, Go, kr, Bb = I_("Voracle Goracle keeperReward borrowerSurplus")
# The debt asset is borrowed directly: the covered cost is the debt repaid (Gcov = Gnet = D, no sell-back g' = 0).
gcov_def = [Dd >= 0, G == Dd, gp == 0, Gnet == Dd, Gcov == Dd, bD == Dd]
# FV-LIQ-01 verifies: SPEC-LIQ-017, REQ-SWAP-088, REQ-SWAP-089
prove("FV-LIQ-01i", "SPEC-LIQ-017 / REQ-SWAP-088: no buy leg and no sell-back: the covered cost of the debt is the debt "
      "repaid itself (Gcov = Gnet = D, g' = 0)",
      gcov_def, z3.And(Gcov == Dd, Gnet == Dd, gp == 0))

share = z3.Int("avanaFeeShareBps")
# FV-LIQ-01 verifies: SPEC-LIQ-008, SPEC-LIQ-009, INV-036, INV-086
prove("FV-LIQ-01k", "T-36: A = min(feeOnOracleValue, S) with feeOnOracleValue = floor(max(0, V - D - phiD) x share / 1e4) "
      "satisfies 0 <= A <= S for every share in [0, 1e4]",
      [S >= 0, share >= 0, share <= BPS, Aor >= 0, A == z_min(Aor, S)], z3.And(A >= 0, A <= S))
# The waterfall of 2.11 (Q-404) in the debt asset. There is no settlement budget (Q-397) and no flash term: the caller
# funds Kf >= D; S = max(0, R_f - D) with R_f = max(R, minRec); G = max(0, V - D); A = min(floor(G x share / 1e4), S);
# kr = min(S, G) - A; B = S - A - kr; gap = max(0, D + A + B - Kf - R); shortfall = max(0, minRec - R, gap);
# R' = R + shortfall; keeperOut = (Kf + R') - (D + A + B), a checked subtraction (defensive).
Rfw = z_max(R, mrw)
split = [Vo >= 0, Go == z_max(0, Vo - Dd - phiD), S == z_max(0, Rfw - Dd - phiD),
         Aor >= 0, Aor <= Go,                              # floor(G x share / 1e4) for share <= 1e4 (FV-LIQ-01al)
         A == z_min(Aor, S), kr == z_min(S, Go) - A, Bb == S - A - kr]
gap_term = Dd + A + Bb - K - R
wf = [K >= Dd, Fm == 0, R >= 0, mrw >= 0, sh == z_max(z_max(0, mrw - R), gap_term), Rp == R + sh,
      phiI == 0, phiD == 0] + gcov_def + split + [
    kout == (K + Fm + Rp) - (Dd + Fm + phiI + A + Bb)]
gap_binds = z3.And(gap_term > 0, gap_term > mrw - R)
# FV-LIQ-01 verifies: SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022, INV-035, REQ-SWAP-062, REQ-SWAP-026, REQ-SWAP-101
prove("FV-LIQ-01j", "T-30: the debt asset balances exactly, Kf + R + shortfall = D + A + B + keeperOut, keeperOut >= 0, "
      "and the leftover Kf - D >= 0 stays in the same asset (Q-404: no flash term)",
      wf + [Xi >= K],
      z3.And(K + R + sh == Dd + A + Bb + kout, kout >= 0, K - Dd >= 0))
prove("FV-LIQ-01l", "T-36: A <= max(0, R' - D); A = 0 whenever R' <= D; the gap never binds beyond the floor gap "
      "(Kf >= D), so the top-up is max(0, minRec - R)",
      wf, z3.And(A <= z_max(0, Rp - Dd), z3.Implies(Rp <= Dd, A == 0), z3.Not(gap_binds), sh == z_max(0, mrw - R)))
prove("FV-LIQ-01m", "T-30 no-revert: once Aave's pull passes and the floor gap is within maxShortfall, InsufficientProceeds "
      "cannot fire: keeperOut >= 0 for every recovery",
      wf, kout >= 0)
prove("FV-LIQ-01n", "SPEC-LIQ-010/017: keeperOut = Kf + kr when R' >= D and Kf - (D - R') when R' < D: a recovery below "
      "the debt is the caller's loss, never Avana's or the borrower's",
      wf, z3.And(z3.Implies(Rp >= Dd, kout == K + kr), z3.Implies(Rp < Dd, z3.And(kout == K - (Dd - Rp), A == 0,
                                                                                Bb == 0))))
# FV-LIQ-01 verifies: SPEC-SET-001, SPEC-LIQ-016, SPEC-LIQ-019, REQ-SWAP-029
prove("FV-LIQ-01t", "s = 0 branch, and every branch: a completed call has Kf + R' >= D + A + B, from the caller's own "
      "funding and top-up (Q-397: no settlement budget exists)",
      wf + [s0], K + Rp >= Dd + A + Bb)

# F-03 (closed by Q-404): no premium enters LPVaultSwap's formulas; a helper's premium on a loan of any size is the
# helper's, paid from keeperOut after liquidate returns.
mFG, hpay, htop = z3.Int("minFD"), z3.Int("helperPayout"), z3.Int("helperTopUp")
fee_fix = [Fm >= 0, phiI >= 0, htop == z_max(0, Fm + phiI - kout), hpay == kout + htop - Fm - phiI]
wf_h = [K >= Dd, R >= 0, mrw >= 0, sh == z_max(z_max(0, mrw - R), gap_term), Rp == R + sh, phiD == 0] + gcov_def \
    + split + [kout == (K + Rp) - (Dd + A + Bb)]
# FV-LIQ-01 verifies: SPEC-LIQ-007, SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-029, REQ-HELPER-007, REQ-HELPER-008
prove("FV-LIQ-01o", "F-03 closed: with a helper loan F = Kf and premium phi of any size, LPVaultSwap's keeperOut, A and B "
      "do not contain them, and the helper's net payout is max(0, keeperOut - F - phi) >= 0 after its top-up",
      wf_h + fee_fix + [K == Fm], z3.And(hpay == z_max(0, kout - Fm - phiI), hpay >= 0, kout == (K + Rp) - (Dd + A + Bb)))
kout_m = z3.Int("keeperOutMutant")
expect_violation("FV-LIQ-01om", "mutation (a premium charged inside LPVaultSwap while the loan is not counted in Kf, the "
                 "split of the design before Q-404 without its flash principal): keeperOut can fall below 0 at a recovery "
                 "at the debt; FV-LIQ-01m shows caller funding rules it out",
                 wf_h + [phiI > 0, kout_m == (K + Rp) - (Dd + phiI + A + Bb)], kout_m >= 0,
                 show=[K, Dd, R, phiI, kout_m], label="mutant")
m, f_, ph, phd = R_("minFDR feeBps phiR phiDR")
# FV-LIQ-01 verifies: SPEC-LIQ-015, REQ-HELPER-009
prove("FV-LIQ-01p", "SPEC-LIQ-015 / REQ-HELPER-009: the premium is non-decreasing in the loan: a smaller loan's premium is "
      "< the larger loan's + 1 (integer: <=), for every premium rate, since percentMul rounds half up monotonically",
      [m >= 0, Fm >= 0, m <= Fm, f_ >= 0, f_ <= BPS, ph * BPS <= Fm * f_ + 5000, (ph + 1) * BPS > Fm * f_ + 5000,
       phd * BPS <= m * f_ + 5000, (phd + 1) * BPS > m * f_ + 5000], phd < ph + 1, real=True)
prove("FV-LIQ-01p2", "SPEC-LIQ-019 / SPEC-SET-001: the gap max(0, D + A + B - Kf - R) never exceeds the floor gap, so "
      "InsufficientProceeds on the gap is defensive",
      wf, gap_term <= z_max(0, mrw - R))

# FV-LIQ-01 verifies: REQ-SWAP-072, REQ-SWAP-073, INV-062
prove("FV-LIQ-01q", "T-45 (Q-404): every caller of liquidate, the one entry point, applies the same top-up rule; a completed "
      "call balances exactly and pays keeperOut >= 0",
      wf, z3.And(kout >= 0, K + R + sh == Dd + A + Bb + kout))

# ---------------------------------------------------------------- rounding-gap bound (T-39) in value space
# The gap term D + phiD - K - R that the caller tops up when R >= minRec is the former draw expression; its bound shows a
# keeper that sets maxShortfall to 2 x floorRoundingAllowance always covers it.
uv, ud, cl, Dl, Vl, Rr, Gc, Kl, Ul, fral, sr, LBl, cbr, eps, Bdl, slipl, minl, bndl = R_(
    "unitValueVault unitValueDebt c_ D_ V_ R_ DplusPhiD_ K_ U_ fra_ s_r LB costsBps_ eps gap_ slip_ minRec_ boundDphi_")
value = [uv > 0, ud > 0, cl >= 0, Dl >= 0, Kl >= 0, Ul >= 1, fral >= 0, sr >= 0, sr < BPS, LBl >= BPS,
         cbr >= 0, cbr <= 100, eps >= 0,                    # cbr: flash premium rate (costsBps)
         cl * uv * BPS <= Dl * ud * LBl,                  # FV-LIQ-02a..d (no over-seizure)
         (cl + 1) * uv * BPS > (Dl - eps) * ud * LBl,      # FV-LIQ-02f..i, eps = Aave's debt rounding in debt units
         Vl <= cl * uv, Vl > cl * uv - 1,
         slipl * BPS >= Vl * (BPS - sr), minl == z3.If(slipl - Ul - fral > 0, slipl - Ul - fral, 0),
         Rr >= minl, Rr >= 0,
         bndl * BPS < Dl * ud * (BPS + cbr) + BPS, Gc <= bndl, Gc >= 0,   # D (+ a premium) <= D (1 + costs) + 1 unit
         Bdl == z3.If(Gc - Rr > 0, Gc - Rr, 0)]                           # the caller's loss below the debt (Q-404)
two_leg = [LBl * (BPS - sr) >= BPS * (BPS + cbr)]
idxu = z3.Real("ceilDrawnIndexOverRay")
# FV-LIQ-01 verifies: SPEC-SET-001, SPEC-SET-002, SPEC-LIQ-019, INV-038
prove("FV-LIQ-01r", "T-39 loss bound: with the one-leg inequality and no premium term, the loss a recovery at the floor "
      "leaves the caller is < one vault unit + 2 units + U + fra + eps debt units (eps < 2 on the target path, "
      "< 2 + index/RAY on the all-collateral path, FV-LIQ-02f..i)",
      value + two_leg + [cbr == 0], Bdl < uv + 2 + Ul + fral + eps * ud * (BPS + cbr) / BPS, real=True)
prove("FV-LIQ-01s", "F-02 fixed: every honest loss is within the bound INV-038 states, one vault unit + 2 units + U + "
      "floorRoundingAllowance + (2 + ceil(drawnIndex/RAY)) debt units valued at Pdebt",
      value + two_leg + [cbr == 0, idxu >= 1, eps <= 2 + idxu],
      Bdl <= uv + 2 + Ul + fral + (2 + idxu) * ud * (BPS + cbr) / BPS, real=True)
# FV-LIQ-01 verifies: SPEC-SET-002, SPEC-LIQ-019, REQ-SWAP-101
prove("FV-LIQ-01s2", "Q-397 sizing: a helper's caller that sets its top-up bound >= 2 x floorRoundingAllowance plus the "
      "premium covers every honest loss whenever the vault-unit, leg-unit and debt-rounding terms together are at most "
      "the allowance (worth $1 at launch: 1 USDC, 1 GHO)",
      value + two_leg + [cbr == 0, idxu >= 1, eps <= 2 + idxu,
                         uv + 2 + Ul + (2 + idxu) * ud * (BPS + cbr) / BPS <= fral],
      Bdl <= 2 * fral, real=True)
expect_violation("FV-LIQ-01sm", "mutation (the text before Q-267): the bound 'one vault unit + 1 unit + U + fra' is "
                 "exceeded by Aave's debt rounding (eps <= 2) and the bound's ceiling; FV-LIQ-01s catches it",
                 value + two_leg + [cbr == 0, eps <= 2], Bdl <= uv + 1 + Ul + fral, show=[eps, ud, cbr, Bdl, uv, Ul, fral],
                 real=True, label="mutant")
expect_violation("FV-LIQ-01tm", "s = 0 (bonus 10,000 after an Aave configuration change) with a 10 bps helper premium "
                 "counted against the recovery: the shortfall to D + premium is not a rounding rest and exceeds the bound "
                 "by more than 1,000 debt-asset units for a large enough D; under Q-404 the premium is the helper's, paid "
                 "from keeperOut and its caller's top-up (REQ-HELPER-007)",
                 value + [sr == 0, LBl == 10_000, cbr == 10, eps <= 2, Ul <= 10**13, fral == 10**18, uv <= 10**18,
                          ud == 10**12],
                 Bdl <= uv + 2 + Ul + fral + eps * ud * (BPS + cbr) / BPS + 1000 * 10**18, show=[Dl, Bdl], real=True,
                 label="accepted")

# ---------------------------------------------------------------- routed payouts only (Q-401, was the in-kind split)
# FV-LIQ-01 verifies: SPEC-LIQ-010, SPEC-LIQ-013, SPEC-LIQ-022, REQ-SWAP-030
prove("FV-LIQ-01u", "Q-401: in-kind settlement is removed, so every payout is in the debt asset; when S > 0 the "
      "rounding-gap term never binds and keeperOut = Kf + kr: the caller gets its funding back plus the keeper reward",
      wf + [S > 0], z3.And(z3.Not(gap_binds), kout == K + kr - (phiI - phiD)))

# ---------------------------------------------------------------- pending floor (SPEC-LIQ-014)
Vp, sp, sP, mp, slp, alw = R_("V_P allowP s_P minPending slipP slippageAllowanceBpsP")
# FV-LIQ-01 verifies: SPEC-LIQ-014, REQ-SWAP-066
prove("FV-LIQ-01v", "SPEC-LIQ-014: with s_P = min(slippageAllowanceBps, 30), 0 <= minPending <= V_P (1 - s_P) and the "
      "allowance a searcher can take from the reserve is at most 30 bps of V_P plus the rounding terms",
      [Vp >= 0, alw >= 0, alw <= BPS, sP == z_min(alw, 30), U >= 1, fra >= 0,
       slp * BPS >= Vp * (BPS - sP), (slp - 1) * BPS < Vp * (BPS - sP),
       mp == z3.If(slp - U - fra > 0, slp - U - fra, 0)],
      z3.And(mp >= 0, mp * BPS <= Vp * (BPS - sP), sP <= 30, Vp - mp <= Vp * 30 / BPS + U + fra), real=True)

# ---------------------------------------------------------------- splitting (family F-08): fee rounding per call
S1, S2, A1, A2, A12, shr = R_("S1 S2 A1 A2 A12 shareR")
prove("FV-LIQ-01x", "Splitting: the oracle fee term floor(x x share / 1e4) over two calls satisfies A(x1) + A(x2) < "
      "A(x1+x2) + 1 and A(x1+x2) - A(x1) - A(x2) < 2 (integer: the split total is A(x1+x2) or 1 unit less; the caller "
      "gains < 1 unit per extra call)",
      [S1 >= 0, S2 >= 0, shr >= 0, shr <= BPS,
       A1 * BPS <= S1 * shr, (A1 + 1) * BPS > S1 * shr, A2 * BPS <= S2 * shr, (A2 + 1) * BPS > S2 * shr,
       A12 * BPS <= (S1 + S2) * shr, (A12 + 1) * BPS > (S1 + S2) * shr],
      z3.And(A1 + A2 < A12 + 1, A12 - (A1 + A2) < 2), real=True)

# ---------------------------------------------------------------- Avana fee from the oracle value (F-06, SPEC-LIQ-009)
R1, R2, Aor6, A1f, A2f, Sx1, Sx2, Gn1, Gn2 = I_("R1 R2 feeAtOracle A1fix A2fix S1x S2x D1 D2")
base6 = [Gn1 >= 0, Gn2 >= 0, phiD >= 0, Aor6 >= 0, R1 >= 0, R2 >= 0,
         Sx1 == z_max(0, R1 - Gn1 - phiD), Sx2 == z_max(0, R2 - Gn2 - phiD),
         A1f == z_min(Aor6, Sx1), A2f == z_min(Aor6, Sx2)]
# FV-LIQ-01 verifies: SPEC-LIQ-008, SPEC-LIQ-009, INV-036, INV-086
prove("FV-LIQ-01y", "F-06 fixed (SPEC-LIQ-009): with A = min(fee on the oracle gain V - D - phiD, S), two executions that "
      "differ only in how the caller converted (R) pay the same A while S covers the fee term, and A <= S keeps the "
      "no-revert property of FV-LIQ-01m",
      base6 + [Gn1 == Gn2, R1 >= Gn1 + phiD + Aor6, R2 >= Gn2 + phiD + Aor6],
      z3.And(A1f == A2f, A1f <= Sx1, A2f <= Sx2))
Acur1, Acur2 = I_("Acur1 Acur2")
expect_violation("FV-LIQ-01z", "mutation (the text before Q-256): A = floor(S x share / 1e4) lets every unit of the debt "
                 "asset the caller diverts from R lower Avana's fee by share/1e4 of it; FV-LIQ-01y catches it",
                 base6 + [Gn1 == Gn2, share == 2000, R1 > R2, R2 >= Gn1 + phiD + 10**18,
                          Acur1 * BPS <= Sx1 * share, (Acur1 + 1) * BPS > Sx1 * share,
                          Acur2 * BPS <= Sx2 * share, (Acur2 + 1) * BPS > Sx2 * share, R1 - R2 >= 10**18],
                 Acur1 == Acur2, show=[R1, R2, Acur1, Acur2], label="mutant")
# The leftover X - D is the debt asset itself: it stays outside the R window (SPEC-LIQ-006) and repays the flash loan.
Lft, Rr6, Dd6, Go6, kr1, kr2, S61, S62, A61, A62 = I_("leftover R6 D6 Goracle6 kr1 kr2 S61 S62 A61 A62")
lft = [Lft > 0, Rr6 >= 0, Dd6 >= 0, Go6 >= 0, Aor6 >= 0, Aor6 <= Go6, phiD >= 0,
       S61 == z_max(0, Rr6 - Dd6 - phiD), A61 == z_min(Aor6, S61), kr1 == z_min(S61, Go6) - A61,
       S62 == z_max(0, Rr6 + Lft - Dd6 - phiD), A62 == z_min(Aor6, S62), kr2 == z_min(S62, Go6) - A62]
# FV-LIQ-01 verifies: SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-017, REQ-SWAP-089, INV-086
expect_violation("FV-LIQ-01z2", "mutation (R measured from before funding): counting the leftover X - D in R lets an "
                 "oversized debtToCover raise S and the keeper reward kr; FV-LIQ-01y2 proves the final R window excludes it",
                 lft + [Rr6 < Dd6 + phiD + Go6], kr1 == kr2, show=[Lft, Rr6, Dd6, Go6, kr1, kr2], label="mutant")
# FV-LIQ-01 verifies: SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-017
prove("FV-LIQ-01y2", "SPEC-LIQ-006/017 (final): R is measured from just before burnSeized, so the leftover X - D never "
      "enters S, A, kr or B; an oversized debtToCover changes only the premium on the extra flash amount, borne by the "
      "caller (phi - phiD)",
      lft, z3.And(S61 == z_max(0, Rr6 - Dd6 - phiD), A61 == z_min(Aor6, S61), kr1 == z_min(S61, Go6) - A61))

# ---------------------------------------------------------------- no sell-back (REQ-SWAP-089, LIQ-071)
Xs9, Ds9, Ks9, Fs9, ph9, Rp9, A9, B9, ko9 = I_("X9 D9 K9 F9 phi9 Rp9 A9 B9 keeperOut9")
# FV-LIQ-01 verifies: REQ-SWAP-089, REQ-SWAP-111, SPEC-LIQ-017, INV-083
prove("FV-LIQ-01ab", "REQ-SWAP-089: the leftover X - D is never swapped (no sell-back leg exists); with K + F >= X >= D it "
      "is >= 0 and is spent within the flash repayment F + phi or returned inside keeperOut, so the debt-asset balance "
      "closes at 0 with no route call for it",
      [Xs9 > 0, Ds9 >= 0, Ds9 <= Xs9, Ks9 >= 0, Fs9 >= 0, Ks9 + Fs9 >= Xs9, ph9 >= 0, Rp9 >= 0, A9 >= 0, B9 >= 0,
       ko9 == (Ks9 + Fs9 + Rp9) - (Ds9 + Fs9 + ph9 + A9 + B9)],
      z3.And(Xs9 - Ds9 >= 0, (Ks9 + Fs9 - Ds9) + Rp9 - (Fs9 + ph9) - A9 - B9 - ko9 == 0))

# ---------------------------------------------------------------- caller shortfall top-up (SPEC-LIQ-019)
Vs, s19, msg, msb, rel, sLeg, mg19, R19, sh19, Kq, Bdq, Gq, phq = R_(
    "V19 s19 maxShortfall maxShortfallBps relaxTerm sLeg19 minRec19 R19 shortfall19 K19 gap19 D19 phiD19")
sl19 = [Vs > 0, s19 >= 0, s19 <= 9999, msg >= 0, msb >= 0, msb <= 5000,
        rel >= 0,                                                     # rel = floor(maxShortfall x 1e4 / V)
        rel * Vs <= msg * BPS, (rel + 1) * Vs > msg * BPS,
        sLeg == z_min(9999, s19 + z_min(msb, rel))]
# FV-LIQ-01 verifies: SPEC-LIQ-019, REQ-SWAP-101, REQ-SWAP-046
prove("FV-LIQ-01ac", "SPEC-LIQ-019: s <= sLeg <= min(9,999, s + maxShortfallBps) and the relaxation buys at most "
      "maxShortfall of value: V x (sLeg - s) / 1e4 <= maxShortfall", sl19,
      z3.And(sLeg >= s19, sLeg <= 9999, sLeg <= s19 + msb, Vs * (sLeg - s19) <= msg * BPS), real=True)
top = [mg19 >= 0, R19 >= 0, Kq >= 0, Gq >= 0, phq >= 0, Bdq == Gq + phq - Kq - R19,
       sh19 == z_max(z_max(0, mg19 - R19), Bdq), sh19 <= msg]
# FV-LIQ-01 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-101, INV-034
prove("FV-LIQ-01ad", "SPEC-LIQ-019: after the top-up R' = R + shortfall >= minRec, shortfall <= maxShortfall, and the "
      "rounding gap is closed in the same pull: R' >= D + phiD - K, so no shared pool pays any gap (Q-397)", sl19 + top,
      z3.And(R19 + sh19 >= mg19, sh19 <= msg, R19 + sh19 >= Gq + phq - Kq), real=True)
# Legs meeting their minimums at sLeg: R >= Sum minOut_i >= Sum (Vleg_i(1 - sLeg) - Uleg_i - fra/n); legs worth >= V.
e0b, e1b, v0b, v1b, Ub = R_("e0b e1b Vleg0b Vleg1b Ub")
meet = [R19 >= 0, e0b >= 0, e1b >= 0, v0b <= e0b, v0b > e0b - 1, v1b <= e1b, v1b > e1b - 1, e0b + e1b >= Vs, Ub >= 2, fra >= 0,
        R19 >= (v0b + v1b) * (BPS - sLeg) / BPS - Ub - fra,
        mg19 == z_max(0, Vs * (BPS - s19) / BPS + 1 - Ub - fra)]      # minRec <= ceil(...) - U - fra < this
# FV-LIQ-01 verifies: SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-101
prove("FV-LIQ-01ae", "SPEC-LIQ-019: when every leg meets its minimum at sLeg, the shortfall is below maxShortfall + n + 1 "
      "(n = 2 legs): RecoveryBelowFloor is left for the few base units by which the rounded leg minimums can miss the floor",
      sl19 + meet + [sh19 == z_max(0, mg19 - R19)], sh19 < msg + 3, real=True)

# ---------------------------------------------------------------- repay with collateral sizing (SPEC-LIQ-020)
Vd, sd, Ud_, Vn, capd, mf_, xd, debt_r, slV = R_("Vdel sDel Udel Vnet capDel maxFlashFeeDel xRepay debtR slipFloorDel")
dl = [Vd >= 0, sd >= 0, sd < BPS, Ud_ >= 1, mf_ >= 0, mf_ <= 9, debt_r >= 0,
      slV * BPS <= Vd * (BPS - sd), (slV + 1) * BPS > Vd * (BPS - sd),
      Vn == z_max(0, slV - Ud_), capd * (BPS + mf_) <= Vn * BPS, (capd + 1) * (BPS + mf_) > Vn * BPS,
      z3.Implies(capd > -1, capd >= 0), xd == z_min(debt_r, capd)]
# FV-LIQ-01 verifies: SPEC-LIQ-020, REQ-SWAP-106, INV-089
prove("FV-LIQ-01ah", "SPEC-LIQ-020: the debt-asset repayment x = min(debt, cap) and its flash premium are covered by the units' oracle "
      "value after the market's slippage and the one-unit-per-leg allowance: x x (1e4 + maxFlashFeeBps) <= Vnet x 1e4 "
      "<= V (1e4 - s), so no bonus, fee or top-up is needed", dl,
      z3.And(xd >= 0, xd * (BPS + mf_) <= Vn * BPS, Vn * BPS <= Vd * (BPS - sd)), real=True)
phx = z3.Real("phiDel")
# FV-LIQ-01 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-FLASH-002
prove("FV-LIQ-01ai", "SPEC-LIQ-020 / REQ-SWAP-106: the flash loan F = x of the debt asset itself, with a premium at most "
      "maxFlashFeeBps of x, satisfies x + phi <= Vnet <= V(1 - s): the swaps that meet their minimums repay the loan up "
      "to rounding; no buy leg exists",
      dl + [phx >= 0, phx * BPS <= mf_ * xd], z3.And(xd + phx <= Vn, Vn * BPS <= Vd * (BPS - sd)), real=True)
HFv, CFv = R_("HFbefore CFdel")
thr = [HFv > 0, CFv > 0, CFv < 1, xd == capd, capd <= debt_r, Vd > 0]
# FV-LIQ-01 verifies: SPEC-LIQ-020, INV-089
expect_violation("FV-LIQ-01aj", "mutation (the SPEC-LIQ-020 threshold before FV-LIQ-F-11): the sizing meets x x HF >= V x CF for "
                 "every account with HF >= CF (1e4 + maxFlashFeeBps) / (1e4 - s); at that exact HF the subtracted U and "
                 "the floors leave x x HF just below V x CF, so the health factor falls by a few base units of value and the "
                 "AaveAdapter reverts HealthFactorNotImproved",
                 dl + thr + [HFv * (BPS - sd) == CFv * (BPS + mf_)], xd * HFv >= Vd * CFv,
                 show=[Vd, sd, Ud_, mf_, xd, HFv, CFv], real=True, label="mutant")
prove("FV-LIQ-01ak", "SPEC-LIQ-020 (final): when HF x (V(1e4 - s) - 1e4 (U + 2) - maxFlashFeeBps) >= CF x V x "
      "(1e4 + maxFlashFeeBps), the cap-limited repayment satisfies x x HF > V x CF, so the health factor does not fall",
      dl + thr + [HFv * (Vd * (BPS - sd) - BPS * (Ud_ + 2) - mf_) >= CFv * Vd * (BPS + mf_)],
      xd * HFv > Vd * CFv, real=True)

# ---------------------------------------------------------------- arithmetic bounds (T-52)
# FV-LIQ-01 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-015, SPEC-LIQ-016, SPEC-LIQ-018, SPEC-LIQ-019
M256 = 2**256
cases = {
    "SPEC-LIQ-001 (b-1e4)(1e4-lf) < 2^64": (2**32) * BPS < 2**64,
    "SPEC-LIQ-003 1e4 x bNet < 2^50": BPS * 2**32 < 2**50,
    "SPEC-LIQ-004 c*Pc < 2^256 and V < 2^200 (Pdebt >= 5e7, dv >= 6, dd <= 18)": (2**120 * 2**64 < M256) and
    (2**120 * 2**64 * 10**18) // (10**6 * 5 * 10**7) < 2**200,
    "SPEC-LIQ-005 V*(1e4) < 2^214": 2**200 * BPS < 2**214,
    "SPEC-LIQ-018 D*Pdebt, a_i*p_i < 2^192": 2**128 * 2**64 <= 2**192,
    "SPEC-LIQ-015 premium*1e4 and maxFlashFeeBps*F < 2^142 for F < 2^128": 2**128 * BPS < 2**142,
    "SPEC-LIQ-016 every product < 2^64": 2**32 * BPS < 2**64 and BPS * (BPS + 100) < 2**64,
    "SPEC-LIQ-010 sums of five terms < 2^129 fit 256 bits": 5 * 2**129 < M256,
    "SPEC-LIQ-018 a_i*p_i*1e18 < 2^252": 2**128 * 2**64 * 10**18 < 2**252,
    "SPEC-LIQ-019 maxShortfall*1e4 < 2^142": 2**128 * BPS < 2**142,
}
for i, (t, ok) in enumerate(cases.items()):
    check(f"FV-LIQ-01w{i}", f"T-52 bound {t}", ok)

# ---------------------------------------------------------------- payout split A / kr / B (SPEC-LIQ-022, Q-337)
Vx, Dx, pdx, Rpx, Sx, Gx, Ax, Ax0, krx, Bx, shx, mrx, Bdx, Kx = I_("Vx Dx phiDx Rpx Sx Gx Ax feeTermX krx Bx shortfallX "
                                                                    "minRecX gapX Kx")
shx_ = z3.Int("shareX")
spl = [Vx >= 0, Dx >= 0, pdx >= 0, Rpx >= 0, shx_ >= 0, shx_ <= 5000,
       Sx == z_max(0, Rpx - Dx - pdx), Gx == z_max(0, Vx - Dx - pdx),
       Ax0 * BPS <= Gx * shx_, (Ax0 + 1) * BPS > Gx * shx_, Ax == z_min(Ax0, Sx),
       krx == z_min(Sx, Gx) - Ax, Bx == Sx - Ax - krx]
# FV-LIQ-01 verifies: SPEC-LIQ-009, SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-027, INV-086
prove("FV-LIQ-01al", "SPEC-LIQ-022: the realized surplus splits exactly, A + kr + B = S, with A, kr, B >= 0, A <= S, "
      "kr <= G - A (the keeper never takes more than the oracle bonus after Avana's share) and B = max(0, S - G)",
      spl, z3.And(Ax + krx + Bx == Sx, Ax >= 0, krx >= 0, Bx >= 0, Ax <= Sx, krx <= Gx - Ax, Bx == z_max(0, Sx - Gx)))
prove("FV-LIQ-01am", "SPEC-LIQ-022: B = 0 whenever S <= G, and when S > G the borrower receives B = R' - max(V, D + phiD), "
      "the recovery above the oracle value of the seizure",
      spl, z3.And(z3.Implies(Sx <= Gx, Bx == 0), z3.Implies(Sx > Gx, Bx == Rpx - z_max(Vx, Dx + pdx))))
# FV-LIQ-01 verifies: SPEC-LIQ-019, SPEC-LIQ-022, SPEC-SET-001, REQ-SWAP-101
prove("FV-LIQ-01an", "SPEC-LIQ-019/022: a call that pulled a shortfall has R' = minRec <= V, so B = 0 and the caller's "
      "top-up never reaches the borrower; a call whose top-up closed a rounding gap (R' = D + phiD - K) has "
      "S = A = kr = B = 0",
      spl + [Kx >= 0, mrx >= 0, mrx <= Vx, shx >= 0, z3.Implies(shx > 0, z3.Or(Rpx == mrx, Rpx == Bdx)),
             Bdx == Dx + pdx - Kx],
      z3.And(z3.Implies(z3.And(shx > 0, Rpx == mrx), Bx == 0),
             z3.Implies(z3.And(shx > 0, Rpx == Bdx), z3.And(Sx == 0, Ax == 0, krx == 0, Bx == 0))))
expect_violation("FV-LIQ-01ao", "mutation (the waterfall before Q-337, no borrower surplus): a keeper paid S - A takes the "
                 "recovery above the oracle value when routes beat the oracle, more than G - A; FV-LIQ-01al catches it",
                 spl + [Rpx > Vx, Vx > Dx + pdx], Sx - Ax <= Gx - Ax, show=[Vx, Dx, Rpx, Sx, Gx, Ax], label="mutant")

# ---------------------------------------------------------------- flash-source gates (REQ-FLASH-002, REQ-FLASH-005)
lender, homeHub, fundHub, pool = z3.Ints("lender homeHub fundingHub v3Pool")
avail, Fq, quote, mfq, go = z3.Int("maxFlashLoan"), z3.Int("Fq"), z3.Int("quote"), z3.Int("maxFlashFeeQ"), z3.Bool("loanTaken")
gate = [Fq > 0, avail >= 0, quote >= 0, mfq >= 0, mfq <= 100,
        go == z3.And(Fq <= avail, quote * BPS <= mfq * Fq, lender != homeHub, lender != fundHub)]
# FV-LIQ-01 verifies: REQ-FLASH-002, REQ-FLASH-005, REQ-SWAP-097, SPEC-LIQ-015, INV-095
prove("FV-LIQ-01ap", "REQ-FLASH-002/005: a flash loan is taken only when F <= maxFlashLoan(T), the quoted premium is at most "
      "maxFlashFeeBps of F and the lender is neither the CDP Spoke's home Hub nor the reserve's funding Hub; the Aave V3 "
      "Pool, which is not a V4 Hub, passes the lender gate",
      gate, z3.And(z3.Implies(go, z3.And(Fq <= avail, quote * BPS <= mfq * Fq, lender != homeHub, lender != fundHub)),
                   z3.Implies(z3.And(lender == pool, pool != homeHub, pool != fundHub, Fq <= avail,
                                     quote * BPS <= mfq * Fq), go)))

finish()
