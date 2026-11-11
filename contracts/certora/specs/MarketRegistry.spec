/*
 * MarketRegistry (planned src/policy/market-registry/MarketRegistry.sol, interface
 * src/policy/market-registry/IMarketRegistry.sol, spec 2.8).
 *
 * The per-Hub pause state and its reason (PROP-041; a call changes only the Hub it names), the address freeze with its protected set, per-caller daily
 * limit and no keeper-floor check, Q-400 (PROP-071), the debt-reserve set at activation and removal (PROP-061), the role map of every
 * restricted selector (PROP-034) and the inductive admin invariant (PROP-070). These hold for the verified
 * MarketRegistry implementation.
 *
 * Storage: ERC-7201 namespace `avana.storage.MarketRegistry` (2.8 Storage); the rules read it only through the
 * contract's views (`pauseState(hub)`, `pauseReason(hub)`, `isFrozenAddress`, `freezesInWindow`, `hasRole`, `getMarket`,
 * `getSpoke`, `getDebtReserve`, `marketOfVaultToken`, `marketOfLpOracle`, `hubTier`, `integrationIdOf`,
 * `flashSource`), so no storage extension is needed.
 *
 * Summaries: LPVaultSwap's keeper views (`isApprovedKeeper`, `activeKeeperCount`, `KEEPER_FLOOR`) and the AaveAdapter's
 * `walletOf` are uninterpreted functions, fixed for the call; the Hub's per-Spoke owed and deficit reads are
 * uninterpreted functions of (hub, assetId, spoke); the RiskModule's `checkAaveConfig` is recorded (its own rule, that
 * it returns only when the Spoke's Aave configuration matches the registry, is proved in RiskModule.spec, PROP-061);
 * every other external read made while listing or activating is NONDET. OpenZeppelin
 * AccessControl and UUPSUpgradeable v5.1.0 are the real code; `upgradeToAndCall` has no interface ABI, so it is named
 * only by selector in filters and never in the methods block. `block.timestamp` is non-decreasing across the calls of
 * a rule (5.2 assumption).
 */

using MarketRegistrySafetyLogicHarness as safetyLogic;

methods {
    // Pause state, per Hub
    function pauseState(address) external returns (MarketRegistry.PauseState) envfree;
    function pauseReason(address) external returns (MarketRegistry.PauseReason) envfree;
    function freeze(address) external;
    function pause(address, MarketRegistry.PauseReason) external;
    function freezeAll() external;
    function pauseAll(MarketRegistry.PauseReason) external;
    function unfreeze(address) external;
    function unpause(address) external;

    // Address freeze
    function freezeAddress(address) external;
    function unfreezeAddress(address) external;
    function isFrozenAddress(address) external returns (bool) envfree;
    function freezesInWindow(address) external returns (uint256);
    function MAX_ADDRESS_FREEZES_PER_DAY() external returns (uint256) envfree;

    // Debt reserves and markets
    function activateMarket(uint256) external;
    function removeDebtReserve(address, uint256) external;
    function isApprovedDebtReserve(address, uint256) external returns (bool) envfree;
    function getDebtReserve(address, uint256) external returns (MarketRegistry.DebtReserveDef) envfree;
    function getMarket(uint256) external returns (MarketRegistry.Market) envfree;
    function getSpoke(address) external returns (MarketRegistry.SpokeDef) envfree;
    function hubTier(address) external returns (MarketRegistry.RiskTier) envfree;
    function integrationIdOf(address) external returns (uint32) envfree;
    function flashSource() external returns (address) envfree;
    function marketOfVaultToken(address) external returns (uint256) envfree;
    function marketOfLpOracle(address) external returns (uint256) envfree;
    function initialize(address) external;

    // Breakers (recordBreach is RiskModule-only, Q-399)
    function recordBreach(bytes32, uint32) external;
    function cancelStandbySwitch(address) external;
    function useStandbyRoute(address, MarketRegistry.RouteSlot) external;
    function tripMarketBreaker(uint256) external;
    function tripDebtBreaker(address, uint256) external;
    function resetMarketBreaker(uint256) external;
    function resetDebtBreaker(address, uint256) external;

    // Immutables
    function TIMELOCK() external returns (address) envfree;
    function AAVE_GOVERNANCE_EXECUTOR() external returns (address) envfree;
    function AAVE_ADAPTER() external returns (address) envfree;
    function COLLATERALIZATION() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function PROXY_MANAGER() external returns (address) envfree;
    function PARAMETER_STORE() external returns (address) envfree;
    function RISK_MODULE() external returns (address) envfree;
    function PAYOUT_ESCROW() external returns (address) envfree;
    function FLASH_LIQUIDATOR() external returns (address) envfree;
    function LOCK() external returns (address) envfree;
    function VAULT_TOKEN_FACTORY() external returns (address) envfree;

    // AccessControl (OpenZeppelin v5.1.0)
    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;

    // LPVaultSwap keeper views and the AaveAdapter's proxy registry
    function _.isApprovedKeeper(address k) external => keeperApproved(k) expect bool;
    function _.activeKeeperCount() external => activeKeepers() expect uint256;
    function _.KEEPER_FLOOR() external => keeperFloor() expect uint256;
    function _.walletOf(address p) external => adapterWalletOf(p) expect address;

    // Hub and Spoke reads of the debt-reserve set
    function _.getSpokeTotalOwed(uint256 a, address s) external => hubSpokeOwed(calledContract, a, s) expect uint256;
    function _.getSpokeDeficitRay(uint256 a, address s) external => hubSpokeDeficit(calledContract, a, s) expect uint256;

    // RiskModule and ParameterStore checks used by activation and debt-reserve enabling
    function _.checkAaveConfig(address s, uint256[] ids) external => recordAaveConfigCheck(s) expect void;
    function _.isHubSharesEqualAssets(uint256) external => NONDET;
    function _.expectedCollateralFactorBps(uint256) external => NONDET;
    function _.liquidationLivenessHolds(address, uint256, uint256) external => NONDET;
}

// ---------------------------------------------------------------------------------------------------------------------
// Roles and external models
// ---------------------------------------------------------------------------------------------------------------------

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256("APPLICATION_ADMIN"), keccak256("APPLICATION_PAUSE_GUARDIAN"), keccak256("APPLICATION_FREEZE_GUARDIAN")
definition APP_ADMIN() returns bytes32 = to_bytes32(0x4a5d77d29c55ea7cb6361740de568b58568c9b25abdfdb58dc883366746cb704);
definition PAUSE_GUARDIAN() returns bytes32 = to_bytes32(0xca16ee6b20db9286cfb1a9beee8e8a87e6c3bf160859d756b3335bdcde7871d2);
definition FREEZE_GUARDIAN() returns bytes32 = to_bytes32(0x0c21afe69d1e0290272fa2a9f3df85589b7946c6845042b725f40fa7a09e18a0);

ghost keeperApproved(address) returns bool;
ghost activeKeepers() returns uint256;
ghost keeperFloor() returns uint256;
ghost adapterWalletOf(address) returns address;
ghost hubSpokeOwed(address, uint256, address) returns uint256;
ghost hubSpokeDeficit(address, uint256, address) returns uint256;

persistent ghost bool aaveConfigChecked;
persistent ghost address aaveConfigCheckedSpoke;

function recordAaveConfigCheck(address s) {
    aaveConfigChecked = true;
    aaveConfigCheckedSpoke = s;
}

definition isPauseGuardOrAdmin(address a) returns bool = hasRole(PAUSE_GUARDIAN(), a) || hasRole(APP_ADMIN(), a);
definition isFreezeGuardOrAdmin(address a) returns bool = hasRole(FREEZE_GUARDIAN(), a) || hasRole(APP_ADMIN(), a);

// The fixed part of the protected set of REQ-MREG-020 (with the public flash liquidation helper) together with the parts
// the registry's views expose: recorded Hubs, registered LPVaults, the flash source, live vault tokens and LPOracles
// (market not Cancelled), approved Spokes and registered proxies.
function isProtected(address a) returns bool {
    uint256 mv = marketOfVaultToken(a);
    uint256 mo = marketOfLpOracle(a);
    bool liveVaultToken = mv != 0 && getMarket(mv).status != MarketRegistry.MarketStatus.Cancelled;
    bool liveOracle = mo != 0 && getMarket(mo).status != MarketRegistry.MarketStatus.Cancelled;
    return a == TIMELOCK() || a == AAVE_GOVERNANCE_EXECUTOR() || a == AAVE_ADAPTER() || a == COLLATERALIZATION()
        || a == LP_VAULT_SWAP() || a == PROXY_MANAGER() || a == currentContract
        || a == PARAMETER_STORE() || a == RISK_MODULE() || a == PAYOUT_ESCROW()
        || a == LOCK() || a == VAULT_TOKEN_FACTORY() || a == FLASH_LIQUIDATOR() || a == flashSource()
        || hubTier(a) != MarketRegistry.RiskTier.None || integrationIdOf(a) != 0
        || liveVaultToken || liveOracle || getSpoke(a).approved || adapterWalletOf(a) != 0;
}

definition isUpgrade(method f) returns bool = f.selector == sig:upgradeToAndCall(address, bytes).selector;
// Parametric rules and invariants range over the router's own functions. The logic contracts in the scene are reached
// only by the router's delegatecall: each refuses a direct call (`_onlyDelegated`, its constructor-set `_SELF`), and
// the harness view is a view.
definition routerEntry(method f) returns bool = f.contract == currentContract;
// The router's `freezeAll` forwards 4 bytes of calldata, and the prover leaves that one delegatecall unresolved
// (an AUTO summary that may write any of the router's storage), so the state rules leave it out and
// `freezeAllFreezesOnlyFreeHubs` checks its body on the safety logic's own copy of the layout instead; its caller
// check is in the router and is proved by onlyRoleCanCall (MarketRegistryRoles.conf).
definition resolvedEntry(method f) returns bool = routerEntry(f) && f.selector != sig:freezeAll().selector;

// The freeze checks run in the safety logic contract, which compares the protected set against its own copy of the
// implementation immutables. The registry's constructor accepts a logic contract only when its immutables hash equals
// the registry's (REQ-CONFIG-005), so the two copies are equal on every deployment; the prover does not run that
// constructor, so the rules that read the protected set state the equality here.
function safetyLogicSharesImmutables() {
    env e;
    require safetyLogic.immutablesMatch(e, TIMELOCK(), AAVE_GOVERNANCE_EXECUTOR(), VAULT_TOKEN_FACTORY(), AAVE_ADAPTER(),
        COLLATERALIZATION(), LOCK(), PROXY_MANAGER(), PARAMETER_STORE(), RISK_MODULE(), LP_VAULT_SWAP(), PAYOUT_ESCROW(),
        FLASH_LIQUIDATOR());
}

// ---------------------------------------------------------------------------------------------------------------------
// Pause state and reason (PROP-041)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-041 verifies: INV-049, Q-227, Q-252
invariant reasonIsNoneExactlyWhenNotPaused(address hub)
    (pauseState(hub) == MarketRegistry.PauseState.Paused) == (pauseReason(hub) != MarketRegistry.PauseReason.None)
    filtered { f -> !isUpgrade(f) && resolvedEntry(f) }

definition isPauseSelector(method f) returns bool =
    f.selector == sig:freeze(address).selector || f.selector == sig:pause(address, MarketRegistry.PauseReason).selector
    || f.selector == sig:unfreeze(address).selector || f.selector == sig:unpause(address).selector;

// freezeAll and pauseAll apply freeze and pause to every recorded Hub at once (REQ-CONFIG-082, REQ-MREG-004).
definition isAllHubsSelector(method f) returns bool =
    f.selector == sig:freezeAll().selector || f.selector == sig:pauseAll(MarketRegistry.PauseReason).selector;

// Calls f, passing `h` (and `r`) explicitly to the pause functions so a rule can name the Hub and reason they act on.
function callWithHub(method f, env e, address h, MarketRegistry.PauseReason r) {
    if (f.selector == sig:pauseAll(MarketRegistry.PauseReason).selector) {
        pauseAll(e, r);
    } else if (f.selector == sig:freeze(address).selector) {
        freeze(e, h);
    } else if (f.selector == sig:pause(address, MarketRegistry.PauseReason).selector) {
        pause(e, h, r);
    } else if (f.selector == sig:unfreeze(address).selector) {
        unfreeze(e, h);
    } else if (f.selector == sig:unpause(address).selector) {
        unpause(e, h);
    } else {
        calldataarg args;
        f(e, args);
    }
}

// PROP-041 verifies: INV-049, Q-227, Q-228, Q-252
rule pauseTransitions(method f, address hub, address h, MarketRegistry.PauseReason r) filtered { f -> !f.isView && !isUpgrade(f) && resolvedEntry(f) } {
    env e;
    requireInvariant reasonIsNoneExactlyWhenNotPaused(hub);
    MarketRegistry.PauseState s0 = pauseState(hub);
    MarketRegistry.PauseReason r0 = pauseReason(hub);

    callWithHub(f, e, h, r);

    MarketRegistry.PauseState s1 = pauseState(hub);
    MarketRegistry.PauseReason r1 = pauseReason(hub);
    bool changed = s0 != s1 || r0 != r1;

    assert changed => ((isPauseSelector(f) && h == hub) || isAllHubsSelector(f)),
        "a Hub's pause state or reason changed outside freeze, pause, unfreeze and unpause of that Hub, freezeAll and pauseAll";
    assert (changed && f.selector == sig:freezeAll().selector) =>
        (s0 == MarketRegistry.PauseState.None && s1 == MarketRegistry.PauseState.Frozen && isFreezeGuardOrAdmin(e.msg.sender)),
        "freezeAll made a transition other than None to Frozen, or ran without the freeze guardian or admin";
    assert (changed && f.selector == sig:pauseAll(MarketRegistry.PauseReason).selector) =>
        (s1 == MarketRegistry.PauseState.Paused && r1 == r && r1 != MarketRegistry.PauseReason.None
            && isPauseGuardOrAdmin(e.msg.sender)),
        "pauseAll did not reach Paused with its reason, or ran without the pause guardian or admin";
    assert (changed && f.selector == sig:freeze(address).selector) =>
        (s0 == MarketRegistry.PauseState.None && s1 == MarketRegistry.PauseState.Frozen && isFreezeGuardOrAdmin(e.msg.sender)),
        "freeze made a transition other than None to Frozen, or ran without the freeze guardian or admin";
    assert (changed && f.selector == sig:pause(address, MarketRegistry.PauseReason).selector) =>
        (s1 == MarketRegistry.PauseState.Paused && r1 != MarketRegistry.PauseReason.None && r1 != r0 && isPauseGuardOrAdmin(e.msg.sender)),
        "pause did not reach Paused with a new, non-None reason, or ran without the pause guardian or admin";
    assert (changed && f.selector == sig:unfreeze(address).selector) =>
        (s0 == MarketRegistry.PauseState.Frozen && s1 == MarketRegistry.PauseState.None && isPauseGuardOrAdmin(e.msg.sender)),
        "unfreeze made a transition other than Frozen to None, or ran without the pause guardian or admin";
    assert (changed && f.selector == sig:unpause(address).selector) =>
        (s0 == MarketRegistry.PauseState.Paused && s1 == MarketRegistry.PauseState.None && r1 == MarketRegistry.PauseReason.None && isPauseGuardOrAdmin(e.msg.sender)),
        "unpause made a transition other than Paused to None with the reason cleared, or ran without the pause guardian or admin";
}

// PROP-041 verifies: INV-049, Q-227, Q-252
rule pauseRefusesNoneAndTheCurrentReason(address hub, MarketRegistry.PauseReason reason) {
    env e;
    requireInvariant reasonIsNoneExactlyWhenNotPaused(hub);
    MarketRegistry.PauseState s0 = pauseState(hub);
    MarketRegistry.PauseReason r0 = pauseReason(hub);

    pause@withrevert(e, hub, reason);

    assert reason == MarketRegistry.PauseReason.None => lastReverted, "pause(hub, None) succeeded";
    assert (s0 == MarketRegistry.PauseState.Paused && reason == r0) => lastReverted, "pause repeated the Hub's current reason";
}

// PROP-041 verifies: INV-049, Q-227
rule unfreezeRevertsWhilePaused(address hub) {
    env e;
    require pauseState(hub) == MarketRegistry.PauseState.Paused;
    unfreeze@withrevert(e, hub);
    assert lastReverted, "unfreeze succeeded while the Hub is Paused";
}

// A caller holding only the freeze role never moves a Hub's state toward None (audit sketch freezeGuardianCannotLift).
// PROP-041 verifies: INV-049, Q-227, Q-228
rule freezeGuardianCannotLift(method f, address hub) filtered { f -> !f.isView && !isUpgrade(f) && resolvedEntry(f) } {
    env e;
    calldataarg args;
    require !hasRole(PAUSE_GUARDIAN(), e.msg.sender) && !hasRole(APP_ADMIN(), e.msg.sender);
    MarketRegistry.PauseState s0 = pauseState(hub);

    // With @withrevert, a function that always reverts for this caller (every admin-only one) keeps a reachable path,
    // so the sanity check does not report it as vacuous; the state is unchanged on a revert.
    f@withrevert(e, args);

    MarketRegistry.PauseState s1 = pauseState(hub);
    assert s0 != MarketRegistry.PauseState.None => s1 == s0, "a caller without the pause guardian or admin role lifted or changed a Hub's freeze or pause";
    assert s0 == MarketRegistry.PauseState.None => (s1 == MarketRegistry.PauseState.None || s1 == MarketRegistry.PauseState.Frozen), "a freeze-only caller paused a Hub";
}

// PROP-041 verifies: INV-049, Q-252
rule pauseIsReachable(address hub, MarketRegistry.PauseReason reason) {
    env e;
    pause(e, hub, reason);
    satisfy pauseState(hub) == MarketRegistry.PauseState.Paused;
}

// freezeAll moves a Hub only from None to Frozen and touches no pause reason and no address freeze. Checked on the
// safety logic's own storage, which has the registry's ERC-7201 layout: the body is the code the router delegatecalls.
// The direct call stands in for the delegatecall (a deployed logic contract refuses direct calls through `_SELF`,
// which the prover leaves unconstrained).
// PROP-041 verifies: INV-049, Q-227, Q-252
rule freezeAllFreezesOnlyFreeHubs(address hub, address a) {
    env e;
    uint8 s0 = safetyLogic.pauseStateOf(e, hub);
    uint8 r0 = safetyLogic.pauseReasonOf(e, hub);
    bool frozen0 = safetyLogic.isFrozenAddressOf(e, a);

    safetyLogic.freezeAll(e);

    uint8 s1 = safetyLogic.pauseStateOf(e, hub);
    assert s1 == s0 || (s0 == 0 && s1 == 1), "freezeAll made a transition other than None to Frozen";
    assert safetyLogic.pauseReasonOf(e, hub) == r0, "freezeAll changed a pause reason";
    assert safetyLogic.isFrozenAddressOf(e, a) == frozen0, "freezeAll changed an address freeze";
}

// PROP-041 verifies: INV-049, Q-252
rule freezeAllCanFreezeAHub(address hub) {
    env e;
    require safetyLogic.pauseStateOf(e, hub) == 0;
    safetyLogic.freezeAll(e);
    satisfy safetyLogic.pauseStateOf(e, hub) == 1;
}

// ---------------------------------------------------------------------------------------------------------------------
// Address freeze (PROP-071)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-071 verifies: INV-085, Q-242
rule freezeAddressGates(address a) {
    env e;
    safetyLogicSharesImmutables();
    bool frozenBefore = isFrozenAddress(a);
    bool protectedBefore = isProtected(a);
    mathint used = freezesInWindow(e, e.msg.sender);

    freezeAddress(e, a);

    assert isFreezeGuardOrAdmin(e.msg.sender), "freezeAddress ran without the freeze guardian or admin";
    assert !frozenBefore, "freezeAddress froze an address that was already frozen";
    assert !protectedBefore, "freezeAddress froze a protected address";
    assert used < to_mathint(MAX_ADDRESS_FREEZES_PER_DAY()), "freezeAddress ran past the caller's daily limit";
    assert isFrozenAddress(a), "freezeAddress did not freeze the address";
    assert to_mathint(freezesInWindow(e, e.msg.sender)) == used + 1, "freezeAddress did not count the freeze";
}

// freezeAddress checks no keeper floor: a guardian can freeze the last active keeper (Q-400); with 0 active keepers
// new borrowing halts in the RiskModule.
// PROP-071 verifies: INV-085, Q-242, Q-400
rule freezeAddressCanFreezeTheLastKeeper(address a) {
    env e;
    require keeperApproved(a) && activeKeepers() == 1 && keeperFloor() == 1;
    freezeAddress(e, a);
    satisfy isFrozenAddress(a);
}

// PROP-071 verifies: INV-085, Q-242
rule onlyUnfreezeAddressLiftsAFreeze(method f, address a) filtered { f -> !f.isView && !isUpgrade(f) && resolvedEntry(f) } {
    env e;
    calldataarg args;
    require isFrozenAddress(a);

    f(e, args);

    assert !isFrozenAddress(a) => (
        f.selector == sig:unfreezeAddress(address).selector && hasRole(APP_ADMIN(), e.msg.sender)),
        "an address freeze was lifted other than by unfreezeAddress from APPLICATION_ADMIN";
}

// The daily limit is 20 (REQ-MREG-019).
// PROP-071 verifies: INV-085, Q-242
rule freezeLimitIsTwenty() {
    assert MAX_ADDRESS_FREEZES_PER_DAY() == 20, "MAX_ADDRESS_FREEZES_PER_DAY is not 20";
}

// No call freezes an address that is protected at call time: only `freezeAddress` sets the flag, and only for an
// address outside the protected set when it runs. An address frozen before it became protected (a predicted proxy address
// frozen before the proxy is deployed) stays frozen until `unfreezeAddress`, so the rule constrains
// the call, not the state.
// PROP-071 verifies: INV-085, Q-242
rule noCallFreezesAProtectedAddress(method f, address a) filtered { f -> !f.isView && !isUpgrade(f) && resolvedEntry(f) } {
    env e;
    safetyLogicSharesImmutables();
    calldataarg args;
    require !isFrozenAddress(a);
    bool protectedBefore = isProtected(a);

    f(e, args);

    assert isFrozenAddress(a) => (f.selector == sig:freezeAddress(address).selector && !protectedBefore),
        "a call froze an address that was protected at call time";
}

// PROP-071 verifies: INV-085, Q-242
rule freezeAddressIsReachable(address a) {
    env e;
    freezeAddress(e, a);
    satisfy isFrozenAddress(a);
}

// ---------------------------------------------------------------------------------------------------------------------
// Debt-reserve set (PROP-061)
// ---------------------------------------------------------------------------------------------------------------------

// Activation runs the RiskModule's drift check over the market's Spoke, which refuses a Spoke whose Aave configuration
// differs from the registry (RiskModule.spec).
// PROP-061 verifies: INV-073, Q-281
rule activateMarketRunsTheDriftCheck(uint256 marketId) {
    env e;
    aaveConfigChecked = false;
    address spoke = getMarket(marketId).spoke;

    activateMarket(e, marketId);

    assert aaveConfigChecked && aaveConfigCheckedSpoke == spoke, "activateMarket did not run checkAaveConfig on the market's Spoke";
    assert getMarket(marketId).status == MarketRegistry.MarketStatus.Active, "activateMarket did not set the market Active";
}

// PROP-061 verifies: INV-073, Q-281
rule removeDebtReserveOnlyWhenNothingOwed(address spoke, uint256 reserveId) {
    env e;
    MarketRegistry.DebtReserveDef d = getDebtReserve(spoke, reserveId);

    removeDebtReserve(e, spoke, reserveId);

    assert hubSpokeOwed(d.fundingHub, d.hubAssetId, spoke) == 0, "a debt reserve with debt owed was removed";
    assert hubSpokeDeficit(d.fundingHub, d.hubAssetId, spoke) == 0, "a debt reserve with a deficit was removed";
    assert !isApprovedDebtReserve(spoke, reserveId), "removeDebtReserve left the reserve approved";
    assert hasRole(APP_ADMIN(), e.msg.sender), "removeDebtReserve ran without APPLICATION_ADMIN";
}

// ---------------------------------------------------------------------------------------------------------------------
// Role map (PROP-034) and admin invariant (PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

definition freezeGuardianSelector(method f) returns bool =
    f.selector == sig:freeze(address).selector || f.selector == sig:freezeAll().selector
    || f.selector == sig:freezeAddress(address).selector
    || f.selector == sig:tripMarketBreaker(uint256).selector || f.selector == sig:tripDebtBreaker(address, uint256).selector;

definition pauseGuardianSelector(method f) returns bool =
    f.selector == sig:pause(address, MarketRegistry.PauseReason).selector
    || f.selector == sig:pauseAll(MarketRegistry.PauseReason).selector || f.selector == sig:unfreeze(address).selector
    || f.selector == sig:unpause(address).selector || f.selector == sig:resetMarketBreaker(uint256).selector
    || f.selector == sig:resetDebtBreaker(address, uint256).selector
    || f.selector == sig:useStandbyRoute(address, MarketRegistry.RouteSlot).selector;

// Callable by anyone (REQ-CONFIG-080: the wind-down step and close after the notice period; REQ-CONFIG-081: re-reading
// a Spoke's draw cap). Their own preconditions are checked by the logic, not by a role.
definition permissionlessSelector(method f) returns bool =
    f.selector == sig:stepWindDown(uint256).selector || f.selector == sig:closeMarket(uint256).selector
    || f.selector == sig:syncDrawCap(address, uint256).selector;

definition riskModuleSelector(method f) returns bool =
    f.selector == sig:recordBreach(bytes32, uint32).selector;

definition roleSelector(method f) returns bool =
    f.selector == sig:grantRole(bytes32, address).selector || f.selector == sig:revokeRole(bytes32, address).selector
    || f.selector == sig:renounceRole(bytes32, address).selector;

// PROP-034 verifies: INV-051, Q-226, Q-228
rule onlyRoleCanCall(method f) filtered {
    f -> !f.isView && f.selector != sig:initialize(address).selector && !roleSelector(f) && routerEntry(f)
} {
    env e;
    calldataarg args;
    bool freezeRole = isFreezeGuardOrAdmin(e.msg.sender);
    bool pauseRole = isPauseGuardOrAdmin(e.msg.sender);
    bool admin = hasRole(APP_ADMIN(), e.msg.sender);

    f(e, args);

    assert freezeGuardianSelector(f) => freezeRole, "a freeze-guardian selector ran without its role";
    assert pauseGuardianSelector(f) => pauseRole, "a pause-guardian selector ran without its role";
    assert riskModuleSelector(f) => e.msg.sender == RISK_MODULE(), "a RiskModule-only selector ran for another caller";
    assert f.selector == sig:cancelStandbySwitch(address).selector => e.msg.sender == AAVE_GOVERNANCE_EXECUTOR(),
        "cancelStandbySwitch ran for a caller other than the Aave governance executor";
    assert (!freezeGuardianSelector(f) && !pauseGuardianSelector(f) && !riskModuleSelector(f)
            && !permissionlessSelector(f) && f.selector != sig:cancelStandbySwitch(address).selector) => admin,
        "a setter, listing, route, keeper, breaker or upgrade selector ran without APPLICATION_ADMIN";
}

// APPLICATION_ADMIN is administered by DEFAULT_ADMIN_ROLE in every reachable state: it is the AccessControl default,
// initialize sets only the two guardian roles' admin, and no other function sets a role admin.
// PROP-034 verifies: INV-051, Q-226, Q-228
invariant appAdminAdministeredByDefaultAdmin()
    getRoleAdmin(APP_ADMIN()) == DEFAULT_ADMIN()
    filtered { f -> !isUpgrade(f) && resolvedEntry(f) }

// PROP-034 verifies: INV-051, Q-226, Q-228
rule roleChangesNeedTheRoleAdmin(bytes32 role, address account) {
    env e;
    requireInvariant appAdminAdministeredByDefaultAdmin();
    bytes32 adminRole = getRoleAdmin(role);
    grantRole(e, role, account);
    assert hasRole(adminRole, e.msg.sender), "grantRole ran without the role's admin";
    assert role == APP_ADMIN() => adminRole == DEFAULT_ADMIN(), "APPLICATION_ADMIN is administered by a role other than DEFAULT_ADMIN_ROLE";
}

definition roleAdminsAsPublished() returns bool =
    getRoleAdmin(PAUSE_GUARDIAN()) == APP_ADMIN() && getRoleAdmin(FREEZE_GUARDIAN()) == APP_ADMIN()
        && getRoleAdmin(APP_ADMIN()) == DEFAULT_ADMIN();

// PROP-034 verifies: INV-051, Q-226, Q-228
// initialize writes no pause state, so on the fresh proxy storage it runs on (the only state in which the initializer
// guard lets it run) every Hub stays at None.
rule initializeSetsTheRoleMap(address timelock, address hub) {
    env e;
    requireInvariant appAdminAdministeredByDefaultAdmin();
    MarketRegistry.PauseState before = pauseState(hub);
    initialize(e, timelock);
    assert roleAdminsAsPublished(), "initialize left a guardian role or APPLICATION_ADMIN with another admin";
    assert timelock == TIMELOCK() && hasRole(APP_ADMIN(), timelock) && hasRole(DEFAULT_ADMIN(), timelock),
        "initialize did not grant both admin roles to the TIMELOCK immutable";
    assert pauseState(hub) == before, "initialize wrote a Hub's pause state";
}

// PROP-034 verifies: INV-051, Q-226, Q-228
rule roleAdminsNeverChange(method f) filtered { f -> !f.isView && !isUpgrade(f) && resolvedEntry(f) } {
    env e;
    calldataarg args;
    require roleAdminsAsPublished();
    f(e, args);
    assert roleAdminsAsPublished(), "a call changed the admin of a guardian role or of APPLICATION_ADMIN";
}

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !isUpgrade(f) && resolvedEntry(f) }
