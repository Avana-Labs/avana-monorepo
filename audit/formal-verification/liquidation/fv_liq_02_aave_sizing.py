"""FV-LIQ-02: Aave V4 liquidationCall sizing at the pin, as LPVaultSwap and the Lens depend on it.

Model: the canonical LiquidationLogic of aave/aave-v4 a3ef63ea (ported in aave_ref.py),
with the vault-token Hub asset at shares == assets (REQ-SWAP-007 checks it before the
call, so previewAddByAssets / previewRemoveByShares are the identity) and
liquidationFee = 0 (REQ-SWAP-016, Q-222). Products of symbolic prices are kept as
positive integers K1 = Pdebt * 10^dv * LB and K2 = 10^dd * Pc * 10^4 * RAY, so every
lemma holds for every price, decimals pair and bonus.

The second half checks the Lens liquidation preview of 2.17 against the same port:
expectedUnitsSeized (REQ-LENS-029) equals Aave's seizure, and the ready-to-send
debtToCover (REQ-LENS-028) keeps the call clear of MustNotLeaveDust after a front-run
repay or pledge at the same drawn index (REQ-SWAP-005). A preview submitted in a later
block, after the drawn index has grown, and a collateral-limited non-GHO preview
followed by a pledge are recorded as findings (02x, 02y) with the corrected rule
proved (02w, 02z).
"""
import z3
from hypothesis import HealthCheck, given, settings, strategies as st

import aave_ref as A
from _lib import BPS, RAY, WAD, ceil_div, check, expect_violation, finish, prove, replay

# ---------------------------------------------------------------- symbolic setup
K1, K2 = z3.Ints("K1 K2")              # K1 = Pdebt*10^dv*LB ; K2 = 10^dd*Pc*1e4*RAY
P, prem = z3.Ints("drawnTimesIndex premiumRay")
idx = z3.Int("drawnIndex")
c, D, X = z3.Ints("c D debtToCover")
base = [K1 > 0, K2 > 0, P >= 0, prem >= 0, idx >= RAY, idx <= 100 * RAY]


def ceil_q(name, num, den):
    q = z3.Int(name)
    return q, [q * den >= num, (q - 1) * den < num]


def floor_q(name, num, den):
    q = z3.Int(name)
    return q, [q * den <= num, (q + 1) * den > num]


# Target branch: debtRay = drawnShares*index + premium; c = floor(debtRay*K1/K2);
# D = rayMulUp(drawnShares, index) + fromRayUp(premium).
dP, h1 = ceil_q("ceilP", P, RAY)
dQ, h2 = ceil_q("ceilPrem", prem, RAY)
cT, h3 = floor_q("cTarget", (P + prem) * K1, K2)
target = base + h1 + h2 + h3 + [D == dP + dQ, c == cT]

# FV-LIQ-02 verifies: SPEC-LIQ-004, SPEC-HUB-005, REQ-SWAP-016, REQ-SWAP-017, INV-032
prove("FV-LIQ-02a", "T-32 target branch: value(c) <= D x LB (c*K2 <= D*RAY*K1), no extra unit",
      target, c * K2 <= D * RAY * K1)

# All-collateral branch: c = suppliedShares; debtRay = ceil(c*K2/K1).
#   (i)  debtRay <= premiumDebtRay: prem' = min(roundRayUp(debtRay), premiumDebtRay), drawn = 0
#   (ii) else prem' = premiumDebtRay, drawn = ceil((debtRay - prem')/index) [MathUtils.divUp]
#   (iii) drawn > drawnShares: drawn = drawnShares, c = min(floor(fullDebtRay*K1/K2), supplied)
sup = z3.Int("supplied")
debtRay, h4 = ceil_q("debtRayAll", sup * K2, K1)
premTot, drawnTot = z3.Ints("premiumDebtRay drawnShares")
caps = base + h4 + [sup > 0, premTot >= 0, drawnTot > 0]
rr, h5 = ceil_q("roundUpUnits", debtRay, RAY)
prem_i = z3.If(rr * RAY <= premTot, rr * RAY, premTot)
Di, h6 = ceil_q("Di", prem_i, RAY)
branch_i = caps + h5 + h6 + [debtRay <= premTot, c == sup, D == Di]
prove("FV-LIQ-02b", "T-32 all-collateral branch (i), premium only: value(c) <= D x LB",
      branch_i, c * K2 <= D * RAY * K1)

dr, h7 = ceil_q("drawnUp", debtRay - premTot, idx)
Pi = z3.Int("drawnUpTimesIndex")
dPi, h8 = ceil_q("ceilDrawn", Pi, RAY)
dQi, h9 = ceil_q("ceilPremTot", premTot, RAY)
branch_ii = caps + h7 + h8 + h9 + [debtRay > premTot, dr <= drawnTot, Pi == dr * idx, c == sup, D == dPi + dQi]
prove("FV-LIQ-02c", "T-32 all-collateral branch (ii): value(c) <= D x LB", branch_ii, c * K2 <= D * RAY * K1)

Pfull = z3.Int("fullDrawnTimesIndex")
cfull, h10 = floor_q("cFull", (Pfull + premTot) * K1, K2)
dPf, h11 = ceil_q("ceilFull", Pfull, RAY)
branch_iii = caps + h7 + h9 + h10 + h11 + [debtRay > premTot, dr > drawnTot, Pfull == drawnTot * idx,
                                           c == z3.If(cfull <= sup, cfull, sup), D == dPf + dQi]
prove("FV-LIQ-02d", "T-32 all-collateral branch (iii), all debt: value(c) <= D x LB", branch_iii,
      c * K2 <= D * RAY * K1)
prove("FV-LIQ-02e", "c <= supplied shares in every all-collateral branch",
      branch_iii, c <= sup)

# Lower bound (how far below D x LB the seizure can fall). Used by FV-LIQ-01 (T-39).
# Target and all-debt branches: D*RAY < debtRay + 2*RAY and c*K2 > debtRay*K1 - K2.
prove("FV-LIQ-02f", "seizure lower bound, target branch: (c+1)*K2 > (D*RAY - 2*RAY)*K1",
      target, (c + 1) * K2 > (D * RAY - 2 * RAY) * K1)
prove("FV-LIQ-02g", "seizure lower bound, all-collateral branch (ii): (c+1)*K2 > (D*RAY - index - 2*RAY)*K1",
      branch_ii, (c + 1) * K2 > (D * RAY - idx - 2 * RAY) * K1)
prove("FV-LIQ-02h", "seizure lower bound, all-debt branch (iii): (c+1)*K2 > (D*RAY - 2*RAY)*K1",
      branch_iii, (c + 1) * K2 > (D * RAY - 2 * RAY) * K1)
prove("FV-LIQ-02i", "seizure lower bound, premium-only branch (i): (c+1)*K2 > (D*RAY - RAY)*K1 - K1",
      branch_i, (c + 1) * K2 > (D * RAY - RAY) * K1 - K1)

# FV-LIQ-02 verifies: REQ-SWAP-089, REQ-SWAP-005, REQ-SWAP-016, REQ-SWAP-108
# MustNotLeaveDust: debtToCover >= rayMulUp(drawn, index) + fromRayUp(premium) = D, in every branch.
# LPVaultSwap passes debtToCover = min(X, Xr), Xr = K + F as received, less an issuer transfer fee (REQ-SWAP-108).
Xr = z3.Int("fundsReceived")
Xp = z3.If(X <= Xr, X, Xr)
prove("FV-LIQ-02j", "D <= debtToCover = min(X, Xr) after Aave's MustNotLeaveDust check, so Aave never pulls more than "
      "the debt asset it received (K + F less any issuer fee), and the leftover Xr - D >= 0 repays the flash loan",
      [Xr >= 0, X > 0, Xp >= dP + dQ, D == dP + dQ] + h1 + h2, z3.And(D <= Xp, Xr - D >= 0, D <= X))

# ---------------------------------------------------------------- deficit condition (T-46, first half)
# FV-LIQ-02 verifies: REQ-SWAP-018, REQ-SWAP-093, DEF-001, REQ-HUB-033, REQ-PROXY-043
n_sup = 3
supplied = [z3.Bool(f"suppliedAfter{i}") for i in range(n_sup)]
cf_pos = [z3.Bool(f"cfPositive{i}") for i in range(n_sup)]
enabled = [z3.Bool(f"enabled{i}") for i in range(n_sup)]
liq_res = 0  # reserve 0 is the liquidated collateral
coll_before = [z3.Bool(f"suppliedBefore{i}") for i in range(n_sup)]
active_count = z3.Sum([z3.If(z3.And(coll_before[i], cf_pos[i], enabled[i]), 1, 0) for i in range(n_sup)])
debt_empty, borrow2 = z3.Bools("debtPositionEmpty borrowCountAboveOne")
coll_empty = z3.Not(supplied[liq_res])
frame = [coll_before[liq_res], cf_pos[liq_res], enabled[liq_res]] + \
        [supplied[i] == coll_before[i] for i in range(1, n_sup)]
deficit = z3.And(coll_empty, active_count <= 1, z3.Or(z3.Not(debt_empty), borrow2))
no_collateral_left = z3.And(*[z3.Not(supplied[i]) for i in range(n_sup)])
avana_rules = [z3.Implies(coll_before[i], z3.And(cf_pos[i], enabled[i])) for i in range(n_sup)]
prove("FV-LIQ-02k", "T-46: Aave reports a deficit only when the account keeps no supplied collateral "
      "(given REQ-HUB-033 CF > 0 on every vault key and REQ-PROXY-043 every supplied reserve enabled)",
      frame + avana_rules, z3.Implies(deficit, no_collateral_left))
only_enabled = [z3.Implies(coll_before[i], enabled[i]) for i in range(n_sup)]
only_cf = [z3.Implies(coll_before[i], cf_pos[i]) for i in range(n_sup)]
expect_violation("FV-LIQ-02l", "mutation: drop REQ-HUB-033; a CF = 0 vault reserve is not an active collateral, "
                 "so a deficit is reported while that collateral stays supplied",
                 frame + only_enabled, z3.Implies(deficit, no_collateral_left), show=cf_pos + coll_before + supplied, label="mutant")
expect_violation("FV-LIQ-02p", "mutation: drop REQ-PROXY-043; a supplied reserve not enabled as collateral is "
                 "not counted, so a deficit is reported while it stays supplied",
                 frame + only_cf, z3.Implies(deficit, no_collateral_left), show=enabled + coll_before + supplied, label="mutant")

# ---------------------------------------------------------------- bonus curve (SPEC-HUB-005)
# FV-LIQ-02 verifies: SPEC-HUB-005
hf, hfmax, fac, maxlb = z3.Ints("hf hfForMaxBonus bonusFactor maxLB")
minlb = z3.Int("minLB")
lbv = z3.Int("lb")
rng = [hfmax >= 0, hfmax < WAD, hf >= 0, hf < WAD, fac >= 0, fac <= BPS, maxlb >= BPS, maxlb <= 2 * BPS]
q1 = z3.Int("q1")
q2 = z3.Int("q2")
bonus = rng + [q1 * BPS <= (maxlb - BPS) * fac, (q1 + 1) * BPS > (maxlb - BPS) * fac, minlb == q1 + BPS,
               q2 * (WAD - hfmax) <= (maxlb - minlb) * (WAD - hf), (q2 + 1) * (WAD - hfmax) > (maxlb - minlb) * (WAD - hf),
               lbv == z3.If(hf <= hfmax, maxlb, minlb + q2)]
prove("FV-LIQ-02m", "SPEC-HUB-005: minLB <= bonus <= maxLB for every HF < 1 (the bNet range SettlementMath assumes)",
      bonus, z3.And(minlb <= lbv, lbv <= maxlb, lbv >= BPS))


# ---------------------------------------------------------------- Hypothesis cross-check on the exact port
# FV-LIQ-02 verifies: SPEC-LIQ-004, REQ-SWAP-016, REQ-SWAP-005
@st.composite
def accounts(draw):
    dv = draw(st.sampled_from([6, 8, 12, 18]))
    dd = draw(st.sampled_from([6, 8, 18]))
    pc = draw(st.integers(10**4, 10**12))
    pdebt = draw(st.integers(10**6, 10**12))
    idx = draw(st.integers(RAY, 3 * RAY))
    drawn = draw(st.integers(1, 10**28))
    prem = draw(st.integers(0, 10**24 * RAY))
    sup = draw(st.integers(1, 10**30))
    hf = draw(st.integers(5 * 10**17, WAD - 1))
    cf = draw(st.integers(1, 9000))
    maxlb = draw(st.integers(BPS, 11000))
    fac = draw(st.integers(0, BPS))
    total_debt_value_ray = (drawn * idx + prem) * pdebt * 10 ** (18 - dd)
    x = draw(st.integers(1, 10**30))
    return A.Params(supplied_shares=sup, coll_A=10**30, coll_S=10**30, coll_decimals=dv, coll_price=pc,
                    drawn_shares=drawn, premium_debt_ray=prem, drawn_index=idx,
                    total_debt_value_ray=total_debt_value_ray, debt_decimals=dd, debt_price=pdebt, debt_to_cover=x,
                    collateral_factor=cf, hf_for_max_bonus=9 * 10**17, bonus_factor=fac, max_lb=maxlb,
                    target_hf=11 * 10**17, hf=hf)


HYP = {"runs": 0, "ok": True, "detail": ""}


@settings(max_examples=4000, deadline=None, derandomize=True, suppress_health_check=list(HealthCheck))
@given(accounts())
def _cross(p):
    try:
        r = A.liquidation_call(p)
    except (A.AaveRevert, ValueError):
        return
    HYP["runs"] += 1
    k1 = p.debt_price * 10**p.coll_decimals * r["lb"]
    k2 = 10**p.debt_decimals * p.coll_price * BPS * RAY
    c_, d_ = r["c"], r["D"]
    ok = (c_ * k2 <= d_ * RAY * k1 and (c_ + 1) * k2 > (d_ * RAY - p.drawn_index - 2 * RAY) * k1 - k1
          and d_ <= p.debt_to_cover and c_ <= p.supplied_shares)
    if not ok and HYP["ok"]:
        HYP["ok"], HYP["detail"] = False, f"{p} -> {r}"


_cross()
check("FV-LIQ-02n", f"Hypothesis cross-check of FV-LIQ-02a..j on the exact Aave port ({HYP['runs']} successful calls)",
      HYP["ok"] and HYP["runs"] > 200, HYP["detail"])



# ================================================================ Lens liquidation preview (2.17)
P8, E18, E6 = 10**8, 10**18, 10**6

# ---------------------------------------------------------------- expectedUnitsSeized = Aave's seizure (REQ-LENS-029)
# All-collateral branches (i) and (ii): Aave sets the seizure to the supplied shares. REQ-LENS-029 recomputes it
# from the drawnShares and premiumDebtRay the sizing returns, floor((drawn*index + premium)*K1/K2), and caps it at
# the supplied shares. The recomputed debt is at least ceil(supplied*K2/K1), so the cap always binds.
lensI, hI = floor_q("lensSharesBranchI", prem_i * K1, K2)
lensII, hII = floor_q("lensSharesBranchII", (Pi + premTot) * K1, K2)
# FV-LIQ-02 verifies: REQ-LENS-029, REQ-LENS-017
prove("FV-LIQ-02q", "REQ-LENS-029 in the all-collateral branches (i) and (ii): the seizure recomputed from the returned "
      "drawnShares and premiumDebtRay is at least the supplied shares, so the capped Lens value equals Aave's "
      "seizure (supplied shares) exactly",
      [z3.Or(z3.And(*(branch_i + hI)), z3.And(*(branch_ii + hII)))],
      z3.If(debtRay <= premTot, z3.If(lensI <= sup, lensI, sup), z3.If(lensII <= sup, lensII, sup)) == sup)

# Mutant: the earlier text computed the seizure from D = rayMulUp(drawn, index) + fromRayUp(premium).
# Pinned to the F-04 account: GHO debt, drawnIndex = 1.5 RAY + 1, debtToCover = 100 GHO, Pc = 2.00, dv = 6, LB 10,200.
idx0 = 3 * RAY // 2 + 1
cOld, hOld = floor_q("seizureFromD", D * RAY * K1, K2)
f04 = target + hOld + [idx == idx0, P == ((100 * E18 * RAY) // idx0) * idx0, prem == 0,
                       K1 == P8 * 10**6 * 10_200, K2 == E18 * 2 * P8 * BPS * RAY]
expect_violation("FV-LIQ-02r", "mutation: seizure computed from D (the earlier REQ-LENS-029 text) on the F-04 account; "
                 "it differs from Aave's seizure from drawnShares x drawnIndex (50,999,999 vs 51,000,000 units)",
                 f04, cOld == c, show=[c, cOld, D], label="mutant")


@st.composite
def seizures(draw):
    dv = draw(st.sampled_from([6, 8, 18]))
    dd = draw(st.sampled_from([6, 18]))
    idx = draw(st.one_of(st.just(RAY), st.integers(RAY, 3 * RAY)))
    drawn = draw(st.integers(1, 10**28))
    prem = draw(st.one_of(st.just(0), st.integers(0, 10**24 * RAY)))
    return A.account(supplied_shares=draw(st.integers(1, 10**30)), coll_price=draw(st.integers(10**4, 10**12)),
                     coll_decimals=dv, collateral_factor=draw(st.integers(1, 9000)), drawn_shares=drawn,
                     premium_debt_ray=prem, drawn_index=idx, debt_price=draw(st.integers(10**6, 10**12)),
                     debt_decimals=dd, debt_to_cover=1, other_debt_value_ray=draw(st.sampled_from([0, 10**30 * RAY])),
                     max_lb=draw(st.integers(BPS, 11_500)), bonus_factor=draw(st.integers(0, BPS)),
                     liquidation_fee=draw(st.sampled_from([0, 0, 1000, 2500, BPS])))


SZ = {"runs": 0, "ok": True, "detail": "", "branches": {}}


@settings(max_examples=6000, deadline=None, derandomize=True, suppress_health_check=list(HealthCheck))
@given(seizures())
def _seizure(p):
    if p.hf >= WAD:
        return
    try:
        lp = A.lens_preview(p, is_gho=(p.debt_decimals == 18 and p.debt_price == P8))
    except A.AaveRevert:
        return
    SZ["runs"] += 1
    SZ["branches"][lp["branch"]] = SZ["branches"].get(lp["branch"], 0) + 1
    aave = lp["aave"]
    if not (lp["units"] == aave["c"] and lp["expected_debt_repaid"] == aave["D"]) and SZ["ok"]:
        SZ["ok"], SZ["detail"] = False, f"{p} lens={lp['units']} aave={aave['c']}"


_seizure()
# FV-LIQ-02 verifies: REQ-LENS-029, REQ-LENS-017
check("FV-LIQ-02o", f"F-04 fixed: REQ-LENS-029 expectedUnitsSeized equals the units Aave's liquidationCall pays "
      f"(fee part removed) and expectedDebtRepaid equals Aave's D, on the exact port (Hypothesis, {SZ['runs']} "
      f"liquidatable accounts, branches {SZ['branches']}; branch (iii) is the same formula as Aave's and 02q covers "
      f"branches (i) and (ii) for all inputs)",
      SZ["ok"] and SZ["runs"] > 1000 and len(SZ["branches"]) >= 2, SZ["detail"])

# ---------------------------------------------------------------- ready-to-send debtToCover (REQ-LENS-028, REQ-SWAP-005)
# Whole debt T = rayMulUp(drawnShares, index) + fromRayUp(premium). Aave's D in every branch uses drawn <= drawnShares
# and premium <= premiumDebtRay, and a repay lowers both, so at the same index D' <= T' <= T.
drs, prs, drs2, prs2, d2, p2_ = z3.Ints("drawnShares premiumRay drawnSharesAfter premiumRayAfter drawnLiq premiumLiq")
T0, hT0 = ceil_q("ceilDrawnBefore", drs * idx, RAY)
T1, hT1 = ceil_q("ceilPremBefore", prs, RAY)
U0, hU0 = ceil_q("ceilDrawnLiq", d2 * idx, RAY)
U1, hU1 = ceil_q("ceilPremLiq", p2_, RAY)
same_index = base + hT0 + hT1 + hU0 + hU1 + [drs > 0, prs >= 0, drs2 >= 0, drs2 <= drs, prs2 >= 0, prs2 <= prs,
                                             d2 >= 0, d2 <= drs2, p2_ >= 0, p2_ <= prs2]
# FV-LIQ-02 verifies: REQ-LENS-028, REQ-SWAP-005, REQ-LENS-017
prove("FV-LIQ-02s", "F-05 fixed, whole-debt quote: with debtToCover = getUserTotalDebt at preview, any repay or new pledge "
      "at the same drawn index leaves Aave's pulled debt D' <= debtToCover, so MustNotLeaveDust never fires (every GHO "
      "preview, every whole-debt preview and every non-GHO preview inside the margin)",
      same_index, U0 + U1 <= T0 + T1)

# Non-GHO preview outside the margin: debtToCover = expectedDebtRepaid = D0 with value(T - D0) * 1e4 >= DUST * 10,500.
# A front-run repay of r base units with value(r + 2) <= 5 % of DUST keeps Aave's ray remainder after a liquidation
# capped at D0 at or above DUST, so the dust rule never asks for the whole debt.
vunit, T, D0, r_, remRay, liqRay = z3.Ints("valuePerUnit wholeDebt expectedRepaid repaid remainderRay liquidatedRay")
DUST = A.DUST_LIQUIDATION_THRESHOLD
margin = z3.Int("marginBps")
debt_dust = [vunit > 0, T > D0, D0 > 0, r_ >= 0, r_ < T - D0,
             (T - D0) * vunit * BPS >= DUST * (BPS + margin),
             (r_ + 2) * vunit * BPS <= DUST * margin,
             liqRay <= D0 * RAY,                                   # capped at debtToCover (drawnSharesToCover floors)
             remRay + liqRay >= (T - r_ - 2) * RAY]                # ray debt after the repay >= (T - r - 2) units
prove("FV-LIQ-02t", "F-05 fixed, near-threshold margin: with LENS_DUST_MARGIN_BPS = 500 and a remainder outside the "
      "margin, a front-run repay worth less than 5 % of DUST_LIQUIDATION_THRESHOLD (2 units of rounding included) "
      "leaves Aave's remainder >= DUST, so the quoted expectedDebtRepaid is never raised to the whole debt",
      debt_dust + [margin == A.LENS_DUST_MARGIN_BPS], remRay * vunit >= DUST * RAY)
expect_violation("FV-LIQ-02u", "mutation: LENS_DUST_MARGIN_BPS = 0 (debtToCover = expectedDebtRepaid at the boundary, "
                 "the earlier text and the F-05 account); a 1-wei repay leaves a remainder below DUST and Aave asks for "
                 "the whole debt", debt_dust[:5] + [(T - D0) * vunit * BPS >= DUST * BPS, r_ == 1] + debt_dust[7:]
                 + [remRay + liqRay == (T - r_) * RAY, liqRay == D0 * RAY],
                 remRay * vunit >= DUST * RAY, show=[T, D0, vunit, remRay], label="mutant")


# Exact port: Lens params under same-index front-runs (1-wei repay, a repay worth up to $45, a pledge).
@st.composite
def previews(draw):
    gho = draw(st.booleans())
    dd = 18 if gho else draw(st.sampled_from([6, 18]))
    pd = P8 if gho else draw(st.integers(5 * 10**7, 4000 * P8))
    dv = draw(st.sampled_from([6, 18]))
    pc = draw(st.integers(10**6, 10**11))
    idx = draw(st.one_of(st.just(RAY), st.integers(RAY, 2 * RAY)))
    usd = draw(st.one_of(st.integers(1, 3000), st.integers(900, 1200), st.integers(1000, 10**5)))
    drawn = max(1, usd * 10**dd * P8 // pd * RAY // idx)
    prem = draw(st.one_of(st.just(0), st.integers(0, 50 * 10**dd * RAY)))
    cf = draw(st.integers(1000, 9000))
    hf_t = draw(st.integers(3 * 10**17, 99 * 10**16))
    sup = max(1, (usd * hf_t * BPS // (cf * WAD) + 1) * 10**dv * P8 // pc)
    other = draw(st.sampled_from([0, 0, 10**4 * 10**26 * RAY]))
    kind = draw(st.sampled_from(["repay1", "repay", "pledge"]))
    amt = draw(st.integers(1, 45 * 10**dd * P8 // pd + 1))
    extra = draw(st.integers(1, max(1, sup // 100)))
    return gho, (sup, pc, dv, cf, drawn, prem, idx, pd, dd, other), kind, amt, extra


FR = {"runs": 0, "ok": True, "detail": "", "cases": {}, "collateral_limited_outside": 0}


def _after(acct, kind, amt, extra, x, idx_after=None, prem_after=None):
    sup, pc, dv, cf, drawn, prem, idx, pd, dd, other = acct
    if idx_after is not None:
        idx, prem = idx_after, prem_after
    if kind == "repay1":
        drawn, prem = A.repay_restore(drawn, prem, idx, 1)
    elif kind == "repay":
        drawn, prem = A.repay_restore(drawn, prem, idx, amt)
    elif kind == "pledge":
        sup += extra
    if drawn == 0:
        return None
    return A.account(sup, pc, dv, cf, drawn, prem, idx, pd, dd, x, other_debt_value_ray=other)


@settings(max_examples=8000, deadline=None, derandomize=True, suppress_health_check=list(HealthCheck))
@given(previews())
def _frontrun(case):
    gho, acct, kind, amt, extra = case
    p = A.account(*acct[:9], debt_to_cover=1, other_debt_value_ray=acct[9])
    if p.hf >= WAD:
        return
    lp = A.lens_preview(p, gho)
    if not gho and lp["collateral_limited"] and lp["expected_debt_repaid"] < lp["total"] and not lp["near"]:
        FR["collateral_limited_outside"] += 1      # quoted with the margin since FV-LIQ-F-14 (FV-LIQ-02y, 02z)
    q = _after(acct, kind, amt, extra, lp["debt_to_cover"])
    if q is None or q.hf >= WAD:
        return
    try:
        A.liquidation_call(q)
        res = "ok"
    except A.AaveRevert as e:
        res = str(e)
    FR["runs"] += 1
    key = ("GHO" if gho else "non-GHO") + (" whole" if lp["expected_debt_repaid"] == lp["total"] else
                                          " X=T" if lp["debt_to_cover"] != lp["expected_debt_repaid"] else " X=D0")
    FR["cases"][key] = FR["cases"].get(key, 0) + 1
    if res != "ok" and FR["ok"]:
        FR["ok"], FR["detail"] = False, f"{case} -> {res}"


_frontrun()
# FV-LIQ-02 verifies: REQ-LENS-028, REQ-SWAP-005, REQ-LENS-017
check("FV-LIQ-02v", f"F-05 fixed on the exact port: the Lens params (REQ-LENS-028) never revert MustNotLeaveDust after a "
      f"1-wei repay, a repay worth up to $45 or a new pledge at the same drawn index (Hypothesis, {FR['runs']} "
      f"liquidations: {FR['cases']}; {FR['collateral_limited_outside']} of them collateral-limited non-GHO previews outside "
      f"the dust margin, quoted whole with the margin)", FR["ok"] and FR["runs"] > 2000 and len(FR["cases"]) >= 5, FR["detail"])

# The F-05 account (1,500 GHO, HF 0.70) and the REQ-LENS-028 near-threshold USDC case, replayed with the final rule.
def f05(debt_wei):
    return A.account(186_726 * 10**16, 2 * P8, 18, 2812, debt_wei, 0, RAY, P8, 18, 1)


lp05 = A.lens_preview(f05(1500 * E18), True)
q05 = A.account(186_726 * 10**16, 2 * P8, 18, 2812, 1500 * E18 - 1, 0, RAY, P8, 18, lp05["debt_to_cover"])
r05 = A.liquidation_call(q05)
# USDC (the REQ-LENS-028 example): 1,060 USDC owed, 26.25 vault tokens at $1 in the seized market, so Aave's sizing is
# collateral-limited at 25 USDC and leaves 1,035 USDC (< $1,050): the quote is the whole debt. A $40 repay front-run.
pu = A.account(26_250_000, P8, 6, 2812, 1060 * E6, 0, RAY, P8, 6, 1)
lpu = A.lens_preview(pu, False)
qd, qp = A.repay_restore(1060 * E6, 0, RAY, 40 * E6)
ru = A.liquidation_call(A.account(26_250_000, P8, 6, 2812, qd, qp, RAY, P8, 6, lpu["debt_to_cover"]))
usdc_ok = lpu["expected_debt_repaid"] == 25 * E6 and lpu["debt_to_cover"] == 1113 * E6 and ru["D"] <= 1020 * E6
usdc_detail = f"USDC D0={lpu['expected_debt_repaid']} X={lpu['debt_to_cover']} D'={ru['D']} ({ru['branch']})"
check("FV-LIQ-02v2", "F-05 account and the REQ-LENS-028 USDC case under the final rule: 1,500 GHO quoted whole with the "
      "margin (1,575 GHO), the 1-wei repay then leaves Aave a 1,499.999... GHO whole-debt liquidation that the quote "
      "covers; 1,060 USDC with a remainder of 1,035 USDC (< $1,050) is quoted ceil(1,060 x 1.05) = 1,113 USDC and "
      "settles after a $40 repay front-run",
      lp05["debt_to_cover"] == 1575 * E18 and r05["D"] == 1500 * E18 - 1 and usdc_ok,
      f"GHO D'={r05['D']}; {usdc_detail}")

# ---------------------------------------------------------------- later block: the drawn index grows
# FV-LIQ-02 verifies: REQ-LENS-028, REQ-SWAP-005
idx2 = z3.Int("drawnIndexLaterBlock")
prs3 = z3.Int("premiumRayLaterBlock")
W0, hW0 = ceil_q("ceilDrawnLater", drs * idx2, RAY)
W1, hW1 = ceil_q("ceilPremLater", prs3, RAY)
later = base + hT0 + hT1 + hW0 + hW1 + [drs >= 10**18, prs >= 0, idx2 > idx, prs3 >= prs]
expect_violation("FV-LIQ-02x", "mutation (the REQ-LENS-028 text before FV-LIQ-F-13): a whole-debt preview without the "
                 "margin (debtToCover = getUserTotalDebt) included in a later block, after the drawn index has grown, quotes less than the whole debt Aave then requires "
                 "(T' > debtToCover), so liquidationCall reverts MustNotLeaveDust; REQ-LENS-028 requires the params to "
                 "stay valid in a later block (shown: at least 1 whole token of drawn shares, index growth at most 1e-9)",
                 later + [idx2 * 10**9 <= idx * (10**9 + 1)], W0 + W1 <= T0 + T1, show=[drs, idx, idx2, T0, W0], label="mutant")
# Concrete: 900 GHO owed at HF 0.90 (any partial liquidation leaves < $1,000, so Aave takes the whole debt); the next
# block's index is 1.00000001 RAY (5 % a year over about 6 seconds).
pA = A.account(900 * E18 * 9 * BPS // (10 * 2812 * 2), 2 * P8, 18, 2812, 900 * E18, 0, RAY, P8, 18, 1)
lpA = A.lens_preview(pA, True)
idxA = RAY + RAY // 10**8
qA = A.account(pA.supplied_shares, 2 * P8, 18, 2812, 900 * E18, 0, idxA, P8, 18, lpA["old_debt_to_cover"])
try:
    A.liquidation_call(qA)
    revA = ""
except A.AaveRevert as e:
    revA = str(e)
fixA = A.account(pA.supplied_shares, 2 * P8, 18, 2812, 900 * E18, 0, idxA, P8, 18, lpA["debt_to_cover"])
check("FV-LIQ-02x2", "REQ-LENS-028 (final) on the F-13 account: 900 GHO at HF 0.90; the Lens quotes debtToCover = "
      "ceil(900 x 1.05) = 945 GHO; one block later (index x 1.00000001) the whole debt is 900.000009 GHO and the call "
      "settles it; the old unmargined quote of 900 GHO reverts MustNotLeaveDust (mutant)",
      lpA["expected_debt_repaid"] == lpA["total"] == 900 * E18 and lpA["debt_to_cover"] == 945 * E18
      and revA == "MustNotLeaveDust"
      and A.liquidation_call(fixA)["D"] == A.get_user_total_debt(900 * E18, 0, idxA),
       f"hf={pA.hf} X={lpA['debt_to_cover']} T'={A.get_user_total_debt(900 * E18, 0, idxA)} -> {revA}")

# ---------------------------------------------------------------- collateral-limited non-GHO preview
# All-collateral branch: D is set by the collateral, debtRay = ceil(supplied*K2/K1). A pledge raises it above the
# quoted expectedDebtRepaid; with a debt remainder outside the margin REQ-LENS-028 quotes exactly that amount.
sup2 = z3.Int("suppliedAfterPledge")
debtRay2, hP = ceil_q("debtRayAfterPledge", sup2 * K2, K1)
dPl, hPl = ceil_q("ceilDebtRay", debtRay, RAY)
dPl2, hPl2 = ceil_q("ceilDebtRayAfterPledge", debtRay2, RAY)
expect_violation("FV-LIQ-02y", "mutation (the REQ-LENS-028 text before FV-LIQ-F-14): for a non-GHO preview whose seizure takes all the market's collateral "
                 "(all-collateral branch) and leaves a debt remainder outside the margin, debtToCover = "
                 "expectedDebtRepaid; a pledge into the market before inclusion raises the debt Aave sizes from the "
                 "collateral above it, so liquidationCall reverts MustNotLeaveDust (REQ-SWAP-005 says a new pledge "
                 "does not); shown with at least 1e18 shares and a pledge of at most 1 %",
                 caps + h4 + hP + hPl + hPl2 + [sup >= 10**18, sup2 > sup, sup2 * 100 <= sup * 101],
                 dPl2 <= dPl, show=[sup, sup2, dPl, dPl2], label="mutant")
# Concrete: 20,000 USDC owed against 400 vault tokens at $2 (CF 0.2812): all 400 seized for 761.904762 USDC,
# 19,238 USDC stays as debt, so debtToCover = 761.904762 USDC; the borrower pledges 5 more vault tokens ($10).
acctB = (400 * E18, 2 * P8, 18, 2812, 20_000 * E6, 0, RAY, P8, 6)
pB = A.account(*acctB, debt_to_cover=1)
lpB = A.lens_preview(pB, False)
qB = A.account(405 * E18, *acctB[1:], debt_to_cover=lpB["old_debt_to_cover"])
try:
    A.liquidation_call(qB)
    revB = ""
except A.AaveRevert as e:
    revB = str(e)
fixB = A.account(405 * E18, *acctB[1:], debt_to_cover=lpB["debt_to_cover"])
rfB = A.liquidation_call(fixB)
check("FV-LIQ-02y2", "REQ-LENS-028 (final) on the F-14 account: 20,000 USDC owed against 400 vault tokens at $2; the "
      "sizing seizes all collateral for 761.904762 USDC, so the Lens quotes debtToCover = 21,000 USDC; after a $10 "
      "pledge Aave sizes 771.428572 USDC and the call settles; the old quote of 761.904762 USDC reverts "
      "MustNotLeaveDust (mutant)",
      lpB["collateral_limited"] and lpB["old_debt_to_cover"] == lpB["expected_debt_repaid"] == 761_904_762
      and lpB["debt_to_cover"] == 21_000 * E6
       and revB == "MustNotLeaveDust" and rfB["D"] == 771_428_572,
       f"X={lpB['debt_to_cover']} -> {revB}; with whole-debt quote D'={rfB['D']} branch={rfB['branch']}")

# ---------------------------------------------------------------- corrected quote (recommended REQ-LENS-028 text)
# debtToCover = ceil(T x (1e4 + LENS_DUST_MARGIN_BPS) / 1e4) for a GHO reserve, a whole-debt preview, a preview
# inside the margin and a collateral-limited preview; expectedDebtRepaid otherwise.
g = z3.Int("growthBps")
Xfix, hXfix = ceil_q("quoteWithMargin", (T0 + T1) * (BPS + A.LENS_DUST_MARGIN_BPS), BPS)
grow = [g >= 0, g < A.LENS_DUST_MARGIN_BPS, idx2 * BPS <= idx * (BPS + g), prs3 * BPS <= prs * (BPS + g),
        (A.LENS_DUST_MARGIN_BPS - g) * (T0 + T1) >= 2 * BPS]
# FV-LIQ-02 verifies: REQ-LENS-028, REQ-SWAP-005
prove("FV-LIQ-02w", "REQ-LENS-028 (final) against FV-LIQ-02x/02y: debtToCover = ceil(T x 10,500 / 10^4) is at least the whole debt "
      "in any later block whose index and premium growth g stays below the 500 bps margin (with (500 - g) bps of T at least "
      "2 base units of rounding), so Aave's D' <= T' <= debtToCover",
      [z3.And(*(later + hXfix + grow))], W0 + W1 <= Xfix)


@st.composite
def later_blocks(draw):
    case = draw(previews())
    growth = draw(st.sampled_from([0, 1, 10, 100, 400]))   # bps of index growth before inclusion
    kind = draw(st.sampled_from(["none", "repay1", "repay", "pledge"]))
    return case, growth, kind


FX = {"runs": 0, "ok": True, "detail": "", "old_reverts": 0}


@settings(max_examples=8000, deadline=None, derandomize=True, suppress_health_check=list(HealthCheck))
@given(later_blocks())
def _corrected(c):
    (gho, acct, _, amt, extra), growth, kind = c
    p = A.account(*acct[:9], debt_to_cover=1, other_debt_value_ray=acct[9])
    if p.hf >= WAD:
        return
    lp = A.lens_preview(p, gho)
    x = lp["debt_to_cover"]                     # final REQ-LENS-028 quote
    idx, prem = acct[6], acct[5]
    idx_l = idx + idx * growth // BPS
    prem_l = prem + (prem // idx) * (idx_l - idx)
    q = _after(acct, kind, amt, extra, x, idx_l, prem_l)
    q_old = _after(acct, kind, amt, extra, lp["old_debt_to_cover"], idx_l, prem_l)
    if q is None or q.hf >= WAD:
        return
    FX["runs"] += 1
    try:
        A.liquidation_call(q_old)
    except A.AaveRevert as e:
        FX["old_reverts"] += str(e) == "MustNotLeaveDust"
    try:
        A.liquidation_call(q)
    except A.AaveRevert as e:
        if FX["ok"]:
            FX["ok"], FX["detail"] = False, f"{c} -> {e}"


_corrected()
# FV-LIQ-02 verifies: REQ-LENS-028, REQ-SWAP-005
check("FV-LIQ-02z", f"REQ-LENS-028 (final) on the exact port: no MustNotLeaveDust after index growth of 0-400 bps combined with "
      f"a 1-wei repay, a repay up to $45 or a pledge (Hypothesis, {FX['runs']} liquidations; the unmargined quote of the "
      f"text before FV-LIQ-F-13 reverts in {FX['old_reverts']} of them)", FX["ok"] and FX["runs"] > 2000 and FX["old_reverts"] > 0,
      FX["detail"])

finish()
