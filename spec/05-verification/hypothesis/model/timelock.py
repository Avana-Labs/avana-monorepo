# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Reference model of the AvanaTimelock (spec 2.15, SPEC-GOV-001/002/003/005/007/013/015).

A call is a tuple `(target, selector, *args)` with plain string names. A call whose selector is the
empty string stands for a payload shorter than four bytes: it has no selector, is never short, never
restoring and never a role change (SPEC-GOV-001, SPEC-GOV-005).

Every failing operation raises `TimelockError` (or a subclass) whose message starts with the spec's
revert name, and leaves the model unchanged.
"""
import copy
import hashlib

SHORT_DELAY = 43_200
MIN_NORMAL_DELAY = 345_600
MAX_DELAY = 432_000
GRACE_PERIOD = 1_209_600
LAUNCH_NORMAL_DELAY = 432_000

# Accounts
TIMELOCK = "AvanaTimelock"
MULTISIG = "governanceMultisig"
EMERGENCY_GUARDIAN = "emergencyGuardian"
AAVE_GUARDIAN = "aaveProtocolGuardian"
AAVE_EXECUTOR = "aaveGovernanceExecutor"

# The open executor account: EXECUTOR_ROLE held by address(0) is public execution (REQ-ACCESS-144).
OPEN = "address(0)"

# Timelock roles
DEFAULT_ADMIN_ROLE = "DEFAULT_ADMIN_ROLE"
PROPOSER_ROLE = "PROPOSER_ROLE"
CANCELLER_ROLE = "CANCELLER_ROLE"
EXECUTOR_ROLE = "EXECUTOR_ROLE"
DAO_CANCELLER_ROLE = "DAO_CANCELLER_ROLE"
TIMELOCK_ROLES = (DEFAULT_ADMIN_ROLE, PROPOSER_ROLE, CANCELLER_ROLE, EXECUTOR_ROLE, DAO_CANCELLER_ROLE)

# Roles on upgradeable Avana contracts
APPLICATION_ADMIN = "APPLICATION_ADMIN"
APPLICATION_PAUSE_GUARDIAN = "APPLICATION_PAUSE_GUARDIAN"
APPLICATION_FREEZE_GUARDIAN = "APPLICATION_FREEZE_GUARDIAN"
ADMIN_ROLES = (DEFAULT_ADMIN_ROLE, APPLICATION_ADMIN)

# Targets
PARAMETER_STORE = "ParameterStore"
MARKET_REGISTRY = "MarketRegistry"
LPVAULT_SWAP = "LPVaultSwap"
AAVE_ADAPTER = "AaveAdapter"
UPGRADEABLE = ("AaveAdapter", "RiskModule", MARKET_REGISTRY, PARAMETER_STORE, "LPOracle",  # ProxyManager is immutable
               "DebtOracle", LPVAULT_SWAP)

TIGHTEN_SETTERS = (  # the compiled ParameterStore tighten selectors (2.15 launch list, REQ-ACCESS-155)
    "tightenHardHealthFloor", "tightenSlippageAllowanceBps", "tightenFloorRoundingAllowance",
    "tightenBorrowPriceMaxAge", "tightenConsistencyToleranceBps", "tightenFeedAgreementToleranceBps",
    "tightenPoolRiskFactor", "tightenRouteDepthThreshold", "tightenMarketUsdCap", "tightenTopUpSliceUsd",
    "tightenTokenUsdCap", "tightenDepositorUsdCap", "tightenPoolShareMaxBps", "tightenPoolShareMaxBpsOf",
    "tightenMinPledgeUsd",
    "tightenBreakerDeficitMax", "tightenGateRecoverySeconds", "tightenMaxShortfallBps", "tightenDebtStressRiseBps",
    "tightenMaxFlashFeeBps",
)
REGISTRY_SHORT = (
    "disableRoute", "restoreRoute",  # no buy route exists (REQ-MREG-011)
    "setMarketOffboarding", "activateMarket", "cancelRegistration", "freeze", "pause", "freezeAddress",
    "tripMarketBreaker", "tripDebtBreaker", "useStandbyRoute",
)
# REQ-ACCESS-155 / Q-262: the launch short-delay list, equal to SHORT_ELIGIBLE.
LAUNCH_SHORT_LIST = frozenset(
    [(PARAMETER_STORE, s) for s in TIGHTEN_SETTERS]
    + [(MARKET_REGISTRY, s) for s in REGISTRY_SHORT]
    + [(LPVAULT_SWAP, "removeKeeper")]
)
# REQ-ACCESS-156 / Q-263: the DAO-only cancel set.
LAUNCH_DAO_CANCEL_SET = frozenset(
    [(MARKET_REGISTRY, s) for s in ("restoreRoute", "useStandbyRoute", "unfreezeAddress")]
    + [(LPVAULT_SWAP, "addKeeper")]
)
ROLE_SELECTORS = frozenset({"grantRole", "revokeRole", "renounceRole"})
# REQ-ACCESS-142: selectors the constructor refuses in SHORT_ELIGIBLE (and, REQ-ACCESS-181, in the DAO-only set).
FORBIDDEN_SHORT_SELECTORS = frozenset({"grantRole", "revokeRole", "renounceRole", "upgradeToAndCall",
                                       "setFlashSource", "deployCdpSpoke", "listCollateralMarket",
                                       "enableDebtReserve", "setCrossHubLinesEnabled", "setCrossHubLine",
                                       "initialize"})

# Error names (the spec's revert identifiers)
ERRORS = ("AccessControlUnauthorizedAccount", "AccessControlBadConfirmation", "TimelockInsufficientDelay",
          "DelayBelowRequired", "TimelockUnexpectedOperationState", "OperationExpired", "OperationNotExpired",
          "ExecutionNotPublic", "RoleChangeCancelRestricted", "RestoringCancelRestricted",
          "TimelockUnauthorizedCaller", "DelayOutOfBounds", "InvalidShortDelaySelector",
          "AdminRoleOnlyTimelock", "UpdateDelayDisabled", "InvalidDaoCancelSelector",
          "PublicExecutionOnlyByToggle", "TimelockAdminRequired")


class TimelockError(Exception):
    """A revert. `name` is the spec's error name; `args` carry its arguments."""

    def __init__(self, name, *args):
        assert name in ERRORS, name
        self.name = name
        super().__init__(f"{name}({', '.join(map(str, args))})")


def selector(call):
    return call[1]


def is_role_call(call):
    return selector(call) in ROLE_SELECTORS


class Operation:
    __slots__ = ("op_id", "calls", "scheduled_at", "delay", "required", "ready_at", "role_change", "restoring",
                 "proposer")

    def __init__(self, op_id, calls, scheduled_at, delay, required, role_change, restoring, proposer):
        self.op_id, self.calls = op_id, calls
        self.scheduled_at, self.delay, self.required = scheduled_at, delay, required
        self.ready_at = scheduled_at + delay
        self.role_change, self.restoring, self.proposer = role_change, restoring, proposer


class AvanaTimelock:
    """AvanaTimelock with an injected clock: `now` is the block timestamp, moved with `advance`."""

    def __init__(self, now=1_780_000_000, short_eligible=LAUNCH_SHORT_LIST, dao_cancel_set=LAUNCH_DAO_CANCEL_SET,
                 normal_delay=LAUNCH_NORMAL_DELAY):
        launch_short = {sel for (_, sel) in LAUNCH_SHORT_LIST}
        launch_dao = {sel for (_, sel) in LAUNCH_DAO_CANCEL_SET}
        for (t, s) in short_eligible:   # REQ-ACCESS-142: never-short selectors, and only launch-list selectors
            if t == TIMELOCK or s in FORBIDDEN_SHORT_SELECTORS or s == "" or s not in launch_short:
                raise TimelockError("InvalidShortDelaySelector", t, s)
        for (t, s) in dao_cancel_set:   # REQ-ACCESS-181: only the four DAO-only selectors
            if t == TIMELOCK or s in FORBIDDEN_SHORT_SELECTORS or s not in launch_dao:
                raise TimelockError("InvalidDaoCancelSelector", t, s)
        if not MIN_NORMAL_DELAY <= normal_delay <= MAX_DELAY:
            raise TimelockError("DelayOutOfBounds", normal_delay)
        self.now = now
        self.SHORT_ELIGIBLE = frozenset(short_eligible)
        self.DAO_CANCEL_SET = frozenset(dao_cancel_set)
        self.normal_delay = normal_delay
        self.short_list = set(self.SHORT_ELIGIBLE)          # equal to SHORT_ELIGIBLE at construction
        self.public_execution = True
        # constructor admin = address(0): the timelock is its own only DEFAULT_ADMIN_ROLE holder
        self.roles = {
            DEFAULT_ADMIN_ROLE: {TIMELOCK},
            PROPOSER_ROLE: {MULTISIG, AAVE_EXECUTOR},
            CANCELLER_ROLE: {MULTISIG, EMERGENCY_GUARDIAN, AAVE_GUARDIAN, AAVE_EXECUTOR},
            EXECUTOR_ROLE: {MULTISIG},
            DAO_CANCELLER_ROLE: {AAVE_EXECUTOR},
        }
        # roles on every upgradeable Avana contract: admin roles only for the timelock
        self.contract_roles = {(c, r): {TIMELOCK} for c in UPGRADEABLE for r in ADMIN_ROLES}
        self.contract_roles[(MARKET_REGISTRY, APPLICATION_PAUSE_GUARDIAN)] = set()
        self.contract_roles[(MARKET_REGISTRY, APPLICATION_FREEZE_GUARDIAN)] = set()
        self.pending = {}                                    # op_id -> Operation (scheduled, not done/cancelled)
        self.done = set()                                    # executed op ids (OpenZeppelin _DONE_TIMESTAMP)
        self.applied = []                                    # (op_id, call) executed on non-timelock targets

    # ------------------------------------------------------------------ clock and views
    def advance(self, seconds):
        assert seconds >= 0
        self.now += seconds

    def has_role(self, role, account):
        return account in self.roles.get(role, ())

    def get_min_delay(self):
        return SHORT_DELAY

    def is_short_eligible(self, target, sel):
        return (target, sel) in self.SHORT_ELIGIBLE

    def is_short_delay_selector(self, target, sel):
        return (target, sel) in self.short_list

    def is_dao_only_call(self, call):
        """daoOnly(t, p) of SPEC-GOV-005: in the DAO-only cancel set (no argument-dependent members since Q-401)."""
        target, sel = call[0], selector(call)
        return (target, sel) in self.DAO_CANCEL_SET

    def required_delay(self, calls):
        """SPEC-GOV-001."""
        if len(calls) >= 1 and all(self.is_short_delay_selector(c[0], selector(c)) for c in calls):
            return SHORT_DELAY
        return self.normal_delay

    def is_role_change(self, calls):
        return len(calls) >= 1 and all(is_role_call(c) for c in calls)

    def is_restoring(self, calls):
        return len(calls) >= 1 and all(self.is_dao_only_call(c) for c in calls)

    @staticmethod
    def hash_operation(calls, salt=0):
        """Stand-in for OpenZeppelin hashOperationBatch: deterministic over the calls and the salt."""
        data = repr((tuple(tuple(c) for c in calls), salt)).encode()
        return hashlib.sha256(data).hexdigest()[:16]

    def is_operation_expired(self, op_id):
        op = self.pending.get(op_id)
        return op is not None and self.now >= op.ready_at + GRACE_PERIOD

    # ------------------------------------------------------------------ proposer / executor / canceller entry points
    def schedule(self, caller, calls, delay, salt=0):
        """schedule / scheduleBatch. Returns the operation id."""
        calls = [tuple(c) for c in calls]
        if not self.has_role(PROPOSER_ROLE, caller):
            raise TimelockError("AccessControlUnauthorizedAccount", caller, PROPOSER_ROLE)
        op_id = self.hash_operation(calls, salt)
        if op_id in self.pending or op_id in self.done:
            raise TimelockError("TimelockUnexpectedOperationState", op_id)
        if delay < SHORT_DELAY:
            raise TimelockError("TimelockInsufficientDelay", delay, SHORT_DELAY)
        required = self.required_delay(calls)
        if delay < required:
            raise TimelockError("DelayBelowRequired", delay, required)
        self.pending[op_id] = Operation(op_id, calls, self.now, delay, required, self.is_role_change(calls),
                                        self.is_restoring(calls), caller)
        return op_id

    def execute(self, caller, op_id):
        """execute / executeBatch (SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-144). Atomic: one failing call reverts all."""
        if not self.public_execution and not self.has_role(EXECUTOR_ROLE, caller):
            raise TimelockError("ExecutionNotPublic", caller)
        op = self.pending.get(op_id)
        if op is None or self.now < op.ready_at:
            raise TimelockError("TimelockUnexpectedOperationState", op_id)
        if self.now >= op.ready_at + GRACE_PERIOD:
            raise TimelockError("OperationExpired", op_id)
        snapshot = copy.deepcopy(self.__dict__)
        try:
            for call in op.calls:
                self._dispatch(op_id, call)
        except TimelockError:
            self.__dict__.clear()
            self.__dict__.update(snapshot)
            raise
        del self.pending[op_id]
        self.done.add(op_id)
        return op

    def cancel(self, caller, op_id):
        """SPEC-GOV-005, SPEC-GOV-007: a pending operation, expired or not."""
        if not self.has_role(CANCELLER_ROLE, caller):
            raise TimelockError("AccessControlUnauthorizedAccount", caller, CANCELLER_ROLE)
        op = self.pending.get(op_id)
        if op is None:
            raise TimelockError("TimelockUnexpectedOperationState", op_id)
        dao = self.has_role(DAO_CANCELLER_ROLE, caller)
        if op.role_change and not dao:
            raise TimelockError("RoleChangeCancelRestricted", op_id)
        if op.restoring and not dao:
            raise TimelockError("RestoringCancelRestricted", op_id)
        del self.pending[op_id]
        return op

    def cleanup_expired(self, op_id):
        """cleanupExpiredOperation (SPEC-GOV-013), by anyone."""
        if not self.is_operation_expired(op_id):
            raise TimelockError("OperationNotExpired", op_id)
        return self.pending.pop(op_id)

    def update_delay(self, caller, new_delay):
        raise TimelockError("UpdateDelayDisabled")

    def renounce_role(self, caller, role, account):
        """A holder leaves its own timelock role (REQ-ACCESS-026)."""
        if caller != account:
            raise TimelockError("AccessControlBadConfirmation")
        if role == DEFAULT_ADMIN_ROLE and account == TIMELOCK:     # REQ-ACCESS-182
            raise TimelockError("TimelockAdminRequired")
        self.roles.setdefault(role, set()).discard(account)

    # ------------------------------------------------------------------ self-call administration
    def _only_self(self, caller):
        if caller != TIMELOCK:
            raise TimelockError("TimelockUnauthorizedCaller", caller)

    def set_normal_delay(self, caller, new_delay):
        """SPEC-GOV-003, REQ-ACCESS-154."""
        self._only_self(caller)
        if not MIN_NORMAL_DELAY <= new_delay <= MAX_DELAY:
            raise TimelockError("DelayOutOfBounds", new_delay)
        self.normal_delay = new_delay

    def set_short_delay_selector(self, caller, target, sel, enabled):
        """REQ-ACCESS-142: enable only pairs of SHORT_ELIGIBLE; disabling always allowed."""
        self._only_self(caller)
        if enabled:
            if (target, sel) not in self.SHORT_ELIGIBLE:
                raise TimelockError("InvalidShortDelaySelector", target, sel)
            self.short_list.add((target, sel))
        else:
            self.short_list.discard((target, sel))

    def toggle_public_execution(self, caller, enabled):
        self._only_self(caller)
        self.public_execution = bool(enabled)

    def grant_role(self, caller, role, account):
        """Timelock grantRole: role admin is DEFAULT_ADMIN_ROLE (the timelock only); Q-259 / REQ-ACCESS-153."""
        if not self.has_role(DEFAULT_ADMIN_ROLE, caller):
            raise TimelockError("AccessControlUnauthorizedAccount", caller, DEFAULT_ADMIN_ROLE)
        if role == DEFAULT_ADMIN_ROLE and account != TIMELOCK:
            raise TimelockError("AdminRoleOnlyTimelock", role, account)
        if role == EXECUTOR_ROLE and account == OPEN:              # REQ-ACCESS-144: only the toggle opens execution
            raise TimelockError("PublicExecutionOnlyByToggle")
        self.roles.setdefault(role, set()).add(account)

    def revoke_role(self, caller, role, account):
        if not self.has_role(DEFAULT_ADMIN_ROLE, caller):
            raise TimelockError("AccessControlUnauthorizedAccount", caller, DEFAULT_ADMIN_ROLE)
        if role == DEFAULT_ADMIN_ROLE and account == TIMELOCK:     # REQ-ACCESS-182
            raise TimelockError("TimelockAdminRequired")
        if role == EXECUTOR_ROLE and account == OPEN:              # REQ-ACCESS-144
            raise TimelockError("PublicExecutionOnlyByToggle")
        self.roles.setdefault(role, set()).discard(account)

    # ------------------------------------------------------------------ dispatch of executed calls
    def _dispatch(self, op_id, call):
        target, sel, args = call[0], selector(call), call[2:]
        if target == TIMELOCK:
            if sel == "setNormalDelay":
                self.set_normal_delay(TIMELOCK, *args)
            elif sel == "setShortDelaySelector":
                self.set_short_delay_selector(TIMELOCK, *args)
            elif sel == "togglePublicExecution":
                self.toggle_public_execution(TIMELOCK, *args)
            elif sel == "grantRole":
                self.grant_role(TIMELOCK, *args)
            elif sel == "revokeRole":
                self.revoke_role(TIMELOCK, *args)
            elif sel == "renounceRole":
                self.renounce_role(TIMELOCK, *args)
            elif sel == "updateDelay":
                self.update_delay(TIMELOCK, *args)
            else:
                raise TimelockError("TimelockUnauthorizedCaller", sel)   # no such selector on the timelock
            return
        if target in UPGRADEABLE and sel in ("grantRole", "revokeRole"):
            role, account = args
            if sel == "grantRole":
                if role in ADMIN_ROLES and account != TIMELOCK:
                    raise TimelockError("AdminRoleOnlyTimelock", role, account)
                self.contract_roles.setdefault((target, role), set()).add(account)
            else:
                self.contract_roles.setdefault((target, role), set()).discard(account)
            return
        self.applied.append((op_id, call))     # any other privileged call: executed with msg.sender = timelock
