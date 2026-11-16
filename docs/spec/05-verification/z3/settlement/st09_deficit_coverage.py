# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-46..50, MATH-ST-61..62, MATH-ST-114, MATH-ST-130: First-Loss coverage and withdrawal (SPEC-FLR-001..003).

First-Loss Reserve (SPEC-FLR-001): amount = min(maxAmount, ceil(deficitRay / RAY), fundedBalance()), reverts if 0;
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
      "the Hub eliminates exactly the First-Loss Reserve's amount (dE == amount), so adding amount to totalCovered "
      "before the call records what the Hub returns",
      model + [dE != amount],
      "PROVED")

# MATH-ST-50: the Hub checks only that the caller is an active Spoke and dRay > 0; it does
# not check that `spoke` is an approved Avana Borrow Spoke. Any Spoke on the Hub with a
# recorded deficit can be covered from the First-Loss shares unless a wrapper enforces it.
spokeApproved = Ints("spokeApproved")[0]
# MATH-ST-50 verifies: SPEC-FLR-001, DEF-005, Q-101, Q-142
check("MATH-ST-50",
      "the Hub alone accepts coverage of any Spoke's deficit; the First-Loss Reserve's COVERAGE_ROLE and Spoke allowlist "
      "check carry the restriction (counterexample expected)",
      model + [spokeApproved == 0],
      "COUNTEREXAMPLE", show=[amount, defS, dRay, dE, sh])

# MATH-ST-130: the reference terms of the First-Loss Reserve Halmos checks (PROP-039). The checks compare the code's
# amount with OpenZeppelin's Math.ceilDiv(x, RAY) = toUint(x > 0) * ((x - 1) / RAY + 1), computed unchecked in 256
# bits, and run against a recording Hub whose eliminateDeficit arithmetic is unchecked. These checks show, in exact
# integers over the full uint256 range, that (a) that term is ceil(x / RAY) and equals (x + RAY - 1) / RAY wherever
# x + RAY - 1 fits 256 bits, and is at least 1 for x > 0; (b) the recording Hub's operations never wrap for a recorded
# deficit d <= 2^256 - RAY and any amount, so its unchecked form computes the checked form's values; (c) the coverage
# amount min(min(maxAmount, ceil(d / RAY)), funded) is at least 1 when all three inputs are, so coverDeficit's
# NothingToCover cannot fire.
U256 = 2**256
x, q1, ozc, cUp, cAlt = Ints("x q1 ozCeil ceilUp ceilAlt")
xmodel = [x >= 0, x < U256] + floor_div(q1, x - 1, RAY) + ceil_div(cUp, x, RAY) \
    + [ozc == If(x > 0, q1 + 1, 0)]
# MATH-ST-130 verifies: SPEC-FLR-001, REQ-FLR-019, Q-101
check("MATH-ST-130",
      "Math.ceilDiv(x, RAY) = ceil(x / RAY) for every uint256 x, with (x - 1) / RAY + 1 below 2^256 (no wrap)",
      xmodel + [Or(ozc != cUp, And(x > 0, q1 + 1 >= U256))],
      "PROVED")
# MATH-ST-130 verifies: SPEC-FLR-001, REQ-FLR-019, Q-101
check("MATH-ST-130",
      "Math.ceilDiv(x, RAY) = (x + RAY - 1) / RAY for every x <= 2^256 - RAY",
      xmodel + floor_div(cAlt, x + RAY - 1, RAY) + [x <= U256 - RAY, ozc != cAlt],
      "PROVED")
# MATH-ST-130 verifies: SPEC-FLR-001, REQ-FLR-031, Q-101
check("MATH-ST-130",
      "Math.ceilDiv(x, RAY) >= 1 for every x > 0",
      xmodel + [x > 0, ozc < 1],
      "PROVED")

d, amt, c2, dR, cov = Ints("d amount ceilD dRay covered")
hmodel = [d >= 0, d <= U256 - RAY, amt >= 0, amt < U256] + floor_div(c2, d + RAY - 1, RAY) \
    + [dR == If(amt < c2, amt * RAY, d)] + floor_div(cov, dR + RAY - 1, RAY)
# MATH-ST-130 verifies: SPEC-FLR-001, REQ-FLR-018, Q-101
check("MATH-ST-130",
      "the recording Hub's eliminateDeficit never wraps for d <= 2^256 - RAY and any uint256 amount: "
      "d + RAY - 1 and dRay + RAY - 1 fit 256 bits, amount * RAY fits when taken, and d - dRay >= 0",
      hmodel + [Or(d + RAY - 1 >= U256, dR + RAY - 1 >= U256, And(amt < c2, amt * RAY >= U256), d - dR < 0)],
      "PROVED")

m2, f2c, a2 = Ints("maxAmount2 funded2 amount2")
amodel = [d >= 1, d < U256, m2 >= 1, m2 < U256, f2c >= 1, f2c < U256] + ceil_div(c2, d, RAY) \
    + [a2 == If(m2 < c2, If(m2 < f2c, m2, f2c), If(c2 < f2c, c2, f2c))]
# MATH-ST-130 verifies: SPEC-FLR-001, REQ-FLR-031, Q-101
check("MATH-ST-130",
      "min(min(maxAmount, ceil(d / RAY)), funded) >= 1 when d, maxAmount and funded are all >= 1",
      amodel + [a2 < 1],
      "PROVED")

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
