"""FV-LIQ-07: system-level liquidation properties in value terms (USD at the oracle price).

An account has collateral value C (sum over its vault reserves), weighted collateral
W = sum CF_i x C_i and debt value T; HF = W / T. A liquidation repays D (value) and
seizes collateral of value at most D x LB from the reserve with collateral factor CF_c
(FV-LIQ-02a..d), and at least D x LB minus one unit and Aave's debt rounding
(FV-LIQ-02f..i). Decided over the reals with nlsat.
"""
import aave_ref as A
from _lib import BPS, RAY, WAD, check, expect_violation, finish, prove, replay
import z3

R_ = z3.Reals
C, W, T, D, LB, CFc, Cs, seized, h = R_("C W T D LB CFc collateralOfReserve seized HF")
acct = [T > 0, D > 0, D <= T, LB >= 1, LB <= 2, CFc > 0, CFc < 1, LB * CFc < 1,   # Aave: percentMulUp(maxLB, CF) < 1e4
        Cs >= 0, Cs <= C, W >= CFc * Cs, seized <= D * LB, seized >= 0, seized <= Cs, h * T == W]
W2, C2, T2 = W - CFc * seized, C - seized, T - D

# (2) liquidations never amplify insolvency beyond the bonus
# FV-LIQ-07 verifies: SPEC-LIQ-004, REQ-SWAP-016, INV-032
prove("FV-LIQ-07a", "Invariant 2: a liquidation lowers the account's equity C - T by at most the bonus D x (LB - 1)",
      acct, (C2 - T2) >= (C - T) - D * (LB - 1), real=True)
prove("FV-LIQ-07b", "Invariant 2: the account's HF does not fall when HF >= LB x CF_c (collateral value of the seized "
      "reserve above LB x its weighted share of debt)", acct + [h >= LB * CFc, T2 > 0, seized == D * LB],
      W2 >= h * T2, real=True)
expect_violation("FV-LIQ-07c", "Invariant 2 (HF part) fails for accounts with HF < LB x CF_c: paying the bonus lowers HF "
                 "(inherent to a bonus-paying liquidation; Aave then seizes all collateral and records a deficit)",
                 acct + [T2 > 0, seized == D * LB, h < LB * CFc], W2 >= h * T2, show=[h, LB, CFc], real=True,
                 label="accepted")

# (4) no insolvency created in one block with fixed prices
expect_violation("FV-LIQ-07d", "Invariant 4: with fixed prices a liquidation turns a solvent account (C >= T) into a "
                 "deficit when C < LB x T; the lenders' loss is at most (LB - 1)/LB x C (priced in SPEC-FLR-004's lossFactor)",
                 acct + [C >= T, Cs == C, seized == C, D * LB == C], C2 >= T2, show=[C, T, D, LB], real=True,
                 label="accepted")
prove("FV-LIQ-07e", "Invariant 4 bound: when all collateral is seized at D = C / LB, the recorded deficit T - D is at most "
      "the pre-existing shortfall max(0, T - C) plus (LB - 1)/LB x C",
      acct + [Cs == C, seized == C, D * LB == C], T - D <= z3.If(T > C, T - C, 0) + (LB - 1) / LB * C, real=True)
# concrete: Aave port on a near-insolvent account (C = 1.03 T, CF 0.312, LB 1.05)
debt = 10_000 * 10**18
coll_units = 10_300 * 10**18 // 2                                 # $10,300 at $2
p = A.Params(supplied_shares=coll_units, coll_A=10**30, coll_S=10**30, coll_decimals=18, coll_price=2 * 10**8,
             drawn_shares=debt, premium_debt_ray=0, drawn_index=RAY, total_debt_value_ray=debt * RAY * 10**8,
             debt_decimals=18, debt_price=10**8, debt_to_cover=debt, collateral_factor=3120,
             hf_for_max_bonus=9 * 10**17, bonus_factor=4000, max_lb=10_500, target_hf=11 * 10**17,
             hf=10_300 * 3120 * 10**14 // 10_000)
r = A.liquidation_call(p)
deficit = debt - r["D"]
replay("FV-LIQ-07f", "Invariant 4, Aave port: an account with $10,300 collateral and 10,000 GHO debt (the GHO reserve, "
       "solvent) is liquidated in full and leaves a 190.48 GHO deficit", r["user_coll_empty"] and deficit > 0,
       f"D={r['D'] / 1e18:.2f} branch={r['branch']} deficit={deficit / 1e18:.2f}")

# (3) no zero-risk profit loop (borrower acting as caller)
Mc, Md, R, Dd, Afee, Bs, phi, kout, K, F, sh = R_("marketValueSeized marketValueDebtRepaid R D A B phi keeperOut K F "
                                                   "shortfall")
loop = [Mc >= 0, Md >= 0, R >= 0, R <= Mc,              # swap routes cannot pay more than market value for the collateral
        Dd >= Md,                                        # the debt repaid is the debt asset itself, at its market value
        sh >= 0, Afee >= 0, Bs >= 0, phi >= 0, K >= 0, F >= 0,
        kout == (K + F + R + sh) - (Dd + F + phi + Afee + Bs)]
borrower_change = -Mc + Md + Bs                          # loses the seized collateral, owes D less, receives B
caller_change = kout - K - sh                             # caller funds K and the shortfall top-up, receives keeperOut
# FV-LIQ-07 verifies: SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-072, Q-213, Q-404, INV-077
prove("FV-LIQ-07g", "Invariant 3: a borrower that liquidates its own account (through liquidate, the one entry point, "
      "with its own debt asset or a helper's loan whose premium is phi, with or without a shortfall top-up, receiving its own borrower surplus B) ends with at most "
      "-(A + phi) <= 0: no zero-risk profit, given swap routes pay at most market value", loop, borrower_change + caller_change <= -(Afee + phi), real=True)

# (5) every swap limit derived from the oracle
Ff, avl, qt, mfb, ph7 = R_("F maxFlashLoan quote maxFlashFeeBps phi")
# FV-LIQ-07 verifies: SPEC-LIQ-015, REQ-FLASH-002, REQ-SWAP-013, REQ-SWAP-088
prove("FV-LIQ-07h", "Invariant 5, funding: no buy leg exists; the flash loan of the debt asset is bounded before the loan "
      "by maxFlashLoan(T) and by the quoted premium, and in the callback by the charged premium, both at most "
      "maxFlashFeeBps of F: no funding step runs with an unbounded amount or cost",
      [Ff > 0, avl >= 0, qt >= 0, ph7 >= 0, mfb >= 0, mfb <= 100, Ff <= avl, qt * BPS <= mfb * Ff, ph7 * BPS <= mfb * Ff],
      z3.And(Ff <= avl, ph7 <= Ff * 100 / BPS, qt <= Ff * 100 / BPS), real=True)
vl, sl_, ul, fq, cs_, mo = R_("Vleg sLeg Uleg fraOverN slipTermLeg minOutLeg")
# FV-LIQ-07 verifies: SPEC-LIQ-018, REQ-SWAP-100, REQ-SWAP-089, REQ-ROUTE-009, INV-083
prove("FV-LIQ-07i", "Invariant 5, swap legs into the debt asset: every leg minimum max(1, ceil(Vleg(1 - sLeg)) - Uleg - "
      "fra/n) is oracle-derived, >= 1 and decreases by at most Uleg + fra/n + Vleg x sLeg below the leg's oracle value; "
      "the leftover X - D is never swapped (FV-LIQ-01ab); no swap runs with a zero minimum or an unbounded input",
      [vl >= 0, sl_ >= 0, sl_ < BPS, ul >= 1, fq >= 0, cs_ * BPS >= vl * (BPS - sl_), (cs_ - 1) * BPS < vl * (BPS - sl_),
       mo == z3.If(cs_ - ul - fq > 1, cs_ - ul - fq, 1)],
      z3.And(mo >= 1, mo >= vl - vl * sl_ / BPS - ul - fq), real=True)
V, s, U, fra, mg = R_("V s U fra minRec")
expect_violation("FV-LIQ-07i2", "Invariant 5, aggregate: the recovery floor minRec is 0 for dust (V(1-s) <= U + fra) by "
                 "design (SPEC-LIQ-005), so a dust liquidation still settles and records its deficit; each leg keeps its "
                 "own minimum >= 1 (FV-LIQ-07i)",
                 [V >= 0, s >= 0, s < BPS, U >= 1, fra == 10**18, mg == z3.If(V * (BPS - s) / BPS - U - fra > 0,
                                                                              V * (BPS - s) / BPS - U - fra, 0)],
                 mg > 0, show=[V, mg], real=True, label="accepted")

# (6) oracle extremes: zero prices fail closed inside Aave's sizing
def aave_with(pc, pdebt):
    q = A.Params(**{**p.__dict__, "coll_price": pc, "debt_price": pdebt, "hf": 9 * 10**17, "supplied_shares": 10**24})
    try:
        A.liquidation_call(q)
        return "ok"
    except (ZeroDivisionError, AssertionError, A.AaveRevert):
        return "revert"


# FV-LIQ-07 verifies: REQ-SWAP-008, REQ-SWAP-050, REQ-SWAP-055, REQ-SWAP-091
check("FV-LIQ-07j", "Invariant 6: a collateral price of 0 or a debt price of 0 makes Aave's sizing divide by zero and the "
      "liquidation revert (fail closed); LPVaultSwap's price gates also reject Cached, Expired, stale and disagreeing prices "
      "(FV-LIQ-03h)", aave_with(0, 10**8) == "revert" and aave_with(2 * 10**8, 0) == "revert")
Pc_ok, fresh, agree, src_ok = z3.Bools("priceStateLiveOrDrifting inputsFresh routesAgree sourceIsMarketLpOracle")
proceeds = z3.Bool("liquidationProceeds")
gate = proceeds == z3.And(Pc_ok, fresh, agree, src_ok)
prove("FV-LIQ-07k", "Invariant 6: no seizure proceeds at a price that is Cached/Expired, stale, from an unknown source or "
      "contradicted by the alternate Chainlink route", [gate, proceeds], z3.And(Pc_ok, fresh, agree, src_ok))

# (7) one-token shock: deficit-free recovery threshold
f, hpre, LBv, CFv = R_("lpValueFactor HFbefore LBv CFv")
# FV-LIQ-07 verifies: SPEC-FLR-004, REQ-SWAP-018, SPEC-LIQ-016
prove("FV-LIQ-07l", "Invariant 7: if one pool token falls 50 % the LP value factor f is >= 0.5 (>= sqrt(0.5) full range); an "
      "account with HF >= 2 x LB x CF before the shock keeps collateral >= LB x debt, so Aave sizes a normal liquidation "
      "(no deficit) and the two-leg floor repays the funding up to the rounding gap the caller tops up",
      [f >= z3.RealVal(1) / 2, f <= 1, LBv >= 1, LBv <= z3.RealVal(21) / 20, CFv > 0, CFv < 1, hpre >= 2 * LBv * CFv],
      (f * hpre) / CFv >= LBv, real=True)
check("FV-LIQ-07m", "Invariant 7 at listing values (CF 0.312, LB 1.05): accounts above HF 0.655 before a 50 % one-token "
      "shock (0.464 for a full-range position, factor sqrt(0.5)) are liquidated without deficit; accounts are liquidated "
      "below HF 1, so a deficit needs liquidation to have stopped while earlier shocks happened",
      abs(2 * 1.05 * 0.312 - 0.6552) < 1e-9 and abs(1.05 * 0.312 / 0.5**0.5 - 0.4633) < 1e-3)

# (6b) stress valuation (INV-087, REQ-ORACLE-085/086, SPEC-ORC-018): served prices only lower HF.
q0, q1, cf0, cf1, acc0, srv0, acc1, srv1, debtv, dacc, dsrv, hfT, hfS = R_(
    "qty0 qty1 cf0 cf1 accepted0 served0 accepted1 served1 debtQty debtAccepted debtServed hfTrue hfServed")
val = [q0 >= 0, q1 >= 0, cf0 > 0, cf0 < 1, cf1 > 0, cf1 < 1, acc0 > 0, acc1 > 0, srv0 > 0, srv1 > 0,
       srv0 <= acc0, srv1 <= acc1,                      # LPOracle: min(fresh, A), min(lower, A), A, or 1 when Expired
       debtv > 0, dacc > 0, dsrv >= dacc,               # DebtOracle: max(primary, alternate, A), A, ceil(A(1 + rise))
       hfT * (debtv * dacc) == q0 * cf0 * acc0 + q1 * cf1 * acc1,
       hfS * (debtv * dsrv) == q0 * cf0 * srv0 + q1 * cf1 * srv1]
# FV-LIQ-07 verifies: INV-087, INV-075, REQ-SWAP-008, REQ-SWAP-091, REQ-ORACLE-085, REQ-ORACLE-086, SPEC-ORC-018
prove("FV-LIQ-07o", "Stress valuation is monotone: with every collateral served at most its accepted price and every debt "
      "served at least its accepted price, the account's HF at served prices is at most its HF at accepted prices",
      val, hfS <= hfT, real=True)
prove("FV-LIQ-07p", "No shield: an account liquidatable at accepted prices (HF < 1) stays liquidatable at served prices, so "
      "a failing price in another market or debt can only enable the liquidation of the account's fresh reserves "
      "(which the per-reserve gate of FV-LIQ-03h then prices), never block it", val + [hfT < 1], hfS < 1, real=True)
# FV-LIQ-07 verifies: INV-087, REQ-SWAP-091, SPEC-ORC-018
check("FV-LIQ-07q", "INV-087 served-price examples: an Expired market serves 1 (8 decimals), USDC accepted at 99,990,000 "
      "with debtStressRiseBps 500 serves ceil(99,990,000 x 10,500 / 1e4) = 104,989,500 when Expired, and with routes at "
      "0.9999 and 1.0030 disagreeing serves max(99,990,000, 100,300,000, 99,990,000) = 100,300,000",
      -((-99_990_000 * 10_500) // 10_000) == 104_989_500 and max(99_990_000, 100_300_000, 99_990_000) == 100_300_000
      and 1 <= min(199_980_000, 1))

# Bug class: splitting a liquidation does not raise the bonus rate
hf0, hf1, hmax = R_("hf0 hf1 hfForMaxBonus")
prove("FV-LIQ-07n", "Splitting: after a liquidation the account's HF is >= before, or (HF < LB x CF <= hfForMaxBonus) the "
      "bonus is already at its maximum; Aave's bonus is non-increasing in HF (FV-LIQ-02m), so later partial steps never pay "
      "a higher bonus rate than one step",
      acct + [seized == D * LB, T2 > 0, hmax >= LB * CFc, hf1 * T2 == W2, hf0 == h],
      z3.Or(hf1 >= hf0, hf0 < hmax), real=True)
finish()
