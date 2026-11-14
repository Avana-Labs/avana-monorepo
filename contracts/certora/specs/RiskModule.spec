/*
 * RiskModule (src/policy/risk-module/RiskModule.sol, interface src/policy/risk-module/IRiskModule.sol,
 * spec 2.7).
 *
 * The borrow-side gates over the account scope the Spoke reports (PROP-031 RiskModule half, PROP-046, PROP-050), the
 * rescue-excluded post-health check (PROP-067), the minimum pledge (PROP-062), the debt-reserve set of the drift check
 * (PROP-061: the registry's set equals the Spoke's borrowable reserves), the absence of any pause-state or freeze
 * read (PROP-066 RiskModule half), the role map (PROP-034) and the admin invariant (PROP-070); the cap booking of PROP-030 and the hfEx arithmetic of PROP-067 (primary tool per
 * 5.2: Halmos) and the arithmetic bounds of PROP-044 (primary tool: SMTChecker) are restated over unbounded integers.
 * These hold for the verified RiskModule implementation, whose check bodies run in five stateless logic contracts linked
 * in certora/conf/RiskModule.conf (the summaries below apply to the calls those contracts make).
 *
 * Storage: ERC-7201 namespace `avana.storage.RiskModule` (2.7); the RiskModule holds no account state, so no hooks.
 *
 * Account scope: each account is one PositionProxy bound to one (Spoke, market); the checks read the Spoke and the
 * market from the proxy's `SPOKE()` and `MARKET_ID()` immutables, modelled as uninterpreted functions of the proxy.
 * The Hub of the shares == assets check is the market's home Hub from its market record.
 *
 * Summaries:
 *  - The CDP Spoke by AaveModel: reserve count, per-account collateral and borrowing status, reserve paused and
 *    frozen flags, supplied shares; the reserve `borrowable` flag is an uninterpreted function of (Spoke, reserve) of
 *    this spec; `getUserAccountData` returns ghost health factor, debt value and borrow count of this spec; other
 *    Spoke reads (reserve struct, dynamic configuration, liquidation configuration, extSload) are NONDET.
 *  - The MarketRegistry by RegistryModel (breakers, approved debt-reserve set, and the counted pause and freeze reads
 *    that PROP-066 asserts never happen, for any Hub) and by uninterpreted market records (`getMarket`,
 *    `marketOfReserve`, `getSpoke`, `getDebtReserve`, `getDebtReserveIds`); `getRoute` is NONDET (it can only add the
 *    `LiquidationHalted` refusal).
 *  - LPOracles by PriceStateModel (`poke`, `getPriceState`, `latestAnswer`, `lastAcceptedPrice`).
 *  - The ParameterStore's `hardHealthFloor(marketId)` and `minPledgeUsd` are uninterpreted; its other reads are NONDET.
 *  - Collateralization's `getAccountRescueUnits` is uninterpreted; LPVaultSwap's `activeKeeperCount` is
 *    uninterpreted; the Hub's added assets and shares by AaveModel; the AMM integration's `validatePosition` and
 *    `riskMetadata` and token reads are NONDET.
 * The LPOracle's and the DebtOracle's `getPriceState()` share one selector with different return types, so one
 * wildcard summary serves only the LPOracle report; the rules that read prices therefore take a debt scope of
 * fixed-price reserves, whose price is Aave's fixed source with no DebtOracle read (`fixedPrice`). The DebtOracle half of the
 * account price check (`DebtPriceTooOld`, `UnexpectedDebtPriceSource`) is covered by TEST-201 and TEST-028.
 * OpenZeppelin AccessControl and UUPSUpgradeable v5.1.0 are the real code; `upgradeToAndCall` is named only by
 * selector.
 */

import "setup/Erc20Model.spec";
import "setup/AaveModel.spec";
import "setup/PriceStateModel.spec";
import "setup/RegistryModel.spec";

using RiskModuleStatusLogic as statusLogic;

methods {
    function preBorrowCheck(address, uint256, uint256) external;
    function preWithdrawCheck(address) external;
    function postHealthCheck(address, uint256) external returns (uint256);
    function checkPledge(address, address, uint256, uint32, bytes32, uint128, PledgeCounters, bool) external returns (PledgeCharge);
    function checkRemainingRecord(uint256, uint128) external;
    function checkAaveConfig(address, uint256[]) external;
    function rescueHealthFactor() external returns (uint256) envfree;
    function RESCUE_MIN_PLEDGE_USD() external returns (uint256) envfree;
    function TIMELOCK() external returns (address) envfree;
    function initialize(address) external;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function grantRole(bytes32, address) external;
    function revokeRole(bytes32, address) external;
    function renounceRole(bytes32, address) external;

    // PositionProxy immutables
    function _.SPOKE() external => proxySpokeOf(calledContract) expect address;
    function _.MARKET_ID() external => proxyMarketOf(calledContract) expect uint256;

    // CDP Spoke
    function _.getReserveCount() external => spokeReserveCount(calledContract) expect uint256;
    function _.getUserReserveStatus(uint256 rid, address u) external => spokeGetUserReserveStatus(calledContract, rid, u) expect (bool, bool);
    function _.getReserveConfig(uint256 rid) external => reserveConfigOf(calledContract, rid) expect IAaveV4Spoke.ReserveConfig;
    function _.getUserSuppliedShares(uint256 rid, address u) external => spokeGetUserSuppliedShares(calledContract, rid, u) expect uint256;
    function _.getUserTotalDebt(uint256 rid, address u) external => spokeGetUserTotalDebt(calledContract, rid, u) expect uint256;
    function _.getUserAccountData(address u) external => accountData(calledContract, u) expect IAaveV4Spoke.UserAccountData;
    function _.ORACLE() external => spokeOracleOf(calledContract) expect address;
    function _.getReserveSource(uint256 rid) external => aaveOracleSourceOf(calledContract, rid) expect address;
    function _.getReserve(uint256) external => NONDET;
    function _.getDynamicReserveConfig(uint256, uint32) external => NONDET;
    function _.getLiquidationConfig() external => NONDET;
    function _.getUserPosition(uint256, address) external => NONDET;
    function _.extSload(bytes32) external => NONDET;
    function _.MAX_USER_RESERVES_LIMIT() external => NONDET;

    // Hub
    function _.getAddedAssets(uint256 a) external => hubGetAddedAssets(calledContract, a) expect uint256;
    function _.getAddedShares(uint256 a) external => hubGetAddedShares(calledContract, a) expect uint256;
    function _.getSpokeConfig(uint256, address) external => NONDET;
    function _.getAssetConfig(uint256) external => NONDET;

    // MarketRegistry
    function _.getSpoke(address s) external => spokeDefOf(s) expect SpokeDef;
    function _.marketOfReserve(address s, uint256 rid) external => mOfReserve(s, rid) expect uint256;
    function _.getMarket(uint256 m) external => marketOf(m) expect Market;
    function _.getDebtReserveIds(address s) external => debtIdsOf(s) expect uint256[];
    function _.getDebtReserve(address s, uint256 r) external => debtDefOf(s, r) expect DebtReserveDef;
    function _.isApprovedDebtReserve(address s, uint256 r) external => registryApprovedDebtReserve(s, r) expect bool;
    function _.marketBreaker(uint256 m) external => registryMarketBreaker(m) expect (uint32, uint64);
    function _.debtBreaker(address s, uint256 r) external => registryDebtBreaker(s, r) expect (uint32, uint64);
    function _.pauseState(address h) external => registryPauseState() expect PauseState;
    function _.pauseReason(address h) external => registryPauseReason() expect PauseReason;
    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
    function _.getRoute(uint256, address, address, uint8) external => NONDET;
    function _.getToken(address) external => NONDET;

    // LPOracles
    function _.poke() external => oraclePoke(calledContract) expect PriceState;
    function _.getPriceState() external => priceStateViewOf(calledContract) expect PriceStateView;
    function _.latestAnswer() external => oracleLatestAnswer(calledContract) expect int256;
    function _.lastAcceptedPrice() external => oracleLastAccepted(calledContract) expect (uint256, uint64);

    // ParameterStore, Collateralization, LPVaultSwap
    function _.hardHealthFloor(uint256 m) external => psHardHealthFloor(m) expect uint256;
    function _.minPledgeUsd(uint256 m) external => psMinPledgeUsd(m) expect uint256;
    function _.getMarketParams(uint256) external => NONDET;
    function _.getAccountRescueUnits(address p, address vt) external => rescueUnitsOf(p, vt) expect uint256;
    function _.activeKeeperCount() external => keeperCount() expect uint256;

    // AMM integration and tokens
    function _.validatePosition(uint256, address, bytes32) external => NONDET;
    function _.riskMetadata(uint256, bytes32) external => NONDET;
    function _.riskStatus(uint256, uint32) external => NONDET;
    function _.positionOwner(bytes32) external => NONDET;
    function _.decimals() external => NONDET;

    // Reads added by the implementation's logic contracts; views of other contracts, so a nondeterministic value is
    // sound: every rule asserts only what the RiskModule enforces whatever these return.
    function _.poolUnits(bytes32) external => NONDET;
    function _.getCounters(address, address) external => NONDET;
    function _.getOpenRecordCount(address, address) external => NONDET;
    function _.proxyOf(address, uint256) external => NONDET;
    function _.predictProxy(address, uint256) external => NONDET;
    function _.sequencer() external => NONDET;
    function _.gateRecoverySeconds() external => NONDET;
    function _.poolShareMaxBpsOf(bytes32) external => NONDET;
    function _.breakerDeficitMax(address, address) external => NONDET;
    function _.getSpokeDeficitRay(uint256, address) external => NONDET;
    function _.marketsOfSpoke(address) external => NONDET;
    function _.crossHubLinesEnabled() external => NONDET;
    function _.creditLine(address, address) external => NONDET;
    function _.creditLineCoverage(address, address) external => NONDET;
    function _.spokeImplementationStatus(address) external => NONDET;

    // The status view's two logic calls, as the RiskModule makes them (PROP-066 second rule). A summary applies to the
    // RiskModule's call only; `statusBodyReadsNoPauseAndChangesNoState` calls the real body directly.
    function statusLogic.getAccountGateStatus(address p) external returns (AccountGateStatus) => recordStatus(p);
    function statusLogic.pauseOf(address p) external returns (PauseState, PauseReason) => recordPause(p);
}

// ---------------------------------------------------------------------------------------------------------------------
// Models specific to this spec
// ---------------------------------------------------------------------------------------------------------------------

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);
// keccak256("APPLICATION_ADMIN")
definition APP_ADMIN() returns bytes32 = to_bytes32(0x4a5d77d29c55ea7cb6361740de568b58568c9b25abdfdb58dc883366746cb704);
definition MAX_RESERVES() returns uint256 = 4;
definition WAD() returns mathint = 10^18;
definition RAY() returns mathint = 10^27;
definition isUpgrade(method f) returns bool = f.selector == sig:upgradeToAndCall(address, bytes).selector;

ghost accountHf(address, address) returns uint256;
ghost accountDebtRay(address, address) returns uint256;
ghost accountBorrowCount(address, address) returns uint256;
ghost spokeBorrowable(address, uint256) returns bool;
ghost proxySpokeOf(address) returns address;
ghost proxyMarketOf(address) returns uint256;
ghost mHub(uint256) returns address;
ghost spokeApproved(address) returns bool;
ghost mOfReserve(address, uint256) returns uint256;
ghost mLpOracle(uint256) returns address;
ghost mStatus(uint256) returns RiskModule.MarketStatus;
ghost mSpoke(uint256) returns address;
ghost mReserve(uint256) returns uint256;
ghost mHubAsset(uint256) returns uint256;
ghost mVaultToken(uint256) returns address;
ghost mDecimals(uint256) returns uint8;
ghost debtFixedPrice(address, uint256) returns bool;
ghost debtPriceSource(address, uint256) returns address;
ghost psHardHealthFloor(uint256) returns uint256;
ghost psMinPledgeUsd(uint256) returns uint256;
ghost rescueUnitsOf(address, address) returns uint256;
ghost keeperCount() returns uint256;

function accountData(address spoke, address user) returns IAaveV4Spoke.UserAccountData {
    IAaveV4Spoke.UserAccountData d;
    require d.healthFactor == accountHf(spoke, user);
    require d.totalDebtValueRay == accountDebtRay(spoke, user);
    require d.borrowCount == accountBorrowCount(spoke, user);
    return d;
}

// AaveModel's reserve configuration with the `borrowable` flag of this spec.
function reserveConfigOf(address spoke, uint256 rid) returns IAaveV4Spoke.ReserveConfig {
    IAaveV4Spoke.ReserveConfig c;
    require c.paused == spokePaused[spoke][rid];
    require c.frozen == spokeFrozen[spoke][rid];
    require c.borrowable == spokeBorrowable(spoke, rid);
    return c;
}

function spokeDefOf(address s) returns RiskModule.SpokeDef {
    RiskModule.SpokeDef d;
    require d.approved == spokeApproved(s);
    return d;
}

function marketOf(uint256 m) returns RiskModule.Market {
    RiskModule.Market k;
    require k.lpOracle == mLpOracle(m);
    require k.status == mStatus(m);
    require k.spoke == mSpoke(m);
    require k.hub == mHub(m);
    require k.reserveId == mReserve(m);
    require k.hubAssetId == mHubAsset(m);
    require k.vaultToken == mVaultToken(m);
    require k.decimals == mDecimals(m);
    return k;
}

function debtDefOf(address s, uint256 r) returns RiskModule.DebtReserveDef {
    RiskModule.DebtReserveDef d;
    require d.reserveId == r;
    require d.approved == regApprovedDebtReserve(s, r);
    require d.fixedPrice == debtFixedPrice(s, r);
    require d.priceSource == debtPriceSource(s, r);
    return d;
}

// The registry's approved debt-reserve list: at most MAX_RESERVES entries, exactly the approved set.
function debtIdsOf(address s) returns uint256[] {
    uint256[] ids;
    require ids.length <= MAX_RESERVES();
    require forall uint256 r. regApprovedDebtReserve(s, r) <=> (
        (ids.length > 0 && ids[0] == r) || (ids.length > 1 && ids[1] == r)
        || (ids.length > 2 && ids[2] == r) || (ids.length > 3 && ids[3] == r));
    return ids;
}

// The proxy's bound market, listed on its bound Spoke, with its reserve enabled as the account's collateral and mapped
// consistently back to the market.
function collateralInScope(address proxy) returns uint256 {
    address spoke = proxySpokeOf(proxy);
    uint256 m = proxyMarketOf(proxy);
    uint256 rid = mReserve(m);
    require spokeReserveCount(spoke) <= MAX_RESERVES();
    require rid < spokeReserveCount(spoke);
    require mSpoke(m) == spoke && mOfReserve(spoke, rid) == m;
    require spokeCollateralEnabled[spoke][rid][proxy];
    return m;
}

function maxOf(mathint a, mathint b) returns mathint {
    return a > b ? a : b;
}

// ---------------------------------------------------------------------------------------------------------------------
// Borrow-side gates (PROP-031 RiskModule half, PROP-046, PROP-050, PROP-066)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-031 verifies: INV-019, INV-023, INV-025, Q-106, Q-128, Q-161, Q-229
rule preBorrowCheckCollateralGates(address proxy, uint256 debtReserveId, uint256 amount) {
    env e;
    address spoke = proxySpokeOf(proxy);
    uint256 m = collateralInScope(proxy);
    address o = mLpOracle(m);
    require forall uint256 r. debtFixedPrice(spoke, r);
    mathint pokesBefore = pokeCount[o];

    preBorrowCheck(e, proxy, debtReserveId, amount);

    assert spokeApproved(spoke), "preBorrowCheck passed for an unapproved Spoke";
    assert mStatus(m) == RiskModule.MarketStatus.Active, "preBorrowCheck passed with a collateral market not Active";
    assert pokeCount[o] > pokesBefore, "preBorrowCheck did not poke the collateral market's LPOracle";
    assert pvIsLive(o), "preBorrowCheck passed with a collateral market that is not Live";
    assert to_mathint(pvServedUpdatedAt[o]) <= to_mathint(e.block.timestamp)
        && to_mathint(e.block.timestamp) <= to_mathint(pvServedUpdatedAt[o]) + to_mathint(pvBorrowMaxAge[o]),
        "preBorrowCheck passed with a collateral price older than borrowPriceMaxAge";
    assert hubAddedAssets[mHub(m)][mHubAsset(m)] == hubAddedShares[mHub(m)][mHubAsset(m)],
        "preBorrowCheck passed while the home Hub's shares differ from assets";
    assert regMarketBreakerReasons[m] == 0, "preBorrowCheck passed with a collateral market breaker latched";
    assert keeperCount() > 0, "preBorrowCheck passed while liquidation is halted (no active keeper)";
}

// PROP-031 verifies: INV-019, INV-023, Q-106, Q-229
rule preBorrowCheckDebtGates(address proxy, uint256 debtReserveId, uint256 amount, uint256 r) {
    env e;
    address spoke = proxySpokeOf(proxy);
    require spokeReserveCount(spoke) <= MAX_RESERVES();
    require r < spokeReserveCount(spoke);
    require spokeDebt[spoke][r][proxy] > 0 || r == debtReserveId;
    require forall uint256 x. debtFixedPrice(spoke, x);

    preBorrowCheck(e, proxy, debtReserveId, amount);

    assert regApprovedDebtReserve(spoke, r), "preBorrowCheck passed with a debt reserve outside the approved set";
    assert regDebtBreakerReasons[spoke][debtReserveId] == 0, "preBorrowCheck passed with the borrowed reserve's debt breaker latched";
}

// A collateral-enabled reserve the account has supplied shares in (REQ-ADAPTER-019); an enabled reserve with zero shares
// carries no collateral and does not block borrowing.
// PROP-046 verifies: INV-023, REQ-ADAPTER-019, Q-203, Q-229
rule borrowRefusesFrozenCollateral(address proxy, uint256 debtReserveId, uint256 amount) {
    env e;
    address spoke = proxySpokeOf(proxy);
    uint256 m = collateralInScope(proxy);
    uint256 rid = mReserve(m);
    require spokeSupplied[spoke][rid][proxy] > 0;
    require forall uint256 r. debtFixedPrice(spoke, r);

    preBorrowCheck(e, proxy, debtReserveId, amount);

    assert !spokeFrozen[spoke][rid], "preBorrowCheck passed with a collateral reserve frozen on Aave";
}

// PROP-050 verifies: INV-060, Q-202, Q-209, Q-229
rule preBorrowCheckRefusesPausedReserves(address proxy, uint256 debtReserveId, uint256 amount, uint256 rid) {
    env e;
    address spoke = proxySpokeOf(proxy);
    require spokeReserveCount(spoke) <= MAX_RESERVES();
    require rid < spokeReserveCount(spoke);
    // rid is a vault-token reserve of the account, one of its debt reserves, or the reserve being borrowed.
    require spokeCollateralEnabled[spoke][rid][proxy] || spokeDebt[spoke][rid][proxy] > 0 || rid == debtReserveId;
    require spokeCollateralEnabled[spoke][rid][proxy] => (mSpoke(proxyMarketOf(proxy)) == spoke && mReserve(proxyMarketOf(proxy)) == rid);
    require forall uint256 r. debtFixedPrice(spoke, r);

    preBorrowCheck(e, proxy, debtReserveId, amount);

    assert !spokePaused[spoke][rid], "preBorrowCheck passed with a paused vault-token or debt reserve";
}

// PROP-050 verifies: INV-060, Q-202, Q-209, Q-229
rule preWithdrawCheckRefusesPausedReserves(address proxy, uint256 rid) {
    env e;
    address spoke = proxySpokeOf(proxy);
    uint256 m = proxyMarketOf(proxy);
    uint256 withdrawRid = mReserve(m);
    require mSpoke(m) == spoke && mOfReserve(spoke, withdrawRid) == m;
    require spokeReserveCount(spoke) <= MAX_RESERVES();
    require rid < spokeReserveCount(spoke);
    require spokeCollateralEnabled[spoke][rid][proxy] || spokeDebt[spoke][rid][proxy] > 0 || rid == withdrawRid;
    require spokeCollateralEnabled[spoke][rid][proxy] => rid == withdrawRid;
    require forall uint256 r. debtFixedPrice(spoke, r);

    preWithdrawCheck(e, proxy);

    assert !spokePaused[spoke][rid], "preWithdrawCheck passed with a paused vault-token or debt reserve";
}

// A withdrawal that leaves debt has the same freshness gates as a borrow, without the frozen-reserve refusal.
// PROP-031 verifies: INV-019, INV-025, Q-128, Q-229
rule preWithdrawCheckFreshnessGates(address proxy) {
    env e;
    address spoke = proxySpokeOf(proxy);
    uint256 m = collateralInScope(proxy);
    address o = mLpOracle(m);
    require forall uint256 r. debtFixedPrice(spoke, r);

    preWithdrawCheck(e, proxy);

    assert pvIsLive(o), "preWithdrawCheck passed with a collateral market that is not Live";
    assert to_mathint(e.block.timestamp) <= to_mathint(pvServedUpdatedAt[o]) + to_mathint(pvBorrowMaxAge[o]),
        "preWithdrawCheck passed with a collateral price older than borrowPriceMaxAge";
    assert hubAddedAssets[mHub(m)][mHubAsset(m)] == hubAddedShares[mHub(m)][mHubAsset(m)],
        "preWithdrawCheck passed while the home Hub's shares differ from assets";
    assert regMarketBreakerReasons[m] == 0, "preWithdrawCheck passed with a collateral market breaker latched";
}

// The withdraw-with-debt gate does not apply the frozen-reserve or Offboarding refusals (REQ-RISK-062 order).
// PROP-031 verifies: INV-025, Q-229
rule preWithdrawCheckAllowsFrozenCollateral(address proxy) {
    env e;
    address spoke = proxySpokeOf(proxy);
    uint256 m = proxyMarketOf(proxy);
    require mSpoke(m) == spoke;
    require spokeFrozen[spoke][mReserve(m)];
    preWithdrawCheck(e, proxy);
    satisfy true;
}

// PROP-031 verifies: INV-019, Q-106
rule preBorrowCheckIsReachable(address proxy, uint256 debtReserveId, uint256 amount) {
    env e;
    require spokeReserveCount(proxySpokeOf(proxy)) <= MAX_RESERVES();
    preBorrowCheck(e, proxy, debtReserveId, amount);
    satisfy true;
}

// No RiskModule check reads any Hub's pause state, its reason or the address freeze (they are read by the Adapter,
// ProxyManager and LPVaultSwap only, for the calling wallet). The non-reverting status view `getAccountGateStatus`
// reports the pause state of the market's Hub (REQ-ADAPTER-038) and gates nothing, so it is the one function outside
// this rule; the two rules after it prove that its pause read reaches only its two pause fields.
// PROP-066 verifies: INV-030, INV-043, INV-045, INV-081, Q-241, Q-242
rule riskModuleNeverReadsPauseOrFreeze(method f) filtered {
    f -> !isUpgrade(f) && f.selector != sig:getAccountGateStatus(address).selector
} {
    env e;
    calldataarg args;
    resetRegistryReads();

    f(e, args);

    assert regPauseStateReads == 0 && regPauseReasonReads == 0, "a RiskModule function read the pause state or reason";
    assert regFreezeReads == 0, "a RiskModule function read the address freeze";
}

// The status view (PROP-066 second rule). The body that computes every gate outcome, `borrowAllowed` and
// `withdrawWithDebtAllowed` included, reads no pause state, no pause reason and no address freeze, pokes nothing and
// writes nothing, on every path including the reverting ones; a field it returns therefore cannot depend on the pause.
// PROP-066 verifies: INV-030, INV-045, INV-081, Q-241, Q-242
rule statusBodyReadsNoPauseAndChangesNoState(address proxy) {
    env e;
    resetRegistryReads();
    mathint pokesBefore = totalPokes;
    storage before = lastStorage;

    statusLogic.getAccountGateStatus@withrevert(e, proxy);

    assert regPauseStateReads == 0 && regPauseReasonReads == 0, "the status body read the pause state or reason";
    assert regFreezeReads == 0, "the status body read the address freeze";
    assert regBreakerWrites == 0, "the status body wrote breaker state";
    assert totalPokes == pokesBefore, "the status body poked an oracle";
    assert lastStorage[currentContract] == before[currentContract], "the status body changed RiskModule state";
    assert lastStorage[statusLogic] == before[statusLogic], "the status body changed its own state";
}

// What the RiskModule's two logic calls returned in the current rule.
persistent ghost bool recSpokeApproved;
persistent ghost uint256 recUnknownCollateral;
persistent ghost uint256 recUnapprovedDebt;
persistent ghost uint256 recPausedDebt;
persistent ghost uint256 recStaleDebt;
persistent ghost uint256 recHaltedDebt;
persistent ghost uint256 recBreakerDebt;
persistent ghost uint32 recDebtBreakerReasons;
persistent ghost uint256 recDriftMarket;
persistent ghost RiskModule.DriftReason recDriftReason;
persistent ghost bool recNoKeeper;
persistent ghost uint256 recHf;
persistent ghost uint256 recHfEx;
persistent ghost uint256 recFloor;
persistent ghost bool recBorrowAllowed;
persistent ghost bool recWithdrawAllowed;
persistent ghost bool recUnavailable;
persistent ghost RiskModule.PauseState recPauseState;
persistent ghost RiskModule.PauseReason recPauseReason;
persistent ghost mathint recStatusCalls { init_state axiom recStatusCalls == 0; }
persistent ghost mathint recPauseCalls { init_state axiom recPauseCalls == 0; }

// An arbitrary status body result, pause fields included, recorded field by field.
function recordStatus(address p) returns RiskModule.AccountGateStatus {
    RiskModule.AccountGateStatus s;
    recStatusCalls = recStatusCalls + 1;
    recSpokeApproved = s.spokeApproved;
    recUnknownCollateral = s.unknownCollateralReserveId;
    recUnapprovedDebt = s.unapprovedDebtReserveId;
    recPausedDebt = s.pausedDebtReserveId;
    recStaleDebt = s.staleDebtReserveId;
    recHaltedDebt = s.haltedDebtReserveId;
    recBreakerDebt = s.breakerDebtReserveId;
    recDebtBreakerReasons = s.debtBreakerReasons;
    recDriftMarket = s.driftMarketId;
    recDriftReason = s.driftReason;
    recNoKeeper = s.noApprovedKeeper;
    recHf = s.healthFactor;
    recHfEx = s.healthFactorExcludingRescue;
    recFloor = s.hardHealthFloor;
    recBorrowAllowed = s.borrowAllowed;
    recWithdrawAllowed = s.withdrawWithDebtAllowed;
    recUnavailable = s.statusUnavailable;
    return s;
}

// An arbitrary pause state and reason of the account's Hub, recorded.
function recordPause(address p) returns (RiskModule.PauseState, RiskModule.PauseReason) {
    RiskModule.PauseState st;
    RiskModule.PauseReason r;
    recPauseCalls = recPauseCalls + 1;
    recPauseState = st;
    recPauseReason = r;
    return (st, r);
}

// The RiskModule copies every gate outcome of the body unchanged and the pause read into `pauseState` and
// `pauseReason` only: for every body result and every pause value, `borrowAllowed`, `withdrawWithDebtAllowed` and every
// other gate field equal the body's, whatever the pause; the pause fields equal the pause read, whatever the body
// reported in them. The view changes no RiskModule state. With `statusBodyReadsNoPauseAndChangesNoState` this proves
// that the pause read reaches only the two pause fields.
// PROP-066 verifies: INV-030, INV-045, INV-081, Q-241, Q-242
rule statusPauseReachesOnlyPauseFields(address proxy) {
    env e;
    require recStatusCalls == 0 && recPauseCalls == 0;
    storage before = lastStorage;

    RiskModule.AccountGateStatus st = getAccountGateStatus(e, proxy);

    assert recStatusCalls == 1 && recPauseCalls == 1, "the view did not read the body and the pause once each";
    assert st.borrowAllowed == recBorrowAllowed, "borrowAllowed differs from the body's gate result";
    assert st.withdrawWithDebtAllowed == recWithdrawAllowed, "withdrawWithDebtAllowed differs from the body's";
    assert st.spokeApproved == recSpokeApproved && st.statusUnavailable == recUnavailable;
    assert st.unknownCollateralReserveId == recUnknownCollateral && st.unapprovedDebtReserveId == recUnapprovedDebt;
    assert st.pausedDebtReserveId == recPausedDebt && st.staleDebtReserveId == recStaleDebt;
    assert st.haltedDebtReserveId == recHaltedDebt && st.breakerDebtReserveId == recBreakerDebt;
    assert st.debtBreakerReasons == recDebtBreakerReasons;
    assert st.driftMarketId == recDriftMarket && st.driftReason == recDriftReason;
    assert st.noApprovedKeeper == recNoKeeper && st.hardHealthFloor == recFloor;
    assert st.healthFactor == recHf && st.healthFactorExcludingRescue == recHfEx;
    assert st.pauseState == recPauseState && st.pauseReason == recPauseReason, "the pause fields are not the pause read";
    assert lastStorage[currentContract] == before[currentContract], "the status view changed RiskModule state";
}

// ---------------------------------------------------------------------------------------------------------------------
// Rescue-excluded health factor (PROP-067)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-067 verifies: INV-082, Q-253
rule postHealthCheckEnforcesTheFloor(address proxy, uint256 minHf) {
    env e;
    address spoke = proxySpokeOf(proxy);
    mathint required = maxOf(maxOf(WAD(), psHardHealthFloor(proxyMarketOf(proxy))), minHf);

    uint256 hfEx = postHealthCheck(e, proxy, minHf);

    assert to_mathint(hfEx) >= required, "postHealthCheck returned below max(1.00, hardHealthFloor, minHF)";
    assert to_mathint(hfEx) <= to_mathint(accountHf(spoke, proxy)), "postHealthCheck valued rescue units above zero";
}

// With no rescue units anywhere, hfEx is Aave's health factor.
// PROP-067 verifies: INV-082, Q-253
rule postHealthCheckWithoutRescueIsAaveHf(address proxy, uint256 minHf) {
    env e;
    address spoke = proxySpokeOf(proxy);
    require forall address p. forall address vt. rescueUnitsOf(p, vt) == 0;
    uint256 hfEx = postHealthCheck(e, proxy, minHf);
    assert hfEx == accountHf(spoke, proxy), "postHealthCheck changed the health factor of an account with no rescue units";
}

// PROP-067 verifies: INV-082, Q-253
// Q-398: no on-chain opening floor remains; the RiskModule's only health constant is the rescue threshold 1.10.
rule floorConstantIsOnePointZeroFive() {
    assert to_mathint(rescueHealthFactor()) == 110 * WAD() / 100, "rescueHealthFactor is not 1.10e18";
}

// SPEC-CF-005 restated: E and the subtracted term round up, so hfEx never exceeds the exact health factor without the
// rescue units, and saturates at 0. Primary tool per 5.2: Halmos.
// PROP-067 verifies: INV-082, Q-253
rule hfExRoundsAgainstTheBorrower(mathint hf, mathint u, mathint p, mathint cf, mathint d, mathint debtRay,
                                  mathint eTerm, mathint sub) {
    require hf >= 0 && hf < 2^128 && u >= 0 && u < 2^120 && p >= 0 && p < 2^64;
    require cf >= 0 && cf <= 10000 && (d == 6 || d == 12 || d == 18) && debtRay > 0 && debtRay < 2^200;
    // E = ceil(u * p * cf * 1e18 / (10^d * 1e4)); sub = ceil(E * WAD * RAY / debtRay).
    require eTerm * 10^d * 10000 >= u * p * cf * 10^18 && (eTerm - 1) * 10^d * 10000 < u * p * cf * 10^18;
    require sub * debtRay >= eTerm * WAD() * RAY() && (sub - 1) * debtRay < eTerm * WAD() * RAY();
    mathint hfEx = hf > sub ? hf - sub : 0;
    // Exact: hf - (u p cf 1e18 / (10^d 1e4)) * WAD * RAY / debtRay, as a scaled comparison.
    assert hfEx * debtRay * 10^d * 10000 <= hf * debtRay * 10^d * 10000 - u * p * cf * 10^18 * WAD() * RAY()
        || hfEx == 0, "hfEx exceeds the exact rescue-excluded health factor";
    assert u * p < 2^184, "u * p overflows the SPEC-CF-005 bound";
}

// ---------------------------------------------------------------------------------------------------------------------
// Minimum pledge (PROP-062) and remaining record (partial removal)
// ---------------------------------------------------------------------------------------------------------------------

// As 5.2 states it: pledgeUsd from the LPOracle's last accepted price (REQ-RISK-026), BelowMinPledge below the required
// minimum: min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD) for a rescue top-up (REQ-RISK-066, REQ-RISK-067), minPledgeUsd for
// every other pledge.
// PROP-062 verifies: INV-069, REQ-RISK-026, REQ-RISK-066, REQ-RISK-067, Q-230, Q-252, Q-277
rule minimumPledgeUsesAcceptedPrice(address depositor, address proxy, uint256 marketId, uint32 integrationId,
                                    bytes32 positionKey, uint128 L, RiskModule.PledgeCounters counters, bool requireRescue) {
    env e;
    address o = mLpOracle(marketId);
    uint8 d = mDecimals(marketId);
    require d <= 18;
    uint256 accepted;
    uint64 acceptedAt;
    accepted, acceptedAt = oracleLastAccepted(o);
    mathint pledgeUsd = (to_mathint(L) * to_mathint(accepted)) / 10^d;
    mathint minUsd = to_mathint(psMinPledgeUsd(marketId));
    mathint rescueMin = to_mathint(RESCUE_MIN_PLEDGE_USD());
    mathint required = minUsd < rescueMin ? minUsd : rescueMin;

    RiskModule.PledgeCharge charge = checkPledge@withrevert(e, depositor, proxy, marketId, integrationId, positionKey, L, counters,
                                                 requireRescue);
    bool reverted = lastReverted;

    assert pledgeUsd < required => reverted, "a pledge below the rescue minimum did not revert";
    assert !reverted => pledgeUsd >= required, "a pledge below the rescue minimum passed";
    assert !reverted && !charge.rescue => pledgeUsd >= minUsd, "a pledge other than a rescue top-up passed below minPledgeUsd";
}

// PROP-062 verifies: INV-069, Q-230
rule minimumPledgeArithmeticFits(mathint L, mathint price8, mathint d) {
    // L <= MAX_CREDITED_LIQUIDITY (2^128 - 1), price8 < 2^64, d <= 18: mulDiv never overflows and the floor result fits.
    require L >= 0 && L < 2^128 && price8 > 0 && price8 < 2^64 && d >= 0 && d <= 18;
    mathint pledgeUsd = L * price8 / 10^d;
    assert L * price8 < 2^192, "L * price8 exceeds 192 bits";
    assert pledgeUsd < 2^256, "pledgeUsd overflows";
    assert L == 5 * 10^18 && price8 == 2 * 10^8 && d == 18 => pledgeUsd == 10 * 10^8, "the 5.2 example does not give 10e8";
    assert L == 499 * 10^16 && price8 == 2 * 10^8 && d == 18 => pledgeUsd == 998000000, "the 5.2 example does not give 998,000,000";
}

// A partial removal that leaves debt keeps the remaining record worth at least minPledgeUsd at the accepted price.
// PROP-062 verifies: INV-069, Q-230
rule remainingRecordAtLeastMinimum(uint256 marketId, uint128 remaining) {
    env e;
    address o = mLpOracle(marketId);
    uint8 d = mDecimals(marketId);
    require d <= 18;
    uint256 accepted;
    uint64 acceptedAt;
    accepted, acceptedAt = oracleLastAccepted(o);

    checkRemainingRecord(e, marketId, remaining);

    assert (to_mathint(remaining) * to_mathint(accepted)) / 10^d >= to_mathint(psMinPledgeUsd(marketId)),
        "a partial removal left a record below minPledgeUsd";
}

// ---------------------------------------------------------------------------------------------------------------------
// Debt-reserve set in the drift check (PROP-061)
// ---------------------------------------------------------------------------------------------------------------------

// REQ-RISK-063: over every reserve of the Spoke, `borrowable` is true exactly for the registry's debt reserves.
// PROP-061 verifies: INV-073, Q-281
rule checkAaveConfigRequiresEqualDebtSets(address spoke, uint256[] marketIds, uint256 r) {
    env e;
    require spokeReserveCount(spoke) <= MAX_RESERVES();
    require r < spokeReserveCount(spoke);
    require marketIds.length <= MAX_RESERVES();

    checkAaveConfig(e, spoke, marketIds);

    assert spokeBorrowable(spoke, r) == regApprovedDebtReserve(spoke, r),
        "the drift check passed while the registry's debt set differs from the Spoke's borrowable reserves";
}

// ---------------------------------------------------------------------------------------------------------------------
// Cap booking (PROP-030; primary tool per 5.2: Halmos) and arithmetic bounds (PROP-044; primary tool: SMTChecker)
// ---------------------------------------------------------------------------------------------------------------------

definition ceilDiv(mathint a, mathint b) returns mathint = (a + b - 1) / b;

// Regular and slice charges booked at no less than stressFloorUsd fit under addCap >= ceil((regular + slice) / floor).
// PROP-030 verifies: INV-028, Q-175
rule pledgeBudgetFitsAddCap(mathint units1, mathint units2, mathint price1, mathint price2, mathint floorUsd,
                            mathint regular, mathint slice, mathint addCap, mathint scale) {
    require scale == 10^6 || scale == 10^12 || scale == 10^18;
    require units1 > 0 && units2 > 0 && units1 < 2^120 && units2 < 2^120;
    require price1 >= 0 && price2 >= 0 && price1 < 2^64 && price2 < 2^64;
    require floorUsd > 0 && floorUsd < 2^64;
    mathint charge1 = ceilDiv(units1 * (price1 > floorUsd ? price1 : floorUsd), scale);
    mathint charge2 = ceilDiv(units2 * (price2 > floorUsd ? price2 : floorUsd), scale);
    require regular >= 0 && slice >= 0 && charge1 + charge2 <= regular + slice;
    require addCap >= ceilDiv(regular + slice, floorUsd);

    assert units1 + units2 <= addCap * scale, "credited units exceed the Hub addCap";
}

// PROP-030 verifies: INV-028, Q-174, Q-175
rule partialExitsKeepBookingAboveFloor(mathint originalUnits, mathint originalCharge, mathint remaining,
                                       mathint floorUsd, mathint scale) {
    require scale == 10^6 || scale == 10^12 || scale == 10^18;
    require originalUnits > 0 && originalUnits < 2^120 && remaining >= 0 && remaining <= originalUnits;
    require floorUsd > 0 && originalCharge < 2^128;
    require originalCharge * scale >= originalUnits * floorUsd;

    mathint remainingCharge = ceilDiv(originalCharge * remaining, originalUnits);
    assert remainingCharge * scale >= remaining * floorUsd, "an exit left units booked below the stress floor";
    assert remainingCharge <= originalCharge, "an exit raised the booked charge";
}

// PROP-044 verifies: Q-191, Q-235
rule bookingArithmeticFits(mathint L, mathint price8, mathint floorUsd, mathint d) {
    require L >= 0 && L < 2^128 && price8 >= 0 && price8 < 2^64 && floorUsd >= 0 && floorUsd < 2^64;
    require d >= 0 && d <= 18;
    mathint p = price8 > floorUsd ? price8 : floorUsd;
    assert L * p < 2^192 && ceilDiv(L * p, 10^d) < 2^192, "the stress-floor charge overflows";
}

// ---------------------------------------------------------------------------------------------------------------------
// Role map (PROP-034) and admin invariant (PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// The RiskModule's only state-changing functions are role management, initialize and upgrade (2.7); the borrow-side
// pre-checks are open to anyone and only poke oracles.
// PROP-034 verifies: INV-051, Q-226, Q-228
rule upgradeNeedsApplicationAdmin(address impl, bytes data) {
    env e;
    bool admin = hasRole(APP_ADMIN(), e.msg.sender);
    upgradeToAndCall@withrevert(e, impl, data);
    assert !lastReverted => admin, "upgradeToAndCall succeeded without APPLICATION_ADMIN";
}

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APP_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !isUpgrade(f) }
