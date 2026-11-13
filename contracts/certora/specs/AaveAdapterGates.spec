/*
 * AaveAdapter gates and call graph (src/policy/aave-adapter/AaveAdapter.sol, the router, with the bodies of its entry
 * points in AaveAdapterUserLogic, AaveAdapterExitLogic, AaveAdapterCollateralLogic and AaveAdapterSettlementLogic,
 * reached by delegatecall and linked in the conf; interface src/policy/aave-adapter/IAaveAdapter.sol, spec 2.6). Conf:
 * AaveAdapterGates.conf. The Adapter's backing, mint and burn, proxy-binding and role rules are in AaveAdapter.spec
 * (AaveAdapter.conf).
 *
 * An account is one PositionProxy per (wallet, CDP Spoke, market): entry points name a `marketId` and act on
 * `proxyOf[msg.sender][marketId]`, whose Spoke is the one the Adapter stored at creation (`accountOf`). Pause state and
 * reason are kept per Hub: "the market's Hub" is the Hub the MarketRegistry records for the market, which is also its
 * CDP Spoke's home Hub and its vault token's Hub, and "the funding Hub" of a debt reserve is the Hub the MarketRegistry
 * records for that reserve. Rules name these Hubs as parameters.
 *
 * What is proved, for the reviewed Adapter:
 *  - PROP-031 (Adapter half): a successful `borrow` acted on `proxyOf[msg.sender][marketId]` through its bound Spoke,
 *    consumed the expected nonce and raised it by exactly 1, ran before the deadline with a positive amount, an approved
 *    debt reserve, a non-zero receiver that received the borrowed amount, the market's Hub and the debt reserve's
 *    funding Hub both in state None and neither caller nor receiver frozen, called `RiskModule.preBorrowCheck(proxy, r,
 *    amount)` before the Spoke borrow and `postHealthCheck(proxy, minHF)` after it; a withdrawal or partial removal that
 *    leaves debt ran while the market's Hub was not Paused, with an unfrozen caller, and called
 *    `preWithdrawCheck(proxy)` before the Spoke withdrawal and `postHealthCheck` after Collateralization's debit. What
 *    the RiskModule checks inside those calls (every collateral market Live and fresh, nothing paused or frozen, Hub
 *    shares == assets, no breaker, hfEx >= max(1.00, hardHealthFloor, minHF)) is proved on the RiskModule in
 *    RiskModule.spec; together they give the 5.2 row.
 *  - PROP-032, PROP-066 (Adapter half): `repay`, a debt-free `withdraw` or `removeLiquidity`, `repayAllAndWithdraw` and
 *    `burnSeized` make no RiskModule call, read no MarketRegistry function (per-Hub pause state and reason, breakers,
 *    freeze list, debt-reserve set, market, Spoke and Hub views) and never read `minPledgeUsd`; `repay` at zero debt
 *    returns 0 and moves no token.
 *  - PROP-057: pledge and re-credit refuse a Frozen market Hub only for an account with no debt, refuse a market Hub
 *    Paused(MintPathSuspect), and under Paused(General) or for a frozen caller pass `requireRescue = true` to
 *    Collateralization, so only a rescue top-up can pass the RiskModule's `checkPledge`; borrow refuses a Frozen or
 *    Paused market Hub or funding Hub; a withdrawal or partial removal with debt refuses a Paused market Hub;
 *    `repayWithCollateral` refuses a market Hub Paused(MintPathSuspect) and stays open under Paused(General) and Frozen,
 *    since it only reduces debt.
 *  - PROP-061 (Adapter half): a borrow names only a debt reserve the MarketRegistry has enabled on the proxy's Spoke
 *    (a standard Spoke has no fixed debt-reserve set; RiskModule.spec proves that the drift check passes only while
 *    the enabled set equals the Spoke's borrowable reserves, Q-281).
 *  - PROP-067 (call order): `postHealthCheck` runs after every borrow, withdrawal that leaves debt and partial removal
 *    that leaves debt.
 *  - PositionManagerApproved by construction (REQ-PROXY-008, REQ-RISK-088): no Adapter method reaches a Spoke's
 *    `setUserPositionManager`, `setUserPositionManagersWithSig`, `renouncePositionManagerRole` or `multicall`, through a
 *    proxy or from the Adapter itself.
 *
 * Storage: the Adapter's `borrowNonce`, `proxyOf` and `accountOf` are read through their views; no hooks.
 *
 * Summaries: the Lock by LockModel; the MarketRegistry by RegistryModel's freeze, breaker and debt-reserve reads plus
 * a pause state and reason per Hub, with every other registry view (market, Spoke, debt reserve, Hub of a Spoke, the
 * receiver rule's LPVault, Hub, PayoutEscrow and flash-source views) counted as a read; the RiskModule's checks
 * recorded with their arguments and a step number (the RiskModule's own behaviour is proved on the RiskModule);
 * Collateralization's `pledge`, `recredit`, `release`, `releasePartial`, `releaseForDeleverage`, `releaseZeroCredit`
 * and `collectFees` recorded with the `requireRescue` flag and a step number, with its credited total per vault token
 * kept as Collateralization keeps it (a pledge or re-credit adds the units it returns, a release subtracts the units
 * it releases: Collateralization.spec and AaveAdapter.spec prove that on the real contract), so the Adapter's
 * backing-gap check passes exactly when the Adapter mints and burns what Collateralization credits and debits; its
 * debt mark and `recordIdOf` are NONDET (no rule here reads the market-closing count or a record identifier); a
 * PositionProxy's `execute` is dispatched to the real logic-free PositionProxy, so each Spoke call the Adapter makes
 * through a proxy reaches the Aave model with the proxy as caller, and `borrow` and `withdraw` on the Spoke are
 * recorded with a step number, the Spoke and the account; the Spoke's `getUserAccountData` returns a ghost borrow
 * count per account, which no summarised call changes within a rule; vault tokens and ERC-20s by Erc20Model with
 * every `transferFrom` counted and the last `transfer` recorded; the ProxyManager and VaultTokenFactory are
 * uninterpreted; the Hub's listing views used by the receiver rule are NONDET (a refusal only makes a rule's success
 * premise stronger); LPVaultSwap `deleverage` calls back `deleverageRepay` and `deleverageRelease` once each with the
 * request's own arguments, as 2.11 specifies; ParameterStore reads (`minPledgeUsd`, `sequencer`) are counted and the
 * sequencer feed's `latestRoundData` is NONDET (any answer: a Down answer only refuses a repay with collateral).
 * Transient storage starts empty in every rule (TransientModel), as at the start of a transaction.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/AaveModel.spec";
import "setup/RegistryReadsModel.spec";
import "setup/TransientModel.spec";

methods {
    function borrow(uint256, uint256, uint256, address, uint256, uint256, uint256) external returns (uint256);
    function withdraw(uint256, AaveAdapter.PositionRef, uint256, uint256, uint256) external;
    function removeLiquidity(uint256, AaveAdapter.PositionRef, uint128, uint256[], uint256, uint256) external returns (uint256[]);
    function repay(address, uint256, uint256, uint256, bool, uint256) external returns (uint256);
    function repayAllAndWithdraw(uint256, AaveAdapter.PositionRef, uint256, uint256[], uint256[], uint256) external;
    function pledge(uint256, AaveAdapter.PositionRef, uint256) external returns (address, uint256, uint128);
    function recredit(uint256, AaveAdapter.PositionRef, bytes, uint256) external returns (uint128);
    function repayWithCollateral(AaveAdapter.RepayWithCollateralParams) external returns (uint256, uint256);
    function burnSeized(uint256, address, uint256) external;
    function deleverageRepay(address, uint256, uint256) external returns (uint256);
    function deleverageRelease(address, AaveAdapter.PositionRef, uint128, uint256[]) external returns (uint256[], bool);
    function collectFees(uint256, AaveAdapter.PositionRef, uint256) external returns (uint256[]);
    function releaseZeroCredit(uint256, AaveAdapter.PositionRef, uint256) external;
    function refreshDebtMark(address) external;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function borrowNonce(address) external returns (uint256) envfree;
    function proxyOf(address, uint256) external returns (address) envfree;
    function accountOf(address) external returns (address, uint256, address, uint256) envfree;

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;

    // MarketRegistry
    function _.pauseState(address hub) external => registryHubPauseState(hub) expect AaveAdapterUserLogic.PauseState;
    function _.pauseReason(address hub) external => registryHubPauseReason(hub) expect AaveAdapterUserLogic.PauseReason;
    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
    function _.marketBreaker(uint256 m) external => registryMarketBreaker(m) expect (uint32, uint64);
    function _.debtBreaker(address s, uint256 r) external => registryDebtBreaker(s, r) expect (uint32, uint64);
    function _.isApprovedDebtReserve(address s, uint256 r) external => registryApprovedDebtReserve(s, r) expect bool;
    function _.getSpoke(address s) external => regSpokeDef(s) expect AaveAdapterUserLogic.SpokeDef;
    function _.hubOf(address s) external => regHubOfSpoke(s) expect address;
    function _.marketOfVaultToken(address vt) external => regMarketOfVaultToken(vt) expect uint256;
    function _.getMarket(uint256 m) external => regMarketDef(m) expect AaveAdapterUserLogic.Market;
    function _.getDebtReserve(address s, uint256 r) external => regDebtReserveDef(s, r) expect AaveAdapterUserLogic.DebtReserveDef;
    function _.integrationIdOf(address a) external => regReceiverIntegration(a) expect uint32;
    function _.isRecordedHub(address a) external => regReceiverHub(a) expect bool;
    function _.PAYOUT_ESCROW() external => regReceiverAddress() expect address;
    function _.flashSource() external => regReceiverAddress() expect address;

    // VaultTokenFactory and vault tokens
    function _.isVaultToken(address vt) external => factoryIsVaultToken(vt) expect bool;
    function _.tokenOf(address s, bytes32 k) external => factoryTokenOf(s, k) expect address;
    function _.marketKey() external => vtMarketKeyOf(calledContract) expect bytes32;
    function _.marketId() external => vtMarketIdOf(calledContract) expect uint256;
    function _.integrationId() external => vtIntegrationIdOf(calledContract) expect uint32;
    function _.spoke() external => vtSpokeOf(calledContract) expect address;
    function _.hub() external => vtHubOf(calledContract) expect address;
    function _.isValidProxy(address p) external => vtIsValidProxy(calledContract, p) expect bool;
    function _.addValidProxy(address) external => NONDET;
    function _.mint(address to, uint256 a) external => vaultTokenMint(calledContract, to, a) expect void;
    function _.burn(address from, uint256 a) external => vaultTokenBurn(calledContract, from, a) expect void;
    function _.totalSupply() external => erc20TotalSupply(calledContract) expect uint256;
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.allowance(address o, address s) external => erc20Allowance(calledContract, o, s) expect uint256;
    function _.approve(address s, uint256 a) external with (env e) => erc20Approve(calledContract, e.msg.sender, s, a) expect bool;
    function _.transfer(address to, uint256 a) external with (env e) => recordedTransfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => countedTransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;

    // Collateralization
    function _.pledge(address d, address p, address vt, bytes32 key, bool rescue) external => collPledge(vt, rescue) expect (uint256, uint128);
    function _.recredit(address d, address p, address vt, bytes32 key, bytes topUp, bool rescue) external => collRecredit(vt, rescue) expect (uint128, uint128);
    function _.release(address p, address vt, bytes32 key, uint256 u) external => collRelease(vt, u) expect void;
    function _.releasePartial(address p, address vt, bytes32 key, uint128 u, uint256[] mins) external => collReleasePartial(vt, u) expect (uint128, uint256[]);
    function _.releaseForDeleverage(address p, address vt, bytes32 key, uint128 u, uint256[] mins) external => collReleaseForDeleverage(vt, u) expect (uint256[], bool);
    // The indebted mark only feeds `closeMarket`'s count, which no rule here reads; record identifiers are only
    // reported in the re-credit event.
    function _.markIndebted(address) external => NONDET;
    function _.markDebtFree(address) external => NONDET;
    function _.recordIdOf(uint32, bytes32) external => NONDET;
    function _.releaseZeroCredit(address d, address vt, bytes32 key) external => collReleaseZeroCredit() expect void;
    function _.collectFees(address d, address vt, bytes32 key) external => feesPaid() expect uint256[];
    function _.getTotalCredited(address vt) external => collTotalCredited(vt) expect uint256;
    function _.getPending(address vt) external => collPending(vt) expect AaveAdapterUserLogic.Pending;

    // LPVault
    function _.collectFees(bytes32 key, address d) external => feesPaid() expect uint256[];

    // RiskModule
    function _.preBorrowCheck(address p, uint256 r, uint256 a) external => rmPreBorrow(p, r, a) expect void;
    function _.preWithdrawCheck(address p) external => rmPreWithdraw(p) expect void;
    function _.postHealthCheck(address p, uint256 minHf) external => rmPostHealth(p, minHf) expect uint256;
    function _.checkRemainingRecord(uint256, uint128) external => rmRemaining() expect void;

    // ProxyManager and PositionProxies (logic-free forwarder, dispatched to the real PositionProxy)
    function _.deployProxy(address w, address s, uint256 m) external => pmDeploy(w, s, m) expect address;
    function _.execute(address target, bytes data) external => DISPATCHER(true);

    // Spoke and Hub (calls through a PositionProxy reach these with the proxy as caller)
    function _.borrow(uint256 r, uint256 a, address onBehalfOf) external with (env e) => recordedSpokeBorrow(calledContract, e.msg.sender, r, a, onBehalfOf) expect (uint256, uint256);
    function _.withdraw(uint256 r, uint256 a, address onBehalfOf) external with (env e) => recordedSpokeWithdraw(calledContract, e.msg.sender, r, a, onBehalfOf) expect (uint256, uint256);
    function _.supply(uint256 r, uint256 a, address onBehalfOf) external with (env e) => spokeSupply(calledContract, e.msg.sender, r, a, onBehalfOf) expect (uint256, uint256);
    function _.repay(uint256 r, uint256 a, address onBehalfOf) external with (env e) => spokeRepay(calledContract, e.msg.sender, r, a, onBehalfOf) expect (uint256, uint256);
    function _.setUsingAsCollateral(uint256 r, bool on, address onBehalfOf) external => spokeSetUsingAsCollateral(calledContract, r, on, onBehalfOf) expect void;
    function _.getUserTotalDebt(uint256 r, address u) external => spokeGetUserTotalDebt(calledContract, r, u) expect uint256;
    function _.getUserAccountData(address u) external => accountData(calledContract, u) expect IAaveV4Spoke.UserAccountData;
    function _.getReserveId(address hub, uint256 assetId) external => spokeReserveIdOf(calledContract, hub, assetId) expect uint256;
    function _.getUserSuppliedShares(uint256 rid, address u) external => spokeGetUserSuppliedShares(calledContract, rid, u) expect uint256;
    function _.getAssetId(address t) external => hubAssetIdOf(calledContract, t) expect uint256;
    function _.getUserReserveStatus(uint256 rid, address u) external => spokeGetUserReserveStatus(calledContract, rid, u) expect (bool, bool);
    function _.getReserveConfig(uint256 rid) external => spokeGetReserveConfig(calledContract, rid) expect IAaveV4Spoke.ReserveConfig;
    function _.getReserve(uint256 rid) external => spokeReserveOf(calledContract, rid) expect IAaveV4Spoke.Reserve;
    function _.getReserveCount() external => spokeReserveCount(calledContract) expect uint256;
    // Receiver rule (REQ-PROXY-017): a listing on the funding Hub only refuses a borrow.
    function _.isSpokeListed(uint256, address) external => NONDET;
    function _.isUnderlyingListed(address) external => NONDET;

    // Position-manager surface of the Spoke (PositionManagerApproved): any call that reaches one of these selectors is
    // recorded. The Adapter never builds one; the rule `noPositionManagerApproval` proves no method reaches them.
    function _.setUserPositionManager(address, bool) external => positionManagerCall() expect void;
    function _.setUserPositionManagersWithSig(IAaveV4SpokePositionManagers.SetUserPositionManagers, bytes) external => positionManagerCall() expect void;
    function _.renouncePositionManagerRole(address) external => positionManagerCall() expect void;
    function _.multicall(bytes[]) external => positionManagerMulticall() expect bytes[];

    // LPVaultSwap and ParameterStore
    function _.deleverage(AaveAdapterCollateralLogic.DeleverageRequest r) external => swapDeleverage(r) expect (uint256, uint256);
    function _.minPledgeUsd(uint256) external => psRead() expect uint256;
    function _.sequencer() external => psSequencer() expect (address, uint32);
    // The sequencer-uptime feed is read by a bounded STATICCALL; any answer is allowed (a Down answer only refuses a
    // repay with collateral, which no rule here needs to pass).
    function _.latestRoundData() external => NONDET;
}

// ---------------------------------------------------------------------------------------------------------------------
// Models of this scene
// ---------------------------------------------------------------------------------------------------------------------

definition MAX_REPAY_RESERVES() returns uint256 = 4;

ghost factoryIsVaultToken(address) returns bool;
ghost factoryTokenOf(address, bytes32) returns address;
ghost vtMarketKeyOf(address) returns bytes32;
ghost vtMarketIdOf(address) returns uint256;
ghost vtIntegrationIdOf(address) returns uint32;
ghost vtSpokeOf(address) returns address;
ghost vtHubOf(address) returns address;
ghost vtIsValidProxy(address, address) returns bool;
ghost regSpokeApproved(address) returns bool;
ghost regSpokeHub(address) returns address;
ghost regMarketOf(address) returns uint256;
ghost regMarketHub(uint256) returns address;
ghost regMarketSpoke(uint256) returns address;
ghost regMarketVaultToken(uint256) returns address;
ghost regFundingHub(address, uint256) returns address;
// Collateralization's credited total per vault token, kept as the real contract keeps it (see the header).
persistent ghost mapping(address => mathint) collCredited;
ghost collPendingUnitsOf(address) returns uint256;
ghost pmProxyOf(address, address, uint256) returns address;
ghost postHealthHf(address) returns uint256;

persistent ghost mapping(address => mapping(address => uint256)) borrowCountOf;

// Pause state and reason per Hub (the MarketRegistry keys every pause by Hub).
persistent ghost mapping(address => AaveAdapterUserLogic.PauseState) hubPause;
persistent ghost mapping(address => AaveAdapterUserLogic.PauseReason) hubPauseReason;

// Step counter: each recorded call takes the next step number.
persistent ghost mathint step;
persistent ghost mathint riskCalls;
persistent ghost mathint psReads;
persistent ghost mathint tokenPulls;
persistent ghost mathint preBorrowStep;
persistent ghost address preBorrowProxy;
persistent ghost uint256 preBorrowReserve;
persistent ghost uint256 preBorrowAmount;
persistent ghost mathint preWithdrawStep;
persistent ghost address preWithdrawProxy;
persistent ghost mathint postHealthStep;
persistent ghost address postHealthProxy;
persistent ghost uint256 postHealthMinHf;
persistent ghost mathint spokeBorrowStep;
persistent ghost address spokeBorrowSpoke;
persistent ghost address spokeBorrowAccount;
persistent ghost uint256 spokeBorrowReserve;
persistent ghost mathint spokeWithdrawStep;
persistent ghost mathint lastTransferStep;
persistent ghost address lastTransferTo;
persistent ghost uint256 lastTransferAmount;
persistent ghost mathint collDebitStep;
persistent ghost mathint collPledgeCalls;
persistent ghost bool collPledgeRescue;
persistent ghost mathint deleverageCalls;
// Calls that reached the Spoke's position-manager surface (setUserPositionManager, renouncePositionManagerRole,
// multicall).
persistent ghost mathint positionManagerCalls;

function resetScene() {
    step = 0;
    riskCalls = 0;
    psReads = 0;
    tokenPulls = 0;
    preBorrowStep = 0;
    preWithdrawStep = 0;
    postHealthStep = 0;
    spokeBorrowStep = 0;
    spokeWithdrawStep = 0;
    lastTransferStep = 0;
    lastTransferTo = 0;
    collDebitStep = 0;
    collPledgeCalls = 0;
    collPledgeRescue = false;
    deleverageCalls = 0;
    positionManagerCalls = 0;
    resetRegistryReads();
    // A rule is one transaction: transient storage (the repay-with-collateral session) starts empty.
    transientStorageEmpty();
}

function nextStep() returns mathint {
    step = step + 1;
    return step;
}

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

function regSpokeDef(address s) returns AaveAdapterUserLogic.SpokeDef {
    regAnyReads = regAnyReads + 1;
    AaveAdapterUserLogic.SpokeDef d;
    require d.approved == regSpokeApproved(s) && d.hub == regSpokeHub(s);
    return d;
}

function regHubOfSpoke(address s) returns address {
    regAnyReads = regAnyReads + 1;
    return regSpokeHub(s);
}

function regMarketOfVaultToken(address vt) returns uint256 {
    regAnyReads = regAnyReads + 1;
    return regMarketOf(vt);
}

function regReceiverIntegration(address a) returns uint32 {
    regAnyReads = regAnyReads + 1;
    uint32 id;
    return id;
}

function regReceiverHub(address a) returns bool {
    regAnyReads = regAnyReads + 1;
    bool recorded;
    return recorded;
}

function regReceiverAddress() returns address {
    regAnyReads = regAnyReads + 1;
    address x;
    return x;
}

function regMarketDef(uint256 m) returns AaveAdapterUserLogic.Market {
    regAnyReads = regAnyReads + 1;
    AaveAdapterUserLogic.Market mk;
    require mk.hub == regMarketHub(m) && mk.spoke == regMarketSpoke(m) && mk.vaultToken == regMarketVaultToken(m);
    return mk;
}

function regDebtReserveDef(address s, uint256 r) returns AaveAdapterUserLogic.DebtReserveDef {
    regAnyReads = regAnyReads + 1;
    AaveAdapterUserLogic.DebtReserveDef d;
    require d.approved == regApprovedDebtReserve(s, r) && d.fundingHub == regFundingHub(s, r);
    return d;
}

// The Hub every source names for a market: the MarketRegistry's market record, its CDP Spoke's home Hub and its vault
// token's Hub agree.
function requireMarketHub(uint256 m, address hub) {
    require hub == regMarketHub(m) && regSpokeHub(regMarketSpoke(m)) == hub && vtHubOf(regMarketVaultToken(m)) == hub;
}

// A bound proxy's stored account agrees with the MarketRegistry's market record: the Adapter writes the binding once,
// in the creating pledge, from that record after checking the record's vault token against the VaultTokenFactory and
// the token's own immutables (bindingIsWrittenOnce in AaveAdapter.spec; a market's Spoke and vault token never change
// in the registry, REQ-ARCH-207).
function requireBinding(address proxy, uint256 m) {
    require proxy != 0 => (boundSpoke(proxy) == regMarketSpoke(m) && boundMarket(proxy) == m
        && boundVaultToken(proxy) == regMarketVaultToken(m));
}

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

function psRead() returns uint256 {
    psReads = psReads + 1;
    uint256 v;
    return v;
}

function psSequencer() returns (address, uint32) {
    psReads = psReads + 1;
    address feed;
    uint32 grace;
    return (feed, grace);
}

function spokeReserveOf(address spoke, uint256 rid) returns IAaveV4Spoke.Reserve {
    IAaveV4Spoke.Reserve r;
    require r.underlying == spokeUnderlyingOf(spoke, rid) && r.hub == spokeHubOf(spoke);
    return r;
}

function positionManagerCall() {
    positionManagerCalls = positionManagerCalls + 1;
}

function positionManagerMulticall() returns bytes[] {
    positionManagerCalls = positionManagerCalls + 1;
    bytes[] results;
    return results;
}

function countedTransferFrom(address t, address spender, address from, address to, uint256 a) returns bool {
    tokenPulls = tokenPulls + 1;
    return erc20TransferFrom(t, spender, from, to, a);
}

function recordedTransfer(address t, address from, address to, uint256 a) returns bool {
    lastTransferStep = nextStep();
    lastTransferTo = to;
    lastTransferAmount = a;
    return erc20Transfer(t, from, to, a);
}

function collPledge(address vt, bool rescue) returns (uint256, uint128) {
    collPledgeCalls = collPledgeCalls + 1;
    collPledgeRescue = rescue;
    uint256 id;
    uint128 credited;
    collCredited[vt] = collCredited[vt] + credited;
    return (id, credited);
}

function collRecredit(address vt, bool rescue) returns (uint128, uint128) {
    collPledgeCalls = collPledgeCalls + 1;
    collPledgeRescue = rescue;
    uint128 added;
    uint128 rescueUnits;
    collCredited[vt] = collCredited[vt] + added;
    return (added, rescueUnits);
}

function collDebit(address vt, mathint units) {
    require collCredited[vt] >= units;
    collCredited[vt] = collCredited[vt] - units;
}

function collRelease(address vt, uint256 units) {
    collDebitStep = nextStep();
    collDebit(vt, units);
}

function collReleasePartial(address vt, uint128 units) returns (uint128, uint256[]) {
    collDebitStep = nextStep();
    collDebit(vt, units);
    uint128 remaining;
    uint256[] amounts;
    return (remaining, amounts);
}

function collReleaseForDeleverage(address vt, uint128 units) returns (uint256[], bool) {
    collDebitStep = nextStep();
    collDebit(vt, units);
    uint256[] amounts;
    bool closed;
    return (amounts, closed);
}

function collReleaseZeroCredit() {
    nextStep();
}

function feesPaid() returns uint256[] {
    uint256[] fees;
    return fees;
}

function collTotalCredited(address vt) returns uint256 {
    require collCredited[vt] >= 0 && collCredited[vt] < 2^128;
    return require_uint256(collCredited[vt]);
}

function collPending(address vt) returns AaveAdapterUserLogic.Pending {
    AaveAdapterUserLogic.Pending p;
    require p.units == collPendingUnitsOf(vt);
    return p;
}

function rmPreBorrow(address p, uint256 r, uint256 a) {
    riskCalls = riskCalls + 1;
    preBorrowStep = nextStep();
    preBorrowProxy = p;
    preBorrowReserve = r;
    preBorrowAmount = a;
}

function rmPreWithdraw(address p) {
    riskCalls = riskCalls + 1;
    preWithdrawStep = nextStep();
    preWithdrawProxy = p;
}

function rmPostHealth(address p, uint256 minHf) returns uint256 {
    riskCalls = riskCalls + 1;
    postHealthStep = nextStep();
    postHealthProxy = p;
    postHealthMinHf = minHf;
    return postHealthHf(p);
}

function rmRemaining() {
    riskCalls = riskCalls + 1;
}

function pmDeploy(address w, address s, uint256 m) returns address {
    return pmProxyOf(w, s, m);
}

function recordedSpokeBorrow(address spoke, address caller, uint256 r, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    spokeBorrowStep = nextStep();
    spokeBorrowSpoke = spoke;
    spokeBorrowAccount = onBehalfOf;
    spokeBorrowReserve = r;
    uint256 drawn;
    uint256 shares;
    drawn, shares = spokeBorrow(spoke, caller, r, amount, onBehalfOf);
    return (drawn, shares);
}

function recordedSpokeWithdraw(address spoke, address caller, uint256 r, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    spokeWithdrawStep = nextStep();
    uint256 withdrawn;
    uint256 shares;
    withdrawn, shares = spokeWithdraw(spoke, caller, r, amount, onBehalfOf);
    return (withdrawn, shares);
}

function accountData(address spoke, address user) returns IAaveV4Spoke.UserAccountData {
    IAaveV4Spoke.UserAccountData d;
    require d.borrowCount == borrowCountOf[spoke][user];
    return d;
}

// LPVaultSwap.deleverage (2.11): flash-borrows the debt asset (not modelled), calls back the session's repay and release
// steps once each, in that order, as LPVaultSwap and with the request's own arguments, and sells the released tokens
// (not modelled).
function swapDeleverage(AaveAdapterCollateralLogic.DeleverageRequest r) returns (uint256, uint256) {
    deleverageCalls = deleverageCalls + 1;
    env eSwap;
    require eSwap.msg.sender == LP_VAULT_SWAP();
    uint256 amount;
    require amount > 0;
    uint256 repaid = currentContract.deleverageRepay(eSwap, r.proxy, r.debtReserveId, amount);
    uint256[] released;
    bool closed;
    released, closed = currentContract.deleverageRelease(eSwap, r.proxy, r.position, r.units, r.minAmounts);
    uint256 out;
    return (repaid, out);
}

// ---------------------------------------------------------------------------------------------------------------------
// Borrow (PROP-031 Adapter half, PROP-046, PROP-061, PROP-067 call order)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-031 verifies: INV-019, INV-023, INV-025, Q-106, Q-128, Q-161, Q-203, Q-229
// PROP-046 verifies: INV-023, Q-203, Q-229
// PROP-061 verifies: INV-073, Q-281
rule borrowEnforcesGates(uint256 marketId, uint256 r, uint256 amount, address receiver, uint256 deadline, uint256 minHf,
                         uint256 nonce, address hub, address fundingHub) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    address spoke = boundSpoke(proxy);
    requireBinding(proxy, marketId);
    requireMarketHub(marketId, hub);
    require fundingHub == regFundingHub(spoke, r);
    mathint nonceBefore = borrowNonce(proxy);
    AaveAdapterUserLogic.PauseState marketHubState = hubPause[hub];
    AaveAdapterUserLogic.PauseState fundingHubState = hubPause[fundingHub];
    bool callerFrozen = regFrozen[e.msg.sender];
    bool receiverFrozen = regFrozen[receiver];

    borrow(e, marketId, r, amount, receiver, deadline, minHf, nonce);

    assert proxy != 0 && spokeBorrowAccount == proxy && spokeBorrowSpoke == spoke && spokeBorrowReserve == r,
        "borrow acted on an account other than proxyOf[msg.sender][marketId] on its bound Spoke";
    assert nonceBefore == to_mathint(nonce) && to_mathint(borrowNonce(proxy)) == nonceBefore + 1,
        "borrow did not consume the expected nonce and raise it by exactly 1";
    assert e.block.timestamp <= deadline, "borrow ran after its deadline";
    assert amount > 0, "borrow of zero succeeded";
    assert regApprovedDebtReserve(spoke, r), "borrow named a debt reserve outside the approved set of the proxy's Spoke";
    assert receiver != 0 && lastTransferStep > spokeBorrowStep && lastTransferTo == receiver
        && lastTransferAmount == amount, "borrow paid an unchecked receiver or another amount";
    assert marketHubState == AaveAdapterUserLogic.PauseState.None && fundingHubState == AaveAdapterUserLogic.PauseState.None,
        "borrow ran while the market's Hub or the debt reserve's funding Hub was Frozen or Paused";
    assert !callerFrozen && !receiverFrozen, "borrow ran for a frozen caller or receiver";
    assert preBorrowStep > 0 && preBorrowStep < spokeBorrowStep, "preBorrowCheck did not run before the Spoke borrow";
    assert preBorrowProxy == proxy && preBorrowReserve == r && preBorrowAmount == amount,
        "preBorrowCheck ran for another account, reserve or amount";
    assert postHealthStep > spokeBorrowStep, "postHealthCheck did not run after the Spoke borrow";
    assert postHealthProxy == proxy && postHealthMinHf == minHf,
        "postHealthCheck ran for another account or without the caller's minimum";
}

// PROP-031 verifies: INV-019, Q-106
rule borrowNonceOneSuccessEach(uint256 marketId, uint256 r, uint256 a1, uint256 a2, address receiver, uint256 deadline,
                               uint256 minHf, uint256 nonce) {
    env e1;
    env e2;
    require e1.msg.sender == e2.msg.sender;
    borrow(e1, marketId, r, a1, receiver, deadline, minHf, nonce);
    borrow@withrevert(e2, marketId, r, a2, receiver, deadline, minHf, nonce);
    assert lastReverted, "two borrows succeeded with the same nonce";
}

// PROP-031 verifies: INV-019, Q-106
rule borrowNonceChangesOnlyInBorrow(method f, address proxy) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    mathint before = borrowNonce(proxy);
    f(e, args);
    mathint after = borrowNonce(proxy);
    assert after != before => (after == before + 1
        && f.selector == sig:borrow(uint256, uint256, uint256, address, uint256, uint256, uint256).selector),
        "a borrow nonce changed outside a successful borrow or by more than 1";
}

// PROP-031 verifies: INV-019, Q-106
rule borrowIsReachable(uint256 marketId, uint256 r, uint256 amount, address receiver, uint256 deadline, uint256 minHf,
                       uint256 nonce) {
    env e;
    borrow(e, marketId, r, amount, receiver, deadline, minHf, nonce);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Withdrawals and partial removals with debt (PROP-031, PROP-057, PROP-067)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-031 verifies: INV-025, Q-128, Q-161, Q-229
// PROP-067 verifies: INV-082, Q-253
rule withdrawLeavingDebtEnforcesFloor(uint256 marketId, AaveAdapter.PositionRef position, uint256 units, uint256 deadline,
                                      uint256 minHf, address hub) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    address spoke = boundSpoke(proxy);
    requireBinding(proxy, marketId);
    requireMarketHub(marketId, hub);
    require borrowCountOf[spoke][proxy] > 0;
    AaveAdapterUserLogic.PauseState state = hubPause[hub];
    bool callerFrozen = regFrozen[e.msg.sender];

    withdraw(e, marketId, position, units, deadline, minHf);

    assert state != AaveAdapterUserLogic.PauseState.Paused, "a withdrawal that leaves debt ran while the market's Hub was Paused";
    assert !callerFrozen, "a withdrawal that leaves debt ran for a frozen caller";
    assert preWithdrawStep > 0 && preWithdrawStep < spokeWithdrawStep && preWithdrawProxy == proxy,
        "preWithdrawCheck did not run for the account before the Spoke withdrawal";
    assert postHealthStep > collDebitStep && collDebitStep > 0, "postHealthCheck did not run after Collateralization's debit";
    assert postHealthProxy == proxy && postHealthMinHf == minHf, "postHealthCheck ran for another account or minimum";
}

// PROP-031 verifies: INV-025, Q-229
// PROP-067 verifies: INV-082, Q-253
rule removeLiquidityLeavingDebtEnforcesFloor(uint256 marketId, AaveAdapter.PositionRef position, uint128 units, uint256[] minAmounts,
                                             uint256 deadline, uint256 minHf, address hub) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    address spoke = boundSpoke(proxy);
    requireBinding(proxy, marketId);
    requireMarketHub(marketId, hub);
    require borrowCountOf[spoke][proxy] > 0;
    AaveAdapterUserLogic.PauseState state = hubPause[hub];
    bool callerFrozen = regFrozen[e.msg.sender];

    removeLiquidity(e, marketId, position, units, minAmounts, deadline, minHf);

    assert state != AaveAdapterUserLogic.PauseState.Paused, "a partial removal that leaves debt ran while the market's Hub was Paused";
    assert !callerFrozen, "a partial removal that leaves debt ran for a frozen caller";
    assert preWithdrawStep > 0 && preWithdrawStep < spokeWithdrawStep && preWithdrawProxy == proxy,
        "preWithdrawCheck did not run for the account before the Spoke withdrawal";
    assert postHealthStep > collDebitStep && collDebitStep > 0, "postHealthCheck did not run after Collateralization's debit";
    assert postHealthProxy == proxy && postHealthMinHf == minHf, "postHealthCheck ran for another account or minimum";
}

// ---------------------------------------------------------------------------------------------------------------------
// Exits that read nothing (PROP-032, PROP-066 Adapter half)
// ---------------------------------------------------------------------------------------------------------------------

function noPolicyRead() returns bool {
    return riskCalls == 0 && regAnyReads == 0 && psReads == 0;
}

// PROP-032 verifies: Q-122, Q-180, Q-209, Q-227, Q-230, Q-241, Q-242, Q-254, Q-260
// PROP-066 verifies: INV-030, INV-043, INV-045, INV-046, INV-067, INV-081, Q-241, Q-242, Q-260
rule repayMakesNoPolicyRead(address borrower, uint256 marketId, uint256 r, uint256 maxSpend, bool all, uint256 deadline) {
    env e;
    resetScene();
    repay(e, borrower, marketId, r, maxSpend, all, deadline);
    assert noPolicyRead(), "repay called the RiskModule or read the MarketRegistry or minPledgeUsd";
}

// PROP-032 verifies: Q-122, Q-158, Q-209, Q-227, Q-241, Q-242, Q-254, Q-260
// PROP-066 verifies: INV-043, INV-045, INV-081, Q-241, Q-242, Q-260
rule debtFreeWithdrawMakesNoPolicyRead(uint256 marketId, AaveAdapter.PositionRef position, uint256 units, uint256 deadline,
                                       uint256 minHf) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    require borrowCountOf[boundSpoke(proxy)][proxy] == 0;
    withdraw(e, marketId, position, units, deadline, minHf);
    assert noPolicyRead(), "a debt-free withdrawal called the RiskModule or read the MarketRegistry or minPledgeUsd";
}

// PROP-032 verifies: Q-122, Q-209, Q-227, Q-241, Q-242, Q-254, Q-260
// PROP-066 verifies: INV-043, INV-045, INV-081, Q-241, Q-242, Q-260
rule debtFreeRemovalMakesNoPolicyRead(uint256 marketId, AaveAdapter.PositionRef position, uint128 units, uint256[] minAmounts,
                                      uint256 deadline, uint256 minHf) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    require borrowCountOf[boundSpoke(proxy)][proxy] == 0;
    removeLiquidity(e, marketId, position, units, minAmounts, deadline, minHf);
    assert noPolicyRead(), "a debt-free partial removal called the RiskModule or read the MarketRegistry or minPledgeUsd";
}

// PROP-032 verifies: Q-180, Q-227, Q-241, Q-242, Q-260
// PROP-066 verifies: INV-043, INV-045, INV-081, Q-241, Q-242, Q-260
rule repayAllAndWithdrawMakesNoPolicyRead(uint256 marketId, AaveAdapter.PositionRef position, uint256 units, uint256[] ids,
                                          uint256[] maxes, uint256 deadline) {
    env e;
    resetScene();
    require ids.length <= MAX_REPAY_RESERVES();
    repayAllAndWithdraw(e, marketId, position, units, ids, maxes, deadline);
    assert noPolicyRead(), "repayAllAndWithdraw called the RiskModule or read the MarketRegistry or minPledgeUsd";
}

// PROP-066 verifies: INV-030, INV-081, Q-241, Q-242
rule burnSeizedMakesNoPolicyRead(uint256 marketId, address vt, uint256 units) {
    env e;
    resetScene();
    burnSeized(e, marketId, vt, units);
    assert noPolicyRead(), "burnSeized called the RiskModule or read the MarketRegistry";
}

// PROP-032 verifies: Q-180, Q-260
rule repayAtZeroDebtIsNoop(address borrower, uint256 marketId, uint256 r, uint256 maxSpend, uint256 deadline) {
    env e;
    resetScene();
    address proxy = proxyOf(borrower, marketId);
    require spokeDebt[boundSpoke(proxy)][r][proxy] == 0;
    require maxSpend > 0;

    uint256 spent = repay(e, borrower, marketId, r, maxSpend, false, deadline);

    assert spent == 0, "repay at zero debt returned a non-zero amount";
    assert tokenPulls == 0, "repay at zero debt moved a token";
}

// PROP-032 verifies: Q-180, Q-212
// Every Hub Paused(MintPathSuspect), caller and borrower frozen: repay still runs.
rule repayIsReachableInEveryPauseState(address borrower, uint256 marketId, uint256 r, uint256 maxSpend, bool all,
                                       uint256 deadline) {
    env e;
    require forall address h. hubPause[h] == AaveAdapterUserLogic.PauseState.Paused && hubPauseReason[h] == AaveAdapterUserLogic.PauseReason.MintPathSuspect;
    require regFrozen[e.msg.sender] && regFrozen[borrower];
    repay(e, borrower, marketId, r, maxSpend, all, deadline);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Pause-state effects (PROP-057)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-057 verifies: INV-043, INV-044, INV-045, INV-046, INV-049, INV-050, INV-067, Q-227, Q-252, Q-254
rule pledgePauseEffects(uint256 marketId, AaveAdapter.PositionRef position, uint256 deadline, address hub) {
    env e;
    resetScene();
    requireMarketHub(marketId, hub);
    AaveAdapterUserLogic.PauseState state = hubPause[hub];
    AaveAdapterUserLogic.PauseReason reason = hubPauseReason[hub];
    address proxyBefore = proxyOf(e.msg.sender, marketId);
    requireBinding(proxyBefore, marketId);
    bool callerFrozen = regFrozen[e.msg.sender];
    bool noDebt = proxyBefore == 0 || borrowCountOf[regMarketSpoke(marketId)][proxyBefore] == 0;

    pledge(e, marketId, position, deadline);

    assert !(state == AaveAdapterUserLogic.PauseState.Frozen && noDebt), "a pledge by an account with no debt ran while the market's Hub was Frozen";
    assert !(state == AaveAdapterUserLogic.PauseState.Paused && reason == AaveAdapterUserLogic.PauseReason.MintPathSuspect),
        "a pledge ran while the market's Hub was Paused(MintPathSuspect)";
    assert collPledgeCalls == 1, "pledge did not call Collateralization.pledge exactly once";
    assert ((state == AaveAdapterUserLogic.PauseState.Paused && reason == AaveAdapterUserLogic.PauseReason.General) || callerFrozen) => collPledgeRescue,
        "a pledge under Paused(General) or by a frozen caller was not limited to a rescue top-up";
}

// PROP-057 verifies: INV-043, INV-044, INV-046, INV-049, INV-067, Q-227, Q-252, Q-254
rule recreditPauseEffects(uint256 marketId, AaveAdapter.PositionRef position, bytes topUp, uint256 deadline, address hub) {
    env e;
    resetScene();
    requireMarketHub(marketId, hub);
    AaveAdapterUserLogic.PauseState state = hubPause[hub];
    AaveAdapterUserLogic.PauseReason reason = hubPauseReason[hub];
    address proxy = proxyOf(e.msg.sender, marketId);
    requireBinding(proxy, marketId);
    bool callerFrozen = regFrozen[e.msg.sender];
    bool noDebt = borrowCountOf[boundSpoke(proxy)][proxy] == 0;

    recredit(e, marketId, position, topUp, deadline);

    assert !(state == AaveAdapterUserLogic.PauseState.Frozen && noDebt), "a re-credit for an account with no debt ran while the market's Hub was Frozen";
    assert !(state == AaveAdapterUserLogic.PauseState.Paused && reason == AaveAdapterUserLogic.PauseReason.MintPathSuspect),
        "a re-credit ran while the market's Hub was Paused(MintPathSuspect)";
    assert ((state == AaveAdapterUserLogic.PauseState.Paused && reason == AaveAdapterUserLogic.PauseReason.General) || callerFrozen) => collPledgeRescue,
        "a re-credit under Paused(General) or by a frozen caller was not limited to a rescue top-up";
}

// A Frozen market Hub admits a top-up of an indebted account (no rescue requirement).
// PROP-057 verifies: INV-044, Q-227
rule topUpIsReachableWhileFrozen(uint256 marketId, AaveAdapter.PositionRef position, uint256 deadline, address hub) {
    env e;
    requireMarketHub(marketId, hub);
    require hubPause[hub] == AaveAdapterUserLogic.PauseState.Frozen;
    address proxy = proxyOf(e.msg.sender, marketId);
    requireBinding(proxy, marketId);
    require proxy != 0 && borrowCountOf[boundSpoke(proxy)][proxy] > 0;
    pledge(e, marketId, position, deadline);
    satisfy true;
}

// A rescue top-up while the market's Hub is Paused(General) is reachable.
// PROP-057 verifies: INV-067, Q-252
rule rescueTopUpIsReachableUnderGeneralPause(uint256 marketId, AaveAdapter.PositionRef position, uint256 deadline, address hub) {
    env e;
    requireMarketHub(marketId, hub);
    require hubPause[hub] == AaveAdapterUserLogic.PauseState.Paused && hubPauseReason[hub] == AaveAdapterUserLogic.PauseReason.General;
    pledge(e, marketId, position, deadline);
    satisfy collPledgeRescue;
}

// PROP-057 verifies: INV-043, INV-049, INV-050, Q-227, Q-255
rule repayWithCollateralRefusesMintPathPause(AaveAdapter.RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    requireBinding(proxyOf(e.msg.sender, p.marketId), p.marketId);
    require hubPause[hub] == AaveAdapterUserLogic.PauseState.Paused && hubPauseReason[hub] == AaveAdapterUserLogic.PauseReason.MintPathSuspect;
    repayWithCollateral@withrevert(e, p);
    assert lastReverted, "repayWithCollateral ran while the market's Hub was Paused(MintPathSuspect)";
}

// PROP-057 verifies: INV-043, INV-049, Q-227, Q-255
rule repayWithCollateralIsReachableUnderGeneralPause(AaveAdapter.RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    requireBinding(proxyOf(e.msg.sender, p.marketId), p.marketId);
    require hubPause[hub] == AaveAdapterUserLogic.PauseState.Paused && hubPauseReason[hub] == AaveAdapterUserLogic.PauseReason.General;
    repayWithCollateral(e, p);
    satisfy deleverageCalls == 1;
}

// PROP-057 verifies: INV-043, INV-049, Q-227, Q-255
rule repayWithCollateralIsReachableWhileFrozen(AaveAdapter.RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    requireBinding(proxyOf(e.msg.sender, p.marketId), p.marketId);
    require hubPause[hub] == AaveAdapterUserLogic.PauseState.Frozen;
    repayWithCollateral(e, p);
    satisfy deleverageCalls == 1;
}

// ---------------------------------------------------------------------------------------------------------------------
// PositionManagerApproved by construction (REQ-PROXY-008, REQ-RISK-088)
// ---------------------------------------------------------------------------------------------------------------------

// No Adapter method, whatever its arguments and caller, reaches the Spoke's position-manager surface: every call a
// proxy makes is one the Adapter builds through `execute` (dispatched to the real PositionProxy), and the Adapter's
// own calls are summarised, so a call with one of these selectors from any contract of the scene would reach
// `positionManagerCall` and be counted. The struct of `setUserPositionManagersWithSig` comes into the scene through
// `AaveAdapterSpokeTypesHarness`, a stateless contract that is never called. The selector-allowlist tests
// (AaveAdapter.Access.unit.t.sol) check the same set on the compiled code and on every call a proxy makes.
rule noPositionManagerApproval(method f) filtered { f -> f.contract == currentContract } {
    env e;
    calldataarg args;
    resetScene();

    f(e, args);

    assert positionManagerCalls == 0,
        "an Adapter method reached a Spoke's position-manager approval, renouncement or multicall";
}
