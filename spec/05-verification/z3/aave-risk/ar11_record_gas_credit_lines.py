# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-CAP-09, MATH-CAP-10 — Record cap against the per-transaction gas limit, the Lens borrow capacity
(recommended at HF 1.10, maximum at HF 1.00), and the cross-Hub credit-line sum of the RiskModule.

Spec: SPEC-CHAIN-001 (per-chain gas model of one liquidation, in gas units) with the record cap
`AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET = 16` (`TooManyRecords`), SPEC-CAP-009 (account debt value against the
borrow capacity `capRay = floor(totalCollateralValue * RAY * avgCollateralFactor / WAD)`; Q-396 removed the idle
test and Q-398 makes the Lens preview a recommended borrow at HF 1.10 beside the maximum at HF 1.00), and SPEC-CAP-010 (sum of drawCaps per
(funding Hub, asset) against the line and the line against first-loss coverage).
Units: gas units for MATH-CAP-09; whole tokens for drawCaps and lines; base units for funded balances.

Changed on 2026-11-10 (Q-381): Avana has no minimum debt, so MATH-CAP-09 no longer checks a minimum-debt gate or a
keeper break-even. It now checks that the record cap keeps every account liquidatable in one transaction (the pledge
check refuses a new record at 16, and one liquidation of an account with n <= 16 records needs
G(n) = 1,310,000 + 240,000 * n <= 16,777,216 / 2 gas units). MATH-CAP-09e..h checked the idle test until
Q-396 removed it (cap squatting by a non-borrowing LP, AMMN-FLOW-16, is an accepted risk handled by listing caps and
monitoring); they now check the Lens capacity figures of Q-398.

MATH-CAP-09 verifies: SPEC-CHAIN-001, SPEC-CAP-009, INV-096, REQ-RISK-080, AMMN-GAS-01, AMMN-FLOW-16, Q-396, Q-398
MATH-CAP-10 verifies: SPEC-CAP-010, REQ-RISK-082, REQ-CONFIG-081
"""
from z3 import And, Ints, Reals, If, Not
from _common import prove, computed, finish

# ---------------------------------------------------------------------------
# MATH-CAP-09  Record cap and the per-transaction gas limit.
BASE, PER_RECORD, CAP, TX_LIMIT = 1_310_000, 240_000, 16, 16_777_216 // 2
before, after, nrec = Ints('recordsBefore recordsAfter records')
# The pledge check: a new record is refused unless recordsBefore < 16; a pledge adds at most one record.
gate = [before >= 0, before < CAP, after >= before, after <= before + 1]
prove('MATH-CAP-09a', 'a pledge that passes the record check (recordsBefore < 16, at most one new record) leaves at most 16 records',
      gate,
      after <= CAP)
prove('MATH-CAP-09b', 'an account with at most 16 records is liquidated in one transaction: G(n) = 1,310,000 + 240,000 n <= 16,777,216 / 2',
      [nrec >= 0, nrec <= CAP],
      BASE + PER_RECORD * nrec <= TX_LIMIT)
prove('MATH-CAP-09c', 'the gas model is monotone in the record count: fewer records never need more gas',
      [nrec >= 0, before >= 0, before <= nrec],
      BASE + PER_RECORD * before <= BASE + PER_RECORD * nrec)
computed('MATH-CAP-09d', 'SPEC-CHAIN-001 worked figures (gas units)', [
    ('G(16)', 5_150_000, BASE + PER_RECORD * CAP),
    ('G(16) <= 8,388,608 (half the per-transaction limit)', True, BASE + PER_RECORD * CAP <= TX_LIMIT),
    ('headroom to half the limit', 3_238_608, TX_LIMIT - (BASE + PER_RECORD * CAP)),
    ('largest record count within half the limit', 29, (TX_LIMIT - BASE) // PER_RECORD),
    ('G(125), an uncapped list of about 125 records', 31_310_000, BASE + PER_RECORD * 125),
    ('G(125) > 16,777,216', True, BASE + PER_RECORD * 125 > TX_LIMIT),
])

# SPEC-CAP-009 / Q-398 Lens capacity, exact integers: capRay = floor(tcv * RAY * acf / WAD) is the maximum debt value
# at HF 1.00; the recommended debt value at HF 1.10 is recRay = floor(capRay * 100 / 110).
RAY, WAD = 10**27, 10**18
tcv, acf, dRay, recRay, capRay = Ints('totalCollateralValue avgCollateralFactor totalDebtValueRay recRay capRay')
cap_def = [tcv >= 0, acf >= 0, acf <= WAD, capRay * WAD <= tcv * RAY * acf, tcv * RAY * acf < (capRay + 1) * WAD]
rec_def = [recRay * 110 <= capRay * 100, capRay * 100 < (recRay + 1) * 110]
prove('MATH-CAP-09e', 'the floored maximum never overstates: debt <= capRay implies debt * WAD <= tcv * RAY * acf (HF >= 1.00 exactly)',
      cap_def + [dRay >= 0, dRay <= capRay],
      dRay * WAD <= tcv * RAY * acf)
prove('MATH-CAP-09f', 'the recommended borrow never exceeds the maximum (recRay <= capRay)',
      cap_def + rec_def, recRay <= capRay)
prove('MATH-CAP-09g', 'debt within the recommended borrow keeps the exact HF >= 1.10 (debt * 1.10 * WAD <= tcv * RAY * acf)',
      cap_def + rec_def + [dRay >= 0, dRay <= recRay],
      dRay * 110 * WAD <= 100 * tcv * RAY * acf)
cap_ex = 9 * 10**31 * RAY * (312 * 10**15) // WAD
cap_q = 10**31 * RAY * (70 * 10**16) // WAD
computed('MATH-CAP-09h', 'SPEC-CAP-009 / Q-398 worked examples ($900,000 at CF 0.312; $100,000 at CF 0.70)', [
    ('capRay ($280,800 maximum at HF 1.00)', 2808 * 10**55, cap_ex),
    ('recommended at HF 1.10: $255,272 (dollars, down)', 255_272, cap_ex * 100 // 110 // (10**26 * RAY)),
    ('$100,000 at CF 70%: maximum $70,000', 70_000, cap_q // (10**26 * RAY)),
    ('$100,000 at CF 70%: recommended $63,636', 63_636, cap_q * 100 // 110 // (10**26 * RAY)),
])

# ---------------------------------------------------------------------------
# MATH-CAP-10  SPEC-CAP-010: sum(h, a) = sum of drawCaps <= line(h, a); line * 10^dec * coverageRatioBps <= funded * 10^4.
c1, c2, c3, line, cov, funded, dpow, delta = Reals('drawCap1 drawCap2 drawCap3 line coverageRatioBps funded tenPowDec delta')
caps = [c1 >= 0, c2 >= 0, c3 >= 0, line >= 0, cov > 0, cov <= 10**4, funded >= 0, dpow >= 1]
total = c1 + c2 + c3
prove('MATH-CAP-10a', 'sum <= line and line*10^dec*coverageRatioBps <= funded*10^4  =>  sum*10^dec*coverageRatioBps <= funded*10^4 (every drawer together stays inside first-loss coverage)',
      caps + [total <= line, line * dpow * cov <= funded * 10**4],
      total * dpow * cov <= funded * 10**4)
prove('MATH-CAP-10b', 'a drawCap raise that passes the sum test on a covered line stays inside coverage (syncDrawCap records every raise; the sum and the coverage are two separate gates and no third test is needed)',
      caps + [delta >= 0, total + delta <= line, line * dpow * cov <= funded * 10**4],
      (total + delta) * dpow * cov <= funded * 10**4)
f2, cov2 = Reals('funded2 coverageRatioBps2')
prove('MATH-CAP-10c', 'the coverage bound is monotone: more funded coverage or a lower coverageRatioBps keeps a passing line passing',
      caps + [line * dpow * cov <= funded * 10**4, f2 >= funded, cov2 > 0, cov2 <= cov],
      line * dpow * cov2 <= f2 * 10**4)
MAXCAP = 2**40 - 1  # Aave MAX_ALLOWED_SPOKE_CAP sentinel: counts as unbounded
cap_eff = If(c3 == MAXCAP, line + 1, c3)
prove('MATH-CAP-10d', 'a drawer at MAX_ALLOWED_SPOKE_CAP counts as unbounded and always fails the sum test',
      caps + [c3 == MAXCAP, line < MAXCAP],
      c1 + c2 + cap_eff > line)

computed('MATH-CAP-10e', 'SPEC-CAP-010 worked example (GHO line of the Ethereum Stable LP Hub)', [
    ('same-Hub drawCaps + cross-Hub request', 21_000_000, 12_000_000 + 9_000_000),
    ('refused: 21,000,000 > line 20,000,000', True, 12_000_000 + 9_000_000 > 20_000_000),
    ('largest cross-Hub drawCap that fits', 8_000_000, 20_000_000 - 12_000_000),
    ('funded GHO base units needed for the line at 2,000 bps', 4_000_000 * 10**18, -(-20_000_000 * 10**18 * 2_000 // 10**4)),
])

# MATH-CAP-10 verifies: DEF-019, DEF-011, DEF-018, DEF-023
E18 = 10**18
covered = lambda caps, f: caps * E18 * 2_000 <= f * 10**4
computed('MATH-CAP-10f', 'launch firstLossReserveMinimum = coverageRatioBps x initial drawCap; DEF-019, DEF-018 and DEF-023 examples', [
    ('Ethereum GHO minimum for the 2,000,000 GHO drawCap', 400_000 * E18, -(-2_000_000 * E18 * 2_000 // 10**4)),
    ('Base GHO minimum for 120,000 GHO of drawCaps', 24_000 * E18, -(-120_000 * E18 * 2_000 // 10**4)),
    ('DEF-019: 2,000,000 x 10^18 x 2,000 = 400,000 x 10^18 x 10^4', True, 2_000_000 * E18 * 2_000 == 400_000 * E18 * 10**4),
    ('DEF-019: drawCaps of 2,050,000 GHO need F >= 410,000 GHO', 410_000 * E18, -(-2_050_000 * E18 * 2_000 // 10**4)),
    ('DEF-023: 399,523.81 GHO fails the bound', False, covered(2_000_000, 399_523_81 * 10**16)),
    ('DEF-023: after fund(477), 400,000.81 GHO passes', True, covered(2_000_000, (399_523_81 + 477_00) * 10**16)),
    ('DEF-018: 398,750 GHO fails the bound', False, covered(2_000_000, 398_750 * E18)),
])

# MATH-CAP-10g  REQ-CONFIG-081 implementation of the coverage test (creditLineCoverage, recordCreditLine, enableDebtReserve):
# k = 10^dec * coverageRatioBps, required = (line*k + 10^4 - 1) div 10^4 unless line > (M - 10^4) div k (k != 0), where
# required = M = 2^256 - 1 (saturated, fail closed). Integers.
gl, gk, gf = Ints('line k funded')
M = 2**256 - 1
B = 10**4
sat_branch = And(gk != 0, gl > (M - B) / gk)
exact_req = (gl * gk + B - 1) / B
prove('MATH-CAP-10g', 'unsaturated branch: line*k + 10^4 - 1 fits 256 bits, so the computed required is the exact ceiling',
      [gl >= 0, gk >= 0, gk <= M, Not(sat_branch)],
      gl * gk + B - 1 <= M)
prove('MATH-CAP-10h', 'saturated branch fails closed: the product line*k exceeds 2^256 - 1 - 10^4 and the registry refuses the line for every balance below 2^256 - 1 (required = 2^256 - 1 > funded)',
      [gl >= 0, gk >= 1, gk <= M, gf >= 0, gf < M, sat_branch],
      And(gl * gk > M - B - gk, Not(M <= gf)))
prove('MATH-CAP-10i', 'ceiling identity: required <= funded  <=>  line*k <= funded*10^4 (the spec inequality), for the unsaturated branch',
      [gl >= 0, gk >= 0, gf >= 0, Not(sat_branch)],
      (exact_req <= gf) == (gl * gk <= gf * B))

# MATH-CAP-10 verifies: REQ-RISK-082
# The borrow gate of a cross-Hub reserve reads creditLineCoverage and refuses when required > funded (2.7 example).
dai_required = -(-1_000_000 * E18 * 2_000 // 10**4)
computed('MATH-CAP-10j', 'REQ-RISK-082 example: a 1,000,000 DAI line at 2,000 bps requires 2x10^23; funded 2x10^23 passes, one base unit less fails', [
    ('required for 1,000,000 DAI at 2,000 bps', 2 * 10**23, dai_required),
    ('funded = required passes', True, dai_required <= 2 * 10**23),
    ('funded = required - 1 fails', False, dai_required <= 2 * 10**23 - 1),
])

finish()
