# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""HYP timelock: the AvanaTimelock reference model (model/timelock.py) against spec 2.15.

The state machine keeps its own shadow of the governance state (normal delay, short-delay list, public
execution, roles, pending operations), predicts the outcome of every call from the spec rules, and checks
that the model agrees. Every failing call must leave the model unchanged. After every step the timelock
invariants run. Each test states its Hypothesis budget with cfg(...).
"""
import copy

from hypothesis import event, given, strategies as st
from hypothesis.stateful import RuleBasedStateMachine, initialize, invariant, precondition, rule

from model.hsettings import cfg
from model.timelock import (
    AvanaTimelock, TimelockError, SHORT_DELAY, MIN_NORMAL_DELAY, MAX_DELAY, GRACE_PERIOD, LAUNCH_NORMAL_DELAY,
    TIMELOCK, MULTISIG, EMERGENCY_GUARDIAN, AAVE_GUARDIAN, AAVE_EXECUTOR, DEFAULT_ADMIN_ROLE, PROPOSER_ROLE,
    CANCELLER_ROLE, EXECUTOR_ROLE, DAO_CANCELLER_ROLE, APPLICATION_ADMIN, APPLICATION_PAUSE_GUARDIAN,
    APPLICATION_FREEZE_GUARDIAN, PARAMETER_STORE, MARKET_REGISTRY, LPVAULT_SWAP, AAVE_ADAPTER,
    UPGRADEABLE, TIGHTEN_SETTERS,
)

DAY = 86_400

# --------------------------------------------------------------------------- spec sets, written from the spec text
# Q-262 / REQ-ACCESS-155: SHORT_ELIGIBLE.
SPEC_REGISTRY_SHORT = ["disableRoute", "restoreRoute",
                       "setMarketOffboarding", "activateMarket", "cancelRegistration", "freeze",
                       "pause", "freezeAddress", "tripMarketBreaker", "tripDebtBreaker", "useStandbyRoute"]
SPEC_SHORT_ELIGIBLE = frozenset(
    [(PARAMETER_STORE, s) for s in TIGHTEN_SETTERS]
    + [(MARKET_REGISTRY, s) for s in SPEC_REGISTRY_SHORT] + [(LPVAULT_SWAP, "removeKeeper")])
# Q-263 / REQ-ACCESS-156: the DAO-only cancel set.
SPEC_DAO_SET = frozenset([(MARKET_REGISTRY, s) for s in ("restoreRoute", "useStandbyRoute",
                                                         "unfreezeAddress")]
                         + [(LPVAULT_SWAP, "addKeeper")])
ROLE_SELS = {"grantRole", "revokeRole", "renounceRole"}
TL_ROLES = [DEFAULT_ADMIN_ROLE, PROPOSER_ROLE, CANCELLER_ROLE, EXECUTOR_ROLE, DAO_CANCELLER_ROLE]
CONTRACT_ROLES = [DEFAULT_ADMIN_ROLE, APPLICATION_ADMIN, APPLICATION_PAUSE_GUARDIAN, APPLICATION_FREEZE_GUARDIAN]
ACCOUNTS = [MULTISIG, EMERGENCY_GUARDIAN, AAVE_GUARDIAN, AAVE_EXECUTOR, TIMELOCK, "eoa1", "eoa2"]
PROPOSER_BIASED = st.sampled_from([MULTISIG, AAVE_EXECUTOR] * 3 + ACCOUNTS)
CANCELLER_BIASED = st.sampled_from([AAVE_EXECUTOR] * 2 + ACCOUNTS)


def spec_role_change(calls):
    return len(calls) >= 1 and all(c[1] in ROLE_SELS for c in calls)


def spec_restoring(calls):
    def dao_only(c):
        return (c[0], c[1]) in SPEC_DAO_SET
    return len(calls) >= 1 and all(dao_only(c) for c in calls)


def all_short_eligible(calls):
    return len(calls) >= 1 and all((c[0], c[1]) in SPEC_SHORT_ELIGIBLE for c in calls)


# --------------------------------------------------------------------------- call strategies
eligible_call = st.sampled_from(sorted(SPEC_SHORT_ELIGIBLE))
NON_ELIGIBLE = [(AAVE_ADAPTER, "upgradeToAndCall"), (MARKET_REGISTRY, "setFlashSource"),
                (PARAMETER_STORE, "loosenMarketUsdCap"), (PARAMETER_STORE, "loosenTopUpSliceUsd"),
                (PARAMETER_STORE, "setFeed"), (MARKET_REGISTRY, "setPriceSource"), (MARKET_REGISTRY, "unpause"),
                (MARKET_REGISTRY, "unfreeze"), (MARKET_REGISTRY, "resetMarketBreaker"),
                (MARKET_REGISTRY, "restorePriceRoute"), (MARKET_REGISTRY, "unfreezeAddress"),
                (LPVAULT_SWAP, "addKeeper"), (PARAMETER_STORE, "loosenHardHealthFloor"), (MARKET_REGISTRY, "")]
non_eligible_call = st.sampled_from(NON_ELIGIBLE)
dao_call = st.sampled_from(sorted(SPEC_DAO_SET))
delay_value = st.one_of(st.integers(0, 10 ** 6),
                        st.sampled_from([0, SHORT_DELAY, MIN_NORMAL_DELAY - 1, MIN_NORMAL_DELAY, 259_200,
                                         MAX_DELAY, MAX_DELAY + 1]))
any_pair = st.one_of(eligible_call, non_eligible_call, st.just((TIMELOCK, "grantRole")),
                     st.just((AAVE_ADAPTER, "grantRole")))
role_call = st.one_of(
    st.tuples(st.just(TIMELOCK), st.sampled_from(["grantRole", "revokeRole"]), st.sampled_from(TL_ROLES),
              st.sampled_from(ACCOUNTS)),
    st.tuples(st.sampled_from(list(UPGRADEABLE)), st.sampled_from(["grantRole", "revokeRole"]),
              st.sampled_from(CONTRACT_ROLES), st.sampled_from(ACCOUNTS)),
)
timelock_admin_call = st.one_of(
    st.one_of(delay_value, st.integers(MIN_NORMAL_DELAY, MAX_DELAY)).map(lambda d: (TIMELOCK, "setNormalDelay", d)),
    st.tuples(any_pair, st.booleans()).map(lambda pb: (TIMELOCK, "setShortDelaySelector", pb[0][0], pb[0][1], pb[1])),
    st.booleans().map(lambda b: (TIMELOCK, "togglePublicExecution", b)),
)
any_call = st.one_of(eligible_call, non_eligible_call, dao_call, role_call, timelock_admin_call)
batch = st.one_of(
    st.lists(any_call, min_size=0, max_size=4),
    st.lists(eligible_call, min_size=1, max_size=3),
    st.lists(dao_call, min_size=1, max_size=3),
    st.lists(role_call, min_size=1, max_size=3),
    st.lists(timelock_admin_call, min_size=1, max_size=2),
)


def fingerprint(tl):
    return (tl.now, tl.normal_delay, frozenset(tl.short_list), tl.public_execution,
            tuple(sorted((r, frozenset(a)) for r, a in tl.roles.items())),
            tuple(sorted((k, frozenset(a)) for k, a in tl.contract_roles.items())),
            tuple(sorted((i, o.ready_at, o.role_change, o.restoring) for i, o in tl.pending.items())),
            frozenset(tl.done), len(tl.applied))


class Shadow:
    """The test's own governance state, advanced only by the spec rules."""

    def __init__(self):
        self.normal_delay = LAUNCH_NORMAL_DELAY
        self.short_list = set(SPEC_SHORT_ELIGIBLE)
        self.public = True
        self.roles = {DEFAULT_ADMIN_ROLE: {TIMELOCK}, PROPOSER_ROLE: {MULTISIG, AAVE_EXECUTOR},
                      CANCELLER_ROLE: {MULTISIG, EMERGENCY_GUARDIAN, AAVE_GUARDIAN, AAVE_EXECUTOR},
                      EXECUTOR_ROLE: {MULTISIG}, DAO_CANCELLER_ROLE: {AAVE_EXECUTOR}}
        self.admins = {(c, r): {TIMELOCK} for c in UPGRADEABLE for r in (DEFAULT_ADMIN_ROLE, APPLICATION_ADMIN)}

    def required(self, calls):
        if len(calls) >= 1 and all((c[0], c[1]) in self.short_list for c in calls):
            return SHORT_DELAY
        return self.normal_delay

    def apply(self, calls):
        """Apply an executed batch; returns the expected revert name or None. Atomic."""
        s = copy.deepcopy(self)
        for c in calls:
            t, sel, a = c[0], c[1], c[2:]
            if t == TIMELOCK:
                if sel == "setNormalDelay":
                    if not MIN_NORMAL_DELAY <= a[0] <= MAX_DELAY:
                        return "DelayOutOfBounds"
                    s.normal_delay = a[0]
                elif sel == "setShortDelaySelector":
                    if a[2]:
                        if (a[0], a[1]) not in SPEC_SHORT_ELIGIBLE:
                            return "InvalidShortDelaySelector"
                        s.short_list.add((a[0], a[1]))
                    else:
                        s.short_list.discard((a[0], a[1]))
                elif sel == "togglePublicExecution":
                    s.public = a[0]
                elif sel in ("grantRole", "revokeRole"):
                    if TIMELOCK not in s.roles[DEFAULT_ADMIN_ROLE]:
                        return "AccessControlUnauthorizedAccount"
                    if sel == "grantRole":
                        if a[0] == DEFAULT_ADMIN_ROLE and a[1] != TIMELOCK:
                            return "AdminRoleOnlyTimelock"
                        s.roles[a[0]].add(a[1])
                    else:
                        if a[0] == DEFAULT_ADMIN_ROLE and a[1] == TIMELOCK:    # REQ-ACCESS-182
                            return "TimelockAdminRequired"
                        s.roles[a[0]].discard(a[1])
            elif t in UPGRADEABLE and sel in ("grantRole", "revokeRole") and a[0] in (DEFAULT_ADMIN_ROLE,
                                                                                        APPLICATION_ADMIN):
                if sel == "grantRole":
                    if a[1] != TIMELOCK:
                        return "AdminRoleOnlyTimelock"
                    s.admins[(t, a[0])].add(a[1])
                else:
                    s.admins[(t, a[0])].discard(a[1])
        self.__dict__.update(s.__dict__)
        return None


class TimelockMachine(RuleBasedStateMachine):

    @initialize()
    def init(self):
        self.tl = AvanaTimelock()
        self.sh = Shadow()
        self.ops = {}            # op_id -> record (every op ever scheduled)
        self.pending = set()
        self.executed = []       # (record, t_exec)
        self.cancelled = []      # (record, canceller, canceller held DAO_CANCELLER_ROLE)
        self.done = set()
        assert self.tl.SHORT_ELIGIBLE == SPEC_SHORT_ELIGIBLE and len(SPEC_SHORT_ELIGIBLE) == 34   # 22 ParameterStore + 11 MarketRegistry + 1 LPVaultSwap, as compiled
        assert self.tl.DAO_CANCEL_SET == SPEC_DAO_SET

    def expect(self, fn, expected, label=""):
        """Run fn; it must raise exactly `expected` (and change nothing) or succeed when expected is None."""
        if label:
            event(f"{label}: {expected or 'ok'}")
        before = fingerprint(self.tl)
        try:
            out = fn()
        except TimelockError as e:
            assert expected == e.name, (expected, str(e))
            assert fingerprint(self.tl) == before, "a failing call changed state"
            return None
        assert expected is None, (expected, "call succeeded")
        return out

    def pick_pool(self, data):
        """Mostly pending operations; sometimes any operation ever scheduled (executed, cancelled, cleaned)."""
        if self.pending and data.draw(st.integers(0, 3)) > 0:
            return sorted(self.pending)
        return sorted(self.ops)

    # ------------------------------------------------------------------ rules
    @rule(calls=st.lists(timelock_admin_call, min_size=1, max_size=2), salt=st.integers(0, 3))
    def schedule_admin(self, calls, salt):
        """The governance multisig queues timelock self-calls at the current normal delay."""
        self.schedule(MULTISIG, calls, self.sh.normal_delay, salt)

    @rule(caller=PROPOSER_BIASED, calls=batch, delay=delay_value, salt=st.integers(0, 3))
    def schedule(self, caller, calls, delay, salt):
        required = self.sh.required(calls)
        assert self.tl.required_delay(calls) == required
        op_id = AvanaTimelock.hash_operation(calls, salt)
        if caller not in self.sh.roles[PROPOSER_ROLE]:
            exp = "AccessControlUnauthorizedAccount"
        elif op_id in self.pending or op_id in self.done:
            exp = "TimelockUnexpectedOperationState"
        elif delay < SHORT_DELAY:
            exp = "TimelockInsufficientDelay"
        elif delay < required:
            exp = "DelayBelowRequired"
        else:
            exp = None
        got = self.expect(lambda: self.tl.schedule(caller, calls, delay, salt), exp, "schedule")
        if exp is None:
            assert got == op_id
            self.ops[op_id] = dict(id=op_id, calls=[tuple(c) for c in calls], t_s=self.tl.now, delay=delay,
                                   required=required, ready=self.tl.now + delay,
                                   role_change=spec_role_change(calls), restoring=spec_restoring(calls))
            self.pending.add(op_id)

    @precondition(lambda self: self.ops)
    @rule(data=st.data(), caller=st.sampled_from(ACCOUNTS))
    def execute(self, data, caller):
        self._execute(data.draw(st.sampled_from(self.pick_pool(data))), caller)

    def executable(self):
        now = self.tl.now
        return sorted(i for i in self.pending if self.ops[i]["ready"] <= now < self.ops[i]["ready"] + GRACE_PERIOD)

    @precondition(lambda self: self.executable())
    @rule(data=st.data(), caller=st.sampled_from(ACCOUNTS))
    def execute_ready(self, data, caller):
        self._execute(data.draw(st.sampled_from(self.executable())), caller)

    def _execute(self, op_id, caller):
        rec, now = self.ops[op_id], self.tl.now
        if not self.sh.public and caller not in self.sh.roles[EXECUTOR_ROLE]:
            exp = "ExecutionNotPublic"
        elif op_id not in self.pending or now < rec["ready"]:
            exp = "TimelockUnexpectedOperationState"
        elif now >= rec["ready"] + GRACE_PERIOD:
            exp = "OperationExpired"
        else:
            trial = copy.deepcopy(self.sh)
            exp = trial.apply(rec["calls"])
        if self.expect(lambda: self.tl.execute(caller, op_id), exp, "execute") is not None:
            self.sh.apply(rec["calls"])
            self.pending.discard(op_id)
            self.done.add(op_id)
            self.executed.append((rec, now))
            for c in rec["calls"]:
                if c[0] == TIMELOCK:
                    event(f"executed self-call {c[1]}")

    @precondition(lambda self: self.ops)
    @rule(data=st.data(), caller=CANCELLER_BIASED)
    def cancel(self, data, caller):
        op_id = data.draw(st.sampled_from(self.pick_pool(data)))
        rec = self.ops[op_id]
        dao = caller in self.sh.roles[DAO_CANCELLER_ROLE]
        model_dao = self.tl.has_role(DAO_CANCELLER_ROLE, caller) and self.tl.has_role(CANCELLER_ROLE, caller)
        if caller not in self.sh.roles[CANCELLER_ROLE]:
            exp = "AccessControlUnauthorizedAccount"
        elif op_id not in self.pending:
            exp = "TimelockUnexpectedOperationState"
        elif rec["role_change"] and not dao:
            exp = "RoleChangeCancelRestricted"
        elif rec["restoring"] and not dao:
            exp = "RestoringCancelRestricted"
        else:
            exp = None
        kind = "role-change" if rec["role_change"] else "restoring" if rec["restoring"] else "ordinary"
        if self.expect(lambda: self.tl.cancel(caller, op_id), exp, f"cancel {kind}") is not None:
            self.pending.discard(op_id)
            self.cancelled.append((rec, caller, model_dao))

    @precondition(lambda self: self.ops)
    @rule(data=st.data())
    def cleanup(self, data):
        op_id = data.draw(st.sampled_from(self.pick_pool(data)))
        rec = self.ops[op_id]
        expired = op_id in self.pending and self.tl.now >= rec["ready"] + GRACE_PERIOD
        assert self.tl.is_operation_expired(op_id) == expired
        if self.expect(lambda: self.tl.cleanup_expired(op_id), None if expired else "OperationNotExpired", "cleanup") is not None:
            self.pending.discard(op_id)

    @rule(caller=st.sampled_from([a for a in ACCOUNTS if a != TIMELOCK]), value=delay_value)
    def direct_admin_calls(self, caller, value):
        """The timelock's own setters only run as an executed self-call; updateDelay never runs."""
        self.expect(lambda: self.tl.set_normal_delay(caller, value), "TimelockUnauthorizedCaller")
        self.expect(lambda: self.tl.set_short_delay_selector(caller, PARAMETER_STORE, "loosenMarketUsdCap", True),
                    "TimelockUnauthorizedCaller")
        self.expect(lambda: self.tl.update_delay(caller, value), "UpdateDelayDisabled")

    @rule(seconds=st.one_of(st.integers(0, 20 * DAY), st.sampled_from([1, SHORT_DELAY, MIN_NORMAL_DELAY, MAX_DELAY,
                                                                         GRACE_PERIOD])))
    def advance(self, seconds):
        self.tl.advance(seconds)

    @precondition(lambda self: self.pending)
    @rule(data=st.data(), edge=st.sampled_from([0, -1, GRACE_PERIOD - 1, GRACE_PERIOD]))
    def advance_to_edge(self, data, edge):
        """Jump to readyAt - 1, readyAt, readyAt + GRACE - 1 or readyAt + GRACE of a pending operation."""
        op_id = data.draw(st.sampled_from(sorted(self.pending)))
        target = self.ops[op_id]["ready"] + edge
        if target > self.tl.now:
            self.tl.advance(target - self.tl.now)

    # ------------------------------------------------------------------ invariants
    # HYP-88 verifies: Q-262, INV-068, INV-090
    @invariant()
    def normal_delay_in_bounds(self):
        assert MIN_NORMAL_DELAY <= self.tl.normal_delay <= MAX_DELAY
        assert self.tl.normal_delay == self.sh.normal_delay
        assert self.tl.get_min_delay() == SHORT_DELAY

    # HYP-88 verifies: Q-262, INV-068, INV-090
    @invariant()
    def short_list_within_allowlist(self):
        assert self.tl.SHORT_ELIGIBLE == SPEC_SHORT_ELIGIBLE      # immutable for life
        assert self.tl.short_list <= self.tl.SHORT_ELIGIBLE
        assert self.tl.short_list == self.sh.short_list

    # HYP-88 verifies: Q-228, Q-262, INV-051, INV-068
    @invariant()
    def executed_ops_waited_their_delay(self):
        for rec, t in self.executed:
            assert rec["delay"] >= rec["required"]
            assert rec["ready"] <= t < rec["ready"] + GRACE_PERIOD
            if not all_short_eligible(rec["calls"]):
                assert rec["required"] >= MIN_NORMAL_DELAY
                assert t - rec["t_s"] >= MIN_NORMAL_DELAY
            if spec_role_change(rec["calls"]):
                assert t - rec["t_s"] >= MIN_NORMAL_DELAY

    # HYP-88 verifies: Q-228, Q-263, INV-090
    @invariant()
    def restricted_cancels_only_by_dao(self):
        for rec, caller, dao in self.cancelled:
            if rec["role_change"] or rec["restoring"]:
                assert dao, (caller, rec["calls"])
        for op_id in self.pending:
            op = self.tl.pending[op_id]
            assert op.role_change == self.ops[op_id]["role_change"]
            assert op.restoring == self.ops[op_id]["restoring"]
        assert set(self.tl.pending) == self.pending

    # HYP-88 verifies: Q-228, Q-259, INV-068, INV-084
    @invariant()
    def admin_roles_only_timelock(self):
        assert self.tl.roles[DEFAULT_ADMIN_ROLE] <= {TIMELOCK}
        for (c, r), holders in self.tl.contract_roles.items():
            if r in (DEFAULT_ADMIN_ROLE, APPLICATION_ADMIN):
                assert holders <= {TIMELOCK}, (c, r, holders)
        for r in TL_ROLES:
            assert self.tl.roles.get(r, set()) == self.sh.roles[r], r


TestTimelockMachine = TimelockMachine.TestCase
TestTimelockMachine.settings = cfg(300, 40)


# --------------------------------------------------------------------------- plain properties
def run(tl, calls, delay=None):
    """Schedule as the multisig at the required delay, wait, execute publicly."""
    op = tl.schedule(MULTISIG, calls, tl.required_delay(calls) if delay is None else delay,
                     salt=len(tl.done) + len(tl.pending))
    tl.advance(tl.pending[op].delay)
    return tl.execute("anyone", op)


# HYP-88 verifies: Q-228, Q-262, INV-068
@cfg(300)
@given(short=st.lists(eligible_call, min_size=1, max_size=4), other=st.lists(non_eligible_call, min_size=1,
                                                                            max_size=3), data=st.data())
def test_hyp88_mixed_batch_takes_normal_delay(short, other, data):
    """SPEC-GOV-001: one non-listed call makes the whole batch normal; at the short delay it reverts."""
    tl = AvanaTimelock()
    assert tl.required_delay(short) == SHORT_DELAY
    mixed = list(short)
    for c in other:
        mixed.insert(data.draw(st.integers(0, len(mixed))), c)
    assert tl.required_delay(mixed) == tl.normal_delay == LAUNCH_NORMAL_DELAY
    try:
        tl.schedule(MULTISIG, mixed, SHORT_DELAY)
        raise AssertionError("short delay accepted for a mixed batch")
    except TimelockError as e:
        assert e.name == "DelayBelowRequired"
    assert not tl.pending
    assert tl.required_delay([]) == tl.normal_delay          # an empty batch is never short


# HYP-88 verifies: Q-228, Q-262, INV-068
@cfg(300)
@given(short=st.lists(eligible_call, min_size=0, max_size=4), loosen=st.sampled_from(
    [(PARAMETER_STORE, "loosenMarketUsdCap"), (PARAMETER_STORE, "loosenTopUpSliceUsd"),
     (PARAMETER_STORE, "loosenHardHealthFloor")]), pos=st.integers(0, 4), nd=st.integers(MIN_NORMAL_DELAY, MAX_DELAY))
def test_hyp88_one_loosening_call_makes_batch_normal(short, loosen, pos, nd):
    tl = AvanaTimelock()
    run(tl, [(TIMELOCK, "setNormalDelay", nd)])
    batch_ = list(short)
    batch_.insert(min(pos, len(batch_)), loosen)
    assert tl.required_delay(batch_) == nd >= MIN_NORMAL_DELAY


# HYP-88 verifies: Q-262, INV-068, INV-090
@cfg(300)
@given(value=st.integers(0, 10 ** 6), caller=st.sampled_from(ACCOUNTS[:4] + ["eoa1"]))
def test_hyp88_set_normal_delay_bounds(value, caller):
    """SPEC-GOV-003: only an executed self-call, only within [MIN_NORMAL_DELAY, MAX_DELAY]."""
    tl = AvanaTimelock()
    try:
        tl.set_normal_delay(caller, value)
        raise AssertionError("direct call accepted")
    except TimelockError as e:
        assert e.name == "TimelockUnauthorizedCaller"
    op = tl.schedule(MULTISIG, [(TIMELOCK, "setNormalDelay", value)], MAX_DELAY)
    tl.advance(MAX_DELAY)
    try:
        tl.execute(caller, op)
        assert MIN_NORMAL_DELAY <= value <= MAX_DELAY and tl.normal_delay == value
    except TimelockError as e:
        assert e.name == "DelayOutOfBounds" and not MIN_NORMAL_DELAY <= value <= MAX_DELAY
        assert tl.normal_delay == LAUNCH_NORMAL_DELAY and op in tl.pending


# HYP-88 verifies: Q-262, INV-090
@cfg(300)
@given(pair=any_pair, enabled=st.booleans())
def test_hyp88_short_selector_allowlist(pair, enabled):
    """REQ-ACCESS-142: enabling outside SHORT_ELIGIBLE reverts; disabling any pair is allowed."""
    tl = AvanaTimelock()
    run(tl, [(TIMELOCK, "setShortDelaySelector", pair[0], pair[1], False)])
    assert pair not in tl.short_list
    try:
        run(tl, [(TIMELOCK, "setShortDelaySelector", pair[0], pair[1], enabled)])
        assert not enabled or pair in SPEC_SHORT_ELIGIBLE
    except TimelockError as e:
        assert enabled and pair not in SPEC_SHORT_ELIGIBLE and e.name == "InvalidShortDelaySelector"
    assert tl.short_list <= tl.SHORT_ELIGIBLE
    assert tl.required_delay([pair]) == (SHORT_DELAY if enabled and pair in SPEC_SHORT_ELIGIBLE else tl.normal_delay)


# HYP-88 verifies: Q-228, Q-263, INV-090
@cfg(300)
@given(restoring=st.lists(dao_call, min_size=1, max_size=3), roles=st.lists(role_call, min_size=1, max_size=3),
       other=non_eligible_call.filter(lambda c: c not in SPEC_DAO_SET),
       canceller=st.sampled_from([MULTISIG, EMERGENCY_GUARDIAN, AAVE_GUARDIAN]))
def test_hyp88_cancel_rules(restoring, roles, other, canceller):
    """SPEC-GOV-005: pure restoring and pure role-change operations are DAO-only; mixing restores the ordinary rule."""
    tl = AvanaTimelock()
    for calls in (restoring, roles):
        op = tl.schedule(MULTISIG, calls, MAX_DELAY)
        pure_restoring = spec_restoring(calls)
        if pure_restoring or spec_role_change(calls):
            try:
                tl.cancel(canceller, op)
                raise AssertionError("guardian cancelled a DAO-only operation")
            except TimelockError as e:
                assert e.name == ("RoleChangeCancelRestricted" if spec_role_change(calls)
                                  else "RestoringCancelRestricted")
            tl.cancel(AAVE_EXECUTOR, op)
        else:   # not restoring (no argument-dependent DAO-only members remain, Q-401)
            tl.cancel(canceller, op)
        mixed = calls + [other]
        op = tl.schedule(MULTISIG, mixed, MAX_DELAY)
        tl.cancel(canceller, op)
        assert op not in tl.pending


# HYP-88 verifies: Q-228, Q-259, INV-068, INV-084
@cfg(300)
@given(target=st.sampled_from([TIMELOCK] + list(UPGRADEABLE)), role=st.sampled_from(CONTRACT_ROLES),
       account=st.sampled_from(ACCOUNTS))
def test_hyp88_admin_roles_only_timelock(target, role, account):
    """Q-259: a grant of an admin role to anyone but the timelock reverts AdminRoleOnlyTimelock at execution."""
    tl = AvanaTimelock()
    if target == TIMELOCK and role not in TL_ROLES:
        role = DEFAULT_ADMIN_ROLE
    admin = role == DEFAULT_ADMIN_ROLE or (target != TIMELOCK and role == APPLICATION_ADMIN)
    op = tl.schedule(MULTISIG, [(target, "grantRole", role, account)], MAX_DELAY)
    assert tl.pending[op].role_change
    tl.advance(MAX_DELAY)
    try:
        tl.execute("anyone", op)
        assert not admin or account == TIMELOCK
    except TimelockError as e:
        assert admin and account != TIMELOCK and e.name == "AdminRoleOnlyTimelock"
    assert tl.roles[DEFAULT_ADMIN_ROLE] == {TIMELOCK}
    assert all(h <= {TIMELOCK} for (c, r), h in tl.contract_roles.items() if r in (DEFAULT_ADMIN_ROLE,
                                                                                    APPLICATION_ADMIN))


# HYP-88 verifies: Q-228, INV-068
@cfg(300)
@given(delay=st.integers(SHORT_DELAY, 10 ** 6), offset=st.integers(-2, GRACE_PERIOD + 2))
def test_hyp88_execution_window(delay, offset):
    """SPEC-GOV-002 / SPEC-GOV-013: executable iff readyAt <= t < readyAt + GRACE; at every t >= readyAt exactly one
    of executable or expired; clean-up only once expired. Spec example: ready 1,780,432,000, last 1,781,641,599."""
    tl = AvanaTimelock(now=1_780_000_000)
    op = tl.schedule(MULTISIG, [(AAVE_ADAPTER, "upgradeToAndCall")], max(delay, MAX_DELAY))
    ready = tl.pending[op].ready_at
    if delay == MAX_DELAY:
        assert ready == 1_780_432_000
    tl.advance(max(0, ready + offset - tl.now))
    t = tl.now
    expired = tl.is_operation_expired(op)
    assert expired == (t >= ready + GRACE_PERIOD)
    try:
        tl.cleanup_expired(op)
        assert expired
        return
    except TimelockError as e:
        assert not expired and e.name == "OperationNotExpired"
    try:
        tl.execute("anyone", op)
        assert ready <= t < ready + GRACE_PERIOD
    except TimelockError as e:
        assert e.name == ("TimelockUnexpectedOperationState" if t < ready else "OperationExpired")


def test_hyp88_spec_examples():
    """Worked examples of SPEC-GOV-001, SPEC-GOV-003 and SPEC-GOV-013."""
    tl = AvanaTimelock(now=1_780_000_000)
    b = [(PARAMETER_STORE, "tightenMarketUsdCap"), (MARKET_REGISTRY, "disableRoute")]
    assert tl.required_delay(b) == 43_200
    assert tl.required_delay(b + [(PARAMETER_STORE, "loosenTopUpSliceUsd")]) == 432_000
    # SPEC-GOV-003: cut to 345,600 published at 1,780,000,000, first benefiting upgrade ready 777,600 s later
    cut = tl.schedule(MULTISIG, [(TIMELOCK, "setNormalDelay", 345_600)], 432_000)
    up = tl.schedule(MULTISIG, [(AAVE_ADAPTER, "upgradeToAndCall")], 432_000, salt=1)
    tl.advance(432_000)
    tl.execute("anyone", cut)
    up2 = tl.schedule(MULTISIG, [(AAVE_ADAPTER, "upgradeToAndCall")], 345_600, salt=2)
    assert tl.pending[up2].ready_at - 1_780_000_000 == 777_600
    assert tl.pending[up].ready_at == 1_780_432_000                 # already scheduled keeps its readyAt
    for bad in (345_599, 259_200, 432_001):
        tl3 = AvanaTimelock()
        try:
            run(tl3, [(TIMELOCK, "setNormalDelay", bad)])
            raise AssertionError(bad)
        except TimelockError as e:
            assert e.name == "DelayOutOfBounds" and tl3.normal_delay == 432_000
    # SPEC-GOV-013: cleanup before expiry reverts; after it, the same call can be scheduled again
    tl2 = AvanaTimelock(now=1_780_000_000)
    op = tl2.schedule(MULTISIG, [(AAVE_ADAPTER, "upgradeToAndCall")], 432_000)
    tl2.advance(1_781_000_000 - tl2.now)
    try:
        tl2.cleanup_expired(op)
        raise AssertionError
    except TimelockError as e:
        assert e.name == "OperationNotExpired"
    tl2.advance(1_781_641_600 - tl2.now)
    try:
        tl2.execute("anyone", op)
        raise AssertionError
    except TimelockError as e:
        assert e.name == "OperationExpired"
    tl2.cleanup_expired(op)
    assert tl2.schedule(MULTISIG, [(AAVE_ADAPTER, "upgradeToAndCall")], 432_000) == op
