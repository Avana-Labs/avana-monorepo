/*
 * AvanaTimelock (src/governance/timelock/AvanaTimelock.sol, interface
 * src/governance/timelock/IAvanaTimelock.sol, spec 2.15).
 *
 * Scheduling needs the required delay, execution only inside [readyAt, readyAt + GRACE_PERIOD), after which only
 * `cleanupExpiredOperation` touches the operation, the normal delay inside [MIN_NORMAL_DELAY, MAX_DELAY] and changed
 * only by a self-call, `updateDelay` disabled, the cancel restriction on role-change and restoring operations, public
 * execution (PROP-058); the short-delay list inside the immutable SHORT_ELIGIBLE set (PROP-073); the timelock as its
 * own only DEFAULT_ADMIN_ROLE holder (PROP-070). The AvanaTimelock is immutable.
 *
 * Calls without a methods entry: OpenZeppelin TimelockController v5.1.0's `schedule`, `scheduleBatch`, `execute`,
 * `executeBatch`, `cancel`, `getTimestamp`, `hashOperation` and `updateDelay` keep their signatures and are not in
 * IAvanaTimelock, so contracts/out holds no ABI for them; the rules call them directly and the prover resolves them
 * against the contract.
 *
 * Storage: OpenZeppelin's `_timestamps` and the AvanaTimelock's own fields are read through views only
 * (`getTimestamp`, `normalDelay`, `isShortDelaySelector`, `isShortEligible`, `isRoleChangeOperation`,
 * `isRestoringOperation`, `isOperationExpired`, `publicExecution`).
 *
 * Summaries: an executed call reaches an arbitrary target; targets other than the timelock are unresolved (any effect
 * on other contracts, none on the timelock's own storage except through its self-calls). `block.timestamp` is
 * non-decreasing across the calls of a rule (5.2 assumption).
 */

methods {
    function SHORT_DELAY() external returns (uint256) envfree;
    function MAX_DELAY() external returns (uint256) envfree;
    function MIN_NORMAL_DELAY() external returns (uint256) envfree;
    function GRACE_PERIOD() external returns (uint256) envfree;
    function normalDelay() external returns (uint256) envfree;
    function isShortDelaySelector(address, bytes4) external returns (bool) envfree;
    function isShortEligible(address, bytes4) external returns (bool) envfree;
    function isDaoOnlyCancelSelector(address, bytes4) external returns (bool) envfree;
    function requiredDelay(address[], bytes[]) external returns (uint256) envfree;
    function publicExecution() external returns (bool) envfree;
    function isOperationExpired(bytes32) external returns (bool);
    function isRoleChangeOperation(bytes32) external returns (bool) envfree;
    function isRestoringOperation(bytes32) external returns (bool) envfree;
    function setNormalDelay(uint256) external;
    function setShortDelaySelector(address, bytes4, bool) external;
    function togglePublicExecution(bool) external;
    function cleanupExpiredOperation(bytes32) external;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;
}

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256 of "CANCELLER_ROLE", "EXECUTOR_ROLE", "DAO_CANCELLER_ROLE"
definition CANCELLER() returns bytes32 = to_bytes32(0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783);
definition EXECUTOR() returns bytes32 = to_bytes32(0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63);
definition DAO_CANCELLER() returns bytes32 = to_bytes32(0x2138e7b918df10dc44ec87455d96d66ce2467bc27ce0bdf57c60550a0a1a35a3);

// ---------------------------------------------------------------------------------------------------------------------
// Delays (PROP-058, PROP-073)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-058 verifies: INV-051, INV-065, INV-068, Q-226, Q-228, Q-262
rule delayConstants() {
    assert SHORT_DELAY() == 43200, "SHORT_DELAY is not 43,200 s";
    assert MIN_NORMAL_DELAY() == 345600, "MIN_NORMAL_DELAY is not 345,600 s";
    assert MAX_DELAY() == 432000, "MAX_DELAY is not 432,000 s";
    assert GRACE_PERIOD() == 1209600, "GRACE_PERIOD is not 1,209,600 s";
}

// PROP-073 verifies: INV-051, INV-068, INV-090, Q-262
invariant normalDelayBounds()
    MIN_NORMAL_DELAY() <= normalDelay() && normalDelay() <= MAX_DELAY();

// PROP-058 verifies: INV-051, INV-068, Q-226, Q-228
rule normalDelayChangesOnlyBySelfCall(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    uint256 before = normalDelay();
    f(e, args);
    assert normalDelay() != before => (
        f.selector == sig:setNormalDelay(uint256).selector && e.msg.sender == currentContract)
        || f.selector == sig:execute(address, uint256, bytes, bytes32, bytes32).selector
        || f.selector == sig:executeBatch(address[], uint256[], bytes[], bytes32, bytes32).selector,
        "normalDelay changed other than by the timelock's own setNormalDelay call";
}

// PROP-058 verifies: INV-051, INV-068, Q-226
rule setNormalDelayOnlyFromTheTimelock(uint256 d) {
    env e;
    mathint minDelay = MIN_NORMAL_DELAY();
    mathint maxDelay = MAX_DELAY();
    setNormalDelay@withrevert(e, d);
    bool reverted = lastReverted;
    assert !reverted => e.msg.sender == currentContract, "setNormalDelay ran for a caller other than the timelock";
    assert (to_mathint(d) < minDelay || to_mathint(d) > maxDelay) => reverted,
        "setNormalDelay accepted a delay outside [MIN_NORMAL_DELAY, MAX_DELAY]";
}

// PROP-058 verifies: INV-051, INV-068, Q-226
rule updateDelayAlwaysReverts(uint256 d) {
    env e;
    updateDelay@withrevert(e, d);
    assert lastReverted, "updateDelay succeeded";
}

// PROP-058 verifies: INV-051, INV-065, INV-068, Q-228, Q-262
rule scheduleBatchNeedsRequiredDelay(address[] targets, uint256[] values, bytes[] payloads, bytes32 pred, bytes32 salt, uint256 delay) {
    env e;
    require targets.length <= 6;
    uint256 required = requiredDelay(targets, payloads);

    scheduleBatch(e, targets, values, payloads, pred, salt, delay);

    assert delay >= required, "an operation was scheduled below its required delay";
    assert delay >= SHORT_DELAY(), "an operation was scheduled below SHORT_DELAY";
}

// PROP-058 verifies: INV-051, INV-065, INV-068, Q-228, Q-262
rule scheduleNeedsRequiredDelay(address target, uint256 value, bytes data, bytes32 pred, bytes32 salt, uint256 delay) {
    env e;
    schedule(e, target, value, data, pred, salt, delay);
    // The one-call form of scheduleBatchNeedsRequiredDelay: SHORT_DELAY is the least any operation can take.
    assert delay >= SHORT_DELAY(), "an operation was scheduled below SHORT_DELAY";
}

// requiredDelay is SHORT_DELAY or the normal delay, never anything else.
// PROP-058 verifies: INV-068, Q-228, Q-262
rule requiredDelayIsShortOrNormal(address[] targets, bytes[] payloads) {
    require targets.length <= 6;
    uint256 r = requiredDelay(targets, payloads);
    assert r == SHORT_DELAY() || r == normalDelay(), "requiredDelay returned a delay other than SHORT_DELAY or normalDelay";
    assert targets.length == 0 => r == normalDelay(), "an empty operation took the short delay";
}

// PROP-073 verifies: INV-051, INV-068, INV-090, Q-262
invariant shortListWithinEligible(address target, bytes4 selector)
    isShortDelaySelector(target, selector) => isShortEligible(target, selector);

// PROP-073 verifies: INV-068, INV-090, Q-262
rule shortEligibleIsImmutable(method f, address target, bytes4 selector) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    bool before = isShortEligible(target, selector);
    f(e, args);
    assert isShortEligible(target, selector) == before, "the SHORT_ELIGIBLE set changed";
}

// An invariant, not a rule: it holds in every reachable state (the constructor refuses the timelock as a target and no
// function writes SHORT_ELIGIBLE afterwards), not in arbitrary storage.
// PROP-073 verifies: INV-068, INV-090, Q-262
invariant timelockNeverShortEligible(bytes4 selector)
    !isShortEligible(currentContract, selector);

// ---------------------------------------------------------------------------------------------------------------------
// Execution window and expiry (PROP-058)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-058 verifies: INV-051, INV-065, INV-068, Q-226, Q-228
rule executeWindow(address target, uint256 value, bytes data, bytes32 pred, bytes32 salt) {
    env e;
    bytes32 id = hashOperation(e, target, value, data, pred, salt);
    uint256 readyAt = getTimestamp(e, id);
    bool open = publicExecution();
    bool executor = hasRole(EXECUTOR(), e.msg.sender);

    execute(e, target, value, data, pred, salt);

    assert readyAt > 1, "an operation that was not scheduled, or already done, executed";
    assert readyAt <= e.block.timestamp, "an operation executed before its readyAt";
    assert to_mathint(e.block.timestamp) < to_mathint(readyAt) + to_mathint(GRACE_PERIOD()),
        "an operation executed at or after readyAt + GRACE_PERIOD";
    assert open || executor, "a non-executor executed while public execution is off";
}

// PROP-058 verifies: INV-051, INV-065, INV-068, Q-226, Q-228
rule executeBatchWindow(address[] targets, uint256[] values, bytes[] payloads, bytes32 pred, bytes32 salt) {
    env e;
    require targets.length <= 6;
    bytes32 id = hashOperationBatch(e, targets, values, payloads, pred, salt);
    uint256 readyAt = getTimestamp(e, id);
    bool open = publicExecution();
    bool executor = hasRole(EXECUTOR(), e.msg.sender);

    executeBatch(e, targets, values, payloads, pred, salt);

    assert readyAt > 1 && readyAt <= e.block.timestamp, "a batch executed before its readyAt";
    assert to_mathint(e.block.timestamp) < to_mathint(readyAt) + to_mathint(GRACE_PERIOD()),
        "a batch executed at or after readyAt + GRACE_PERIOD";
    assert open || executor, "a non-executor executed a batch while public execution is off";
}

// After expiry only cleanupExpiredOperation or a permitted cancel touches the operation (SPEC-GOV-013); cancelRights
// bounds who may cancel.
// PROP-058 verifies: INV-065, INV-068, SPEC-GOV-013, Q-226, Q-228
rule expiredOperationOnlyCleanedUp(method f, bytes32 id) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    require isOperationExpired(e, id);
    uint256 before = getTimestamp(e, id);

    f(e, args);

    // execute/executeBatch of another operation may itself call cleanupExpiredOperation(id) on the timelock.
    assert getTimestamp(e, id) != before => (f.selector == sig:cleanupExpiredOperation(bytes32).selector
        || f.selector == sig:cancel(bytes32).selector
        || f.selector == sig:execute(address, uint256, bytes, bytes32, bytes32).selector
        || f.selector == sig:executeBatch(address[], uint256[], bytes[], bytes32, bytes32).selector),
        "an expired operation was changed other than by cleanupExpiredOperation or cancel";
}

// ---------------------------------------------------------------------------------------------------------------------
// Cancel rights (PROP-058, PROP-073)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-058 verifies: INV-051, INV-068, Q-263
// PROP-073 verifies: INV-068, INV-090, Q-263
rule cancelRights(bytes32 id) {
    env e;
    bool roleChange = isRoleChangeOperation(id);
    bool restoring = isRestoringOperation(id);
    bool canceller = hasRole(CANCELLER(), e.msg.sender);
    bool dao = hasRole(DAO_CANCELLER(), e.msg.sender);

    cancel(e, id);

    assert canceller, "an operation was cancelled by a caller without CANCELLER_ROLE";
    assert roleChange => dao, "a role-change operation was cancelled without DAO_CANCELLER_ROLE";
    assert restoring => dao, "a restoring operation was cancelled without DAO_CANCELLER_ROLE";
}

// An operation that is neither all role changes nor all restoring calls is cancellable by any canceller.
// PROP-073 verifies: INV-068, INV-090, Q-263
rule mixedOperationCancellableByAnyCanceller(bytes32 id) {
    env e;
    require !isRoleChangeOperation(id) && !isRestoringOperation(id);
    require hasRole(CANCELLER(), e.msg.sender) && !hasRole(DAO_CANCELLER(), e.msg.sender);
    cancel(e, id);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Own admin role (PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-070 verifies: INV-084, Q-259
invariant timelockIsItsOwnOnlyAdmin(address a)
    hasRole(DEFAULT_ADMIN(), a) => a == currentContract;

// The timelock keeps its own admin role for life: no call revokes or renounces it.
// PROP-070 verifies: INV-084, REQ-ACCESS-182, Q-259
rule selfAdminNeverDropped(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    require hasRole(DEFAULT_ADMIN(), currentContract);
    f(e, args);
    assert hasRole(DEFAULT_ADMIN(), currentContract), "the timelock lost its own DEFAULT_ADMIN_ROLE";
}

// Public execution (EXECUTOR_ROLE held by address(0)) changes only through togglePublicExecution, directly or as a
// self-call inside an executed operation.
// PROP-058 verifies: INV-068, REQ-ACCESS-144, Q-228
rule openExecutorOnlyByToggle(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    requireInvariant togglingFlagClearBetweenCalls();
    bool before = publicExecution();
    f(e, args);
    assert publicExecution() != before => (
        (f.selector == sig:togglePublicExecution(bool).selector && e.msg.sender == currentContract)
        || f.selector == sig:execute(address, uint256, bytes, bytes32, bytes32).selector
        || f.selector == sig:executeBatch(address[], uint256[], bytes[], bytes32, bytes32).selector),
        "public execution changed other than by togglePublicExecution";
}

// The `_toggling` flag that lets `togglePublicExecution` (and the constructor) grant or revoke the open executor role
// is set and cleared inside that one call, so it is clear between calls.
// PROP-058 verifies: INV-068, REQ-ACCESS-144
invariant togglingFlagClearBetweenCalls()
    !currentContract._toggling;

// grantRole and revokeRole of the open executor role always revert, whoever calls.
// PROP-058 verifies: INV-068, REQ-ACCESS-144
rule openExecutorRoleCallsRevert(bool grant) {
    env e;
    requireInvariant togglingFlagClearBetweenCalls();
    if (grant) {
        grantRole@withrevert(e, EXECUTOR(), 0);
    } else {
        revokeRole@withrevert(e, EXECUTOR(), 0);
    }
    assert lastReverted, "the open executor role changed outside togglePublicExecution";
}

