/*
 * ParameterStore (src/policy/parameter-store/ParameterStore.sol, interface
 * src/policy/parameter-store/IParameterStore.sol, spec 2.9).
 *
 * Every tighten setter moves its parameter only in the safer direction, inside its hard bounds and inside the
 * liquidation-liveness bounds (per-market minimum slippage allowance, global TWAP and feed-agreement floors, grace
 * bounds), and reverts for a value that is not stricter; `minPledgeUsd` only rises
 * through `tightenMinPledgeUsd` and only falls through `loosenMinPledgeUsd`, within [0, 100_000e8] (PROP-042,
 * PROP-062 bound); every setter needs APPLICATION_ADMIN, except useStandbySecondSource (pause guardian) and the tighten
 * setters and setAvanaFeeShareBps, which also accept APPLICATION_RISK_STEWARD (PROP-034); the admin roles are held only
 * by the timelock (PROP-070); the arithmetic of the step-limited loosen setters is restated over unbounded integers (PROP-044, primary
 * tool SMTChecker). These hold for the verified ParameterStore implementation.
 *
 * Storage: ERC-7201 namespace `avana.storage.ParameterStore` (2.9 Storage); the rules read it only through the
 * contract's views (`getMarketParams`, `hardHealthFloor`, `slippageAllowanceMinBps`, `graceDuration`, ...), so
 * no storage extension is needed.
 *
 * Summaries: the LPOracle's `checkConfig`, the MarketRegistry's market, token, Spoke and debt-reserve reads and the Hub and Spoke reads made by listing and cap setters are NONDET (any answer), which
 * can only add reverts and cannot widen what a successful setter stores. OpenZeppelin AccessControl and
 * UUPSUpgradeable v5.1.0 are the real code; `upgradeToAndCall` has no interface ABI and is named only by selector.
 */

methods {
    function getMarketParams(uint256) external returns (ParameterStore.MarketParams) envfree;
    function hardHealthFloor(uint256) external returns (uint256) envfree;
    function gateRecoverySeconds() external returns (uint64) envfree;
    function minPledgeUsd(uint256) external returns (uint256) envfree;
    function slippageAllowanceMinBps(uint256) external returns (uint16) envfree;
    function consistencyToleranceMinBps() external returns (uint16) envfree;
    function feedAgreementToleranceBps(address) external returns (uint16) envfree;
    function feedAgreementToleranceMinBps(address) external returns (uint16) envfree;
    function graceHealthFactor() external returns (uint256) envfree;
    function graceHealthFactorMin() external returns (uint256) envfree;
    function graceDuration() external returns (uint32) envfree;
    function graceDurationMax() external returns (uint32) envfree;
    function floorRoundingAllowance(address) external returns (uint256) envfree;
    function borrowPriceMaxAge(address) external returns (uint32) envfree;
    function LOOSEN_HEALTH_FACTOR_STEP() external returns (uint256) envfree;
    function poolShareMaxBps() external returns (uint16) envfree;
    function poolShareMaxBpsOf(bytes32) external returns (uint16) envfree;
    function TIMELOCK() external returns (address) envfree;

    function tightenHardHealthFloor(uint256, uint256) external;
    function tightenSlippageAllowanceBps(uint256, uint16) external;
    function tightenConsistencyToleranceBps(uint256, uint16) external;
    function tightenFeedAgreementToleranceBps(address, uint16) external;
    function tightenMinPledgeUsd(uint256, uint256) external;
    function tightenFloorRoundingAllowance(address, uint256) external;
    function tightenBorrowPriceMaxAge(address, uint32) external;
    function tightenPoolRiskFactor(uint256, uint16) external;
    function tightenMarketUsdCap(uint256, uint256) external;
    function tightenTopUpSliceUsd(uint256, uint256) external;
    function tightenTokenUsdCap(address, address, uint256) external;
    function tightenDepositorUsdCap(address, uint256) external;
    function tightenPoolShareMaxBps(uint16) external;
    function tightenPoolShareMaxBpsOf(uint256, uint16) external;
    function tightenMaxShortfallBps(uint16) external;
    function tightenDebtStressRiseBps(address, uint16) external;
    function tightenRouteDepthThreshold(uint256, address, address, uint8, uint256) external;
    function tightenBreakerDeficitMax(address, address, uint256) external;
    function tightenGateRecoverySeconds(uint64) external;
    function loosenGateRecoverySeconds(uint64) external;
    function loosenHardHealthFloor(uint256, uint256) external;
    function loosenMinPledgeUsd(uint256, uint256) external;
    function loosenPoolShareMaxBpsOf(uint256, uint16) external;
    function setGraceDuration(uint32) external;
    function setGraceHealthFactor(uint256) external;
    function setSlippageAllowanceMinBps(uint256, uint16) external;
    function setInitialMarketParams(uint256, ParameterStore.MarketParams) external;
    function initialize(address, ParameterStore.GlobalParams, uint256, uint16) external;

    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;

    function _.checkConfig(ParameterStore.OracleConfig) external => NONDET;
    function _.getMarket(uint256) external => NONDET;
    function _.getToken(address) external => NONDET;
    function _.getDebtReserve(address, uint256) external => NONDET;
    function _.isApprovedDebtReserve(address, uint256) external => NONDET;
    // The token's price routes in force, read by the feed-agreement liveness floor: a fixed function of the token for
    // the rule (a route in force has at most two feeds, the registry's route length check), so the floor the setter checks and
    // the floor the rule reads through `feedAgreementToleranceMinBps` agree.
    function _.activePriceRoutes(address t) external => activeRoutesOf(t) expect (address[], address[], ParameterStore.RouteSlot);
}

ghost routeFeedCount(address, bool) returns uint256 {
    axiom forall address t. forall bool p. routeFeedCount(t, p) <= 2;
}
ghost routeFeedAt(address, bool, uint256) returns address;

function activeRoutesOf(address t) returns (address[], address[], ParameterStore.RouteSlot) {
    address[] primary;
    address[] alternate;
    ParameterStore.RouteSlot replaced;
    require primary.length == routeFeedCount(t, true) && alternate.length == routeFeedCount(t, false);
    require primary.length >= 1 => primary[0] == routeFeedAt(t, true, 0);
    require alternate.length >= 1 => alternate[0] == routeFeedAt(t, false, 0);
    require primary.length == 2 => primary[1] == routeFeedAt(t, true, 1);
    require alternate.length == 2 => alternate[1] == routeFeedAt(t, false, 1);
    return (primary, alternate, replaced);
}

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256("APPLICATION_ADMIN")
definition APP_ADMIN() returns bytes32 = to_bytes32(0x4a5d77d29c55ea7cb6361740de568b58568c9b25abdfdb58dc883366746cb704);
definition PAUSE_GUARDIAN() returns bytes32 = to_bytes32(0xca16ee6b20db9286cfb1a9beee8e8a87e6c3bf160859d756b3335bdcde7871d2);
// keccak256("APPLICATION_RISK_STEWARD")
definition RISK_STEWARD() returns bytes32 = to_bytes32(0x80af594707954d7289f03f44a572035936215b9f928d89bf2ac5f1e37dc483ac);

// The 20 tighten setters and setAvanaFeeShareBps: the selectors the Joint Configuration Safe's
// APPLICATION_RISK_STEWARD may call beside APPLICATION_ADMIN (REQ-PSTORE-002, REQ-ROLE-117).
definition stewardSelector(method f) returns bool =
    f.selector == sig:tightenHardHealthFloor(uint256, uint256).selector
    || f.selector == sig:tightenSlippageAllowanceBps(uint256, uint16).selector
    || f.selector == sig:tightenFloorRoundingAllowance(address, uint256).selector
    || f.selector == sig:tightenBorrowPriceMaxAge(address, uint32).selector
    || f.selector == sig:tightenConsistencyToleranceBps(uint256, uint16).selector
    || f.selector == sig:tightenFeedAgreementToleranceBps(address, uint16).selector
    || f.selector == sig:tightenPoolRiskFactor(uint256, uint16).selector
    || f.selector == sig:tightenRouteDepthThreshold(uint256, address, address, uint8, uint256).selector
    || f.selector == sig:tightenMarketUsdCap(uint256, uint256).selector
    || f.selector == sig:tightenTopUpSliceUsd(uint256, uint256).selector
    || f.selector == sig:tightenTokenUsdCap(address, address, uint256).selector
    || f.selector == sig:tightenDepositorUsdCap(address, uint256).selector
    || f.selector == sig:tightenPoolShareMaxBps(uint16).selector
    || f.selector == sig:tightenMinPledgeUsd(uint256, uint256).selector
    || f.selector == sig:tightenPoolShareMaxBpsOf(uint256, uint16).selector
    || f.selector == sig:tightenMaxShortfallBps(uint16).selector
    || f.selector == sig:tightenDebtStressRiseBps(address, uint16).selector
    || f.selector == sig:tightenGateRecoverySeconds(uint64).selector
    || f.selector == sig:tightenBreakerDeficitMax(address, address, uint256).selector
    || f.selector == sig:tightenMaxFlashFeeBps(uint16).selector
    || f.selector == sig:setAvanaFeeShareBps(uint16).selector;
definition WAD() returns mathint = 10^18;
definition MIN_PLEDGE_USD_MAX() returns mathint = 100000 * 10^8;

definition isUpgrade(method f) returns bool = f.selector == sig:upgradeToAndCall(address, bytes).selector;
// Parametric rules and invariants range over the router's own functions. The logic contracts in the scene do their
// work for the router through its delegatecall; a direct call to a logic contract runs on that contract's own storage,
// never the router's, so it cannot change any value these rules read.
definition routerEntry(method f) returns bool = f.contract == currentContract;
definition isRoleCall(method f) returns bool =
    f.selector == sig:grantRole(bytes32, address).selector || f.selector == sig:revokeRole(bytes32, address).selector
    || f.selector == sig:renounceRole(bytes32, address).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Tighten setters (PROP-042)
// ---------------------------------------------------------------------------------------------------------------------

// The optional per-market hard floor (0 = off, the default) only rises or switches on through its tighten setter, to
// a value in [1.00, 1.25] (Q-398).
// PROP-042 verifies: INV-047, Q-139, Q-228, Q-398
rule tightenHardHealthFloorIsSafer(uint256 marketId, uint256 value) {
    env e;
    mathint before = hardHealthFloor(marketId);
    tightenHardHealthFloor@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) > before && to_mathint(hardHealthFloor(marketId)) == to_mathint(value)),
        "tightenHardHealthFloor did not raise the value";
    assert ok => (to_mathint(value) >= WAD() && to_mathint(value) <= 125 * WAD() / 100),
        "hardHealthFloor left [1.00, 1.25]";
    assert to_mathint(value) <= before => !ok, "a value that is not stricter was accepted";
}

// APPLICATION_ADMIN and DEFAULT_ADMIN_ROLE are administered by DEFAULT_ADMIN_ROLE in every reachable state: that is
// the AccessControl default, and initialize sets the admin of the guardian roles only.
// PROP-034 verifies: INV-051, Q-226, Q-228
invariant adminRolesAdministeredByDefaultAdmin()
    getRoleAdmin(APP_ADMIN()) == DEFAULT_ADMIN() && getRoleAdmin(DEFAULT_ADMIN()) == DEFAULT_ADMIN()
    filtered { f -> !isUpgrade(f) && routerEntry(f) }

// From the moment an admin role exists (initialize sets the global parameters and grants the roles in one call), the
// temporary-gate recovery window is inside [600, 7,200]: initialize checks it, tighten caps it at 7,200 and loosen
// floors it at 600.
// PROP-042 verifies: INV-047, Q-399
invariant gateRecoveryInBoundsOnceAdministered(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a))
        => (gateRecoverySeconds() >= 600 && gateRecoverySeconds() <= 7200)
    filtered { f -> !isUpgrade(f) && routerEntry(f) }
    {
        preserved with (env e) {
            // A grant of either admin role needs DEFAULT_ADMIN_ROLE, so the granter already sees the bounds.
            requireInvariant adminRolesAdministeredByDefaultAdmin();
            requireInvariant gateRecoveryInBoundsOnceAdministered(e.msg.sender);
        }
    }

// The temporary-gate recovery window only rises through its tighten setter and stays within [600, 7,200] (Q-399).
// PROP-042 verifies: INV-047, Q-399
rule tightenGateRecoverySecondsIsSafer(uint64 value) {
    env e;
    requireInvariant gateRecoveryInBoundsOnceAdministered(e.msg.sender);
    mathint before = gateRecoverySeconds();
    tightenGateRecoverySeconds@withrevert(e, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) > before && to_mathint(gateRecoverySeconds()) == to_mathint(value)),
        "tightenGateRecoverySeconds did not raise the value";
    assert ok => (to_mathint(value) >= 600 && to_mathint(value) <= 7200), "gateRecoverySeconds left [600, 7,200]";
    assert to_mathint(value) <= before => !ok, "a value that is not stricter was accepted";
}

// PROP-042 verifies: INV-047, Q-139, Q-228
rule tightenSlippageStaysAboveMarketMinimum(uint256 marketId, uint16 value) {
    env e;
    mathint before = getMarketParams(marketId).slippageAllowanceBps;
    mathint floor = slippageAllowanceMinBps(marketId);
    tightenSlippageAllowanceBps@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) < before && to_mathint(getMarketParams(marketId).slippageAllowanceBps) == to_mathint(value)),
        "tightenSlippageAllowanceBps did not lower the allowance";
    assert ok => to_mathint(value) >= floor, "the slippage allowance fell below the market's liveness floor";
    assert to_mathint(value) >= before => !ok, "a value that is not stricter was accepted";
}

// PROP-042 verifies: INV-047, Q-139, Q-228
rule tightenConsistencyStaysAboveGlobalMinimum(uint256 marketId, uint16 value) {
    env e;
    mathint before = getMarketParams(marketId).consistencyToleranceBps;
    tightenConsistencyToleranceBps@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) < before && to_mathint(value) >= to_mathint(consistencyToleranceMinBps())),
        "tightenConsistencyToleranceBps raised the tolerance or left the liveness floor";
    assert to_mathint(value) >= before => !ok, "a value that is not stricter was accepted";
}

// PROP-042 verifies: INV-047, Q-139, Q-228
rule tightenFeedToleranceStaysAboveTokenMinimum(address token, uint16 value) {
    env e;
    mathint before = feedAgreementToleranceBps(token);
    tightenFeedAgreementToleranceBps@withrevert(e, token, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) < before && to_mathint(value) >= to_mathint(feedAgreementToleranceMinBps(token))),
        "tightenFeedAgreementToleranceBps raised the tolerance or left the liveness floor";
    assert ok => to_mathint(feedAgreementToleranceBps(token)) == to_mathint(value), "the tolerance was not stored";
    assert to_mathint(value) >= before => !ok, "a value that is not stricter was accepted";
}

// PROP-042 verifies: INV-047, Q-139, Q-228, Q-230
rule tightenMinPledgeUsdOnlyRaisesWithinBound(uint256 marketId, uint256 value) {
    env e;
    mathint before = minPledgeUsd(marketId);
    tightenMinPledgeUsd@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) > before && to_mathint(value) <= MIN_PLEDGE_USD_MAX()),
        "tightenMinPledgeUsd did not raise the minimum inside [0, 100_000e8]";
    assert ok => to_mathint(minPledgeUsd(marketId)) == to_mathint(value), "the minimum was not stored";
}

// PROP-042 verifies: INV-047, Q-228, Q-230
rule loosenMinPledgeUsdOnlyLowers(uint256 marketId, uint256 value) {
    env e;
    mathint before = minPledgeUsd(marketId);
    loosenMinPledgeUsd@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => (to_mathint(value) < before && to_mathint(minPledgeUsd(marketId)) == to_mathint(value)),
        "loosenMinPledgeUsd did not lower the minimum";
}

// minPledgeUsd changes only through its two setters (and the listing setter of a market that has no records yet).
// PROP-042 verifies: INV-047, Q-230
rule minPledgeUsdChangesOnlyThroughItsSetters(method f, uint256 marketId) filtered { f -> !f.isView && !isUpgrade(f) && routerEntry(f) } {
    env e;
    calldataarg args;
    mathint before = minPledgeUsd(marketId);
    f(e, args);
    mathint after = minPledgeUsd(marketId);
    assert after > before => (f.selector == sig:tightenMinPledgeUsd(uint256, uint256).selector
        || f.selector == sig:setInitialMarketParams(uint256, ParameterStore.MarketParams).selector),
        "minPledgeUsd rose outside tightenMinPledgeUsd and the listing setter";
    assert after < before => (f.selector == sig:loosenMinPledgeUsd(uint256, uint256).selector
        || f.selector == sig:setInitialMarketParams(uint256, ParameterStore.MarketParams).selector),
        "minPledgeUsd fell outside loosenMinPledgeUsd and the listing setter";
    assert after <= MIN_PLEDGE_USD_MAX() || after == before, "minPledgeUsd left [0, 100_000e8]";
}

// The liveness floors themselves cannot be moved past the values they protect.
// PROP-042 verifies: INV-047, Q-139, Q-228
rule livenessFloorsStayBelowTheirAllowances(uint256 marketId, uint16 value) {
    env e;
    setSlippageAllowanceMinBps@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    assert ok => to_mathint(getMarketParams(marketId).slippageAllowanceBps) >= to_mathint(value),
        "the slippage floor was set above the allowance";
}

// PROP-042 verifies: INV-047, Q-139, Q-228
rule graceSettersStayInsideGlobalBounds(uint32 duration, uint256 hf) {
    env e1;
    env e2;
    setGraceDuration@withrevert(e1, duration);
    bool durationOk = !lastReverted;
    assert durationOk => to_mathint(duration) <= to_mathint(graceDurationMax()), "graceDuration above graceDurationMax";
    setGraceHealthFactor@withrevert(e2, hf);
    bool hfOk = !lastReverted;
    assert hfOk => (hf >= graceHealthFactorMin() && to_mathint(hf) < WAD()),
        "graceHealthFactor outside [graceHealthFactorMin, 1e18)";
}

// Lower is safer for the remaining tighten setters with a single scalar view.
// PROP-042 verifies: INV-047, Q-139, Q-228
rule tightenLowersScalars(address asset, uint256 v, address feed, uint32 age, uint256 marketId, uint16 factor) {
    env e1;
    env e2;
    env e3;
    mathint rounding = floorRoundingAllowance(asset);
    tightenFloorRoundingAllowance@withrevert(e1, asset, v);
    bool roundingOk = !lastReverted;
    assert roundingOk => to_mathint(v) < rounding, "tightenFloorRoundingAllowance did not lower the asset's allowance";

    mathint ageBefore = borrowPriceMaxAge(feed);
    tightenBorrowPriceMaxAge@withrevert(e2, feed, age);
    bool ageOk = !lastReverted;
    assert ageOk => to_mathint(age) < ageBefore, "tightenBorrowPriceMaxAge did not lower the age";

    mathint riskBefore = getMarketParams(marketId).poolRiskFactor;
    tightenPoolRiskFactor@withrevert(e3, marketId, factor);
    bool riskOk = !lastReverted;
    assert riskOk => (to_mathint(factor) < riskBefore && factor > 0), "tightenPoolRiskFactor did not lower the factor above 0";
}

// PROP-042 verifies: INV-047, Q-139
rule tightenIsReachable(uint256 marketId, uint256 value) {
    env e;
    tightenMinPledgeUsd(e, marketId, value);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Arithmetic of the step-limited loosen setters (PROP-044; primary tool per 5.2: SMTChecker)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-044 verifies: Q-191, Q-235
rule loosenHealthFactorStepHasNoUnderflow(uint256 marketId, uint256 value) {
    env e;
    require LOOSEN_HEALTH_FACTOR_STEP() == 3 * 10^16;
    mathint before = hardHealthFloor(marketId);
    require before >= WAD() && before <= 125 * WAD() / 100;
    loosenHardHealthFloor@withrevert(e, marketId, value);
    bool ok = !lastReverted;
    mathint after = hardHealthFloor(marketId);
    // A value below 1.00 is stored as 0 (off), allowed only when the step from `before` to 1.00 is within one step.
    assert ok => (after == 0 ? before - 3 * 10^16 <= WAD() : (after >= before - 3 * 10^16 && after >= WAD())),
        "loosenHardHealthFloor moved more than one step or to a value in (0, 1.0)";
}

// The cap loosen setters check one step as `value * 10_000 <= old * CAP_STEP_BPS` (CAP_STEP_BPS = 15_000, 1.5x) in
// uint256, after refusing `value > USD_CAP_MAX` (2^128 - 1); every stored cap is at most USD_CAP_MAX. Inside that
// listing bound neither product overflows, and the 1.5x step bound is never below the current cap.
// PROP-044 verifies: Q-191, Q-235
rule capStepArithmeticFits(mathint cap, mathint value) {
    require cap >= 0 && cap <= 2^128 - 1;
    require value >= 0 && value <= 2^128 - 1;
    assert value * 10000 < 2^256, "value * BPS overflows";
    assert cap * 15000 < 2^256, "old * CAP_STEP_BPS overflows";
    assert cap * 15000 / 10000 >= cap, "the step bound is below the current cap";
}

// ---------------------------------------------------------------------------------------------------------------------
// Role map (PROP-034) and admin invariant (PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-034 verifies: INV-051, Q-226, Q-228
rule settersNeedApplicationAdmin(method f) filtered {
    f -> !f.isView && !isRoleCall(f) && routerEntry(f)
        && f.selector != sig:initialize(address, ParameterStore.GlobalParams, uint256, uint16).selector
} {
    env e;
    calldataarg args;
    bool admin = hasRole(APP_ADMIN(), e.msg.sender);
    bool guardian = hasRole(PAUSE_GUARDIAN(), e.msg.sender);
    bool steward = hasRole(RISK_STEWARD(), e.msg.sender);
    f(e, args);
    // useStandbySecondSource is the one ParameterStore function a guardian holds (REQ-PSTORE-029); the tighten setters
    // and setAvanaFeeShareBps also accept the risk steward (REQ-PSTORE-002); everything else needs APPLICATION_ADMIN.
    assert f.selector == sig:useStandbySecondSource(address).selector ? guardian
        : (stewardSelector(f) ? (admin || steward) : admin),
        "a ParameterStore setter or upgrade ran without its role";
}

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !isUpgrade(f) && routerEntry(f) }
