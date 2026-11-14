#!/usr/bin/env python3
"""FV-C AvanaTimelock: required delay, execution window and expiry, the normal-delay floor, cancel rights
(role-change and restoring operations), the short-delay allowlist and the exit window.

How Avana works here: an operation takes the short delay (12 hours) only when every call is on the
short-delay list, which is always a subset of the constructor-fixed SHORT_ELIGIBLE set; every other
operation takes `normalDelay`, which stays within [MIN_NORMAL_DELAY, MAX_DELAY] = [4 days, 5 days]. A
role-change operation (every call a role call) and a restoring operation (every call in the immutable DAO-only
cancel set) can be cancelled only by DAO_CANCELLER_ROLE; any other operation by every canceller. With the
floor, a borrower with a 3-day reaction can leave with up to 7,199 positions before any normal-delay change.

Targets: T-54, T-55, T-64 (delay part). Batches are unrolled to N_CALLS calls (stated bound); timing
properties are over unbounded integers.
"""
import sys

import z3

from common import exhaustive, expect, finish, prove, zmax

SHORT, MIN_ND, MAX, GRACE = 43_200, 345_600, 432_000, 1_209_600
N_CALLS = 4  # batch length bound for the symbolic batch checks

# ---------------------------------------------------------------- SPEC-GOV-001 required delay
n = z3.Int("n")
short = [z3.Bool(f"short_{i}") for i in range(N_CALLS)]
normal = z3.Int("normalDelay")
delay = z3.Int("delay")
nd_ok = z3.And(normal >= MIN_ND, normal <= MAX)


def all_short(k, flags):
    return z3.And(k >= 1, *[z3.Implies(i < k, flags[i]) for i in range(N_CALLS)])


def required(k, flags):
    return z3.If(all_short(k, flags), z3.IntVal(SHORT), normal)


sched_ok = z3.And(delay >= required(n, short), delay >= SHORT)  # DelayBelowRequired + OZ getMinDelay check
batch = [n >= 0, n <= N_CALLS, nd_ok]
# FV-CTL-16 verifies: SPEC-GOV-001, REQ-ACCESS-141, REQ-ACCESS-117, INV-068
prove("FV-CTL-16", "schedule succeeds only with delay >= requiredDelay; one non-listed call makes the batch normal",
      z3.Implies(sched_ok, z3.And(delay >= SHORT,
                                  z3.Implies(z3.Or([z3.And(i < n, z3.Not(short[i])) for i in range(N_CALLS)]),
                                             delay >= normal),
                                  z3.Implies(n == 0, delay >= normal))),
      assumptions=batch, verifies=["SPEC-GOV-001", "REQ-ACCESS-141", "REQ-ACCESS-117", "INV-068"],
      targets=["T-54"], detail=f"batches of up to {N_CALLS} calls")

# Splitting: required(A ++ B) = max(required(A), required(B)) for non-empty A, B (no split lowers the delay).
m = z3.Int("m")
short_b = [z3.Bool(f"shortB_{i}") for i in range(N_CALLS)]
cat_flags = [z3.If(i < n, short[i], z3.Or([z3.And(i - n == j, short_b[j]) for j in range(N_CALLS)]))
             for i in range(N_CALLS)]
# FV-CTL-17 verifies: SPEC-GOV-001, REQ-ROLE-105
prove("FV-CTL-17", "A batch never needs less delay than any of its parts (no riding a loosening on a tightening batch)",
      required(n + m, cat_flags) == zmax(required(n, short), required(m, short_b)),
      assumptions=batch + [m >= 1, n >= 1, n + m <= N_CALLS],
      verifies=["SPEC-GOV-001", "REQ-ROLE-105"], targets=["T-54"])

# ---------------------------------------------------------------- SPEC-GOV-002 / SPEC-GOV-013 window
ts, t, ready = z3.Ints("t_s t readyAt")
pred_done = z3.Bool("predecessor_done")
executable = z3.And(ready <= t, t < ready + GRACE, pred_done)
expired = t >= ready + GRACE
# FV-CTL-18 verifies: SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-118, REQ-ACCESS-144, REQ-ACCESS-126
prove("FV-CTL-18", "From readyAt on an operation is exactly one of executable or expired; never executable before readyAt",
      z3.And(z3.Implies(z3.And(t >= ready, pred_done), z3.Xor(executable, expired)),
             z3.Implies(t < ready, z3.And(z3.Not(executable), z3.Not(expired))),
             z3.Implies(executable, t - ts >= delay)),
      assumptions=[ready == ts + delay, delay >= SHORT, ts >= 0],
      verifies=["SPEC-GOV-002", "SPEC-GOV-013", "REQ-ACCESS-118", "REQ-ACCESS-126"], targets=["T-54"])
# Worked example of SPEC-GOV-002: scheduled 1,780,000,000 with 432,000 -> executable through 1,781,641,599.
expect("FV-CTL-18-EX", "SPEC-GOV-002 example: last executable second 1,781,641,599, expiry at 1,781,641,600",
       1_780_000_000 + MAX + GRACE - 1 == 1_781_641_599, verifies=["SPEC-GOV-002"], targets=["T-54"])

# ---------------------------------------------------------------- SPEC-GOV-003 normal-delay change
old, new, cut_s, cut_x, s_op, d_op = z3.Ints("old new cut_scheduled cut_executed op_scheduled op_delay")
nd_at = z3.If(s_op >= cut_x, new, old)  # requiredDelay is read at scheduling (SPEC-GOV-003)
# FV-CTL-19 verifies: SPEC-GOV-003, REQ-ACCESS-125, REQ-ACCESS-017
prove("FV-CTL-19", "After a normal-delay cut, any operation using the shorter delay executes no earlier than old + new (at least 8 days) after the cut was scheduled",
      z3.And(z3.Implies(d_op < old, s_op + d_op >= cut_s + old + new),
             z3.Implies(d_op < old, s_op + d_op - cut_s >= 2 * MIN_ND)),
      assumptions=[old >= MIN_ND, old <= MAX, new >= MIN_ND, new <= MAX, new < old, cut_x >= cut_s + old,
                   d_op >= nd_at, s_op >= 0, cut_s >= 0],
      verifies=["SPEC-GOV-003", "REQ-ACCESS-125", "REQ-ACCESS-017"], targets=["T-54"])

# normalDelay stays in [SHORT_DELAY, MAX_DELAY] (inductive over setNormalDelay; updateDelay always reverts).
nd, nd2, arg = z3.Ints("nd nd_after newDelay")
which = z3.Int("call")  # 0 setNormalDelay, 1 updateDelay, 2 any other selector
trans = z3.And(z3.Implies(which == 0, nd2 == z3.If(z3.And(arg >= MIN_ND, arg <= MAX), arg, nd)),
               z3.Implies(which == 1, nd2 == nd), z3.Implies(which == 2, nd2 == nd))
# FV-CTL-20 verifies: SPEC-GOV-012, SPEC-GOV-015, REQ-ACCESS-030, REQ-ACCESS-140, REQ-ACCESS-154, REQ-ACCESS-125
prove("FV-CTL-20", "normalDelay stays within [MIN_NORMAL_DELAY, MAX_DELAY] = [345,600, 432,000] (base 432,000; every step preserves it)",
      z3.And(nd2 >= MIN_ND, nd2 <= MAX), assumptions=[nd >= MIN_ND, nd <= MAX, which >= 0, which <= 2, trans],
      verifies=["SPEC-GOV-012", "SPEC-GOV-015", "REQ-ACCESS-030", "REQ-ACCESS-140", "REQ-ACCESS-154",
                "REQ-ACCESS-125"], targets=["T-54"])
# SPEC-GOV-003 / SPEC-GOV-012 examples: 345,599, 259,200, 300,000, 432,001 and 864,000 revert; 345,600 executes.
accepted = lambda v: MIN_ND <= v <= MAX
# FV-CTL-20-EX verifies: SPEC-GOV-003, SPEC-GOV-012, SPEC-GOV-015
expect("FV-CTL-20-EX", "setNormalDelay examples: 345,600 and 432,000 accepted; 345,599, 259,200, 300,000, 432,001 and 864,000 revert DelayOutOfBounds; a cut scheduled at 1,780,000,000 lets an upgrade be ready at 1,780,777,600",
       accepted(345_600) and accepted(432_000) and not any(accepted(v) for v in (345_599, 259_200, 300_000, 432_001, 864_000))
       and 1_780_000_000 + 432_000 + 345_600 == 1_780_777_600,
       verifies=["SPEC-GOV-003", "SPEC-GOV-012", "SPEC-GOV-015"], targets=["T-54"])

# ---------------------------------------------------------------- SPEC-GOV-005 cancel rights
# Each call of a batch is one of: a role call (grantRole/revokeRole/renounceRole), a call in the DAO-only cancel set
# (restoreRoute, restoreBuyRoute, useStandbyRoute, unfreezeAddress, addKeeper), or any other call. The in-kind
# selectors (enableInKind, setInKindAutoTrigger) are removed (Q-401); kinds 2 and 3 are kept as unused slots and
# fixed to 'other' so the model's shape is unchanged.
K_ROLE, K_DAO, K_IKAT_T, K_IKAT_F, K_OTHER = range(5)
kind = [z3.Int(f"call_kind_{i}") for i in range(N_CALLS)]
has_c, has_dao = z3.Bools("hasCanceller hasDaoCanceller")


def every(pred):
    return z3.And(n >= 1, *[z3.Implies(i < n, pred(kind[i])) for i in range(N_CALLS)])


role_change = every(lambda k: k == K_ROLE)
restoring = every(lambda k: z3.Or(k == K_DAO, k == K_IKAT_T))
cancel_ok = z3.And(has_c, z3.Or(z3.And(z3.Not(role_change), z3.Not(restoring)), has_dao))
some_ordinary = z3.Or([z3.And(i < n, z3.Or(kind[i] == K_OTHER, kind[i] == K_IKAT_F,
                                             z3.And(kind[i] == K_ROLE, z3.Or([z3.And(j < n, kind[j] != K_ROLE)
                                                                              for j in range(N_CALLS)])),
                                             z3.And(z3.Or(kind[i] == K_DAO, kind[i] == K_IKAT_T),
                                                    z3.Or([z3.And(j < n, z3.Or(kind[j] == K_ROLE, kind[j] == K_OTHER,
                                                                               kind[j] == K_IKAT_F))
                                                           for j in range(N_CALLS)]))))
                       for i in range(N_CALLS)])
kinds_wf = [z3.Or(k == K_ROLE, k == K_DAO, k == K_OTHER) for k in kind]
# FV-CTL-21 verifies: SPEC-GOV-005, REQ-ACCESS-020, REQ-ACCESS-143, REQ-ACCESS-156, REQ-ACCESS-163, INV-068, INV-090
prove("FV-CTL-21", "Only DAO_CANCELLER cancels a pure role-change or pure restoring operation; every canceller cancels a mixed batch or any other operation",
      z3.And(z3.Implies(z3.And(z3.Or(role_change, restoring), z3.Not(has_dao)), z3.Not(cancel_ok)),
             z3.Implies(z3.And(z3.Not(role_change), z3.Not(restoring), has_c), cancel_ok),
             z3.Implies(z3.And(has_c, has_dao), cancel_ok),
             z3.Implies(z3.And(n >= 1, z3.Not(role_change), z3.Not(restoring)), some_ordinary),
             z3.Not(z3.And(role_change, restoring))),
      assumptions=[n >= 0, n <= N_CALLS] + kinds_wf,
      verifies=["SPEC-GOV-005", "REQ-ACCESS-020", "REQ-ACCESS-143", "REQ-ACCESS-156", "REQ-ACCESS-163",
                "INV-068", "INV-090"],
      targets=["T-55"])

# SPEC-GOV-005 examples, evaluated with the same predicates on concrete batches.
def marks(batch):
    rc = len(batch) >= 1 and all(k == K_ROLE for k in batch)
    rs = len(batch) >= 1 and all(k in (K_DAO, K_IKAT_T) for k in batch)
    return rc, rs


def guardian_may_cancel(batch):  # a guardian holds CANCELLER_ROLE, not DAO_CANCELLER_ROLE
    rc, rs = marks(batch)
    return not rc and not rs


EXAMPLES = [  # (description, batch, guardian may cancel per SPEC-GOV-005 / SPEC-GOV-006 / REQ-MREG-022)
    ("[revokeRole(PAUSE_G, g), unpause()]", [K_ROLE, K_OTHER], True),
    ("[revokeRole(PAUSE_G, g)]", [K_ROLE], False),
    ("[upgradeToAndCall, grantRole(PAUSE_G, g)]", [K_OTHER, K_ROLE], True),
    ("[restoreRoute(m1), restoreRoute(m2)]", [K_DAO, K_DAO], False),
    ("[restoreRoute, useStandbyRoute, loosenTopUpSliceUsd]", [K_DAO, K_DAO, K_OTHER], True),
    ("[unfreezeAddress(W)]", [K_DAO], False),
    ("[useStandbyRoute(USDC, Primary)] by APPLICATION_ADMIN", [K_DAO], False),
    ("[revokeRole(PAUSE_G, g), revokeRole(FREEZE_G, g)]", [K_ROLE, K_ROLE], False),
    ("[] (empty batch)", [], True),
]
# FV-CTL-21-EX verifies: SPEC-GOV-005, SPEC-GOV-006, REQ-MREG-022, REQ-MREG-028
exhaustive("FV-CTL-21-EX", "SPEC-GOV-005 and SPEC-GOV-006 examples: who may cancel each listed batch",
           EXAMPLES, lambda e: guardian_may_cancel(e[1]) == e[2] or {"batch": e[0], "guardian_may_cancel": not e[2]},
           verifies=["SPEC-GOV-005", "SPEC-GOV-006", "REQ-MREG-022", "REQ-MREG-028"], targets=["T-55"])

# SPEC-GOV-007 cancel window and SPEC-GOV-006 guardian removal.
t_exec = z3.Int("t_exec")
# FV-CTL-22 verifies: SPEC-GOV-007, SPEC-GOV-006, REQ-ACCESS-112
prove("FV-CTL-22", "The cancel window lasts at least requiredDelay; a guardian cannot cancel its own pure revocation, which anyone executes at readyAt",
      z3.And(t_exec - ts >= required(n, short),
             z3.Implies(z3.And(role_change, z3.Not(has_dao)), z3.Not(cancel_ok))),
      assumptions=batch + kinds_wf + [sched_ok, ready == ts + delay, t_exec >= ready],
      verifies=["SPEC-GOV-007", "SPEC-GOV-006", "REQ-ACCESS-112"], targets=["T-55"])

# ---------------------------------------------------------------- short-delay allowlist
FORBIDDEN_SHORT = {"grantRole", "revokeRole", "renounceRole", "upgradeToAndCall", "setProxyImplementation",
                   "initialize"}
SHORT_ELIGIBLE = {  # 2.15 "Delay classes and timing" launch list = SHORT_ELIGIBLE (REQ-ACCESS-155)
    "ParameterStore": ["tightenHardHealthFloor", "tightenSlippageAllowanceBps", "tightenFloorRoundingAllowance",
                       "tightenBorrowPriceMaxAge", "tightenConsistencyToleranceBps", "tightenFeedAgreementToleranceBps",
                       "tightenPoolRiskFactor", "tightenRouteDepthThreshold", "tightenMarketUsdCap",
                       "tightenTopUpSliceUsd", "tightenTokenUsdCap", "tightenDepositorUsdCap", "tightenPoolShareMaxBps",
                       "tightenPoolShareMaxBpsOf",
                       "tightenMinPledgeUsd", "tightenBreakerDeficitMax", "tightenGateRecoverySeconds",
                       "tightenMaxShortfallBps", "tightenDebtStressRiseBps", "tightenMaxFlashFeeBps"],
    "MarketRegistry": ["disableRoute", "restoreRoute", "setMarketOffboarding", "activateMarket", "cancelRegistration", "freeze",
                       "pause", "freezeAddress", "tripMarketBreaker", "tripDebtBreaker", "useStandbyRoute"],
    "LPVaultSwap": ["removeKeeper"],
}
ELIGIBLE = {(c, s) for c, sels in SHORT_ELIGIBLE.items() for s in sels}


def constructor_accepts(target, sel):
    """REQ-ACCESS-142: the constructor reverts InvalidShortDelaySelector for the timelock or a forbidden selector."""
    return target != "AvanaTimelock" and sel not in FORBIDDEN_SHORT


def set_short_ok(target, sel, enabled):
    """REQ-ACCESS-142: enabling needs a SHORT_ELIGIBLE pair; disabling is always allowed."""
    return (not enabled) or (target, sel) in ELIGIBLE


def reachable_short_lists(depth=2):
    """Short lists reachable from the launch list by setShortDelaySelector operations (bounded depth, over the
    eligible pairs and a sample of non-eligible pairs)."""
    probes = sorted(ELIGIBLE)[:6] + [("AaveAdapter", "upgradeToAndCall"), ("MarketRegistry", "unpause"),
                                      ("ParameterStore", "loosenMarketUsdCap"), ("LPVaultSwap", "addKeeper"),
                                      ("MarketRegistry", "unfreezeAddress"), ("AvanaTimelock", "setNormalDelay")]
    lists = {frozenset(ELIGIBLE)}
    frontier = list(lists)
    for _ in range(depth):
        nxt = []
        for L in frontier:
            for pr in probes:
                for en in (True, False):
                    if set_short_ok(*pr, en):
                        n2 = (L | {pr}) if en else (L - {pr})
                        if n2 not in lists:
                            lists.add(n2)
                            nxt.append(n2)
        frontier = nxt
    return lists


# FV-CTL-23 verifies: REQ-ACCESS-142, REQ-ACCESS-155, REQ-ACCESS-141, REQ-ACCESS-148, REQ-ACCESS-018, INV-090
exhaustive("FV-CTL-23", "The constructor accepts the whole SHORT_ELIGIBLE list, and every reachable short list stays inside it: no role, upgrade, implementation-setter, initializer or timelock selector ever takes the short delay",
           sorted(reachable_short_lists(), key=len),
           lambda L: (L <= ELIGIBLE and all(constructor_accepts(*e) for e in L)) or sorted(L - ELIGIBLE),
           verifies=["REQ-ACCESS-142", "REQ-ACCESS-155", "REQ-ACCESS-141", "REQ-ACCESS-148", "REQ-ACCESS-018",
                     "INV-090"],
           targets=["T-54", "T-64"], bounded_note="(bounded: two setShortDelaySelector operations over 12 probe pairs)")

RISK_RAISING = [("MarketRegistry", "setRoute"), ("MarketRegistry", "setPriceSource"), ("MarketRegistry", "approveSpoke"),
                ("MarketRegistry", "approveDebtReserve"), ("ParameterStore", "setFeed"),
                ("ParameterStore", "loosenHardHealthFloor"), ("ParameterStore", "loosenMarketUsdCap"),
                ("ParameterStore", "setAvanaFeeShareBps"), ("LPVaultSwap", "addKeeper"),
                ("MarketRegistry", "unpause"), ("MarketRegistry", "unfreeze"), ("MarketRegistry", "unfreezeAddress"),
                ("MarketRegistry", "resetMarketBreaker"), ("MarketRegistry", "resetDebtBreaker"),
                ("MarketRegistry", "restorePriceRoute"), ("ParameterStore", "loosenGateRecoverySeconds"),
                ("ParameterStore", "loosenPoolShareMaxBpsOf"),
                ("AaveAdapter", "upgradeToAndCall"), ("ProxyManager", "setProxyImplementation")]
# FV-CTL-24 verifies: REQ-ACCESS-016, REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-155, REQ-ROLE-105
exhaustive("FV-CTL-24", "setShortDelaySelector refuses every risk-raising, loosening, lifting or code-changing selector (InvalidShortDelaySelector)",
           RISK_RAISING, lambda e: not set_short_ok(*e, True),
           verifies=["REQ-ACCESS-016", "REQ-ACCESS-141", "REQ-ACCESS-142", "REQ-ACCESS-155", "REQ-ROLE-105"],
           targets=["T-54"])

# The governance Safe can stop new activity in 12 hours without the guardians (DR-16): a batch of freeze, pause,
# freezeAddress and the two trips needs only SHORT_DELAY.
STOPS = [("MarketRegistry", s) for s in ("freeze", "pause", "freezeAddress", "tripMarketBreaker", "tripDebtBreaker")]
# FV-CTL-27 verifies: REQ-ACCESS-155, REQ-ACCESS-128, REQ-ACCESS-062, REQ-ACCESS-063, SPEC-GOV-001
expect("FV-CTL-27", "Every stop selector (freeze, pause, freezeAddress, tripMarketBreaker, tripDebtBreaker) is short-eligible, so the governance Safe halts new activity in 43,200 s; no lifting selector is",
       all(e in ELIGIBLE for e in STOPS) and not any(("MarketRegistry", s) in ELIGIBLE
                                                     for s in ("unfreeze", "unpause", "unfreezeAddress",
                                                               "resetMarketBreaker", "resetDebtBreaker",
                                                               "restorePriceRoute")),
       verifies=["REQ-ACCESS-155", "REQ-ACCESS-128", "REQ-ACCESS-062", "REQ-ACCESS-063", "SPEC-GOV-001"],
       targets=["T-54", "T-56"])

# ---------------------------------------------------------------- SPEC-GOV-014 / SPEC-GOV-015 exit window
r_, k_, W = z3.Ints("reaction k_positions W")
exit_ok = r_ + 12 * (k_ + 1) <= W
# FV-CTL-25 verifies: SPEC-GOV-014, REQ-ACCESS-148, INV-068
prove("FV-CTL-25", "At the launch normal delay a borrower with a 3-day reaction and up to 14,399 positions exits before any normal-delay change",
      exit_ok, assumptions=[W >= MAX, r_ >= 0, r_ <= 259_200, k_ >= 0, k_ <= 14_399],
      verifies=["SPEC-GOV-014", "REQ-ACCESS-148", "INV-068"], targets=["T-64"])
# FV-CTL-25-EX verifies: SPEC-GOV-014
expect("FV-CTL-25-EX", "SPEC-GOV-014 example: k = 14,400 no longer fits the launch delay (bound is exactly 14,399)",
       259_200 + 12 * (14_399 + 1) <= MAX < 259_200 + 12 * (14_400 + 1), verifies=["SPEC-GOV-014"], targets=["T-64"])
# FV-CTL-26 verifies: SPEC-GOV-015, SPEC-GOV-014, REQ-ACCESS-148, REQ-ACCESS-154, REQ-ROLE-104, INV-068
prove("FV-CTL-26", "For every reachable normalDelay, a borrower with a 3-day reaction and up to 7,199 positions exits before any normal-delay operation executes",
      exit_ok, assumptions=[W >= normal, nd_ok, r_ >= 0, r_ <= 259_200, k_ >= 0, k_ <= 7_199],
      verifies=["SPEC-GOV-015", "SPEC-GOV-014", "REQ-ACCESS-148", "REQ-ACCESS-154", "REQ-ROLE-104", "INV-068"],
      targets=["T-64"], show={"normalDelay", "W", "reaction", "k_positions"})
k_max = (MIN_ND - 259_200) // 12 - 1
# FV-CTL-26-EX verifies: SPEC-GOV-015
expect("FV-CTL-26-EX", "SPEC-GOV-015 example: k_max = 7,199 at the floor; k = 1 leaves 86,376 s to spare; k = 7,200 needs 345,612 s",
       k_max == 7_199 and MIN_ND - (259_200 + 24) == 86_376 and 259_200 + 12 * 7_201 == 345_612 > MIN_ND
       and 259_200 + 12 * 7_200 == MIN_ND, verifies=["SPEC-GOV-015"], targets=["T-64"])

sys.exit(finish())
