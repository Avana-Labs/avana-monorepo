#!/usr/bin/env python3
"""FV-C application pause state with its reason: transitions, caller bounds, the gating matrix on every
page that states it, the AaveAdapter's decision procedure, and exit, rescue and liquidation liveness.

How Avana works here: the MarketRegistry holds one state for the whole application, None, Frozen or
Paused, and while Paused a reason, General or MintPathSuspect (REQ-MREG-001, REQ-MREG-024). The
AaveAdapter alone reads it, on pledge, re-credit, borrow, withdraw-with-debt, removal with debt and repay
with collateral. Frozen stops new accounts and borrowing; Paused(General) also stops withdraw-with-debt and
admits a pledge or re-credit only as a rescue top-up (the Adapter sets `requireRescue`, the RiskModule
reverts `NotRescueTopUp` otherwise); Paused(MintPathSuspect) refuses every pledge, top-up and re-credit,
rescue included, so no vault token is minted. Repay, fee collection, debt-free withdrawal and removal,
`repayAllAndWithdraw`, zero-credit release, liquidation and pending settlement never read the state.

Target: T-56 (and the exit part of T-57). Every domain here is finite, so each exhaustive check is a
complete proof for the model.
"""
import itertools
import sys

from common import exhaustive, finish

# A pause state is (state, reason) with reason "None" exactly when state != "Paused".
PSTATES = (("None", "None"), ("Frozen", "None"), ("Paused", "General"), ("Paused", "MintPathSuspect"))
REASONS = ("None", "General", "MintPathSuspect")
CALLS = [("freeze", None), ("unfreeze", None), ("unpause", None)] + [("pause", r) for r in REASONS]
ROLES = ("F", "P", "A")  # APPLICATION_FREEZE_GUARDIAN, APPLICATION_PAUSE_GUARDIAN, APPLICATION_ADMIN
CALLERS = [frozenset(c) for k in range(4) for c in itertools.combinations(ROLES, k)]


def spec_gov_004(ps, call, roles):
    """SPEC-GOV-004 (2.15): returns the new (state, reason) or the revert error."""
    s, rho = ps
    fn, arg = call
    need = {"freeze": {"F", "A"}, "pause": {"P", "A"}, "unfreeze": {"P", "A"}, "unpause": {"P", "A"}}[fn]
    if not (roles & need):
        return "Unauthorized"
    if fn == "freeze":
        return {"None": ("Frozen", "None"), "Frozen": "AlreadyFrozen", "Paused": "AlreadyPaused"}[s]
    if fn == "pause":
        if arg == "None" or (s == "Paused" and arg == rho):
            return "InvalidPauseReason"
        return ("Paused", arg)
    if fn == "unfreeze":
        return {"None": "NotFrozen", "Frozen": ("None", "None"), "Paused": "CannotUnfreezeWhilePaused"}[s]
    return ("None", "None") if s == "Paused" else "NotPaused"


def mreg_001_024(ps, call, roles):
    """REQ-MREG-001, REQ-MREG-004 and REQ-MREG-024 (2.8), encoded independently from their text."""
    s, rho = ps
    fn, arg = call
    allowed = ("F" in roles or "A" in roles) if fn == "freeze" else ("P" in roles or "A" in roles)
    if not allowed:
        return "Unauthorized"
    if fn == "pause":
        if arg == "None":
            return "InvalidPauseReason"
        if s == "Paused":
            return "InvalidPauseReason" if arg == rho else ("Paused", arg)
        return ("Paused", arg)  # None or Frozen -> Paused(reason)
    table = {("freeze", "None"): ("Frozen", "None"), ("freeze", "Frozen"): "AlreadyFrozen",
             ("freeze", "Paused"): "AlreadyPaused",
             ("unfreeze", "None"): "NotFrozen", ("unfreeze", "Frozen"): ("None", "None"),
             ("unfreeze", "Paused"): "CannotUnfreezeWhilePaused",
             ("unpause", "Paused"): ("None", "None"), ("unpause", "None"): "NotPaused",
             ("unpause", "Frozen"): "NotPaused"}
    return table[(fn, s)]


DOM = list(itertools.product(PSTATES, CALLS, CALLERS))
# FV-CTL-31 verifies: SPEC-GOV-004, REQ-MREG-001, REQ-MREG-004, REQ-MREG-024, REQ-ACCESS-085, REQ-ACCESS-122, REQ-ACCESS-123, INV-049
exhaustive("FV-CTL-31", "2.15 SPEC-GOV-004 and 2.8 REQ-MREG-001/004/024 define the same transition and revert for every state, reason, call and caller",
           DOM, lambda x: spec_gov_004(*x) == mreg_001_024(*x) or (spec_gov_004(*x), mreg_001_024(*x)),
           verifies=["SPEC-GOV-004", "REQ-MREG-001", "REQ-MREG-004", "REQ-MREG-024", "REQ-ACCESS-085",
                     "REQ-ACCESS-122", "REQ-ACCESS-123", "INV-049"], targets=["T-56"])


def reachable_from(ps, roles):
    seen, queue = {ps}, [ps]
    while queue:
        cur = queue.pop()
        for c in CALLS:
            nxt = spec_gov_004(cur, c, roles)
            if isinstance(nxt, tuple) and nxt not in seen:
                seen.add(nxt)
                queue.append(nxt)
    return seen


ALL_REACHED = reachable_from(("None", "None"), frozenset(ROLES))
# FV-CTL-32 verifies: SPEC-GOV-004, REQ-ACCESS-086, REQ-ACCESS-087, REQ-ROLE-071, REQ-MREG-024, INV-050
exhaustive("FV-CTL-32", "A freeze-only key never leaves Frozen or Paused; P or A reaches None from every state; Paused never returns to Frozen; the reason is None exactly when not Paused; either guardian raises General to MintPathSuspect at once",
           PSTATES, lambda ps: (("None", "None") not in reachable_from(ps, frozenset("F")) or ps[0] == "None")
           and ("None", "None") in reachable_from(ps, frozenset("P"))
           and ("None", "None") in reachable_from(ps, frozenset("A"))
           and all(not (isinstance(spec_gov_004(("Paused", r), c, k), tuple) and spec_gov_004(("Paused", r), c, k)[0] == "Frozen")
                   for r in ("General", "MintPathSuspect") for c in CALLS for k in CALLERS)
           and all((st == "Paused") == (rs != "None") for st, rs in ALL_REACHED)
           and set(ALL_REACHED) == set(PSTATES)
           and spec_gov_004(("Paused", "General"), ("pause", "MintPathSuspect"), frozenset("P")) == ("Paused", "MintPathSuspect"),
           verifies=["SPEC-GOV-004", "REQ-ACCESS-086", "REQ-ACCESS-087", "REQ-ROLE-071", "REQ-MREG-024", "INV-050"],
           targets=["T-56"])

# ------------------------------------------------------------------ gating matrix on every page
ACTIONS = ("new_pledge", "top_up", "rescue_top_up", "borrow", "with_debt", "repay", "repay_all_and_withdraw",
           "fees", "debt_free_exit", "zero_credit_release", "liquidation", "settle_pending")
# with_debt = withdraw-with-debt, removal with debt and repay with collateral (they share every row);
# debt_free_exit = debt-free withdrawal and partial removal; top_up = a top-up or re-credit that is not a rescue.
Y = "Y"


def adapter_procedure(ps, action):
    """Outcome of the pause state for each action as 2.6 specifies the Adapter (REQ-ADAPTER-065, -083, -045,
    -046, -080, -082, REQ-PROXY-015, -036) and 2.7 the RiskModule's rescue rule (REQ-RISK-066): 'Y' or the error."""
    s, rho = ps
    if action in ("new_pledge", "top_up", "rescue_top_up"):
        if s == "Paused" and rho == "MintPathSuspect":
            return "ApplicationPaused"
        if s == "Frozen" and action == "new_pledge":  # borrowCount == 0
            return "ApplicationFrozen"
        if s == "Paused" and rho == "General" and action != "rescue_top_up":  # requireRescue
            return "NotRescueTopUp"
        return Y
    if action == "borrow":
        return {"None": Y, "Frozen": "ApplicationFrozen", "Paused": "ApplicationPaused"}[s]
    if action == "with_debt":
        return "ApplicationPaused" if s == "Paused" else Y
    return Y  # exits, liquidation and pending settlement never read the state


def row(none, frozen, general, mps):
    return {("None", "None"): none, ("Frozen", "None"): frozen, ("Paused", "General"): general,
            ("Paused", "MintPathSuspect"): mps}


# Each page's statement per action: 'Y', 'N' (blocked, no error named) or the error the page names.
PAGES = {
    "1.4 pause table": {
        "new_pledge": row(Y, "ApplicationFrozen", "NotRescueTopUp", "ApplicationPaused"),
        "top_up": row(Y, Y, "N", "ApplicationPaused"), "rescue_top_up": row(Y, Y, Y, "ApplicationPaused"),
        "borrow": row(Y, "ApplicationFrozen", "ApplicationPaused", "ApplicationPaused"),
        "with_debt": row(Y, Y, "ApplicationPaused", "ApplicationPaused"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
    "2.15 REQ-ACCESS-072/073/074/164": {
        "new_pledge": row(Y, "ApplicationFrozen", "NotRescueTopUp", "ApplicationPaused"),
        "top_up": row(Y, Y, "NotRescueTopUp", "ApplicationPaused"), "rescue_top_up": row(Y, Y, Y, "ApplicationPaused"),
        "borrow": row(Y, "ApplicationFrozen", "ApplicationPaused", "ApplicationPaused"),
        "with_debt": row(Y, Y, "ApplicationPaused", "ApplicationPaused"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
    "3.6 EMG-017/018/071": {
        "new_pledge": row(Y, "ApplicationFrozen", "NotRescueTopUp", "ApplicationPaused"),
        "top_up": row(Y, Y, "NotRescueTopUp", "ApplicationPaused"), "rescue_top_up": row(Y, Y, Y, "ApplicationPaused"),
        "borrow": row(Y, "ApplicationFrozen", "ApplicationPaused", "ApplicationPaused"),
        "with_debt": row(Y, Y, "ApplicationPaused", "ApplicationPaused"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
    "2.8 REQ-MREG-002": {
        "new_pledge": row(Y, "N", "N", "N"), "top_up": row(Y, Y, "N", "N"), "rescue_top_up": row(Y, Y, Y, "N"),
        "borrow": row(Y, "N", "N", "N"), "with_debt": row(Y, Y, "N", "N"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
    "4.1 INV-067": {
        "new_pledge": row(Y, "ApplicationFrozen", "NotRescueTopUp", "ApplicationPaused"),
        "top_up": row(Y, Y, "NotRescueTopUp", "ApplicationPaused"), "rescue_top_up": row(Y, Y, Y, "ApplicationPaused"),
        "borrow": row(Y, "N", "ApplicationPaused", "ApplicationPaused"),
        "with_debt": row(Y, Y, "ApplicationPaused", "ApplicationPaused"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
    "2.17 REQ-LENS-031": {
        "new_pledge": row(Y, "N", "N", "N"), "top_up": row(Y, Y, "N", "N"), "rescue_top_up": row(Y, Y, Y, "N"),
        "borrow": row(Y, "N", "N", "N"), "with_debt": row(Y, Y, "N", "N"),
        **{a: row(Y, Y, Y, Y) for a in ACTIONS[5:]}},
}


def allowed(v):
    return v == Y


cases = [(p, ps, a) for p in PAGES for ps in PSTATES for a in ACTIONS]
# FV-CTL-33 verifies: REQ-ACCESS-072, REQ-ACCESS-073, REQ-ACCESS-074, REQ-ACCESS-164, REQ-MREG-002, REQ-ROLE-073, INV-067, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-083, REQ-LENS-031, REQ-SWAP-003
exhaustive("FV-CTL-33", "Every page's pause matrix (four states, twelve actions) allows exactly what the AaveAdapter's decision procedure allows",
           cases, lambda c: allowed(PAGES[c[0]][c[2]][c[1]]) == allowed(adapter_procedure(c[1], c[2])) or c,
           verifies=["REQ-ACCESS-072", "REQ-ACCESS-073", "REQ-ACCESS-074", "REQ-ACCESS-164", "REQ-MREG-002",
                     "REQ-ROLE-073", "INV-067", "REQ-ADAPTER-045", "REQ-ADAPTER-046", "REQ-ADAPTER-083",
                     "REQ-LENS-031", "REQ-SWAP-003"], targets=["T-56"])

# Where a page names the revert, it is the error the contracts raise.
named = [c for c in cases if PAGES[c[0]][c[2]][c[1]] not in (Y, "N")]
# FV-CTL-36 verifies: REQ-ACCESS-074, REQ-ADAPTER-083, REQ-RISK-066, INV-026
exhaustive("FV-CTL-36", "Every error a page names for a blocked action is the error the Adapter and RiskModule raise",
           named, lambda c: PAGES[c[0]][c[2]][c[1]] == adapter_procedure(c[1], c[2])
           or {"page": c[0], "state": c[1], "action": c[2], "page_says": PAGES[c[0]][c[2]][c[1]],
               "contracts_raise": adapter_procedure(c[1], c[2])},
           verifies=["REQ-ACCESS-074", "REQ-ADAPTER-083", "REQ-RISK-066", "INV-026"], targets=["T-56"])

EXITS = ("repay", "repay_all_and_withdraw", "fees", "debt_free_exit", "zero_credit_release", "liquidation",
         "settle_pending")
# FV-CTL-34 verifies: REQ-ACCESS-068, REQ-ROLE-068, REQ-ADAPTER-047, REQ-RISK-040, LIQ-002, INV-081
exhaustive("FV-CTL-34", "Repay, repayAllAndWithdraw, fees, debt-free withdrawal and removal, zero-credit release, liquidation and pending settlement are open in every state and reason",
           list(itertools.product(PSTATES, EXITS)), lambda x: adapter_procedure(*x) == Y,
           verifies=["REQ-ACCESS-068", "REQ-ROLE-068", "REQ-ADAPTER-047", "REQ-RISK-040", "LIQ-002", "INV-081"],
           targets=["T-56", "T-57"])

# Rescue top-ups are open in every state except Paused(MintPathSuspect); under General they are the only pledge
# that passes; under MintPathSuspect nothing that mints passes.
MINTING = ("new_pledge", "top_up", "rescue_top_up")
# FV-CTL-37 verifies: REQ-MREG-024, REQ-ADAPTER-083, REQ-ACCESS-164, REQ-RISK-066, INV-067
exhaustive("FV-CTL-37", "A rescue top-up is open in None, Frozen and Paused(General) and is the only pledge Paused(General) admits; Paused(MintPathSuspect) admits no minting action",
           PSTATES, lambda ps: (adapter_procedure(ps, "rescue_top_up") == Y) == (ps[1] != "MintPathSuspect")
           and (ps[1] != "General" or [a for a in MINTING if adapter_procedure(ps, a) == Y] == ["rescue_top_up"])
           and (ps[1] != "MintPathSuspect" or all(adapter_procedure(ps, a) != Y for a in MINTING)),
           verifies=["REQ-MREG-024", "REQ-ADAPTER-083", "REQ-ACCESS-164", "REQ-RISK-066", "INV-067"],
           targets=["T-56"])

# Monotone restriction: None <= Frozen <= Paused(General) <= Paused(MintPathSuspect).
order = {ps: i for i, ps in enumerate(PSTATES)}
# FV-CTL-35 verifies: SPEC-GOV-004, REQ-ACCESS-074, REQ-ACCESS-164
exhaustive("FV-CTL-35", "A stronger pause state or reason never allows an action a weaker one blocks",
           list(itertools.product(PSTATES, PSTATES, ACTIONS)),
           lambda x: not (order[x[0]] <= order[x[1]] and adapter_procedure(x[1], x[2]) == Y
                          and adapter_procedure(x[0], x[2]) != Y),
           verifies=["SPEC-GOV-004", "REQ-ACCESS-074", "REQ-ACCESS-164"], targets=["T-56"])

sys.exit(finish())
