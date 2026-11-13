/*
 * AaveAdapter (src/policy/aave-adapter/AaveAdapter.sol, the router, with the bodies of its entry points in
 * AaveAdapterUserLogic, AaveAdapterExitLogic, AaveAdapterCollateralLogic and AaveAdapterSettlementLogic, reached by
 * delegatecall and linked in the conf; interface src/policy/aave-adapter/IAaveAdapter.sol, spec 2.6), with
 * Collateralization (src/custody/collateralization/Collateralization.sol) linked as real code.
 *
 * Backing across the Adapter and Collateralization: every mint equals the units Collateralization credited in the
 * same call and goes to the caller's own proxy for the named market; every burn equals the units Collateralization
 * debits for that record, from the proxy that just withdrew them or, in `burnSeized`, from LPVaultSwap; every pledge,
 * withdrawal, partial removal, re-credit and repay with collateral leaves the backing gap
 * `totalCredited + pending.units − totalSupply` unchanged, and only an unsettled `burnSeized` raises it. Also: the
 * wallet-to-proxy binding of a (wallet, market) and the proxy's stored account (Spoke, market, vault token, reserve)
 * are written once, every entry point acts on the caller's own proxy for the market it names (a repay on the named
 * borrower's), the repay-with-collateral steps run only inside the Adapter's own session, and the Adapter's admin
 * roles are held only by the timelock. The Adapter's gates and call graph (per-Hub pause, freeze, RiskModule checks,
 * health floor) are in AaveAdapterGates.spec.
 *
 * Positions are named by `PositionRef` (`integrationId`, `positionKey`) and token amounts are arrays in the market's
 * token order. An account is one PositionProxy per (wallet, CDP Spoke, market), so `proxyOf` is keyed by
 * (wallet, marketId) and `accountOf(proxy)` returns the bound Spoke, market, vault token and reserve.
 *
 * Storage assumption: the Adapter is upgradeable and keeps its state in an ERC-7201 namespace, so rules read it
 * through its views (`proxyOf`, `walletOf`, `accountOf`, `borrowNonce`, `hasRole`); Collateralization is immutable and
 * is read directly with its 2.3 Storage names (`totalCredited`, `pending`, `records`) and its `recordIdOf` view.
 *
 * Summaries (certora/README.md): vault tokens and every other ERC-20 by the ERC-20 model, so the vault-token supply is
 * the model's ghost and `mint`/`burn` are counted per token and holder (their authority is proved on the real token,
 * VaultToken.spec); each market's LPVault by a custody model keyed by (LPVault, positionKey): `receivePosition` takes
 * an owned position into custody and returns its units below 2^120, `returnPosition` hands it back to its depositor,
 * `unwind` and `releaseToDepositor` remove exactly the requested units from a custodied position and return one amount
 * per token for each per-token minimum, `unitsOf` reads the units, `collectFees` leaves the units unchanged (pool-token
 * payouts are not modelled: no rule here reads a pool-token balance; LPVault.spec proves the LPVault); the Spoke and
 * Hub by the Aave model, so `supply`, `withdraw`, `borrow`, `repay` and `setUsingAsCollateral` move the vault token or
 * debt asset and change supplied shares and debt of `onBehalfOf` exactly as Aave does, and the reserve of (Hub, asset)
 * that `getReserveId` returns is supplied to that Hub with that asset's token as underlying; a PositionProxy's `execute` is
 * dispatched to the real logic-free PositionProxy, so every Spoke and token call the Adapter makes through a proxy
 * reaches those summaries with the proxy as caller; the ProxyManager's `deployProxy(wallet, spoke, marketId)` returns
 * its `predictProxy(wallet, spoke, marketId)` address, an uninterpreted function; the MarketRegistry by the registry
 * model with a pause state and reason per Hub and uninterpreted listing views (the receiver rule's LPVault, Hub,
 * PayoutEscrow and flash-source views and the Hub's listing views are NONDET: a refusal only strengthens a success
 * premise); the RiskModule checks are NONDET (any RiskModule: the backing rules must hold whatever it approves);
 * LPVaultSwap is havocked except that `deleverage` calls back the Adapter's `deleverageRepay` and `deleverageRelease`
 * once each with the session's arguments and, as 2.11 specifies (`DeleverageTooSmall`, REQ-SWAP-106), returns only
 * when the debt it repaid is at least the request's `minDebtRepaid`; the ParameterStore's `sequencer()` and the
 * sequencer feed's `latestRoundData()` are NONDET (the sequencer gate only refuses a repay with collateral); the Lock by
 * its model. Transient storage starts empty in every rule (TransientModel), as at the start of a transaction.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/AaveModel.spec";
import "setup/RegistryReadsModel.spec";
import "setup/TransientModel.spec";

using Collateralization as coll;

methods {
    // AaveAdapter
    function APPLICATION_ADMIN() external returns (bytes32) envfree;
    function COLLATERALIZATION() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function PROXY_MANAGER() external returns (address) envfree;
    function TIMELOCK() external returns (address) envfree;
    function LOCK() external returns (address) envfree;
    function proxyOf(address, uint256) external returns (address) envfree;
    function walletOf(address) external returns (address) envfree;
    function accountOf(address) external returns (address, uint256, address, uint256) envfree;
    function predictProxy(address, uint256) external returns (address) envfree;
    function borrowNonce(address) external returns (uint256) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function pledge(uint256, AaveAdapter.PositionRef, uint256) external returns (address, uint256, uint128);
    function recredit(uint256, AaveAdapter.PositionRef, bytes, uint256) external returns (uint128);
    function withdraw(uint256, AaveAdapter.PositionRef, uint256, uint256, uint256) external;
    function removeLiquidity(uint256, AaveAdapter.PositionRef, uint128, uint256[], uint256, uint256) external returns (uint256[]);
    function repay(address, uint256, uint256, uint256, bool, uint256) external returns (uint256);
    function repayAllAndWithdraw(uint256, AaveAdapter.PositionRef, uint256, uint256[], uint256[], uint256) external;
    function repayWithCollateral(AaveAdapter.RepayWithCollateralParams) external returns (uint256, uint256);
    function burnSeized(uint256, address, uint256) external;
    function deleverageRepay(address, uint256, uint256) external returns (uint256);
    function deleverageRelease(address, AaveAdapter.PositionRef, uint128, uint256[]) external returns (uint256[], bool);
    function collectFees(uint256, AaveAdapter.PositionRef, uint256) external returns (uint256[]);
    function releaseZeroCredit(uint256, AaveAdapter.PositionRef, uint256) external;
    function refreshDebtMark(address) external;

    // Collateralization (linked)
    function coll.ADAPTER() external returns (address) envfree;
    function coll.LP_VAULT_SWAP() external returns (address) envfree;
    function coll.recordIdOf(uint32, bytes32) external returns (uint256) envfree;

    // ERC-20 tokens and vault tokens
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.allowance(address o, address s) external => erc20Allowance(calledContract, o, s) expect uint256;
    function _.totalSupply() external => erc20TotalSupply(calledContract) expect uint256;
    function _.approve(address s, uint256 a) external with (env e) => erc20Approve(calledContract, e.msg.sender, s, a) expect bool;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => erc20TransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.mint(address to, uint256 a) external => vaultTokenMint(calledContract, to, a) expect void;
    function _.burn(address from, uint256 a) external => vaultTokenBurn(calledContract, from, a) expect void;
    function _.addValidProxy(address p) external => vtAddValidProxy(calledContract, p) expect void;
    function _.isValidProxy(address p) external => vtIsValidProxy(calledContract, p) expect bool;
    function _.hub() external => vtHubOf(calledContract) expect address;
    function _.spoke() external => vtSpokeOf(calledContract) expect address;
    function _.marketId() external => vtMarketIdOf(calledContract) expect uint256;
    function _.marketKey() external => vtMarketKeyOf(calledContract) expect bytes32;
    function _.lpOracle() external => vtLpOracleOf(calledContract) expect address;
    function _.integrationId() external => vtIntegrationIdOf(calledContract) expect uint32;
    function _.integration() external => vtIntegrationOf(calledContract) expect address;
    function _.collateralization() external => vtCollateralizationOf(calledContract) expect address;
    function _.adapter() external => vtAdapterOf(calledContract) expect address;
    function _.lpVaultSwap() external => vtLpVaultSwapOf(calledContract) expect address;

    // VaultTokenFactory
    function _.isVaultToken(address vt) external => factoryIsVaultToken(vt) expect bool;
    function _.tokenOf(address s, bytes32 k) external => factoryTokenOf(s, k) expect address;
    function _.lpVaultOf(uint32 id) external => factoryLpVaultOf(id) expect address;

    // LPVault of each AMM integration (custody model)
    function _.receivePosition(uint256 m, address owner, bytes32 key) external => lpvReceive(calledContract, owner, key) expect uint128;
    function _.returnPosition(bytes32 key) external => lpvReturn(calledContract, key) expect address;
    function _.unwind(bytes32 key, uint128 u, uint256[] mins, address to) external => lpvRemove(calledContract, key, u, mins) expect uint256[];
    function _.releaseToDepositor(bytes32 key, uint128 u, uint256[] mins) external => lpvRemove(calledContract, key, u, mins) expect uint256[];
    function _.unitsOf(bytes32 key) external => lpvUnitsOf(calledContract, key) expect uint128;
    function _.collectFees(bytes32 key, address d) external => lpvCollectFees(calledContract, key) expect uint256[];
    function _.checkReadSafe(uint256 m) external => NONDET;

    // Aave V4 Spoke and Hub (calls through a PositionProxy reach these with the proxy as caller)
    function _.supply(uint256 rid, uint256 a, address onBehalfOf) external with (env e) => spokeSupply(calledContract, e.msg.sender, rid, a, onBehalfOf) expect (uint256, uint256);
    function _.withdraw(uint256 rid, uint256 a, address onBehalfOf) external with (env e) => spokeWithdraw(calledContract, e.msg.sender, rid, a, onBehalfOf) expect (uint256, uint256);
    function _.borrow(uint256 rid, uint256 a, address onBehalfOf) external with (env e) => spokeBorrow(calledContract, e.msg.sender, rid, a, onBehalfOf) expect (uint256, uint256);
    function _.repay(uint256 rid, uint256 a, address onBehalfOf) external with (env e) => spokeRepay(calledContract, e.msg.sender, rid, a, onBehalfOf) expect (uint256, uint256);
    function _.setUsingAsCollateral(uint256 rid, bool on, address onBehalfOf) external => spokeSetUsingAsCollateral(calledContract, rid, on, onBehalfOf) expect void;
    function _.getUserSuppliedShares(uint256 rid, address u) external => spokeGetUserSuppliedShares(calledContract, rid, u) expect uint256;
    function _.getUserTotalDebt(uint256 rid, address u) external => spokeGetUserTotalDebt(calledContract, rid, u) expect uint256;
    function _.getUserAccountData(address u) external => accountDataOf(calledContract, u) expect IAaveV4Spoke.UserAccountData;
    function _.getUserReserveStatus(uint256 rid, address u) external => spokeGetUserReserveStatus(calledContract, rid, u) expect (bool, bool);
    function _.getReserveCount() external => spokeReserveCount(calledContract) expect uint256;
    function _.getReserveId(address hub, uint256 assetId) external => spokeReserveIdWired(calledContract, hub, assetId) expect uint256;
    function _.getAssetId(address t) external => hubAssetIdWired(calledContract, t) expect uint256;
    function _.getAddedAssets(uint256 a) external => hubGetAddedAssets(calledContract, a) expect uint256;
    function _.getAddedShares(uint256 a) external => hubGetAddedShares(calledContract, a) expect uint256;
    function _.getReserve(uint256 rid) external => spokeReserveOf(calledContract, rid) expect IAaveV4Spoke.Reserve;
    function _.getReserveConfig(uint256 rid) external => spokeGetReserveConfig(calledContract, rid) expect IAaveV4Spoke.ReserveConfig;
    // Receiver rule (REQ-PROXY-017): a listing on the funding Hub only refuses a borrow.
    function _.isSpokeListed(uint256, address) external => NONDET;
    function _.isUnderlyingListed(address) external => NONDET;

    // PositionProxy: logic-free forwarder, dispatched to the real PositionProxy
    function _.execute(address target, bytes data) external => DISPATCHER(true);

    // ProxyManager
    function _.deployProxy(address w, address s, uint256 m) external => pmDeployProxy(w, s, m) expect address;
    function _.predictProxy(address w, address s, uint256 m) external => pmPredict(w, s, m) expect address;

    // MarketRegistry
    function _.pauseState(address hub) external => registryHubPauseState(hub) expect AaveAdapterUserLogic.PauseState;
    function _.pauseReason(address hub) external => registryHubPauseReason(hub) expect AaveAdapterUserLogic.PauseReason;
    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
    function _.isApprovedDebtReserve(address s, uint256 r) external => registryApprovedDebtReserve(s, r) expect bool;
    function _.getSpoke(address s) external => NONDET;
    function _.marketOfVaultToken(address vt) external => NONDET;
    function _.getMarket(uint256 m) external => NONDET;
    function _.getDebtReserve(address s, uint256 r) external => NONDET;
    function _.integrationIdOf(address) external => NONDET;
    function _.isRecordedHub(address) external => NONDET;
    function _.PAYOUT_ESCROW() external => NONDET;
    function _.flashSource() external => NONDET;

    // Policy (any RiskModule) and the LPOracle poke
    function _.checkPledge(address d, address p, uint256 m, uint32 i, bytes32 k, uint128 u, Collateralization.PledgeCounters c, bool rr) external => NONDET;
    function _.preBorrowCheck(address p, uint256 r, uint256 a) external => NONDET;
    function _.preWithdrawCheck(address p) external => NONDET;
    function _.postHealthCheck(address p, uint256 minHf) external => NONDET;
    function _.checkRemainingRecord(uint256 m, uint128 u) external => NONDET;
    function _.poke() external => NONDET;

    // LPVaultSwap repay with collateral
    function _.deleverage(AaveAdapterCollateralLogic.DeleverageRequest r) external => swapDeleverage(r) expect (uint256, uint256);

    // ParameterStore sequencer read and the sequencer-uptime feed (bounded STATICCALL)
    function _.sequencer() external => NONDET;
    function _.latestRoundData() external => NONDET;

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;
}

// ---------------------------------------------------------------------------------------------------------------------
// External models of the Adapter scene
// ---------------------------------------------------------------------------------------------------------------------

ghost vtHubOf(address) returns address;
ghost vtSpokeOf(address) returns address;
ghost vtMarketIdOf(address) returns uint256;
ghost vtMarketKeyOf(address) returns bytes32;
ghost vtLpOracleOf(address) returns address;
ghost vtIntegrationIdOf(address) returns uint32;
ghost vtIntegrationOf(address) returns address;
ghost vtCollateralizationOf(address) returns address;
ghost vtAdapterOf(address) returns address;
ghost vtLpVaultSwapOf(address) returns address;
ghost factoryIsVaultToken(address) returns bool;
ghost factoryTokenOf(address, bytes32) returns address;
ghost factoryLpVaultOf(uint32) returns address;
ghost pmPredict(address, address, uint256) returns address;

persistent ghost mapping(address => mapping(address => bool)) vtRegistry;
persistent ghost mathint registryAddsInCall;
persistent ghost address lastRegisteredProxy;
persistent ghost mapping(address => mapping(address => mathint)) acctBorrowCount;

// Pause state and reason per Hub (the MarketRegistry keys every pause by Hub).
persistent ghost mapping(address => AaveAdapterUserLogic.PauseState) hubPause;
persistent ghost mapping(address => AaveAdapterUserLogic.PauseReason) hubPauseReason;

// LPVault custody model, keyed by (LPVault, positionKey): the depositor of a custodied position (0 when not in
// custody) and its units.
persistent ghost mapping(address => mapping(bytes32 => address)) lvDepositor;
persistent ghost mapping(address => mapping(bytes32 => mathint)) lvUnits;

// Repay-with-collateral session as LPVaultSwap drives it.
persistent ghost address swapAddr;
persistent ghost mathint deleverageCalls;

function registryHubPauseState(address hub) returns AaveAdapterUserLogic.PauseState {
    regPauseStateReads = regPauseStateReads + 1;
    regAnyReads = regAnyReads + 1;
    // pauseReason(hub) == None exactly when the Hub is not Paused (PROP-041).
    require (hubPause[hub] == AaveAdapterUserLogic.PauseState.Paused) == (hubPauseReason[hub] != AaveAdapterUserLogic.PauseReason.None);
    return hubPause[hub];
}

function registryHubPauseReason(address hub) returns AaveAdapterUserLogic.PauseReason {
    regPauseReasonReads = regPauseReasonReads + 1;
    regAnyReads = regAnyReads + 1;
    require (hubPause[hub] == AaveAdapterUserLogic.PauseState.Paused) == (hubPauseReason[hub] != AaveAdapterUserLogic.PauseReason.None);
    return hubPauseReason[hub];
}

// Aave's reserve wiring: a Hub asset identifier names one token, and the Spoke reserve of (Hub, asset) is supplied to
// that Hub with that token as underlying.
ghost hubAssetTokenOf(address, uint256) returns address;

function hubAssetIdWired(address hub, address t) returns uint256 {
    uint256 a = hubAssetIdOf(hub, t);
    require hubAssetTokenOf(hub, a) == t;
    return a;
}

function spokeReserveIdWired(address spoke, address hub, uint256 assetId) returns uint256 {
    uint256 rid = spokeReserveIdOf(spoke, hub, assetId);
    require spokeHubOf(spoke) == hub && spokeUnderlyingOf(spoke, rid) == hubAssetTokenOf(hub, assetId);
    return rid;
}

function vtAddValidProxy(address t, address p) {
    require p != 0;
    if (!vtRegistry[t][p]) {
        registryAddsInCall = registryAddsInCall + 1;
        lastRegisteredProxy = p;
    }
    vtRegistry[t][p] = true;
}

function vtIsValidProxy(address t, address p) returns bool {
    return vtRegistry[t][p];
}

function accountDataOf(address spoke, address user) returns IAaveV4Spoke.UserAccountData {
    IAaveV4Spoke.UserAccountData d;
    require spokeHealthFactor[spoke][user] >= 0;
    require to_mathint(d.healthFactor) == spokeHealthFactor[spoke][user];
    require acctBorrowCount[spoke][user] >= 0;
    require to_mathint(d.borrowCount) == acctBorrowCount[spoke][user];
    return d;
}

function pmDeployProxy(address wallet, address spoke, uint256 marketId) returns address {
    address p = pmPredict(wallet, spoke, marketId);
    require p != 0;
    return p;
}

// LPVaultSwap.deleverage: flash-borrows the debt asset through the chain's IFlashSource and swaps the released tokens
// (not modelled), then calls back the session's repay and release steps once each, in that order, as LPVaultSwap.
function swapDeleverage(AaveAdapterCollateralLogic.DeleverageRequest r) returns (uint256, uint256) {
    deleverageCalls = deleverageCalls + 1;
    env eSwap;
    require eSwap.msg.sender == swapAddr;
    uint256 amount;
    require amount > 0;
    uint256 repaid = currentContract.deleverageRepay(eSwap, r.proxy, r.debtReserveId, amount);
    uint256[] released;
    bool closed;
    released, closed = currentContract.deleverageRelease(eSwap, r.proxy, r.position, r.units, r.minAmounts);
    // LPVaultSwap reverts `DeleverageTooSmall` below the borrower's minimum (2.11 REQ-SWAP-106).
    require repaid >= r.minDebtRepaid;
    uint256 debtAssetOut;
    return (repaid, debtAssetOut);
}

function lpvReceive(address lpv, address owner, bytes32 key) returns uint128 {
    require owner != 0 && owner != lpv && lvDepositor[lpv][key] == 0;
    require lvUnits[lpv][key] >= 0 && lvUnits[lpv][key] < 2^120;
    lvDepositor[lpv][key] = owner;
    return require_uint128(lvUnits[lpv][key]);
}

function lpvReturn(address lpv, bytes32 key) returns address {
    address d = lvDepositor[lpv][key];
    require d != 0;
    lvDepositor[lpv][key] = 0;
    return d;
}

function lpvRemove(address lpv, bytes32 key, uint128 units, uint256[] mins) returns uint256[] {
    require lvDepositor[lpv][key] != 0;
    require lvUnits[lpv][key] >= to_mathint(units);
    lvUnits[lpv][key] = lvUnits[lpv][key] - units;
    uint256[] amounts;
    require amounts.length == mins.length;
    return amounts;
}

function lpvUnitsOf(address lpv, bytes32 key) returns uint128 {
    require lvUnits[lpv][key] >= 0 && lvUnits[lpv][key] <= max_uint128;
    return require_uint128(lvUnits[lpv][key]);
}

function spokeReserveOf(address spoke, uint256 rid) returns IAaveV4Spoke.Reserve {
    IAaveV4Spoke.Reserve r;
    require r.underlying == spokeUnderlyingOf(spoke, rid) && r.hub == spokeHubOf(spoke);
    return r;
}

function lpvCollectFees(address lpv, bytes32 key) returns uint256[] {
    require lvDepositor[lpv][key] != 0;
    uint256[] fees;
    return fees;
}

function setup() {
    require swapAddr == LP_VAULT_SWAP() && coll.LP_VAULT_SWAP() == swapAddr && swapAddr != currentContract;
    require coll.ADAPTER() == currentContract && COLLATERALIZATION() == coll;
    // Outer calls start with the Lock free (an Adapter entry point is an outer call, REQ-LOCK of 2.16).
    require lockHolder == 0;
    // A rule is one transaction: transient storage (the repay-with-collateral session) starts empty.
    transientStorageEmpty();
}

function resetCall(address vt) {
    vtMintCalls = 0;
    lastMintToken = 0;
    lastMintTo = 0;
    lastMintAmount = 0;
    vtBurnedInCall[vt] = 0;
    registryAddsInCall = 0;
    deleverageCalls = 0;
}

function gap(address vt) returns mathint {
    return to_mathint(coll.totalCredited[vt]) + to_mathint(coll.pending[vt].units) - erc20Supply[vt];
}

// The account the Adapter stored for a proxy at creation.
function boundSpoke(address proxy) returns address {
    address s; uint256 m; address vt; uint256 r;
    s, m, vt, r = accountOf(proxy);
    return s;
}

function boundMarket(address proxy) returns uint256 {
    address s; uint256 m; address vt; uint256 r;
    s, m, vt, r = accountOf(proxy);
    return m;
}

function boundVaultToken(address proxy) returns address {
    address s; uint256 m; address vt; uint256 r;
    s, m, vt, r = accountOf(proxy);
    return vt;
}

function boundReserve(address proxy) returns uint256 {
    address s; uint256 m; address vt; uint256 r;
    s, m, vt, r = accountOf(proxy);
    return r;
}

function recordOf(AaveAdapter.PositionRef position) returns uint256 {
    return coll.recordIdOf(position.integrationId, position.positionKey);
}

definition backingCall(method f) returns bool =
    f.selector == sig:pledge(uint256, AaveAdapter.PositionRef, uint256).selector
    || f.selector == sig:recredit(uint256, AaveAdapter.PositionRef, bytes, uint256).selector
    || f.selector == sig:withdraw(uint256, AaveAdapter.PositionRef, uint256, uint256, uint256).selector
    || f.selector == sig:removeLiquidity(uint256, AaveAdapter.PositionRef, uint128, uint256[], uint256, uint256).selector
    || f.selector == sig:repayAllAndWithdraw(uint256, AaveAdapter.PositionRef, uint256, uint256[], uint256[], uint256).selector
    || f.selector == sig:repayWithCollateral(AaveAdapter.RepayWithCollateralParams).selector;

definition burnsFromProxy(method f) returns bool =
    f.selector == sig:withdraw(uint256, AaveAdapter.PositionRef, uint256, uint256, uint256).selector
    || f.selector == sig:removeLiquidity(uint256, AaveAdapter.PositionRef, uint128, uint256[], uint256, uint256).selector
    || f.selector == sig:repayAllAndWithdraw(uint256, AaveAdapter.PositionRef, uint256, uint256[], uint256[], uint256).selector
    || f.selector == sig:repayWithCollateral(AaveAdapter.RepayWithCollateralParams).selector;

definition walletEntry(method f) returns bool =
    f.selector == sig:pledge(uint256, AaveAdapter.PositionRef, uint256).selector
    || f.selector == sig:recredit(uint256, AaveAdapter.PositionRef, bytes, uint256).selector
    || f.selector == sig:withdraw(uint256, AaveAdapter.PositionRef, uint256, uint256, uint256).selector
    || f.selector == sig:removeLiquidity(uint256, AaveAdapter.PositionRef, uint128, uint256[], uint256, uint256).selector
    || f.selector == sig:repayAllAndWithdraw(uint256, AaveAdapter.PositionRef, uint256, uint256[], uint256[], uint256).selector
    || f.selector == sig:repayWithCollateral(AaveAdapter.RepayWithCollateralParams).selector
    || f.selector == sig:borrow(uint256, uint256, uint256, address, uint256, uint256, uint256).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Backing across the Adapter and Collateralization (PROP-001, PROP-054, PROP-065)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-065 verifies: INV-001, INV-066, INV-080, INV-088, Q-254, Q-255, Q-257
// PROP-054 verifies: INV-001, INV-066, Q-224, Q-240, Q-254, Q-255, Q-257
// PROP-001 verifies: INV-001, Q-066, Q-092, Q-201, Q-224, Q-257
rule adapterCallsKeepTheBackingGap(method f, address vt) filtered { f -> backingCall(f) } {
    env e;
    calldataarg args;
    setup();
    require e.msg.sender != swapAddr && e.msg.sender != currentContract && e.msg.sender != coll;
    mathint gapBefore = gap(vt);

    f(e, args);

    assert gap(vt) == gapBefore, "an Adapter entry point changed the backing gap";
    assert gapBefore >= 0 => erc20Supply[vt] <= to_mathint(coll.totalCredited[vt]) + to_mathint(coll.pending[vt].units),
        "an Adapter entry point left more vault tokens than credited plus pending units";
}

// PROP-008 verifies: INV-011, Q-068, Q-120, Q-224
// End-of-call holders: an Adapter entry point leaves every vault-token balance other than the Hub's and LPVaultSwap's
// as it found it (minted units end at the Hub through the proxy's supply, withdrawn units are burned from the proxy),
// so with the reviewed Adapter only the Hub and LPVaultSwap hold units at the end of an outer call.
rule adapterCallsLeaveNoUnitsOutsideHub(method f, address vt, address x) filtered { f -> backingCall(f) } {
    env e;
    calldataarg args;
    setup();
    require x != vtHubOf(vt) && x != swapAddr;
    mathint before = erc20Bal[vt][x];

    f(e, args);

    assert erc20Bal[vt][x] == before, "an Adapter entry point left vault tokens with an address other than the Hub";
}

// PROP-065 verifies: INV-080, Q-257
// PROP-007 verifies: INV-010, Q-165, Q-201, Q-224
// The orphan burn: only `burnSeized` not followed by its debit raises the gap, by exactly the burned units.
rule burnSeizedRaisesGapOnlyByItsUnits(uint256 marketId, address vt, uint256 units) {
    env e;
    setup();
    setLockHolder(swapAddr);
    mathint gapBefore = gap(vt);
    mathint swapBalance = erc20Bal[vt][swapAddr];
    resetCall(vt);

    burnSeized(e, marketId, vt, units);

    assert e.msg.sender == swapAddr && lockHolder == swapAddr, "burnSeized ran outside LPVaultSwap holding the lock";
    assert units > 0 && gap(vt) == gapBefore + units, "burnSeized changed the gap by other than its units";
    assert erc20Bal[vt][swapAddr] == swapBalance - units, "burnSeized burned other than LPVaultSwap's units";
    assert vtBurnedFrom[vt][swapAddr] == to_mathint(units) && vtBurnedInCall[vt] == to_mathint(units),
        "burnSeized burned from a holder other than LPVaultSwap";
}

// PROP-065 verifies: INV-001, INV-080, Q-257
// No Adapter function lowers the gap: an orphan burn can only leave more backing than units, never less.
rule noAdapterFunctionLowersTheGap(method f, address vt) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    require e.msg.sender != currentContract && e.msg.sender != coll;
    mathint gapBefore = gap(vt);

    f(e, args);

    assert gap(vt) >= gapBefore, "an Adapter function lowered the backing gap";
}

// ---------------------------------------------------------------------------------------------------------------------
// Mint and burn (PROP-006, PROP-007, PROP-054)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-006 verifies: INV-009, Q-092, Q-094, Q-123, Q-223, Q-224, Q-254
rule mintOnlyInPledgeAndRecredit(method f, address vt) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    resetCall(vt);

    f(e, args);

    assert vtMintCalls > 0 => (f.selector == sig:pledge(uint256, AaveAdapter.PositionRef, uint256).selector
        || f.selector == sig:recredit(uint256, AaveAdapter.PositionRef, bytes, uint256).selector),
        "a vault token was minted outside pledge and recredit";
    assert vtMintCalls <= 1, "one call minted more than once";
}

// PROP-006 verifies: INV-009, Q-092, Q-094, Q-123, Q-223, Q-224
// PROP-054 verifies: INV-066, Q-224, Q-240
rule pledgeMintsCreditedToCallerProxy(uint256 marketId, address vt, AaveAdapter.PositionRef position, uint256 deadline) {
    env e;
    setup();
    resetCall(vt);
    mathint hubBefore = erc20Bal[vt][vtHubOf(vt)];

    address proxy;
    uint256 id;
    uint128 credited;
    proxy, id, credited = pledge(e, marketId, position, deadline);

    assert proxy == proxyOf(e.msg.sender, marketId) && proxy != 0, "pledge acted on a proxy other than the caller's";
    assert walletOf(proxy) == e.msg.sender && boundMarket(proxy) == marketId,
        "the proxy is not bound to the caller and the named market";
    assert vtMintCalls == 1 && lastMintToken == boundVaultToken(proxy) && lastMintTo == proxy,
        "pledge did not mint once, in the market's vault token, to the caller's proxy";
    assert lastMintAmount == to_mathint(credited) && to_mathint(coll.records[id].credited) == to_mathint(credited),
        "minted units differ from the units Collateralization credited";
    assert coll.records[id].proxy == proxy && coll.records[id].depositor == e.msg.sender,
        "the record is not the caller's on the caller's proxy";
    assert vt == boundVaultToken(proxy) => erc20Bal[vt][vtHubOf(vt)] == hubBefore + credited,
        "the minted units did not all reach the Hub through the proxy's supply";
}

// PROP-006 verifies: INV-009, Q-224, Q-254
// PROP-054 verifies: INV-066, Q-254
rule recreditMintsAddedToCallerProxy(uint256 marketId, address vt, AaveAdapter.PositionRef position, bytes topUp, uint256 deadline) {
    env e;
    setup();
    resetCall(vt);
    uint256 id = recordOf(position);

    uint128 added = recredit(e, marketId, position, topUp, deadline);

    address proxy = proxyOf(e.msg.sender, marketId);
    assert vtMintCalls == 1 && lastMintToken == boundVaultToken(proxy) && lastMintTo == proxy
        && lastMintAmount == to_mathint(added),
        "re-credit did not mint exactly added, in the market's vault token, to the caller's proxy";
    assert coll.records[id].depositor == e.msg.sender, "re-credit by a caller other than the depositor of record";
}

// PROP-007 verifies: INV-010, Q-069, Q-165, Q-201, Q-224, Q-254, Q-255
// The Adapter burns only from the proxy of the account it is acting for, or from LPVaultSwap in burnSeized; never
// from the Hub.
rule burnsOnlyFromOwnProxyOrSwap(method f, address vt, address holder) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    require holder != 0;
    mathint burnedBefore = vtBurnedFrom[vt][holder];

    f(e, args);

    bool burned = vtBurnedFrom[vt][holder] > burnedBefore;
    assert burned => holder != vtHubOf(vt), "the Adapter burned units held by the Hub";
    assert burned => (
        (f.selector == sig:burnSeized(uint256, address, uint256).selector && holder == swapAddr)
        || (burnsFromProxy(f) && walletOf(holder) == e.msg.sender)
        || (f.selector == sig:deleverageRelease(address, AaveAdapter.PositionRef, uint128, uint256[]).selector && e.msg.sender == swapAddr)),
        "the Adapter burned from a holder other than the caller's proxy or LPVaultSwap";
}

// PROP-007 verifies: INV-010, Q-069, Q-165, Q-224
// PROP-054 verifies: INV-066, Q-224
rule withdrawBurnsTheRecordCredit(uint256 marketId, address vt, AaveAdapter.PositionRef position, uint256 units, uint256 deadline,
                                  uint256 minHf) {
    env e;
    setup();
    resetCall(vt);
    address proxy = proxyOf(e.msg.sender, marketId);
    require boundVaultToken(proxy) == vt;
    mathint totalBefore = coll.totalCredited[vt];
    mathint pendingBefore = coll.pending[vt].units;

    withdraw(e, marketId, position, units, deadline, minHf);

    assert units > 0 && vtBurnedFrom[vt][proxy] == to_mathint(units) && vtBurnedInCall[vt] == to_mathint(units),
        "withdraw burned other than units from the caller's proxy";
    assert to_mathint(coll.totalCredited[vt]) + to_mathint(coll.pending[vt].units) == totalBefore + pendingBefore - units,
        "Collateralization debited other than the burned units";
    assert recordOf(position) == 0, "withdraw left the record open";
}

// PROP-007 verifies: INV-010, Q-224, Q-254
// PROP-054 verifies: INV-066, INV-088, Q-254
rule removeLiquidityBurnsTheDebitedUnits(uint256 marketId, address vt, AaveAdapter.PositionRef position, uint128 units,
                                         uint256[] minAmounts, uint256 deadline, uint256 minHf) {
    env e;
    setup();
    resetCall(vt);
    address proxy = proxyOf(e.msg.sender, marketId);
    require boundVaultToken(proxy) == vt;
    uint256 id = recordOf(position);
    mathint totalBefore = coll.totalCredited[vt];
    mathint pendingBefore = coll.pending[vt].units;

    removeLiquidity(e, marketId, position, units, minAmounts, deadline, minHf);

    assert vtBurnedFrom[vt][proxy] == to_mathint(units) && vtBurnedInCall[vt] == to_mathint(units),
        "removeLiquidity burned other than units from the caller's proxy";
    assert to_mathint(coll.totalCredited[vt]) + to_mathint(coll.pending[vt].units) == totalBefore + pendingBefore - units,
        "Collateralization debited other than the burned units";
    assert recordOf(position) == id && coll.records[id].credited > 0, "a partial removal closed the record";
}

// ---------------------------------------------------------------------------------------------------------------------
// Proxy binding and registry origin (PROP-009, PROP-033, PROP-064)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-033 verifies: INV-016, Q-093, Q-123, Q-212, Q-223
// PROP-064 verifies: INV-012, INV-064, Q-225, Q-226
rule bindingIsWrittenOnce(method f, address w, uint256 m) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    address p = proxyOf(w, m);
    address spokeBefore = boundSpoke(p);
    address vtBefore = boundVaultToken(p);
    uint256 reserveBefore = boundReserve(p);

    f(e, args);

    address q = proxyOf(w, m);
    assert p != 0 => q == p, "a wallet's proxy binding for a market was overwritten or deleted";
    assert p != 0 => (walletOf(p) == w && boundMarket(p) == m && boundSpoke(p) == spokeBefore
        && boundVaultToken(p) == vtBefore && boundReserve(p) == reserveBefore),
        "a bound proxy's wallet, market, Spoke, vault token or reserve changed";
    assert (p == 0 && q != 0) => (
        f.selector == sig:pledge(uint256, AaveAdapter.PositionRef, uint256).selector && e.msg.sender == w
        && walletOf(q) == w && boundMarket(q) == m && q == pmPredict(w, boundSpoke(q), m)),
        "a binding was created outside the wallet's own pledge to the market or at an address other than the ProxyManager's";
}

// PROP-009 verifies: INV-012, Q-092, Q-120, Q-224, Q-225
rule registersOnlyTheCallerProxy(method f, address vt) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    resetCall(vt);

    f(e, args);

    assert registryAddsInCall > 0 => (f.selector == sig:pledge(uint256, AaveAdapter.PositionRef, uint256).selector
        && walletOf(lastRegisteredProxy) == e.msg.sender
        && lastRegisteredProxy == pmPredict(e.msg.sender, boundSpoke(lastRegisteredProxy), boundMarket(lastRegisteredProxy))),
        "a proxy was registered outside its wallet's pledge or at an address the ProxyManager did not predict";
}

// PROP-033 verifies: INV-016, Q-093, Q-123, Q-223
// Wallet entry points change Spoke state only for proxies bound to the caller.
rule walletEntriesActOnCallerProxyOnly(method f, address spoke, uint256 rid, address other) filtered { f -> walletEntry(f) } {
    env e;
    calldataarg args;
    setup();
    mathint suppliedBefore = spokeSupplied[spoke][rid][other];
    mathint debtBefore = spokeDebt[spoke][rid][other];

    f(e, args);

    assert walletOf(other) != e.msg.sender =>
        (spokeSupplied[spoke][rid][other] == suppliedBefore && spokeDebt[spoke][rid][other] == debtBefore),
        "a wallet entry point changed the Spoke position of a proxy not bound to the caller";
}

// PROP-033 verifies: INV-016, Q-093, Q-212, Q-223
rule repayFromAnyPayerTouchesOnlyPayerAndDebt(address borrower, uint256 marketId, uint256 r, uint256 maxSpend, bool all,
                                              uint256 deadline, address other, uint256 r2) {
    env e;
    setup();
    address proxy = proxyOf(borrower, marketId);
    address spoke = boundSpoke(proxy);
    uint256 collateralReserve = boundReserve(proxy);
    address asset = spokeUnderlyingOf(spoke, r);
    require other != e.msg.sender && other != proxy && other != spokeHubOf(spoke);
    require r2 != r;
    mathint otherBalance = erc20Bal[asset][other];
    mathint debtOther = spokeDebt[spoke][r2][proxy];
    mathint suppliedBefore = spokeSupplied[spoke][collateralReserve][proxy];
    mathint debtBefore = spokeDebt[spoke][r][proxy];

    uint256 spent = repay(e, borrower, marketId, r, maxSpend, all, deadline);

    assert erc20Bal[asset][other] == otherBalance, "repay moved the debt asset of an address other than the payer";
    assert spokeDebt[spoke][r2][proxy] == debtOther, "repay changed another reserve's debt";
    assert spokeSupplied[spoke][collateralReserve][proxy] == suppliedBefore, "repay moved collateral";
    assert spokeDebt[spoke][r][proxy] <= debtBefore, "repay raised the debt";
}

// PROP-033 verifies: INV-016, Q-212
rule thirdPartyRepayIsReachable(address borrower, uint256 marketId, uint256 r, uint256 maxSpend, uint256 deadline) {
    env e;
    setup();
    require e.msg.sender != borrower;
    uint256 spent = repay(e, borrower, marketId, r, maxSpend, false, deadline);
    satisfy spent > 0;
}

// ---------------------------------------------------------------------------------------------------------------------
// Repay with collateral, Adapter side (PROP-037, PROP-072)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-037 verifies: INV-054, Q-148, Q-223
// PROP-072 verifies: INV-089, Q-255
// Outside the Adapter's own repayWithCollateral session (transient, empty at the start of a transaction) both steps
// revert, whoever calls them.
rule deleverageStepsOnlyInsideASession(method f) filtered {
    f -> f.selector == sig:deleverageRepay(address, uint256, uint256).selector
        || f.selector == sig:deleverageRelease(address, AaveAdapter.PositionRef, uint128, uint256[]).selector
} {
    env e;
    calldataarg args;
    setup();

    f@withrevert(e, args);

    assert lastReverted, "a repay-with-collateral step ran outside the Adapter's own session";
}

// PROP-072 verifies: INV-089, Q-255
rule repayWithCollateralNeverRaisesDebtAndRepaysFirst(AaveAdapter.RepayWithCollateralParams p, uint256 rOther) {
    env e;
    setup();
    address proxy = proxyOf(e.msg.sender, p.marketId);
    address spoke = boundSpoke(proxy);
    address vt = boundVaultToken(proxy);
    require rOther != p.debtReserveId;
    mathint debtBefore = spokeDebt[spoke][p.debtReserveId][proxy];
    mathint otherDebtBefore = spokeDebt[spoke][rOther][proxy];
    mathint hfBefore = spokeHealthFactor[spoke][proxy];
    mathint burnedBefore = vtBurnedFrom[vt][proxy];
    resetCall(vt);

    uint256 repaid;
    uint256 debtAssetToWallet;
    repaid, debtAssetToWallet = repayWithCollateral(e, p);

    assert deleverageCalls == 1, "repayWithCollateral did not run exactly one LPVaultSwap deleverage";
    assert spokeDebt[spoke][rOther][proxy] <= otherDebtBefore, "repay with collateral raised another reserve's debt";
    assert spokeDebt[spoke][p.debtReserveId][proxy] <= debtBefore - p.minDebtRepaid,
        "the named reserve fell by less than minDebtRepaid";
    assert acctBorrowCount[spoke][proxy] > 0 => (
        spokeHealthFactor[spoke][proxy] >= hfBefore && spokeHealthFactor[spoke][proxy] >= to_mathint(p.minHealthFactor)),
        "debt remains and Aave's HF fell below max(HF before, minHealthFactor)";
    assert vtBurnedFrom[vt][proxy] - burnedBefore == to_mathint(p.units),
        "the release burned other than p.units from the proxy";
    assert debtAssetToWallet >= p.minAssetOut, "the wallet received less than the caller's minAssetOut";
}

// ---------------------------------------------------------------------------------------------------------------------
// Admin roles (PROP-034, PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-070 verifies: INV-084, Q-259
invariant adminRolesOnlyTimelock(address a)
    (hasRole(to_bytes32(0), a) || hasRole(APPLICATION_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> !f.isView }

// PROP-034 verifies: INV-051, Q-226, Q-228
rule roleChangesNeedTheRoleAdmin(method f, bytes32 role, address account) filtered {
    f -> f.selector == sig:grantRole(bytes32, address).selector || f.selector == sig:revokeRole(bytes32, address).selector
} {
    env e;
    require hasRole(to_bytes32(0), e.msg.sender) == (e.msg.sender == TIMELOCK());
    bool before = hasRole(role, account);

    if (f.selector == sig:grantRole(bytes32, address).selector) {
        grantRole(e, role, account);
    } else {
        revokeRole(e, role, account);
    }

    assert hasRole(role, account) != before => e.msg.sender == TIMELOCK(),
        "a role changed for a caller other than the timelock";
}
