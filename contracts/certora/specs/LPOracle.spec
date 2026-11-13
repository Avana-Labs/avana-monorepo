/*
 * LPOracle (the AMM-neutral base src/oracle/lp-oracle/LPOracle.sol, verified as the deployable concentrated-liquidity
 * implementation src/oracle/lp-oracle/LPOracleCL.sol with its three logic contracts; interface ILPOracle.sol; spec 2.10).
 *
 * Serving (`latestAnswer` never reverts and is at least 1 once seeded, PROP-027), the served price by state with the
 * stale-at-Expired value and the lower route during a disagreement (PROP-074, SPEC-ORC-017), the stored first
 * observation of a route disagreement (set once, never moved, cleared only by an evaluation that sees agreement or a
 * route-version change, PROP-049), the failure timer across a standby switch (PROP-074, REQ-ORACLE-095), the restricted
 * setter (PROP-034), the admin invariant (PROP-070) and the oracle arithmetic of PROP-023 to PROP-026 (primary tool per
 * 5.2: Halmos) and PROP-044 (primary tool: SMTChecker), restated as CVL rules over unbounded integers.
 *
 * Storage: ERC-7201 namespace `avana.storage.LPOracle` (2.10 Storage) declared as a struct annotated
 * `@custom:storage-location erc7201:avana.storage.LPOracle`; with `storage_extension_annotation` (conf) the prover
 * exposes it as `currentContract.ext_avana_storage_LPOracle`, with the 2.10 field names `accepted` (`answer`,
 * `updatedAt`, `prices`), `failedSince`, `disagreeSince` and `routeVersion` (one entry per market token, in the order
 * of `tokens()`). A market has at most `MAX_POOL_TOKENS = 8` tokens, so the route-version comparison is written out
 * for indices 0 to 7.
 *
 * Summaries: Chainlink aggregators and the pool's `slot0`, `observe`, `token0`, `token1` and `tickSpacing` are not
 * summarised, so each call returns arbitrary data or reverts (both failure paths of the gas-guarded static reads); the ParameterStore's `getOracleConfig` and `getFeed` and the MarketRegistry's
 * `activePriceRoutes` and `getToken` are NONDET (any configuration, including a failed read); the MarketRegistry's
 * `priceRouteVersion` is an uninterpreted function of the token, so a rule can make it differ from the stored version
 * (a standby switch, its cancellation, a restore or a new price source). A GAS opcode hook fixes a gas floor above
 * POKE_MIN_GAS_CEILING, the 5.2 assumption "a gas floor after catch": the `InsufficientGas` exits are out of scope.
 * OpenZeppelin AccessControl and UUPSUpgradeable v5.1.0 are the real code; `upgradeToAndCall` is named only by
 * selector.
 */

methods {
    function latestAnswer() external returns (int256);
    function getPriceState() external returns (PriceStateView);
    function lastAcceptedPrice() external returns (uint256, uint64) envfree;
    function poke() external returns (PriceState);
    function setPokeMinGas(uint32) external;
    function initialize(InitParams) external;
    function decimals() external returns (uint8) envfree;
    function tokens() external returns (address[]) envfree;
    function TIMELOCK() external returns (address) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;

    function _.getOracleConfig(address) external => NONDET;
    function _.getFeed(address) external => NONDET;
    function _.activePriceRoutes(address) external => NONDET;
    function _.getToken(address) external => NONDET;
    function _.priceRouteVersion(address t) external => routeVersionOf(t) expect uint64;
}

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256("APPLICATION_ADMIN")
definition APP_ADMIN() returns bytes32 = to_bytes32(0x4a5d77d29c55ea7cb6361740de568b58568c9b25abdfdb58dc883366746cb704);
definition isUpgrade(method f) returns bool = f.selector == sig:upgradeToAndCall(address, bytes).selector;

ghost routeVersionOf(address) returns uint64;

// Gas floor (see header).
hook GAS uint256 gasLeft {
    require to_mathint(gasLeft) >= 10000000;
}

definition seeded() returns bool = currentContract.ext_avana_storage_LPOracle.accepted.answer > 0;

// Token i's route version differs from the version the last writing call stored.
function versionChangedAt(address[] ts, uint256 i) returns bool {
    return i < ts.length && routeVersionOf(ts[i]) != currentContract.ext_avana_storage_LPOracle.routeVersion[i];
}

// Some market token's route version differs from the stored one (a standby switch, its cancellation, a restore or a
// new price source).
function versionChanged() returns bool {
    address[] ts = tokens();
    require ts.length <= 8; // MAX_POOL_TOKENS
    return versionChangedAt(ts, 0) || versionChangedAt(ts, 1) || versionChangedAt(ts, 2) || versionChangedAt(ts, 3)
        || versionChangedAt(ts, 4) || versionChangedAt(ts, 5) || versionChangedAt(ts, 6) || versionChangedAt(ts, 7);
}

// ---------------------------------------------------------------------------------------------------------------------
// Serving (PROP-027, PROP-074)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-027 verifies: INV-055, Q-056, Q-128, Q-191
rule latestAnswerAlwaysServesOnceSeeded() {
    env e;
    require e.msg.value == 0;
    require seeded();

    int256 answer = latestAnswer@withrevert(e);

    assert !lastReverted, "latestAnswer reverted";
    assert answer >= 1, "latestAnswer returned a value below 1";
}

// PROP-074 verifies: INV-055, INV-087, Q-247, Q-248
rule servedPriceByState() {
    env e;
    require e.msg.value == 0;
    require seeded();
    uint256 accepted;
    uint64 acceptedAt;
    accepted, acceptedAt = lastAcceptedPrice();

    PriceStateView v = getPriceState(e);
    int256 served = latestAnswer(e);
    mathint A = to_mathint(accepted);
    mathint fresh = to_mathint(v.freshAnswer);
    bool disagree = v.disagreementPauseActive || v.disagreementExpired;

    assert served == v.answer, "getPriceState().answer differs from latestAnswer()";
    assert served >= 1, "the served price is below 1";
    assert v.state == PriceState.Expired => served == 1, "Expired did not serve 1";
    assert v.state == PriceState.Cached => to_mathint(served) == A, "Cached did not serve the accepted price";
    // SPEC-ORC-017: the accepted price bounds borrowing only; Live and Drifting serve the fresh price, a disagreement
    // at most the fresh price, so a rally since the last accepted price never lowers the served price.
    assert (v.state == PriceState.Live || (v.state == PriceState.Drifting && !disagree))
        => to_mathint(served) == (fresh < 1 ? 1 : fresh), "Live or Drifting did not serve the fresh price";
    assert (v.state == PriceState.Drifting && disagree) => to_mathint(served) <= (fresh < 1 ? 1 : fresh),
        "a disagreement served above the fresh price";
}

// ---------------------------------------------------------------------------------------------------------------------
// Timers (PROP-049, PROP-074)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-049 verifies: INV-059, Q-162, Q-199, Q-208, Q-248
rule disagreementStartSetOnceAndNeverMoved(method f) filtered { f -> !f.isView && !isUpgrade(f) } {
    env e;
    calldataarg args;
    uint64 before = currentContract.ext_avana_storage_LPOracle.disagreeSince;
    bool changedVersion = versionChanged();

    f(e, args);

    uint64 after = currentContract.ext_avana_storage_LPOracle.disagreeSince;
    assert (before != 0 && after != before) => (after == 0 || (changedVersion && to_mathint(after) == to_mathint(e.block.timestamp))),
        "the stored disagreement start moved without a route-version change";
    assert (before == 0 && after != 0) => to_mathint(after) == to_mathint(e.block.timestamp),
        "a new disagreement start is not the observation time";
    assert after != before => (
        f.selector == sig:poke().selector || f.selector == sig:initialize(InitParams).selector),
        "the disagreement start changed outside an evaluation";
}

// A route-version change restarts the disagreement timer and never moves the failure timer.
// PROP-074 verifies: INV-087, Q-248
rule routeVersionRestartsDisagreementOnly(uint256 i) {
    env e;
    require e.msg.value == 0;
    require seeded();
    uint64 failedBefore = currentContract.ext_avana_storage_LPOracle.failedSince;
    bool changedVersion = versionChanged();
    uint64 acceptedAtBefore = currentContract.ext_avana_storage_LPOracle.accepted.updatedAt;

    poke(e);

    uint64 failedAfter = currentContract.ext_avana_storage_LPOracle.failedSince;
    uint64 dAfter = currentContract.ext_avana_storage_LPOracle.disagreeSince;
    assert changedVersion => (dAfter == 0 || to_mathint(dAfter) == to_mathint(e.block.timestamp)),
        "a route-version change did not restart the disagreement timer";
    assert (failedBefore != 0 && failedAfter != 0) => failedAfter == failedBefore, "the failure timer moved";
    address[] ts = tokens();
    assert i < ts.length => currentContract.ext_avana_storage_LPOracle.routeVersion[i] == routeVersionOf(ts[i]),
        "poke did not store the observed route version of a market token";
    assert currentContract.ext_avana_storage_LPOracle.accepted.answer > 0, "poke cleared the accepted price";
    assert currentContract.ext_avana_storage_LPOracle.accepted.updatedAt >= acceptedAtBefore,
        "poke stored an accepted price older than the stored one";
}

// PROP-044 verifies: Q-191 (primary tool per 5.2: SMTChecker)
rule pokeHasNoArithmeticFailureOnceSeeded() {
    env e;
    require e.msg.value == 0;
    require seeded();

    poke@withrevert(e);

    assert !lastReverted, "poke reverted inside the listing bounds";
}

// ---------------------------------------------------------------------------------------------------------------------
// Roles (PROP-034, PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-034 verifies: INV-051, Q-226, Q-228
rule setPokeMinGasNeedsApplicationAdmin(uint32 value) {
    env e;
    bool admin = hasRole(APP_ADMIN(), e.msg.sender);
    setPokeMinGas(e, value);
    assert admin, "setPokeMinGas ran without APPLICATION_ADMIN";
}

// PROP-034 verifies: INV-051, Q-226, Q-228
rule onlyPokeIsPermissionless(method f) filtered {
    f -> !f.isView && f.selector != sig:poke().selector && f.selector != sig:initialize(InitParams).selector
        && f.selector != sig:renounceRole(bytes32, address).selector
} {
    env e;
    calldataarg args;
    bool privileged = hasRole(APP_ADMIN(), e.msg.sender) || hasRole(DEFAULT_ADMIN(), e.msg.sender);
    f(e, args);
    assert privileged, "a restricted LPOracle selector ran for a caller with no admin role";
}

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !isUpgrade(f) }

// ---------------------------------------------------------------------------------------------------------------------
// Oracle arithmetic (primary tool per 5.2: Halmos)
// ---------------------------------------------------------------------------------------------------------------------

// SPEC-ORC-008 term for one token: floor((a - 1)+ * v / q), where q stands for 10^(d_i).
function compositionTerm(mathint a, mathint v, mathint q) returns mathint {
    mathint reduced = a >= 1 ? a - 1 : 0;
    return reduced * v / q;
}

// SPEC-ORC-008 for a two-token composition a = composition(10^d, v): max(1, sum of the terms).
function compositionPrice8(mathint a0, mathint a1, mathint v0, mathint v1, mathint q0, mathint q1) returns mathint {
    mathint total = compositionTerm(a0, v0, q0) + compositionTerm(a1, v1, q1);
    return total >= 1 ? total : 1;
}

// PROP-023 verifies: Q-191 (primary tool per 5.2: Halmos)
// Bounds of SPEC-ORC-008: amounts of 10^d <= 10^18 units below 2^128, prices at most MAX_ROUTE_ANSWER = 1e12.
rule price8IsPositiveAndBelowExact(mathint a0, mathint a1, mathint v0, mathint v1, mathint q0, mathint q1) {
    require a0 >= 0 && a1 >= 0 && a0 < 2^128 && a1 < 2^128;
    require v0 >= 0 && v1 >= 0 && v0 <= 10^12 && v1 <= 10^12;
    require q0 >= 1 && q1 >= 1;
    mathint price8 = compositionPrice8(a0, a1, v0, v1, q0, q1);
    // q0 * q1 times the exact value a0 * v0 / q0 + a1 * v1 / q1 of the composition
    mathint exactScaled = a0 * v0 * q1 + a1 * v1 * q0;

    assert a0 * v0 < 2^256 && a1 * v1 < 2^256, "a term product overflows uint256";
    assert price8 >= 1, "price8 below 1";
    assert exactScaled >= q0 * q1 => price8 * q0 * q1 <= exactScaled,
        "price8 above the exact value of the composition";
    assert price8 < 2^255, "price8 does not fit int256";
}

// PROP-024 verifies: Q-177 (primary tool per 5.2: Halmos)
rule stableCeilingNeverRaisesAndIsMonotone(
    mathint p, mathint q, mathint cap, mathint a0, mathint a1, mathint q0, mathint q1
) {
    require p >= 0 && q >= p && cap >= 0;
    require a0 >= 0 && a1 >= 0 && q0 >= 1 && q1 >= 1;
    mathint cp = p < cap ? p : cap;
    mathint cq = q < cap ? q : cap;
    assert cp <= p, "the ceiling raised a price";
    assert cp <= cq, "the ceiling is not monotone";
    // For the same amounts, a capped price never raises a composition term.
    assert compositionTerm(a0, cp, q0) <= compositionTerm(a0, p, q0), "the ceiling raised a composition term";
    assert compositionPrice8(a0, a1, cp, q, q0, q1) == compositionPrice8(a1, a0, q, cp, q1, q0),
        "the valuation depends on token order";
}

// PROP-025 verifies: Q-191 (primary tool per 5.2: Halmos)
rule clampedSqrtPriceStaysInTickMathRange(mathint s) {
    // Uniswap TickMath bounds at the pinned commit.
    mathint minSqrt = 4295128739;
    mathint maxSqrt = 1461446703485210103287273052203988822378723970342;
    require s >= 0 && s < 2^160;
    mathint clamped = s < minSqrt ? minSqrt : (s >= maxSqrt ? maxSqrt - 1 : s);
    assert clamped >= minSqrt && clamped < maxSqrt, "the pre-check leaves the sqrt price outside [MIN, MAX)";
}

// PROP-026 verifies: Q-184 (primary tool per 5.2: Halmos)
rule agreementCheckIsSymmetric(mathint p, mathint b, mathint tol) {
    require p >= 0 && b >= 0 && p < 2^128 && b < 2^128 && tol >= 0 && tol <= 10000;
    mathint diffPB = p > b ? p - b : b - p;
    mathint diffBP = b > p ? b - p : p - b;
    mathint minPB = p < b ? p : b;
    mathint minBP = b < p ? b : p;
    bool agreePB = diffPB * 10000 <= tol * minPB;
    bool agreeBP = diffBP * 10000 <= tol * minBP;
    assert agreePB == agreeBP, "the agreement check depends on argument order";
    assert diffPB * 10000 < 2^256 && tol * minPB < 2^256, "the agreement check overflows";
}
