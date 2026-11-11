#!/usr/bin/env python3
"""FV-C RiskModule opening checks and governance parameter bounds.

How Avana works here, and what each check proves:

- Pledges. The RiskModule books a pledge at `usdCharge = ceil(L * max(price8, stressFloorUsd) / 10^d)` and
  tests its value `pledgeUsd = floor(L * price8 / 10^d)` against `minPledgeUsd`, or, for a rescue top-up, against
  `min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD = 10e8)`. A raised `minPledgeUsd` therefore never stops a borrower
  adding collateral to escape liquidation, and every pledge that passes is worth at least the minimum that
  applies to it. The cap tests split an eligible top-up into regular room and the top-up slice, and the record's
  rescue units are `L` for a rescue and `ceil(L * sliceUsd / usdCharge)` for a slice top-up (FV-CTL-53, 54, 136,
  137). The price states that admit a pledge are read from the LPOracle state-effects table itself (FV-CTL-55).
- Parameter changes. Every `tighten*` setter moves its parameter only in the safer direction and inside its hard
  and liveness bounds, with no step limit; every loosening of a USD cap, the top-up slice or a slippage
  allowance moves one bounded step and at least `normalDelay` after the previous loosening
  of the same key, so n loosenings take at least (n - 1) * 345,600 s (FV-CTL-56, 134, 135). There is no on-chain
  opening health floor (Q-398). The one stored breaker threshold, `breakerDeficitMax`, and `maxShortfallBps` and
  `debtStressRiseBps` tighten at the short delay within their bounds; `poolShareMaxBps` is both the pledge cap
  and the concentration gate, a chain default with a per-pool override that only lowers it
  (`tightenPoolShareMaxBpsOf` short, `loosenPoolShareMaxBpsOf` normal, never short) (FV-CTL-132, 133). Under any sequence of setter calls the relational bounds hold (FV-CTL-61).
- Liquidation liveness. No buy leg exists: the flash source lends the debt asset itself and each swap route
  converts a pool token straight into it. `slippageAllowanceBps` never goes below the market's
  `slippageAllowanceMinBps`, which always covers the worst swap-route cost into every enabled debt asset
  (FV-CTL-57); and `minLB * (10^4 - slippageAllowanceMinBps) >= 10^4 * (10^4 + maxFlashFeeBps)` holds for every
  Active or Offboarding market and enabled debt reserve under every setter, activation and reserve change
  (FV-CTL-130, 131); the flash-fee ceiling example of REQ-PSTORE-024 holds (FV-CTL-139).
- Delay classes. Every page names the same parameters as having a short-delay tighten selector, with the same
  direction, under the compiled ParameterStore selector names, and no page or compiled source names a
  SettlementBudget selector (FV-CTL-58; resolves FV-CTL-F-25), and every selector an owning page marks short is in
  `SHORT_ELIGIBLE` (FV-CTL-153, open finding FV-CTL-F-26). The short-delay list starts equal to the timelock's immutable `SHORT_ELIGIBLE` set and
  can never gain a pair outside it; that set holds no loosen, structural, role, upgrade, price-source, route,
  keeper, unfreeze or reset selector (FV-CTL-62), and it holds every new-activity stop, so the governance Safe
  halts new activity within 12 hours when no guardian acts (FV-CTL-140).
- No SettlementBudget (Q-397). The keeper sizes `debtToCover` and its funding up front for the exact flash
  principal and premium, and pays any rounding gap at final settlement through the caller shortfall top-up, so
  no third-party draw, per-call cap, window or reserved floor exists (FV-CTL-59, 60, 138, 141, 142).

Specification text is read from the spec pages at run time where a check compares pages, so a later edit of a
page is compared again on the next run.
"""
import itertools
import re
import sys

import z3

from common import HERE, exhaustive, expect, finish, open_finding, prove, witness, zmax, zmin

SPEC = HERE.parents[2] / "spec"


def spec_text(rel):
    return (SPEC / rel).read_text()


def spec_line(rel, marker):
    for line in spec_text(rel).splitlines():
        if line.startswith(marker):
            return line
    raise LookupError(f"{marker!r} not found in {rel}")


def table_after(rel, heading_marker):
    """Rows (lists of cells) of the first markdown table after the line containing heading_marker."""
    lines = spec_text(rel).splitlines()
    start = next(i for i, l_ in enumerate(lines) if heading_marker in l_)
    rows, seen = [], False
    for l_ in lines[start + 1:]:
        if l_.startswith("|"):
            seen = True
            if not l_.startswith("|---"):
                rows.append([c.strip() for c in l_.strip().strip("|").split("|")])
        elif seen:
            break
    return rows


WAD = 10**18
RESCUE_MIN_PLEDGE_USD = 10 * 10**8
MIN_NORMAL_DELAY, MAX_DELAY, SHORT_DELAY = 345_600, 432_000, 43_200

# ---------------------------------------------------------------- pledge charge, minimum and rescue minimum
L, p, sf, d10, mn = z3.Ints("L price8 stressFloorUsd tenPowD minPledgeUsd")
c, pledge_usd, rb = z3.Ints("usdCharge pledgeUsd restoreBooked")
req_rescue, ps_x, mb_x, elig = z3.Bools("requireRescue poolShareExceeded marketBreakerTripped eligible")
book = zmax(p, sf)
dom = [L >= 1, L < 2**120, p >= 1, p < 2**64, sf >= 1, d10 >= 10**6, d10 <= 10**18,
       c * d10 >= L * book, (c - 1) * d10 < L * book,             # usdCharge = mulDiv(L, max(p, sf), 10^d, Ceil)
       pledge_usd * d10 <= L * p, L * p < (pledge_usd + 1) * d10,  # pledgeUsd = mulDiv(L, p, 10^d, Floor)
       mn >= 0, mn <= 100_000 * 10**8, rb >= 0]
rescue_min = zmin(mn, z3.IntVal(RESCUE_MIN_PLEDGE_USD))
other_reason = z3.Or(req_rescue, ps_x, mb_x)
needs_exemption = z3.Or(other_reason, pledge_usd < mn)
rescue_ok = z3.And(elig, c <= rb)
# REQ-RISK-066 decision order. Outcomes: 0 regular pass, 1 rescue pass, 2 BelowMinPledge(rescue minimum),
# 3 BelowMinPledge(minPledgeUsd), 4 NotRescueTopUp.
outcome = z3.If(z3.Not(needs_exemption), 0,
                z3.If(pledge_usd < rescue_min, 2,
                      z3.If(rescue_ok, 1, z3.If(z3.And(pledge_usd < mn, z3.Not(other_reason)), 3, 4))))
# FV-CTL-53 verifies: SPEC-CAP-001, REQ-RISK-057, REQ-RISK-066, REQ-RISK-067, REQ-PSTORE-005, INV-028
prove("FV-CTL-53", "A regular pledge passes only if its exact value reaches minPledgeUsd and a rescue top-up only if it reaches min(minPledgeUsd, $10) and is eligible within the restore amount; an eligible rescue at or above that minimum is never refused for value; the booked charge is >= 1 and never below the value",
      z3.And(z3.Implies(outcome == 0, L * p >= mn * d10),
             z3.Implies(outcome == 1, z3.And(L * p >= rescue_min * d10, rescue_min <= RESCUE_MIN_PLEDGE_USD,
                                             rescue_min <= mn, elig, c <= rb)),
             z3.Implies(z3.And(elig, c <= rb, pledge_usd >= rescue_min), z3.Or(outcome == 0, outcome == 1)),
             z3.Implies(outcome == 2, pledge_usd < rescue_min), z3.Implies(outcome == 3, pledge_usd < mn),
             c >= 1, c * d10 >= L * p, c >= pledge_usd),
      assumptions=dom, verifies=["SPEC-CAP-001", "REQ-RISK-057", "REQ-RISK-066", "REQ-RISK-067", "REQ-PSTORE-005",
                                 "INV-028"], targets=["T-77"])

R, S, K, Z, T0, T1, P0 = z3.Ints("regularUsed sliceUsed marketUsdCap topUpSliceUsd token0Used token1Used depositorUsed")
Tc0, Tc1, Pc, room, slice_, ru = z3.Ints("tokenUsdCap0 tokenUsdCap1 depositorUsdCap room sliceUsd rescueUnits")
rescue = z3.Bool("rescue")
room_def = room == z3.If(K > R, K - R, 0)
slice_def = slice_ == z3.If(elig, z3.If(c > room, c - room, 0), 0)
cap_ok = z3.And(z3.Implies(z3.Not(elig), c <= room), z3.Implies(elig, z3.And(S + slice_ <= Z, slice_ <= rb)),
                T0 + (c - slice_) <= Tc0, T1 + (c - slice_) <= Tc1, P0 + (c - slice_) <= Pc)
ru_def = z3.And(z3.Implies(rescue, ru == L),
                z3.Implies(z3.And(z3.Not(rescue), slice_ == 0), ru == 0),
                z3.Implies(z3.And(z3.Not(rescue), slice_ > 0), z3.And(ru * c >= L * slice_, (ru - 1) * c < L * slice_)))
# FV-CTL-54 verifies: SPEC-CAP-002, SPEC-CAP-003, REQ-RISK-025, REQ-RISK-066, INV-028
prove("FV-CTL-54", "After a passing pledge: sliceUsd <= usdCharge and > 0 only for an eligible top-up within restoreBooked; a non-zero slice fits topUpSliceUsd and the token and depositor counters exceed their caps by at most the slice; rescueUnits is L for a rescue, ceil(L*sliceUsd/usdCharge) for a slice top-up, 0 otherwise, and never above L",
      z3.Implies(cap_ok, z3.And(slice_ >= 0, slice_ <= c, z3.Implies(z3.Not(elig), slice_ == 0),
                                z3.Implies(elig, slice_ <= rb),
                                R + c - slice_ <= zmax(R, K), z3.Implies(slice_ > 0, S + slice_ <= Z), T0 + c <= Tc0 + slice_,
                                T1 + c <= Tc1 + slice_, P0 + c <= Pc + slice_,
                                ru >= 0, ru <= L, z3.Implies(rescue, ru == L),
                                z3.Implies(z3.And(z3.Not(rescue), slice_ > 0), z3.And(ru >= 1, ru * c >= L * slice_)))),
      assumptions=[c >= 1, L >= 1, L < 2**120, R >= 0, S >= 0, K >= 1, Z >= 0, T0 >= 0, T1 >= 0, P0 >= 0, rb >= 0,
                   room_def, slice_def, ru_def, z3.Implies(rescue, z3.And(elig, c <= rb))],
      verifies=["SPEC-CAP-002", "SPEC-CAP-003", "REQ-RISK-025", "REQ-RISK-066", "INV-028"], targets=["T-77"])

# Pledge price-state eligibility: REQ-RISK-017 against the LPOracle state-effects table, read from 2.10.
# AMM-neutral 2.10: the table heading is "State or condition"; Live splits into "Live, borrowAllowed" and
# "Live, a second source disagrees or is unavailable" (both are Live for a pledge), the TWAP row is now the
# consistency row, and the two sequencer rows are modifiers ("As the state"), not price states.
_rows = table_after("02-contracts/10-lp-oracle.md", "| State or condition | New pledge | Top-up")
_LABEL = {"Live, `borrowAllowed`": "Live", "Live, a second source disagrees or is unavailable": "LiveSecondSource",
          "Drifting (USD band breach only)": "DriftingBandOnly",
          "Drifting (consistency, clamp)": "DriftingOther", "Cached": "Cached", "Expired": "Expired"}
TABLE_2_10 = {}
for _r in _rows:
    if _r[0] == "State or condition" or _r[0].startswith("Sequencer"):
        continue
    _st = _LABEL.get(_r[0], "DriftingDisagreement" if _r[0].startswith("Drifting, routes disagree") else _r[0])
    TABLE_2_10[_st] = {"new": int(_r[1].startswith("Allowed")), "topup": int(_r[2].startswith("Allowed"))}


def risk_017(cls, st):
    if st in ("Cached", "Expired"):
        return 0
    if cls == "new":
        return 1 if st in ("Live", "LiveSecondSource", "DriftingBandOnly") else 0
    return 1


# FV-CTL-55 verifies: REQ-RISK-017, INV-026, REQ-ORACLE-015
exhaustive("FV-CTL-55", "Pledge price-state rule of the RiskModule equals the LPOracle state-effects table (read from 2.10) for new accounts and top-ups",
           [("table", "rows")] + list(itertools.product(("new", "topup"), sorted(TABLE_2_10))),
           lambda x: (set(TABLE_2_10) == {"Live", "LiveSecondSource", "DriftingBandOnly", "DriftingOther", "DriftingDisagreement",
                                          "Cached", "Expired"} or sorted(TABLE_2_10)) if x[0] == "table"
           else risk_017(*x) == TABLE_2_10[x[1]][x[0]],
           verifies=["REQ-RISK-017", "INV-026", "REQ-ORACLE-015"], targets=["T-77"])

# ---------------------------------------------------------------- tighten predicates and loosening steps
# (name, safer direction, hard lo, hard hi, step kind). Bounds may name relational symbols (see REL below).
CAPSTEP = 15_000
PARAMS = [
    ("slippageAllowanceBps", "down", "slippageAllowanceMinBps", 10_000, "bps25"),
    ("floorRoundingAllowance", "down", 0, None, None),
    ("borrowPriceMaxAge", "down", 0, "borrowAgeCeiling", None),
    ("consistencyToleranceBps", "down", "consistencyToleranceMinBps", None, None),
    ("feedAgreementToleranceBps", "down", "feedAgreementToleranceMinBps", 10_000, None),
    ("poolRiskFactor", "down", 1, 4_000, None),
    ("routeDepthThreshold", "up", 1, None, None),
    ("marketUsdCap", "down", "topUpSliceUsdCurrent", 2**128, "cap"),
    ("topUpSliceUsd", "down", 0, "marketUsdCapCurrent", "slice"),
    ("tokenUsdCap", "down", 1, 2**128, "cap"),
    ("depositorUsdCap", "down", 1, 2**128, "cap"),
    ("poolShareMaxBps", "down", 0, 10_000, None),
    ("hardHealthFloor", "up", 0, 125 * 10**16, "hf"),  # Q-398: 0 = off, else [1e18, 1.25e18] (REQ-PSTORE-031)
    ("gateRecoverySeconds", "up", 600, 7_200, None),  # Q-399: breaker recovery window, launch 1,800 s (REQ-PSTORE-030)
    ("minPledgeUsd", "up", 0, 100_000 * 10**8, None),
    ("maxFlashFeeBps", "down", 0, 100, None),
    ("breakerDeficitMax", "down", 0, "firstLossReserveMinimum", None),
    ("maxShortfallBps", "down", 0, 5_000, None),
    ("debtStressRiseBps", "up", 100, 5_000, None),
]
t_exec, last, ndelay, last2 = z3.Ints("executionTime lastLoosenedAt normalDelay lastLoosenedAt_after")
claims56, ctx56 = [], [ndelay >= MIN_NORMAL_DELAY, ndelay <= MAX_DELAY, last >= 0, t_exec >= last]
for name, dirn, lo, hi, stepk in PARAMS:
    old, new = z3.Ints(f"{name}_old {name}_new")
    sym = {}

    def bound(b, nm=name, sy=sym):
        if b is None or isinstance(b, int):
            return b
        if b not in sy:
            sy[b] = z3.Int(f"{nm}__{b}")
            ctx56.append(sy[b] >= 0)
        return sy[b]
    lo_e, hi_e = bound(lo), bound(hi)
    inv = lambda v, a=lo_e, b=hi_e: z3.And(v >= a, *( [v <= b] if b is not None else []))  # noqa: E731
    stricter = new > old if dirn == "up" else new < old
    looser = new < old if dirn == "up" else new > old
    tighten_ok = z3.And(stricter, inv(new))  # NotStricter / OutOfBounds / LivenessBound otherwise
    claims56.append(z3.Implies(z3.And(inv(old), tighten_ok), z3.And(inv(new), stricter)))
    if stepk:
        spacing = z3.Or(last == 0, t_exec >= last + ndelay)
        if stepk == "hf":
            step = old - new <= 3 * 10**16
        elif stepk == "bps25":
            step = new - old <= 25
        elif stepk == "cap":
            step = new * 10**4 <= old * CAPSTEP
        else:  # slice: old replaced by max(old, floor(marketUsdCap / 10))
            mcap = sym["marketUsdCapCurrent"]
            step = new * 10**4 <= zmax(old, mcap / 10) * CAPSTEP
        loosen_ok = z3.And(looser, inv(new), step, spacing)
        after = z3.If(loosen_ok, t_exec, last)
        claims56.append(z3.Implies(z3.And(inv(old), loosen_ok),
                                   z3.And(inv(new), step, z3.Or(last == 0, t_exec - last >= MIN_NORMAL_DELAY),
                                          after == t_exec)))
# FV-CTL-56 verifies: SPEC-GOV-011, SPEC-GOV-009, REQ-PSTORE-017, REQ-CONFIG-051, REQ-CONFIG-052, REQ-ACCESS-120, REQ-ACCESS-161
prove("FV-CTL-56", f"Every tighten setter ({len(PARAMS)} ParameterStore parameters) moves only in the safer direction inside its hard and liveness bounds; every step-limited loosening moves one step (x1.5 exact product, slice base max(old, floor(cap/10)), +25 bps) at least normalDelay >= 345,600 s after the previous one and records its time",
      z3.And(claims56), assumptions=ctx56,
      verifies=["SPEC-GOV-011", "SPEC-GOV-009", "REQ-PSTORE-017", "REQ-CONFIG-051", "REQ-CONFIG-052", "REQ-ACCESS-120",
                "REQ-ACCESS-161"], targets=["T-71"])

# ---------------------------------------------------------------- liquidation liveness, lower side
# AMM-neutral design (REQ-PSTORE-006, REQ-PSTORE-015): no buy leg exists. The flash source lends the debt asset
# itself and each swap route converts a pool token straight into it, so the lower side of liveness is the market's
# slippageAllowanceMinBps, written to cover the real cost of every swap route into every enabled debt asset.
sa, sa2, sfl, sfl2, rc, vv, opb = z3.Ints("slippageAllowanceBps slippageAllowanceBps_after slippageAllowanceMinBps "
                                          "slippageAllowanceMinBps_after worstRouteCostBps value setter")
newcost, enab = z3.Int("newReserveRouteCostBps"), z3.Bool("enableDebtReserveInBatch")
inv57 = lambda a_, f_, c_: z3.And(f_ >= 1, f_ <= a_, a_ <= 10_000, c_ <= f_)  # noqa: E731
ok_t = z3.And(vv < sa, vv >= sfl)                               # tightenSlippageAllowanceBps
ok_l = z3.And(vv > sa, vv <= sa + 25, vv <= 10_000)             # loosenSlippageAllowanceBps (one step)
ok_m = z3.And(vv >= 1, vv <= sa, vv >= rc)                      # setSlippageAllowanceMinBps (normal), covers routes
step57 = z3.And(
    z3.Implies(opb == 0, z3.And(sa2 == z3.If(ok_t, vv, sa), sfl2 == sfl)),
    z3.Implies(opb == 1, z3.And(sa2 == z3.If(ok_l, vv, sa), sfl2 == sfl)),
    z3.Implies(opb == 2, z3.And(sa2 == sa, sfl2 == z3.If(ok_m, vv, sfl))),
    opb >= 0, opb <= 2)
# enableDebtReserve: a new reserve whose routes cost more than the floor is refused unless the same batch raised
# the floor first (REQ-PSTORE-015); after the batch the worst route cost is max(rc, newcost) <= floor.
rc2 = z3.If(z3.And(enab, newcost <= sfl2), zmax(rc, newcost), rc)
# FV-CTL-57 verifies: REQ-PSTORE-015, REQ-PSTORE-006, REQ-CONFIG-052, INV-047, INV-046
prove("FV-CTL-57", "slippageAllowanceBps never goes below slippageAllowanceMinBps(m), the floor never above the allowance, and the floor always covers the worst swap-route cost of every enabled debt asset, so every accepted allowance admits the honest swap (no buy leg exists)",
      inv57(sa2, sfl2, rc2), assumptions=[inv57(sa, sfl, rc), rc >= 0, newcost >= 0, step57],
      verifies=["REQ-PSTORE-015", "REQ-PSTORE-006", "REQ-CONFIG-052", "INV-047", "INV-046"], targets=["T-71"],
      detail="Changed for the AMM-neutral design: the buy-leg allowance and its floor were removed (REQ-PSTORE-006); "
             "the per-market slippage floor is the lower side for every debt asset.")

# ---------------------------------------------------------------- liquidation liveness, upper side
# The invariant is a conjunction over (market, debt reserve) pairs, and every guard of the real setters includes the
# conjunct of each pair it can affect, so one generic pair under guards that keep only its conjunct proves every pair.
# Proved over the reals: the formula has no division or rounding.
s_m, s_m2, lb_m, ff, ff2, v2 = z3.Reals("slippageAllowanceMinBps slippageAllowanceMinBps_after minLB "
                                        "maxFlashFeeBps maxFlashFeeBps_after argValue")
op2 = z3.Int("op")
act, act2, en, en2 = z3.Bools("activeOrOffboarding activeOrOffboarding_after enabled enabled_after")


def live(lb, s, f_):
    """REQ-PSTORE-021 liquidationLivenessHolds for one (market, debt reserve) pair."""
    return z3.And(lb >= 10**4, f_ < 10**4, lb * (10**4 - s) >= 10**4 * (10**4 + f_))


def pair_ok(sm, ac, e_, f_):
    return z3.Implies(z3.And(ac, e_), live(lb_m, sm, f_))


dom130 = [lb_m >= 10**4, lb_m <= 20_000, s_m >= 1, s_m <= 9_999, ff >= 0, ff <= 100, v2 >= 0, v2 <= 10_000]
ok_smin = z3.And(v2 >= 1, v2 <= 9_999, z3.Or(v2 <= s_m, z3.Not(act), z3.Implies(en, live(lb_m, v2, ff))))
ok_flash = z3.And(v2 >= 0, v2 <= 100, z3.Or(v2 <= ff, pair_ok(s_m, act, en, v2)))
ok_activate = z3.And(z3.Not(act), z3.Implies(en, live(lb_m, s_m, ff)))
ok_enable = z3.And(z3.Not(en), z3.Implies(act, live(lb_m, s_m, ff)))
frame = [en2 == z3.If(z3.And(op2 == 5, ok_enable), True, z3.If(op2 == 6, False, en)),
         s_m2 == z3.If(z3.And(op2 == 2, ok_smin), v2, s_m),
         act2 == z3.If(z3.And(op2 == 4, ok_activate), True, act),       # setMarketOffboarding keeps it counted
         ff2 == z3.If(z3.And(op2 == 3, ok_flash), v2, ff), op2 >= 0, op2 <= 7]  # 7: any call on another pair
# FV-CTL-130 verifies: REQ-PSTORE-021, REQ-MREG-032, REQ-CONFIG-052, INV-047, REQ-PSTORE-024
prove("FV-CTL-130", "minLB x (10^4 - slippageAllowanceMinBps) >= 10^4 x (10^4 + maxFlashFeeBps) holds for every Active/Offboarding market and enabled debt reserve after every slippageAllowanceMinBps or maxFlashFeeBps change, activateMarket, enableDebtReserve and reserve removal (inductive step, per pair)",
      pair_ok(s_m2, act2, en2, ff2), assumptions=dom130 + frame + [pair_ok(s_m, act, en, ff)],
      verifies=["REQ-PSTORE-021", "REQ-MREG-032", "REQ-CONFIG-052", "INV-047", "REQ-PSTORE-024"], targets=["T-71"],
      detail="Changed for the AMM-neutral design: one swap leg per pool token into the debt asset, so the two-leg "
             "inequality with a buy allowance became the single-leg inequality of REQ-PSTORE-021. minLB is Aave "
             "configuration read at each check; an Aave bonus cut after activation is drift (REQ-HUB-108).")

_l = 10_200 * 9_970
_r10, _r169, _r170 = 10**4 * 10_010, 10**4 * 10_169, 10**4 * 10_170
_l35 = 10_200 * 9_965
_floor = max(5 + 10, 5 + 25)
_ok131 = (10**4 + (10_500 - 10**4) * 4_000 // 10**4 == 10_200 and _l == 101_694_000 and _r10 == 100_100_000
          and _l >= _r10 and _r169 == 101_690_000 and _l >= _r169 and _r170 == 101_700_000 and _l < _r170
          and _l35 >= _r10 and _floor == 30 and (30 < 50 and 30 >= _floor) and not (29 >= _floor) and not (51 <= 50)
          and "`10,200 × 9,970 = 101,694,000`" in spec_text("02-contracts/09-parameter-store.md"))
# FV-CTL-131 verifies: REQ-PSTORE-021, REQ-MREG-032, REQ-PSTORE-015, REQ-CONFIG-052
expect("FV-CTL-131", "Spec examples: minLB 10,200 with floor 30 bps gives 101,694,000, which admits maxFlashFeeBps 10 and 169 and refuses 170; raising the floor to 35 for a 35 bps route still passes at 10 bps; floor max(15, 30) = 30 admits tightening to 30, refuses 29 and a floor of 51 above a 50 bps allowance",
       _ok131, verifies=["REQ-PSTORE-021", "REQ-MREG-032", "REQ-PSTORE-015", "REQ-CONFIG-052"], targets=["T-71"],
       cex={"lhs": _l, "rhs10": _r10, "rhs169": _r169, "rhs170": _r170, "lhs35": _l35})

# REQ-PSTORE-024 example: a 20,000 USDC flash loan, ceiling 10 bps, exact check phi x 10^4 <= maxFlashFeeBps x amount.
_amt = 20_000 * 10**6
_rhs = 10 * _amt
_p5, _p15 = _amt * 5 // 10**4, _amt * 15 // 10**4
_ps = spec_text("02-contracts/09-parameter-store.md")
# FV-CTL-139 verifies: REQ-PSTORE-024, REQ-PSTORE-006, SPEC-LIQ-015
expect("FV-CTL-139", "REQ-PSTORE-024 example: the exact check phi x 10^4 <= 10 x 20,000e6 = 2e11 passes the 5 bps premium (10 USDC, 1e11) and refuses a 15 bps premium (30 USDC, 3e11), so the keeper funds the debt; 2.9 has no buy-leg setter",
       _rhs == 2 * 10**11 and _p5 == 10 * 10**6 and _p5 * 10**4 == 10**11 and _p5 * 10**4 <= _rhs
       and _p15 == 30 * 10**6 and _p15 * 10**4 == 3 * 10**11 and _p15 * 10**4 > _rhs
       and "`φ × 10⁴ ≤ maxFlashFeeBps × amount`" in _ps
       and "`10e6 × 10⁴ = 1e11 ≤ 10 × 20,000e6 = 2e11`" in _ps and "`30e6 × 10⁴ = 3e11 > 2e11`" in _ps
       and "BuySlippageAllowance" not in _ps,
       verifies=["REQ-PSTORE-024", "REQ-PSTORE-006", "SPEC-LIQ-015"], targets=["T-71"],
       detail="Changed for the AMM-neutral design: the old GHO buy-leg example is replaced by the flash-fee ceiling, "
              "checked in the exact form phi x 10^4 <= maxFlashFeeBps x amount (no rounded ceiling).",
       cex={"rhs": _rhs, "premium5": _p5, "premium15": _p15})

# ---------------------------------------------------------------- breaker thresholds, shortfall cap, stress rise
BREAKERS = {r[0].strip("`").split("[")[0].split("(")[0]: r for r in table_after("02-contracts/09-parameter-store.md", "### Circuit breakers")
            if r[0].startswith("`breaker")}
_bok = (set(BREAKERS) == {"breakerDeficitMax"} and BREAKERS["breakerDeficitMax"][4] == "lower")
bo, bn, flr = z3.Ints("breakerDeficitMax_old breakerDeficitMax_new firstLossReserveMinimum")
psm, psm2 = z3.Ints("poolShareMaxBps poolShareMaxBps_after")
inb = lambda v: z3.And(v >= 0, v <= flr)  # noqa: E731
cl132 = [z3.Implies(z3.And(inb(bo), bn < bo, inb(bn)), z3.And(inb(bn), bn < bo)),
         z3.Implies(z3.And(psm >= 0, psm <= 10_000, psm2 < psm, psm2 >= 0), z3.And(psm2 >= 0, psm2 <= 10_000))]
_ex132 = (10_000 * 10**18 > 9_999 * 10**18) and not (10_001 * 10**18 <= 10_000 * 10**18)
# FV-CTL-132 verifies: REQ-PSTORE-016, REQ-ROLE-112, REQ-CONFIG-049
prove("FV-CTL-132", "Breaker thresholds (Q-399): the 2.9 table holds only breakerDeficitMax (10,000 GHO launch), lowered at the short delay within [0, firstLossReserveMinimum]; the price-drop, seizure and route-failure thresholds and breakerCooldown are monitoring settings, not stored trips; poolShareMaxBps is the one concentration parameter, lowered within [0, 10,000]",
      z3.And(cl132 + [z3.BoolVal(_bok), z3.BoolVal(_ex132)]), assumptions=[flr >= 0],
      verifies=["REQ-PSTORE-016", "REQ-ROLE-112", "REQ-CONFIG-049"], targets=["T-71"],
      detail=f"2.9 breaker table parsed: {sorted(BREAKERS)}")

ms_o, ms_n, dr_o, dr_n, acc, s_, mg, V_ = z3.Ints("maxShortfallBps_old maxShortfallBps_new debtStressRiseBps_old debtStressRiseBps_new acceptedPrice8 legSlippageBps maxShortfallGho V")
served = z3.Int("servedStressPrice8")
served_def = z3.And(served * 10**4 >= acc * (10**4 + dr_n), (served - 1) * 10**4 < acc * (10**4 + dr_n))
sleg = lambda m_: zmin(z3.IntVal(9_999), s_ + zmin(m_, mg * 10**4 / V_))  # noqa: E731
_srv_ex = -(-99_990_000 * 10_500 // 10_000)
_sleg_ex = (min(9_999, 100 + min(1_000, (200 * 10**18 * 10**4) // (12_422_600 * 10**15))),
            min(9_999, 100 + min(50, (200 * 10**18 * 10**4) // (12_422_600 * 10**15))))
# FV-CTL-133 verifies: REQ-PSTORE-018, REQ-PSTORE-020, SPEC-LIQ-019, SPEC-ORC-018, REQ-ROLE-112
prove("FV-CTL-133", "tightenMaxShortfallBps lowers within [0, 5,000] and never widens any leg's slippage; tightenDebtStressRiseBps raises within [100, 5,000] and the served stress price ceil(accepted*(10^4+rise)/10^4) is never below the accepted price; spec examples hold",
      z3.And(z3.Implies(z3.And(ms_n < ms_o, ms_n >= 0, ms_o <= 5_000), sleg(ms_n) <= sleg(ms_o)),
             z3.Implies(z3.And(dr_n > dr_o, dr_n >= 100, dr_n <= 5_000, served_def), served >= acc),
             z3.BoolVal(_srv_ex == 104_989_500 and _sleg_ex == (260, 150) and not (99 >= 100))),
      assumptions=[ms_o >= 0, s_ >= 0, s_ <= 9_999, mg >= 0, V_ >= 1, acc >= 1, dr_o >= 0],
      verifies=["REQ-PSTORE-018", "REQ-PSTORE-020", "SPEC-LIQ-019", "SPEC-ORC-018", "REQ-ROLE-112"], targets=["T-71"])

# ---------------------------------------------------------------- loosening spacing over a sequence
ts = z3.Ints("t1 t2 t3")
ds = z3.Ints("normalDelay_at_t2 normalDelay_at_t3")
hv = z3.Ints("hf0 hf1 hf2 hf3")
cv = z3.Ints("cap0 cap1 cap2 cap3")
seq = [ds[0] >= MIN_NORMAL_DELAY, ds[1] >= MIN_NORMAL_DELAY, ts[0] >= 1,
       ts[1] >= ts[0] + ds[0], ts[2] >= ts[1] + ds[1]]                       # lastLoosenedAt = previous success
seq += [cv[k + 1] * 10**4 <= cv[k] * CAPSTEP for k in range(3)]
seq += [cv[0] >= 1] + [cv[k + 1] > cv[k] for k in range(3)]
# FV-CTL-134 verifies: SPEC-GOV-011, REQ-PSTORE-017, REQ-ACCESS-161, SPEC-GOV-003
prove("FV-CTL-134", "Three loosenings of one key span at least 2 x MIN_NORMAL_DELAY = 691,200 s and raise a cap by at most 3.375x, however normalDelay moves within its bounds (no health-factor parameter is loosened: Q-398)",
      z3.And(ts[2] - ts[0] >= 2 * MIN_NORMAL_DELAY, cv[3] * 1_000 <= cv[0] * 3_375),
      assumptions=seq, verifies=["SPEC-GOV-011", "REQ-PSTORE-017", "REQ-ACCESS-161", "SPEC-GOV-003"], targets=["T-71"])


def loosen_hf_ok(old, new):
    return new < old and old - new <= 3 * 10**16


def loosen_cap_ok(old, new):
    return new > old and new * 10**4 <= old * CAPSTEP


def loosen_bps_ok(old, new):
    return new > old and new - old <= 25


def spacing_ok(lastt, t, d=MAX_DELAY):
    return lastt == 0 or t >= lastt + d


_T = 1_780_000_000
_ok135 = (not spacing_ok(_T, _T + 3 * 86_400) and _T + 432_000 == 1_780_432_000
          and loosen_cap_ok(5_000_000 * 10**8, 7_500_000 * 10**8) and not loosen_cap_ok(5_000_000 * 10**8, 7_500_000 * 10**8 + 1)
          and loosen_bps_ok(100, 125) and not loosen_bps_ok(100, 126)
          and loosen_bps_ok(40, 65) and loosen_bps_ok(65, 90) and loosen_bps_ok(90, 100) and not loosen_bps_ok(40, 100)
          and loosen_cap_ok(2_000_000 * 10**8, 3_000_000 * 10**8)
          and loosen_bps_ok(50, 75) and not loosen_bps_ok(50, 76)
          and (0 + 1) * 10**4 <= max(0, (2_000_000 * 10**8) // 10) * CAPSTEP          # slice restored from 0
          and 300_000 * 10**8 * 10**4 <= max(0, (2_000_000 * 10**8) // 10) * CAPSTEP
          and not ((300_000 * 10**8 + 1) * 10**4 <= max(0, (2_000_000 * 10**8) // 10) * CAPSTEP))
# FV-CTL-135 verifies: SPEC-GOV-011, REQ-PSTORE-017, REQ-CONFIG-071, MKT-053, REQ-PSTORE-006
expect("FV-CTL-135", "Spec examples: a second loosening at T + 3 days LoosenTooSoon(T + 432,000); $5M -> $7.5M accepted, +1 refused; 100 -> 125 bps accepted, 126 refused; 40 -> 65 -> 90 -> 100 in three steps; a slice at 0 restores to 1.5 x cap/10; 50 -> 75 bps, 76 refused",
       _ok135, verifies=["SPEC-GOV-011", "REQ-PSTORE-017", "REQ-CONFIG-071", "MKT-053", "REQ-PSTORE-006"], targets=["T-71"])

# ---------------------------------------------------------------- pledge examples and the error the rules name
def pledge_usd_int(L_, p_, d):
    return L_ * p_ // 10**d


def charge_int(L_, p_, sf_, d):
    return -(-L_ * max(p_, sf_) // 10**d)


_ok136 = (charge_int(50_000_000_000, 199_990_000, 10**8, 6) == 9_999_500_000_000
          and pledge_usd_int(50_000_000_000, 199_990_000, 6) == 9_999_500_000_000
          and charge_int(50_000_000_000, 80_000_000, 10**8, 6) == 5_000_000_000_000
          and pledge_usd_int(5_000_000, 199_990_000, 6) == 999_950_000
          and pledge_usd_int(5_001_000, 199_990_000, 6) == 1_000_149_990
          and pledge_usd_int(5_000_000, 199_986_998, 6) == 999_934_990
          and pledge_usd_int(5_001_000, 199_986_998, 6) == 1_000_134_976
          and min(50 * 10**8, RESCUE_MIN_PLEDGE_USD) <= 12 * 10**8 < 50 * 10**8)
# FV-CTL-136 verifies: SPEC-CAP-001, REQ-PSTORE-005, REQ-RISK-067, REQ-RISK-057
expect("FV-CTL-136", "Spec examples: $99,995 charge and value at 199,990,000; $50,000 charge at the $1 floor; 999,950,000 and 999,934,990 below $10, 1,000,149,990 and 1,000,134,976 above; a $12 rescue passes and a $12 ordinary top-up fails at minPledgeUsd $50",
       _ok136, verifies=["SPEC-CAP-001", "REQ-PSTORE-005", "REQ-RISK-067", "REQ-RISK-057"], targets=["T-77"])

# REQ-RISK-057: a pledge below the rescue minimum reverts BelowMinPledge(pledgeUsd, rescue minimum) whatever its other
# exemption reasons; one at or above it but below minPledgeUsd that is not admitted as a rescue reverts
# BelowMinPledge(pledgeUsd, minPledgeUsd) when the value is its only exemption reason and NotRescueTopUp otherwise.
err_057 = z3.If(pledge_usd < rescue_min, 2,
                z3.If(z3.And(pledge_usd < mn, outcome != 1), z3.If(z3.Not(other_reason), 3, 4), 0))
err_066 = z3.If(z3.Or(outcome == 2, outcome == 3), outcome, z3.If(outcome == 4, 4, 0))
# FV-CTL-137 verifies: REQ-RISK-057, REQ-RISK-066
prove("FV-CTL-137", "REQ-RISK-057 and REQ-RISK-066 name the same revert for every pledge below a minimum",
      z3.Implies(z3.Or(err_057 != 0, err_066 == 2, err_066 == 3), err_057 == err_066), assumptions=dom,
      verifies=["REQ-RISK-057", "REQ-RISK-066"], targets=["T-77"],
      show={"pledgeUsd", "minPledgeUsd", "requireRescue", "poolShareExceeded", "marketBreakerTripped", "eligible",
            "usdCharge", "restoreBooked"})

# ---------------------------------------------------------------- delay classes across pages
# Selectors that write one scope of a parameter another selector also names: `tightenPoolShareMaxBpsOf(marketId, v)`
# writes the per-pool override of `poolShareMaxBps` (Q-383, Q-399). Only the parameter reading is shared; the selector
# comparison (SEL_PS) and SHORT_ELIGIBLE still treat each selector separately.
PARAM_OF_SELECTOR = {"tightenPoolShareMaxBpsOf": "poolShareMaxBps"}


def ps_param(sel):
    """Parameter named by a tighten selector, as the selector spells it (AMM-neutral design: no aliasing, because
    SHORT_ELIGIBLE is a selector set and a renamed selector is a different selector), except the per-scope selectors of
    PARAM_OF_SELECTOR, which name a scope of an existing parameter."""
    if sel in PARAM_OF_SELECTOR:
        return PARAM_OF_SELECTOR[sel]
    base = sel[len("tighten"):]
    return base[0].lower() + base[1:]


def pname(n):
    """Parameter name with its scope arguments removed: `tokenUsdCap(hub, token)` -> tokenUsdCap."""
    return n.split("[")[0].split("(")[0]


GOV = "02-contracts/15-governance-and-timelock.md"
LAUNCH = {r[0]: re.findall(r"`(\w+)`", r[1]) for r in table_after(GOV, "Launch short-delay list (`REQ-ACCESS-141`)")
          if r[0] != "Contract"}
P215 = {ps_param(s) for s in LAUNCH["ParameterStore"]} | {ps_param(s) for s in LAUNCH["MarketRegistry"]
                                                         if s.startswith("tighten")}
P29 = set()  # setter rows whose delay column names the short delay
for r in table_after("02-contracts/09-parameter-store.md", "| `initialize(address timelock"):
    if len(r) >= 3 and "short" in r[2].lower():
        P29 |= {ps_param(s) for s in re.findall(r"(tighten[A-Z]\w*)", r[0])}
P15 = set()
P15_SB = set()  # 1.5 rows whose contract column is SettlementBudget
for line in spec_text("01-architecture/05-parameters.md").splitlines():
    if line.startswith("| `"):
        cells = [x.strip() for x in line.strip().strip("|").split("|")]
        if cells[-1].startswith("Short"):
            P15 |= {pname(n) for n in re.findall(r"`([^`]+)`", cells[0])}
            if len(cells) >= 2 and cells[-2].startswith("SettlementBudget"):
                P15_SB |= {pname(n) for n in re.findall(r"`([^`]+)`", cells[0])}
# SettlementBudget parameters (perCall, the windows, reservedFloor) are compared by selector against the SettlementBudget
# readings (compiled ISettlementBudget*, 2.13, 2.15, 1.5, 1.4, 3.8: SEL_SB below), not against the 2.9 ParameterStore table.
P15 -= {"settlementBudgetPerCallCap", "settlementBudgetPer24hCap", "perCallCap", "marketWindowCap",
        "assetWindowCap", "reservedFloor"} | P15_SB
# 1.5 names the swap-route slot field (`routeDepthThresholdUsd`, REQ-CONFIG-070); its selectors are
# tighten/loosenRouteDepthThreshold, so the field and the selector stem name one parameter.
P15 = {"routeDepthThreshold" if n == "routeDepthThresholdUsd" else n for n in P15}
# 1.4: REQ-ROLE-027 covers "the tighten selector of each Tighten / Loosen or Tighten / Structural parameter in 1.5"
# plus its named list; REQ-ROLE-088/090/091/112 name further tighten selectors at the short delay.
ROLES = "01-architecture/04-permissions-and-roles.md"
_SRC = HERE.parents[2] / "contracts" / "src"
_compiled = lambda files: {m for f in files for m in re.findall(r"function (tighten[A-Z]\w*)\s*\(", f.read_text())}
SEL_SB_SRC = _compiled(sorted(_SRC.rglob("ISettlementBudget*.sol")))
P14 = set(P15)
# REQ-ROLE-090 is the retired buy-leg row (delay "Prohibited"); its selectors no longer exist.
for rid in ("REQ-ROLE-027", "REQ-ROLE-088", "REQ-ROLE-091", "REQ-ROLE-112"):
    P14 |= {ps_param(s) for s in re.findall(r"(tighten[A-Z]\w*)", spec_line(ROLES, f"| `{rid}` |"))
            if s not in ("tightenCaps", "tightenMarketWindow", "tightenAssetWindow", "tightenReservedFloor")
            and s not in SEL_SB_SRC}
P14 = {"routeDepthThreshold" if n == "routeDepthThresholdUsd" else n for n in P14}
NO_TIGHTEN = {"usdBandLow", "usdBandHigh", "graceDuration", "graceHealthFactor"}
_no_tighten_stated = {
    "1.4 REQ-ROLE-025": spec_line(ROLES, "| `REQ-ROLE-025` |"), "1.4 REQ-ROLE-027": spec_line(ROLES, "| `REQ-ROLE-027` |"),
    "1.4 REQ-ROLE-105": spec_line(ROLES, "- `REQ-ROLE-105`"),
    "2.9 REQ-CONFIG-049": spec_line("02-contracts/09-parameter-store.md", "- `REQ-CONFIG-049`"),
    "3.8 MKT-027": spec_line("03-operations/08-market-lifecycle.md", "- `MKT-027`")}
# 2.9 REQ-CONFIG-049 and 3.8 MKT-027 are prose; their short-tighten parameters are encoded here and each name is
# checked to occur in the paragraph (directions: short = the tighten side named in the text).
P049 = {"slippageAllowanceBps", "floorRoundingAllowance", "marketUsdCap", "topUpSliceUsd",
        "poolShareMaxBps", "tokenUsdCap", "depositorUsdCap", "minPledgeUsd", "maxFlashFeeBps",
        "routeDepthThreshold", "consistencyToleranceBps", "feedAgreementToleranceBps", "borrowPriceMaxAge",
        "poolRiskFactor", "hardHealthFloor", "gateRecoverySeconds",
        # "breakerDeficitMax, maxShortfallBps and debtStressRiseBps follow REQ-PSTORE-016, -018 and -020",
        # each of which gives a short tighten selector (Q-399: no other stored breaker threshold):
        "breakerDeficitMax", "maxShortfallBps", "debtStressRiseBps"}
_049_text = _no_tighten_stated["2.9 REQ-CONFIG-049"]
_049_anchor = [n for n in P049 if not n.startswith("breaker") and n not in ("routeDepthThreshold", "maxShortfallBps",
                                                                            "debtStressRiseBps")
               and not re.search(r"`" + n + r"[`(]", _049_text)]
_049_anchor += [] if "depth threshold tighten = raise (short" in _049_text else ["depth thresholds"]
_049_anchor += [] if all(f"`{r}`" in _049_text for r in ("REQ-PSTORE-016", "REQ-PSTORE-018", "REQ-PSTORE-020")) else ["016/018/020"]
# 3.8 MKT-027 is prose: its ParameterStore tighten list is the backticked names before the MarketRegistry entries.
_mkt = _no_tighten_stated["3.8 MKT-027"]
# Q-397 removed the SettlementBudget, so the ParameterStore list now ends at the MarketRegistry entries.
_mkt_end = "; the SettlementBudget setters" if "; the SettlementBudget setters" in _mkt else "; `MarketRegistry."
_mkt_head = (_mkt.split("the ParameterStore setters", 1)[1].split(_mkt_end, 1)[0]
             if "the ParameterStore setters" in _mkt and _mkt_end in _mkt else "")
P38 = {ps_param(pname(n)) if n.startswith("tighten") else pname(n)
       for n in re.findall(r"`([A-Za-z]\w*(?:\([^`]*\))?)`", _mkt_head)}
_38_anchor = [] if P38 else ["MKT-027 ParameterStore list not found"]
# Compiled selector names (contracts/src): the ParameterStore and SettlementBudget tighten functions. Every page
# names exactly these selectors as short (FV-CTL-F-25 resolved by aligning the pages with the compiled names).
SEL_PS_SRC = _compiled(sorted((_SRC / "policy" / "parameter-store").rglob("*.sol")))
SEL_PS = {
    "compiled IParameterStore*": SEL_PS_SRC,
    "2.15 launch list / SHORT_ELIGIBLE": set(LAUNCH["ParameterStore"]),
    "2.9 setter table": {s_ for r in table_after("02-contracts/09-parameter-store.md", "| `initialize(address timelock")
                         if len(r) >= 3 and "short" in r[2].lower() for s_ in re.findall(r"(tighten[A-Z]\w*)", r[0])},
    "3.8 MKT-027": set(re.findall(r"`(tighten[A-Z]\w*)", _mkt_head)),
}
_mkt_sb = (_mkt.split("; the SettlementBudget setters", 1)[1].split("; `MarketRegistry.", 1)[0]
           if "; the SettlementBudget setters" in _mkt and "; `MarketRegistry." in _mkt else "")
_sb15 = set()
for line in spec_text("01-architecture/05-parameters.md").splitlines():
    if line.startswith("| `"):
        cells = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[-2].startswith("SettlementBudget") and cells[-1].startswith("Short"):
            _sb15 |= set(re.findall(r"`(tighten[A-Z]\w*)`", cells[-1]))
_p213 = SPEC / "02-contracts/13-settlement-budget.md"
_sb_rows213 = [l_ for l_ in (_p213.read_text().splitlines() if _p213.exists() else [])
               if l_.startswith("| `tighten") and "Short (12 hours)" in l_]
SEL_SB = {
    "compiled ISettlementBudget": SEL_SB_SRC,
    "2.15 launch list / SHORT_ELIGIBLE": set(LAUNCH.get("SettlementBudget", [])),
    "2.13 delay table": {s_ for l_ in _sb_rows213 for s_ in re.findall(r"`(tighten[A-Z]\w*)`", l_.split("|")[1])},
    "1.5 class column": _sb15,
    "1.4 REQ-ROLE-027": {s_ for s_ in re.findall(r"(tighten[A-Z]\w*)", spec_line(ROLES, "| `REQ-ROLE-027` |"))
                         if s_ in ("tightenCaps", "tightenMarketWindow", "tightenAssetWindow") or s_ not in SEL_PS_SRC},
    "1.4 REQ-ROLE-094": set(re.findall(r"(tighten[A-Z]\w*)", spec_line(ROLES, "| `REQ-ROLE-094` |"))),
    "1.4 REQ-ROLE-105": {s_ for s_ in re.findall(r"(tighten[A-Z]\w*)", spec_line(ROLES, "- `REQ-ROLE-105`"))
                         if s_ not in SEL_PS_SRC},
    "3.8 MKT-027": set(re.findall(r"`(tighten[A-Z]\w*)`", _mkt_sb)),
}
_sel_bad = {}
_ref = SEL_PS[next(iter(SEL_PS))]
for _pg, _st in SEL_PS.items():
    if _st != _ref or not _st:
        _sel_bad[f"ParameterStore {_pg}"] = {"missing": sorted(_ref - _st), "extra": sorted(_st - _ref)}
for _pg, _st in SEL_SB.items():  # Q-397: no SettlementBudget, so no reading may name one of its selectors
    if _st:
        _sel_bad[f"SettlementBudget (removed) {_pg}"] = {"extra": sorted(_st)}
# Cross-Hub credit-line caps are MarketRegistry parameters (2.8): compared on 1.4, 1.5 and 2.15 only.
REGISTRY_PARAMS = {"crossHubCap"}
PAGES = {"2.15 launch list / SHORT_ELIGIBLE": P215, "2.9 setter table": P29, "2.9 REQ-CONFIG-049": P049,
         "1.5 class column": P15, "1.4 role table": P14, "3.8 MKT-027": P38}
UNIVERSE = sorted(set().union(*PAGES.values()) | NO_TIGHTEN)
# Safer direction per 1.5 class column against the FV-CTL-56 model.
DIR15 = {}
for line in spec_text("01-architecture/05-parameters.md").splitlines():
    if line.startswith("| `"):
        cells = [x.strip() for x in line.strip().strip("|").split("|")]
        m_ = re.match(r"Short \((raise|lower)", cells[-1])
        if m_:
            for n in re.findall(r"`([^`]+)`", cells[0]):
                DIR15["routeDepthThreshold" if pname(n) == "routeDepthThresholdUsd" else pname(n)] = "up" if m_.group(1) == "raise" else "down"
DIR56 = {n: d for n, d, *_ in PARAMS}


def page_agreement(x):
    kind, name = x
    if kind == "anchor":
        bad = {"2.9 REQ-CONFIG-049 names missing": _049_anchor, "3.8 MKT-027 names missing": _38_anchor,
               "no-tighten sentence missing": [k for k, t in _no_tighten_stated.items()
                                               if not all(f"`{n}`" in t for n in NO_TIGHTEN)]}
        return True if not any(bad.values()) else bad
    if kind == "selectors":
        return True if not _sel_bad else _sel_bad
    if kind == "direction":
        return DIR15.get(name) == DIR56.get(name) or {"1.5": DIR15.get(name), "FV-CTL-56 model": DIR56.get(name)}
    pages = {pg: st for pg, st in PAGES.items()
             if not (name in REGISTRY_PARAMS and pg in ("2.9 setter table", "2.9 REQ-CONFIG-049", "3.8 MKT-027"))}
    vals = {pg: (name in st) for pg, st in pages.items()}
    if name in NO_TIGHTEN and any(vals.values()):
        return vals
    return len(set(vals.values())) == 1 or vals


_cases58 = [("anchor", "-"), ("selectors", "-")] + [("param", n) for n in UNIVERSE] + [("direction", n) for n in sorted(DIR56)]
_dis58 = {f"{k}:{n}": r for k, n in _cases58 for r in [page_agreement((k, n))] if r is not True}
# FV-CTL-58 verifies: REQ-CONFIG-049, REQ-ROLE-027, REQ-ROLE-105, REQ-ACCESS-155, REQ-PSTORE-002, MKT-027
exhaustive("FV-CTL-58", "Every page (1.4 role table, 1.5 class column, 2.9 setter table and REQ-CONFIG-049, 2.15 launch list, 3.8 MKT-027) names the same parameters as having a short-delay tighten selector, with the same safer direction, under the compiled ParameterStore selector names; no page or compiled source names a SettlementBudget selector (Q-397); usdBand and grace parameters have none on any page",
           [("all", "-")],
           lambda x: True if not _dis58 else {"disagreements": _dis58}, verifies=["REQ-CONFIG-049", "REQ-ROLE-027", "REQ-ROLE-105", "REQ-ACCESS-155",
                                     "REQ-PSTORE-002", "MKT-027"], targets=["T-71", "T-54"],
           detail=f"{len(UNIVERSE)} parameters compared over {len(PAGES)} page readings; {len(SEL_PS_SRC)} ParameterStore "
                  f"compiled tighten selectors compared with {len(SEL_PS) - 1} page readings; "
                  f"{len(SEL_SB)} SettlementBudget readings checked empty")

# ---------------------------------------------------------------- no SettlementBudget (Q-397)
_sb_files = sorted(str(f.relative_to(_SRC)) for f in _SRC.rglob("*.sol") if "settlement-budget" in str(f) or "SettlementBudget" in f.name)
_sb_refs = sorted(str(f.relative_to(_SRC)) for f in _SRC.rglob("*.sol") if "SettlementBudget" in f.read_text())
# FV-CTL-59 verifies: REQ-BUDGET-006, REQ-BUDGET-017, REQ-BUDGET-019, REQ-ACCESS-058, REQ-ROLE-094
expect("FV-CTL-59", "The SettlementBudget is removed (Q-397): contracts/src holds no settlement-budget interface and no source names it, so no cap, window, reserved floor or draw exists to configure",
       not _sb_files and not _sb_refs, verifies=["REQ-BUDGET-006", "REQ-BUDGET-017", "REQ-BUDGET-019", "REQ-ACCESS-058", "REQ-ROLE-094"],
       targets=["T-79"], cex={"files": _sb_files, "referenced in": _sb_refs})
# FV-CTL-60 verifies: REQ-CONFIG-050, REQ-ACCESS-132, REQ-BUDGET-017, REQ-BUDGET-022, REQ-ROLE-027
expect("FV-CTL-60", "REQ-CONFIG-050 replacement (Q-397): the 2.15 launch short-delay list names no SettlementBudget selector, so floorRoundingAllowance is bounded by its own bounds only",
       "SettlementBudget" not in LAUNCH, verifies=["REQ-CONFIG-050", "REQ-ACCESS-132", "REQ-BUDGET-017", "REQ-BUDGET-022", "REQ-ROLE-027"],
       targets=["T-79"], cex={"launch list contracts": sorted(LAUNCH)})
# Keeper-funded settlement (Q-397). D: debtToCover; phi: flash premium; Kf: caller's own funding; R: swap proceeds;
# top: caller shortfall top-up. Settlement completes when Kf + R + top >= D + phi (the flash principal is returned
# from the same funds); the caller sizes D and its funding for Aave's dust rule up front.
Dk, phk, Kfk, Rk, topk, maxsf, Vk = z3.Ints("debtToCover flashPremium callerFunding proceeds shortfallTopUp maxShortfall seizedValue")
gap = zmax(z3.IntVal(0), Dk + phk - Kfk - Rk)
wf142 = [Dk >= 0, phk >= 0, Kfk >= 0, Rk >= 0, maxsf >= 0, Vk >= 0, topk == gap]
# FV-CTL-142 verifies: SPEC-SET-002, REQ-CONFIG-050, REQ-MREG-010
prove("FV-CTL-142", "Without a SettlementBudget every settlement balances from the caller: with the top-up equal to the rounding gap max(0, D + premium - funding - proceeds), funding + proceeds + top-up >= D + premium, and the top-up is 0 whenever proceeds and funding already cover D + premium",
      z3.And(Kfk + Rk + topk >= Dk + phk, z3.Implies(Kfk + Rk >= Dk + phk, topk == 0)),
      assumptions=wf142, verifies=["SPEC-SET-002", "REQ-CONFIG-050", "REQ-MREG-010"], targets=["T-79"])
# FV-CTL-141 verifies: REQ-CONFIG-050, REQ-BUDGET-006
expect("FV-CTL-141", "Q-397 example: a 10,000 GHO repay flash-borrowed at 5 bps (premium 5 GHO) with 10,004.2 GHO of proceeds leaves a 0.8 GHO gap that the keeper pays as its top-up; with 10,005 GHO of proceeds the top-up is 0",
       max(0, 10_000 * 10**18 + 5 * 10**18 - 10_0042 * 10**17) == 8 * 10**17 and max(0, 10_005 * 10**18 - 10_005 * 10**18) == 0,
       verifies=["REQ-CONFIG-050", "REQ-BUDGET-006"], targets=["T-79"])
# FV-CTL-138 verifies: SPEC-SET-006, REQ-BUDGET-024, REQ-BUDGET-025, REQ-MREG-031, REQ-ACCESS-058
expect("FV-CTL-138", "No per-market budget window remains (Q-397): no source names a market window cap, so one market's liquidations can never draw down another market's settlement funds",
       not any("MarketWindow" in f.read_text() or "marketWindowCap" in f.read_text() for f in _SRC.rglob("*.sol")),
       verifies=["SPEC-SET-006", "REQ-BUDGET-024", "REQ-BUDGET-025", "REQ-MREG-031", "REQ-ACCESS-058"], targets=["T-79"])

# ---------------------------------------------------------------- relational bounds under any setter sequence
cap, sl, ba, la, hb, fma, sa, sm, gh, gd, psm_, bpsr, cby, cbm = z3.Ints(
    "marketUsdCap topUpSliceUsd borrowPriceMaxAge liquidationPriceMaxAge feedHeartbeat feedMaxAge slippageAllowanceBps slippageAllowanceMinBps graceHealthFactor graceDuration poolShareMaxBps retiredSlot buyAllowance buyFloor")
post = z3.Ints("cap_a sl_a ba_a la_a hb_a fma_a sa_a sm_a gh_a gd_a psm_a bpsr_a cby_a cbm_a")
v, v2_, v3_, which = z3.Ints("value value2 value3 setter")
GHMIN, GDMAX = 9 * 10**17, 7_200
ceiling = lambda h: zmin(h + 600, z3.IntVal(4_200))  # noqa: E731


def rel_inv(cp, s_, b, l_, h, fm, a_, m_, g, gdur, ps, bp, cy, cm_):
    return z3.And(cp >= 1, s_ >= 0, s_ <= cp, b >= 0, b <= ceiling(h), b <= l_, h >= 1, h < fm, fm <= l_,
                  m_ >= 1, m_ <= a_, a_ <= 10_000, g >= GHMIN, g < 10**18, gdur >= 0, gdur <= GDMAX,
                  ps >= 0, ps <= 10_000, cm_ >= 1, cm_ <= cy, cy <= 300)


def upd(i, cur, ok, val=None):
    return z3.If(z3.And(which == i, ok), v if val is None else val, cur)


setfeed_ok = z3.And(v >= 1, v < v2_, v2_ <= v3_, ceiling(v) <= v3_)  # setFeed(hb = v, feedMaxAge = v2, liqAge = v3)
setters = z3.And(
    post[0] == upd(0, cap, z3.And(v >= sl, v >= 1)),
    post[1] == upd(1, sl, z3.And(v >= 0, v <= cap)),
    post[2] == z3.If(z3.And(which == 2, v >= 0, v <= ceiling(hb), v <= la), v,
                     z3.If(z3.And(which == 9, setfeed_ok), ceiling(v), ba)),
    post[3] == z3.If(z3.And(which == 3, v >= ba, v >= fma), v, z3.If(z3.And(which == 9, setfeed_ok), v3_, la)),
    post[4] == z3.If(z3.And(which == 9, setfeed_ok), v, hb),
    post[5] == z3.If(z3.And(which == 10, v > hb, v <= la), v, z3.If(z3.And(which == 9, setfeed_ok), v2_, fma)),
    post[6] == upd(4, sa, z3.And(v >= sm, v <= 10_000)),
    post[7] == upd(5, sm, z3.And(v >= 1, v <= sa)),
    post[8] == upd(6, gh, z3.And(v >= GHMIN, v < 10**18)),
    post[9] == upd(7, gd, z3.And(v >= 0, v <= GDMAX)),
    post[10] == upd(8, psm_, z3.And(v >= 0, v <= 10_000)),
    post[11] == bpsr,
    post[12] == upd(12, cby, z3.And(v >= cbm, v >= 1, v <= 300)),
    post[13] == upd(13, cbm, z3.And(v >= 1, v <= cby)),
    which >= 0, which <= 13)
# FV-CTL-61 verifies: REQ-CONFIG-050, REQ-CONFIG-052, REQ-CONFIG-023, REQ-PSTORE-016, REQ-PSTORE-015, REQ-ACCESS-095, REQ-ACCESS-096, INV-047
prove("FV-CTL-61", "Under any sequence of tighten, loosen, structural and setFeed calls every relational bound stays satisfied: slice <= cap, borrowPriceMaxAge <= min(heartbeat + 600, 4,200) and <= liquidationPriceMaxAge, heartbeat < feedMaxAge <= liquidationPriceMaxAge, slippage floor, grace bounds, poolShareMaxBps <= 10,000, buy floor <= allowance",
      rel_inv(*post), assumptions=[rel_inv(cap, sl, ba, la, hb, fma, sa, sm, gh, gd, psm_, bpsr, cby, cbm), setters],
      verifies=["REQ-CONFIG-050", "REQ-CONFIG-052", "REQ-CONFIG-023", "REQ-PSTORE-016", "REQ-PSTORE-015", "REQ-ACCESS-095",
                "REQ-ACCESS-096", "INV-047"], targets=["T-71"])

# The drift check (activation, every borrow, withdraw-with-debt and new-account pledge) requires drawCap == 0 for
# the vault-token asset on every Spoke listed on it (INV-029, REQ-CONFIG-043); three Spokes unrolled.
dc = [z3.Int(f"vaultAssetDrawCap_spoke{k}") for k in range(3)]
drift_ok = z3.And([x == 0 for x in dc])
opened = z3.Bool("borrow_or_newAccountPledge_completed")
# FV-CTL-99 verifies: INV-029, REQ-CONFIG-043, INV-057
prove("FV-CTL-99", "No borrow, withdraw-with-debt or new-account pledge completes while any Spoke can draw the vault-token asset",
      z3.Implies(z3.And(opened, opened == drift_ok), z3.And([x == 0 for x in dc])), assumptions=[x >= 0 for x in dc],
      verifies=["INV-029", "REQ-CONFIG-043", "INV-057"], targets=["T-80"],
      detail="The sum of Borrow Spoke drawCaps against the credit line is Aave DAO configuration checked by the live-config check.")

# ---------------------------------------------------------------- the short-delay list and SHORT_ELIGIBLE
SHORT_ELIGIBLE = {(t, s) for t, sels in LAUNCH.items() for s in sels}
# Effect of each pair (REQ-ACCESS-155: tighten within liveness bounds, stop new activity, or restore reviewed config).
EFFECT = {s: "tighten" for s in LAUNCH["ParameterStore"]}
EFFECT.update({"disableRoute": "stop", "disableBuyRoute": "stop", "setMarketOffboarding": "stop",
               "freeze": "stop", "pause": "stop", "freezeAddress": "stop", "tripMarketBreaker": "stop",
               "tripDebtBreaker": "stop", "removeKeeper": "stop", "cancelRegistration": "stop",
               "restoreRoute": "restore", "restoreBuyRoute": "restore", "activateMarket": "restore", "useStandbyRoute": "restore",
               # AMM-neutral design (2.15 REQ-ACCESS-155): activation of a reviewed Spoke or debt reserve restores
               # reviewed configuration; the chain-wide stops and the cross-Hub controls only stop or tighten.
               "activateCdpSpoke": "restore", "activateDebtReserve": "restore", "freezeAll": "stop",
               "pauseAll": "stop", "tightenCrossHubCap": "tighten", "disableCrossHubLines": "stop"})
FORBIDDEN_SELECTORS = {"grantRole", "revokeRole", "renounceRole", "upgradeToAndCall", "setProxyImplementation",
                       "initialize", "setNormalDelay", "setShortDelaySelector", "togglePublicExecution", "setPriceSource",
                       "setRoute", "setBuyRoute", "setSellBackRoute", "addKeeper", "unfreezeAddress", "unfreeze",
                       "unpause", "resetMarketBreaker", "resetDebtBreaker", "restorePriceRoute", "registerMarket",
                       "listToken", "approveSpoke", "approveDebtReserve", "withdraw"}
LOOSEN_OR_SET = set()
for r in table_after("02-contracts/09-parameter-store.md", "| `initialize(address timelock"):
    LOOSEN_OR_SET |= set(re.findall(r"\b((?:loosen|set)[A-Z]\w*)", r[0]))
LOOSEN_OR_SET |= {"loosen" + s_[len("tighten"):] for s_ in LAUNCH["ParameterStore"]}  # "the matching loosen… setters"
# Per-pool pool-share cap (Q-383, Q-399): the tighten selector is short (a SHORT_ELIGIBLE member, effect "tighten"),
# the loosen selector is a forbidden short selector (normal delay only). Stated here so a launch-list change that drops
# the tighten selector, or a reading that puts the loosen selector on the list, fails FV-CTL-62.
POOL_SHARE_OF_SHORT, POOL_SHARE_OF_FORBIDDEN = "tightenPoolShareMaxBpsOf", "loosenPoolShareMaxBpsOf"
EFFECT[POOL_SHARE_OF_SHORT] = "tighten"
LOOSEN_OR_SET.add(POOL_SHARE_OF_FORBIDDEN)
PARAM_LOOSEN_RE = re.compile(r"^(loosen|set|raise)[A-Z]")


def short_list_case(x):
    kind = x[0]
    if kind == "pool-share-of":
        bad = {}
        if ("ParameterStore", POOL_SHARE_OF_SHORT) not in SHORT_ELIGIBLE:
            bad["not short-eligible"] = POOL_SHARE_OF_SHORT
        if ("ParameterStore", POOL_SHARE_OF_FORBIDDEN) in SHORT_ELIGIBLE:
            bad["loosen selector short-eligible"] = POOL_SHARE_OF_FORBIDDEN
        return True if not bad else bad
    if kind == "member":
        t_, s_ = x[1]
        eff = EFFECT.get(s_)
        if eff is None:
            return {"unclassified": s_}
        if s_ in FORBIDDEN_SELECTORS or s_ in LOOSEN_OR_SET or t_ == "AvanaTimelock":
            return {"forbidden": s_}
        if PARAM_LOOSEN_RE.match(s_) and t_ == "ParameterStore":
            return {"parameter loosen/set selector": s_}
        return True
    # kind == "step": setShortDelaySelector(target, selector, enabled) from a list that is a subset of SHORT_ELIGIBLE
    _, pair, enabled, cur = x
    after = (cur | {pair}) if (enabled and pair in SHORT_ELIGIBLE) else (cur - {pair}) if not enabled else cur
    return after <= SHORT_ELIGIBLE or {"after": sorted(after - SHORT_ELIGIBLE)}


_cands = sorted(SHORT_ELIGIBLE) + [("ParameterStore", s) for s in sorted(LOOSEN_OR_SET)] + \
         [("MarketRegistry", s) for s in sorted(FORBIDDEN_SELECTORS)] + [("AvanaTimelock", "setNormalDelay")]
_some = [frozenset(SHORT_ELIGIBLE), frozenset(), frozenset(list(SHORT_ELIGIBLE)[:5])]
# FV-CTL-62 verifies: REQ-ACCESS-142, REQ-ACCESS-155, REQ-ACCESS-141, REQ-CONFIG-053, REQ-PSTORE-002
exhaustive("FV-CTL-62", "SHORT_ELIGIBLE (2.15 launch list) holds no loosen, structural set, role, upgrade, implementation-setter, initializer, timelock, price-source, route, keeper-add, unfreeze or reset selector; setShortDelaySelector(..., true) admits only SHORT_ELIGIBLE pairs, so no loosen selector can ever be short",
           [("pool-share-of", "-")] + [("member", pr) for pr in sorted(SHORT_ELIGIBLE)] +
           [("step", pr, en, set(cur)) for pr in _cands for en in (True, False) for cur in _some],
           short_list_case, verifies=["REQ-ACCESS-142", "REQ-ACCESS-155", "REQ-ACCESS-141", "REQ-CONFIG-053",
                                      "REQ-PSTORE-002"], targets=["T-71", "T-54"],
           detail=f"{len(SHORT_ELIGIBLE)} SHORT_ELIGIBLE pairs; {len(LOOSEN_OR_SET)} ParameterStore loosen or set selectors")

STOPS = ("freeze", "pause", "freezeAddress", "tripMarketBreaker", "tripDebtBreaker", "useStandbyRoute")
_acc128 = spec_line(GOV, "| `REQ-ACCESS-128` |")
_MR_FN = [l_ for l_ in spec_text("02-contracts/08-market-registry.md").splitlines() if l_.startswith("| `")]


def mr_caller_cell(fn):
    for l_ in _MR_FN:
        cells = [x.strip() for x in l_.strip().strip("|").split("|")]
        if f"`{fn}(" in cells[0] and len(cells) >= 3:
            return cells[2]
    return ""


def required_delay(calls, short_list, normal):
    return SHORT_DELAY if calls and all(cl in short_list for cl in calls) else normal


def stop_case(s_):
    pair = ("MarketRegistry", s_)
    if pair not in SHORT_ELIGIBLE:
        return {"not short-eligible": s_}
    if "`APPLICATION_ADMIN` (short" not in mr_caller_cell(s_):
        return {"2.8 function table: APPLICATION_ADMIN at the short delay missing": s_}
    if f"`{s_}" not in _acc128:
        return {"REQ-ACCESS-128 omits": s_}
    batch = [("MarketRegistry", x) for x in STOPS]
    return (required_delay(batch, SHORT_ELIGIBLE, MIN_NORMAL_DELAY) == SHORT_DELAY < MIN_NORMAL_DELAY
            and required_delay(batch + [("MarketRegistry", "unpause")], SHORT_ELIGIBLE, MIN_NORMAL_DELAY) == MIN_NORMAL_DELAY)


# FV-CTL-140 verifies: REQ-ACCESS-155, REQ-ACCESS-128, REQ-ACCESS-062, REQ-ACCESS-063, REQ-MREG-028, SPEC-GOV-001
exhaustive("FV-CTL-140", "With both guardians unavailable the governance Safe halts new activity at the short delay: freeze, pause, freezeAddress, both breaker trips and useStandbyRoute are APPLICATION_ADMIN selectors in SHORT_ELIGIBLE, so a batch of them needs 43,200 s; adding a lift makes it normal",
           list(STOPS), stop_case, verifies=["REQ-ACCESS-155", "REQ-ACCESS-128", "REQ-ACCESS-062", "REQ-ACCESS-063",
                                             "REQ-MREG-028", "SPEC-GOV-001"], targets=["T-54"])

# ---------------------------------------------------------------- short selectors of the owning pages vs SHORT_ELIGIBLE
# AMM-neutral design: the owning contract page names each tighten selector and its delay; SHORT_ELIGIBLE (2.15) is a
# selector set, so a selector a page marks short but SHORT_ELIGIBLE does not hold executes at the normal delay.
_short_owner = {}
for r in table_after("02-contracts/09-parameter-store.md", "| `initialize(address timelock"):
    if len(r) >= 3 and "short" in r[2].lower():
        for s_ in re.findall(r"(tighten[A-Z]\w*)", r[0]):
            _short_owner[("ParameterStore", s_)] = "2.9"
_missing153 = sorted(f"{t}.{s_} ({pg})" for (t, s_), pg in _short_owner.items() if (t, s_) not in SHORT_ELIGIBLE)
_extra153 = sorted(f"{t}.{s_}" for t, s_ in SHORT_ELIGIBLE if t == "ParameterStore" and (t, s_) not in _short_owner)
open_finding("FV-CTL-153", "FV-CTL-F-26")
# FV-CTL-153 verifies: REQ-ACCESS-141, REQ-ACCESS-155, REQ-CONFIG-049, REQ-PSTORE-024
expect("FV-CTL-153", "Every ParameterStore tighten selector that its owning page (2.9 setter table) marks short is in SHORT_ELIGIBLE, and SHORT_ELIGIBLE names no ParameterStore tighten selector that 2.9 does not define",
       not _missing153 and not _extra153, verifies=["REQ-ACCESS-141", "REQ-ACCESS-155", "REQ-CONFIG-049", "REQ-PSTORE-024"],
       targets=["T-54", "T-71"], detail=f"{len(_short_owner)} short selectors read from the owning pages",
       cex={"short on the owning page, missing from SHORT_ELIGIBLE": _missing153,
            "in SHORT_ELIGIBLE, not defined on 2.9": _extra153})

sys.exit(finish())
