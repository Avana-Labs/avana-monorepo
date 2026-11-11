/*
 * DebtOracle (planned src/oracle/debt-oracle/DebtOracle.sol, interface src/oracle/debt-oracle/IDebtOracle.sol,
 * spec 2.10 DebtOracle).
 *
 * The served debt price never reverts and is at least 1 once seeded, and is never below the accepted price unless
 * Live: `max(primary, alternate, accepted)` while the routes disagree, the accepted price when Cached and
 * `ceil(accepted × (10000 + debtStressRiseBps) / 10000)` when Expired (PROP-074, SPEC-ORC-018); the stored first
 * observation of a disagreement is set once and cleared only by an evaluation, and a route-version change restarts it
 * without moving the failure timer (PROP-049, PROP-074, REQ-ORACLE-095); the restricted setter (PROP-034); the admin
 * invariant (PROP-070); and the stress-rise arithmetic (PROP-044, primary tool SMTChecker), restated over unbounded
 * integers. These hold for the verified DebtOracle implementation.
 *
 * Storage: ERC-7201 namespace `avana.storage.DebtOracle` (2.10 DebtOracle Storage) declared as a struct annotated
 * `@custom:storage-location erc7201:avana.storage.DebtOracle`; with `storage_extension_annotation` (conf) the prover
 * exposes it as `currentContract.ext_avana_storage_DebtOracle`, with the field names `asset`, `accepted` (`price8`,
 * `updatedAt`), `failedSince`, `disagreeSince`, `routeVersion`.
 *
 * Summaries: Chainlink aggregators are not summarised (arbitrary answers or reverts, both try/catch paths); the
 * MarketRegistry's `activePriceRoutes` and `getToken` and the ParameterStore's feed, tolerance and timer reads are
 * NONDET; `priceRouteVersion` and `debtStressRiseBps` are uninterpreted functions of the asset, the latter inside its
 * [100, 5,000] bps bound. A GAS opcode hook fixes a gas floor above POKE_MIN_GAS_CEILING, so the `InsufficientGas`
 * exits are out of scope. OpenZeppelin AccessControl and UUPSUpgradeable v5.1.0 are the real code; `upgradeToAndCall`
 * is named only by selector.
 */

methods {
    function latestAnswer() external returns (int256);
    function getPriceState() external returns (DebtPriceView);
    function lastAcceptedPrice() external returns (uint256, uint64) envfree;
    function poke() external returns (PriceState);
    function setPokeMinGas(uint32) external;
    function initialize(DebtOracleInitParams) external;
    function ASSET() external returns (address) envfree;
    function TIMELOCK() external returns (address) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;

    function _.activePriceRoutes(address) external => NONDET;
    function _.getToken(address) external => NONDET;
    function _.getFeed(address) external => NONDET;
    function _.feedAgreementToleranceBps(address) external => NONDET;
    function _.cachedWindow() external => NONDET;
    function _.disagreementPauseMax() external => NONDET;
    function _.graceDuration() external => NONDET;
    function _.priceRouteVersion(address t) external => routeVersionOf(t) expect uint64;
    function _.debtStressRiseBps(address t) external => stressRiseOf(t) expect uint16;
}

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256("APPLICATION_ADMIN")
definition APP_ADMIN() returns bytes32 = to_bytes32(0x4a5d77d29c55ea7cb6361740de568b58568c9b25abdfdb58dc883366746cb704);
definition isUpgrade(method f) returns bool = f.selector == sig:upgradeToAndCall(address, bytes).selector;
definition MAX_ROUTE_ANSWER() returns mathint = 10^28;

ghost routeVersionOf(address) returns uint64;
ghost stressRiseOf(address) returns uint16 {
    axiom forall address t. stressRiseOf(t) >= 100 && stressRiseOf(t) <= 5000;
}

hook GAS uint256 gasLeft {
    require to_mathint(gasLeft) >= 10000000;
}

definition seeded() returns bool =
    currentContract.ext_avana_storage_DebtOracle.accepted.price8 > 0
    && to_mathint(currentContract.ext_avana_storage_DebtOracle.accepted.price8) <= MAX_ROUTE_ANSWER();

definition ceilDiv(mathint a, mathint b) returns mathint = (a + b - 1) / b;

// ---------------------------------------------------------------------------------------------------------------------
// Serving (PROP-074)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-074 verifies: INV-055, INV-087, Q-247
rule debtAnswerAlwaysServesOnceSeeded() {
    env e;
    require e.msg.value == 0;
    require seeded();

    int256 answer = latestAnswer@withrevert(e);

    assert !lastReverted, "the DebtOracle's latestAnswer reverted";
    assert answer >= 1, "the DebtOracle served a value below 1";
}

// PROP-074 verifies: INV-087, Q-247, Q-248
rule servedDebtPriceByState() {
    env e;
    require e.msg.value == 0;
    require seeded();
    uint256 accepted;
    uint64 acceptedAt;
    accepted, acceptedAt = lastAcceptedPrice();
    mathint A = to_mathint(accepted);
    mathint delta = stressRiseOf(ASSET());

    DebtPriceView v = getPriceState(e);
    int256 served = latestAnswer(e);
    bool disagree = v.disagreementPauseActive || v.disagreementExpired;
    mathint p = v.primaryValue;
    mathint b = v.alternateValue;
    mathint maxPB = p > b ? p : b;

    assert served == v.answer, "getPriceState().answer differs from latestAnswer()";
    assert v.state != PriceState.Live => to_mathint(served) >= A, "a non-Live DebtOracle served below the accepted price";
    assert v.state == PriceState.Cached => to_mathint(served) == A, "Cached did not serve the accepted price";
    assert v.state == PriceState.Expired => to_mathint(served) == ceilDiv(A * (10000 + delta), 10000),
        "Expired did not serve the accepted price raised by debtStressRiseBps, rounded up";
    assert (v.state == PriceState.Drifting && disagree) => to_mathint(served) == (maxPB > A ? maxPB : A),
        "a disagreement did not serve max(primary, alternate, accepted)";
}

// SPEC-ORC-018 arithmetic: the Expired value rounds up, never exceeds 1.5 A + 1 and fits in 256 bits.
// PROP-044 verifies: Q-191, Q-235
rule stressRiseArithmetic(mathint A, mathint delta) {
    require A >= 1 && A <= MAX_ROUTE_ANSWER() && delta >= 100 && delta <= 5000;
    mathint stressed = ceilDiv(A * (10000 + delta), 10000);
    assert A * (10000 + delta) < 2^256, "the stress rise overflows";
    assert stressed * 10000 >= A * (10000 + delta), "the stress rise rounds down";
    assert stressed >= A && 2 * stressed <= 3 * A + 2, "the stress value leaves [A, 1.5 A + 1]";
    // 5.2 example: USDC accepted 0.9999 with a 500 bps rise serves 1.049895.
    assert (A == 99990000 && delta == 500) => stressed == 104989500, "the 5.2 example does not serve 1.049895";
}

// ---------------------------------------------------------------------------------------------------------------------
// Timers (PROP-049, PROP-074)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-049 verifies: INV-059, Q-162, Q-199, Q-208, Q-248
rule debtDisagreementStartSetOnce(method f) filtered { f -> !f.isView && !isUpgrade(f) } {
    env e;
    calldataarg args;
    uint64 before = currentContract.ext_avana_storage_DebtOracle.disagreeSince;
    bool changedVersion = routeVersionOf(ASSET()) != currentContract.ext_avana_storage_DebtOracle.routeVersion;

    f(e, args);

    uint64 after = currentContract.ext_avana_storage_DebtOracle.disagreeSince;
    assert (before != 0 && after != before) => (after == 0 || (changedVersion && to_mathint(after) == to_mathint(e.block.timestamp))),
        "the stored disagreement start moved without a route-version change";
    assert (before == 0 && after != 0) => to_mathint(after) == to_mathint(e.block.timestamp),
        "a new disagreement start is not the observation time";
    assert after != before => (
        f.selector == sig:poke().selector || f.selector == sig:initialize(DebtOracleInitParams).selector),
        "the disagreement start changed outside an evaluation";
}

// PROP-074 verifies: INV-087, Q-248
rule debtRouteVersionNeverMovesFailureTimer() {
    env e;
    require e.msg.value == 0;
    require seeded();
    uint64 failedBefore = currentContract.ext_avana_storage_DebtOracle.failedSince;
    bool changedVersion = routeVersionOf(ASSET()) != currentContract.ext_avana_storage_DebtOracle.routeVersion;

    poke@withrevert(e);
    assert !lastReverted, "the DebtOracle's poke reverted";

    uint64 failedAfter = currentContract.ext_avana_storage_DebtOracle.failedSince;
    uint64 dAfter = currentContract.ext_avana_storage_DebtOracle.disagreeSince;
    assert changedVersion => (dAfter == 0 || to_mathint(dAfter) == to_mathint(e.block.timestamp)),
        "a route-version change did not restart the disagreement timer";
    assert (failedBefore != 0 && failedAfter != 0) => failedAfter == failedBefore, "the failure timer moved";
    assert currentContract.ext_avana_storage_DebtOracle.routeVersion == routeVersionOf(ASSET()),
        "poke did not store the observed route version";
    assert currentContract.ext_avana_storage_DebtOracle.accepted.price8 > 0, "poke cleared the accepted price";
}

// ---------------------------------------------------------------------------------------------------------------------
// Roles (PROP-034, PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-034 verifies: INV-051, Q-226, Q-228
rule debtSetPokeMinGasNeedsApplicationAdmin(uint32 value) {
    env e;
    bool admin = hasRole(APP_ADMIN(), e.msg.sender);
    setPokeMinGas(e, value);
    assert admin, "setPokeMinGas ran without APPLICATION_ADMIN";
}

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !isUpgrade(f) }
