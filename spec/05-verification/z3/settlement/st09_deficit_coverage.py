# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-46..50, MATH-ST-61..62, MATH-ST-114: First-Loss coverage and withdrawal (SPEC-FLR-001..003).

Coverage Spoke (SPEC-FLR-001): amount = min(maxAmount, ceil(deficitRay / RAY), fundedBalance()), reverts if 0;
fundedBalance() = floor(callerShares (A+1e6) / (S+1e6)) (SPEC-FLR-002).

Aave V4 Hub.eliminateDeficit(assetId, amount, spoke) (pinned a3ef63e), caller = coverage Spoke:
  dRay  = amount < ceil(deficitRay_spoke / RAY) ? amount * RAY : deficitRay_spoke
  require caller active and dRay > 0                    (_validateEliminateDeficit; nothing else)
  dE    = ceil(dRay / RAY)                               GHO wei eliminated
  sh    = toAddedSharesUp(dE) = ceil(dE (S+1e6)/(A+1e6)) coverage shares burned
  callerShares -= sh   (uint120 checked: reverts if sh > callerShares)
  deficitRay_spoke -= dRay; deficitRay_asset -= dRay
totalAddedAssets A = liquidity + swept + ceil(owedRay / RAY) - fees, where owedRay includes
deficitRay; after elimination A' = A - (ceil(agg/RAY) - ceil((agg - dRay)/RAY)).
"""
from z3 import Ints, If, And, Or, Not
from _common import check, floor_div, ceil_div, done, RAY

VV = 10**6
amount, defS, defA, dRay, dE, sh, A, S, cs, agg, aggUp, aggUp2, A2, S2, base_, funded, maxAmt = Ints(
    "amount defS defA dRay dE sh A S callerShares agg aggUp aggUp2 A2 S2 base funded maxAmount")

defUp = Ints("defUp")[0]
model = [maxAmt >= 0, maxAmt < 2**128, defS >= 0, defS <= defA, defA < 2**200,
         S >= 1, S < 2**120, cs >= 0, cs <= S, base_ >= 0, base_ < 2**128,
         agg >= defA, agg < 2**200] \
    + ceil_div(defUp, defS, RAY) \
    + floor_div(funded, cs * (A + VV), S + VV) \
    + [amount == If(maxAmt < defUp, If(maxAmt < funded, maxAmt, funded), If(defUp < funded, defUp, funded)),
       amount > 0] \
    + [dRay == If(amount < defUp, amount * RAY, defS), dRay > 0] \
    + ceil_div(dE, dRay, RAY) \
    + ceil_div(aggUp, agg, RAY) + [A == base_ + aggUp] \
    + ceil_div(sh, dE * (S + VV), A + VV) \
    + ceil_div(aggUp2, agg - dRay, RAY) + [A2 == A - (aggUp - aggUp2), S2 == S - sh]

# MATH-ST-46 verifies: SPEC-FLR-001, DEF-POST-001, DEF-006, Q-101, Q-142
check("MATH-ST-46",
      "coverage never exceeds the covered Spoke's recorded deficit (in ray)",
      model + [dRay > defS],
      "PROVED")

# MATH-ST-47 verifies: SPEC-FLR-001, SPEC-FLR-002, DEF-POST-001, Q-101, Q-142
check("MATH-ST-47",
      "GHO eliminated <= funded balance, and shares burned <= shares held (the uint120 subtraction never reverts)",
      model + [Or(dE > funded, sh > cs)],
      "PROVED")

# MATH-ST-48 verifies: SPEC-FLR-001, Q-101
check("MATH-ST-48",
      "coverage pays less than 1 wei above the exact deficit (ceil of dRay / RAY)",
      model + [dE * RAY - dRay >= RAY],
      "PROVED")

# MATH-ST-49 verifies: SPEC-FLR-001, DEF-POST-001, Q-142
check("MATH-ST-49",
      "other suppliers' share price does not fall: (A'+1e6)/(S'+1e6) >= (A+1e6)/(S+1e6)",
      model + [(A2 + VV) * (S + VV) < (A + VV) * (S2 + VV)],
      "PROVED")

# MATH-ST-114 verifies: SPEC-FLR-001, REQ-FLR-018, Q-101
check("MATH-ST-114",
      "the Hub eliminates exactly the Coverage Spoke's amount (dE == amount), so adding amount to totalCovered "
      "before the call records what the Hub returns",
      model + [dE != amount],
      "PROVED")

# MATH-ST-50: the Hub checks only that the caller is an active Spoke and dRay > 0; it does
# not check that `spoke` is an approved Avana Borrow Spoke. Any Spoke on the Hub with a
# recorded deficit can be covered from the First-Loss shares unless a wrapper enforces it.
spokeApproved = Ints("spokeApproved")[0]
# MATH-ST-50 verifies: SPEC-FLR-001, DEF-005, Q-101, Q-142
check("MATH-ST-50",
      "the Hub alone accepts coverage of any Spoke's deficit; the Coverage Spoke's COVERAGE_ROLE and Spoke allowlist "
      "check carry the restriction (counterexample expected)",
      model + [spokeApproved == 0],
      "COUNTEREXAMPLE", show=[amount, defS, dRay, dE, sh])

# MATH-ST-61: withdrawal (SPEC-FLR-003): withdrawn = min(request, fundedBalance()); shares burned
# ceil(withdrawn (S+1e6)/(A+1e6)) never exceed the shares held.
req, wd, shw = Ints("request withdrawn sharesBurned")
wmodel = [S >= 1, S < 2**120, cs >= 0, cs <= S, A >= 0, A < 2**128, req >= 0, req < 2**128] \
    + floor_div(funded, cs * (A + VV), S + VV) + [wd == If(req < funded, req, funded)] \
    + ceil_div(shw, wd * (S + VV), A + VV)
# MATH-ST-61 verifies: SPEC-FLR-003, Q-101
check("MATH-ST-61",
      "withdrawal burns at most the shares held and never more than fundedBalance()",
      wmodel + [Or(shw > cs, wd > funded)],
      "PROVED")

# MATH-ST-62: funded balance (SPEC-FLR-002) moves by the amount funded, up to Hub rounding: after adding x
# (shares minted floor(x (S+1e6)/(A+1e6))), fundedBalance rises by at least x - 2 and at most x + 1.
x, mint, f2 = Ints("x minted funded_after")
fmodel = [S >= 1, S < 2**100, A >= S, A <= 2 * S, cs >= 0, cs <= S, x >= 0, x < 2**100] \
    + floor_div(funded, cs * (A + VV), S + VV) + floor_div(mint, x * (S + VV), A + VV) \
    + floor_div(f2, (cs + mint) * (A + x + VV), S + mint + VV)
# MATH-ST-62 verifies: SPEC-FLR-002, Q-142
check("MATH-ST-62",
      "fund(x) raises fundedBalance by between x - 2 and x + 1 (two floors; share price between 1 and 2)",
      fmodel + [Or(f2 < funded + x - 2, f2 > funded + x + 1)],
      "PROVED", timeout_ms=120_000)

done()
