# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-GOV-16..24: the timelock delay floor and the exit window, the short-delay allowlist, loosening
steps and spacing, the restoring cancel mark, expiry clean-up and guardian removal
([2.15] SPEC-GOV-003, 005, 006, 011, 012, 013, 014, 015; REQ-ACCESS-142, 152, 154, 156).

All times are integer seconds; no rounding except k_max = floor((MIN_NORMAL_DELAY - r) / 12) - 1.
Constants: SHORT_DELAY 43,200; MIN_NORMAL_DELAY 345,600; MAX_DELAY 432,000; GRACE_PERIOD 1,209,600.
"""
from z3 import Int, Ints, Bool, Bools, If, And, Or, Not, Implies
from _common import check, done

SHORT, MIN_NORMAL, MAX, GRACE = 43_200, 345_600, 432_000, 1_209_600
R_DESIGN = 259_200
WAD = 10**18

k, r, normal = Ints("k r normalDelay")
need = r + 12 * (k + 1)

# MATH-GOV-16 verifies: SPEC-GOV-015, SPEC-GOV-014, REQ-ACCESS-154
check("MATH-GOV-16",
      "at every reachable normal delay (>= MIN_NORMAL_DELAY) a borrower with k <= 7,199 NFTs and a 3-day reaction exits first",
      [k >= 0, k <= 7_199, r >= 0, r <= R_DESIGN, normal >= MIN_NORMAL, normal <= MAX, need > normal],
      "PROVED")
# MATH-GOV-17 verifies: SPEC-GOV-015
check("MATH-GOV-17",
      "the bound is exact: k = 7,200 at the floor needs 345,612 s > 345,600 s (deliberate counterexample, why k_max = 7,199)",
      [k == 7_200, r == R_DESIGN, normal == MIN_NORMAL, need > normal],
      "COUNTEREXAMPLE", show=[k, r, normal])
km = Int("k_max")
# MATH-GOV-18 verifies: SPEC-GOV-015
check("MATH-GOV-18",
      "k_max = floor((MIN_NORMAL_DELAY - r) / 12) - 1 is the largest k with r + 12(k+1) <= MIN_NORMAL_DELAY, for every r <= MIN_NORMAL_DELAY - 12",
      [r >= 0, r <= MIN_NORMAL - 12, km == (MIN_NORMAL - r) / 12 - 1,
       Or(r + 12 * (km + 1) > MIN_NORMAL, r + 12 * (km + 2) <= MIN_NORMAL)],
      "PROVED")

# MATH-GOV-19: short-delay allowlist (REQ-ACCESS-142, REQ-ACCESS-152). One (target, selector) pair x.
# setShortDelaySelector(x, true) succeeds only if x is in the immutable SHORT_ELIGIBLE; (x, false) always.
STEPS = 5
eligible = Bool("eligible")
listed0 = Bool("listed0")
en = [Bool(f"enable_{i}") for i in range(STEPS)]
listed = [listed0]
for i in range(STEPS):
    listed.append(If(en[i], Or(listed[-1], eligible), And(listed[-1], Bool(f"keep_{i}"))))
is_role_or_upgrade = Bool("roleUpgradeBeaconOrTimelockTarget")
# MATH-GOV-19 verifies: SPEC-GOV-001, SPEC-GOV-015, REQ-ACCESS-142, REQ-ACCESS-152
check("MATH-GOV-19",
      f"over {STEPS} setShortDelaySelector calls a pair outside SHORT_ELIGIBLE (every role, upgrade, beacon and timelock pair) never becomes short",
      [Implies(is_role_or_upgrade, Not(eligible)), Implies(listed0, eligible), is_role_or_upgrade,
       Or([x for x in listed])],
      "PROVED")
t_s, d = Ints("t_s delay")
# MATH-GOV-19 verifies: SPEC-GOV-001, SPEC-GOV-014, SPEC-GOV-015
check("MATH-GOV-19b",
      "hence any batch containing an upgrade or role call is ready no earlier than t_s + MIN_NORMAL_DELAY",
      [normal >= MIN_NORMAL, normal <= MAX, t_s >= 0, d >= normal, t_s + d < t_s + MIN_NORMAL],
      "PROVED")

# MATH-GOV-20: loosening step and spacing (SPEC-GOV-011), evaluated at execution.
old, new, cap, t1, t2, t3, c0, c1, c2, c3 = Ints("old new marketUsdCap tLoosen1 tLoosen2 tLoosen3 cap0 cap1 cap2 cap3")
# MATH-GOV-20 verifies: SPEC-GOV-011, REQ-ACCESS-120
check("MATH-GOV-20",
      "cap step new * 10^4 <= old * 15,000 admits exactly new <= 1.5 * old (no rounding in the loosener's favour)",
      [old >= 0, old < 2**128, new >= 0, Not((new * 10_000 <= old * 15_000) == (2 * new <= 3 * old))],
      "PROVED")
# MATH-GOV-20 verifies: SPEC-GOV-011
check("MATH-GOV-20b",
      "three loosenings of one cap key: at most 3.375x the start value and at least 2 x MIN_NORMAL_DELAY between the first and the third",
      [c0 >= 1, c1 * 10_000 <= c0 * 15_000, c2 * 10_000 <= c1 * 15_000, c3 * 10_000 <= c2 * 15_000,
       normal >= MIN_NORMAL, t1 >= 0, t2 >= t1 + normal, t3 >= t2 + normal,
       Or(8 * c3 > 27 * c0, t3 - t1 < 2 * MIN_NORMAL)],
      "PROVED")
# hardHealthFloor (optional per-market floor, Q-398): 0 means off; a set value lies in [1.00e18, 1.25e18]. One
# loosening step is old - new <= 0.03e18, where a value of 0 (off) counts as 1.00e18.
eff = lambda v: If(v == 0, WAD, v)
# MATH-GOV-20 verifies: SPEC-GOV-011
check("MATH-GOV-20c",
      "hardHealthFloor loosening: old - new <= 0.03e18 per step (0, off, counts as 1.00e18), so one step from 1.10 "
      "reaches at most 1.07 and cannot switch the floor off; switching off needs a set floor of at most 1.03",
      [Or(old == 0, And(old >= WAD, old <= 125 * 10**16)), Or(new == 0, And(new >= WAD, new <= 125 * 10**16)),
       eff(new) < eff(old), eff(old) - eff(new) <= 3 * 10**16,
       Or(And(old == 110 * 10**16, eff(new) < 107 * 10**16),
          And(old == 110 * 10**16, new == 0),
          And(new == 0, old > 103 * 10**16))],
      "PROVED")
sl_old, sl_new = Ints("sliceOld sliceNew")
base_sl = If(sl_old > cap / 10, sl_old, cap / 10)
# MATH-GOV-20 verifies: SPEC-GOV-011
check("MATH-GOV-20d",
      "topUpSliceUsd loosening from 0 is capped by 1.5 x floor(marketUsdCap / 10): a 4,000,000e8 cap admits at most 600,000e8",
      [cap == 4_000_000 * 10**8, sl_old == 0, sl_new * 10_000 <= base_sl * 15_000, sl_new > 600_000 * 10**8],
      "PROVED")

# MATH-GOV-21: restoring mark (SPEC-GOV-005, REQ-ACCESS-156). The immutable DAO-only cancel set is MarketRegistry
# restoreRoute, useStandbyRoute, unfreezeAddress and LPVaultSwap addKeeper; membership depends on (target, selector)
# only, never on arguments. Per call i < n: inSet_i. restoring = n >= 1 and
# every call in the set; a batch that mixes a restoring call with any other call keeps the ordinary cancel rule.
NR = 4
nr = Int("nCalls")
inSet = [Bool(f"inSet_{i}") for i in range(NR)]
restoring = And(nr >= 1, And([Or(i >= nr, inSet[i]) for i in range(NR)]))
mixed = And(Or([And(i < nr, inSet[i]) for i in range(NR)]), Or([And(i < nr, Not(inSet[i])) for i in range(NR)]))
# MATH-GOV-21 verifies: SPEC-GOV-005, REQ-ACCESS-156
check("MATH-GOV-21",
      "an operation is restoring iff it has at least one call and every call is in the DAO-only cancel set; an empty "
      "batch or one mixing a DAO-only call with any other call is never restoring",
      [nr >= 0, nr <= NR,
       Or(And(mixed, restoring), And(nr == 0, restoring),
          And(nr >= 1, And([Or(i >= nr, inSet[i]) for i in range(NR)]), Not(restoring)))],
      "PROVED")

# MATH-GOV-22: expiry and clean-up (SPEC-GOV-013).
ready, tc, t_new, d_new, req = Ints("readyAt t_cleanup t_reschedule delay_new requiredDelay")
expired = tc >= ready + GRACE
# MATH-GOV-22 verifies: SPEC-GOV-013, REQ-ACCESS-126
check("MATH-GOV-22",
      "cleanupExpiredOperation succeeds only when the operation can no longer execute, and the same calls scheduled again are ready only after a fresh requiredDelay",
      [ready > 1, req >= SHORT, t_new >= tc, d_new >= req,
       Or(And(expired, tc < ready + GRACE),                 # cleaned up while still executable
          And(expired, t_new + d_new < tc + req))],         # rescheduled ready before a fresh delay
      "PROVED")

# MATH-GOV-23: liveness and governance bounds (SPEC-GOV-012): every accepted normalDelay keeps a normal-delay
# operation scheduled at exactly requiredDelay between 4 and 5 days.
# MATH-GOV-23 verifies: SPEC-GOV-012, SPEC-GOV-003, REQ-ACCESS-125
check("MATH-GOV-23",
      "an accepted setNormalDelay value v (MIN_NORMAL_DELAY <= v <= MAX_DELAY) gives a wait of 4 to 5 days at the required delay",
      [normal >= MIN_NORMAL, normal <= MAX, d == normal, Or(d < 4 * 86_400, d > 5 * 86_400)],
      "PROVED")

# MATH-GOV-24: removal of a guardian (SPEC-GOV-006). A batch of only revokeRole calls is a role-change operation;
# a guardian (canceller without DAO_CANCELLER_ROLE) cannot cancel it, and public execution at readyAt ends the
# guardian's power no later than t_s + delay.
canc, dao, pure_revoke = Bools("canceller daoCanceller pureRevokeBatch")
t_exec, t_act = Ints("t_exec t_guardianAction")
has_power = t_act < t_exec                                # the role is revoked when the batch executes
# MATH-GOV-24 verifies: SPEC-GOV-006, SPEC-GOV-005
check("MATH-GOV-24",
      "a pure revokeRole batch cannot be cancelled by a guardian, and executed at readyAt it leaves the guardian no power from t_s + delay on",
      [pure_revoke, canc, Not(dao), normal >= MIN_NORMAL, normal <= MAX, d >= normal, t_s >= 0,
       t_exec == t_s + d,
       Or(And(canc, Or(Not(pure_revoke), dao)),           # the guardian's cancel would succeed
          And(has_power, t_act >= t_s + d))],            # the guardian still acts with power at or after readyAt
      "PROVED")

done()
