/*
 * AaveAdapter gates and call graph (planned src/policy/aave-adapter/AaveAdapter.sol, interface
 * src/policy/aave-adapter/IAaveAdapter.sol, spec 2.6). Conf: AaveAdapterGates.conf. The Adapter's backing, mint and
 * burn, proxy-binding and role rules are in AaveAdapter.spec (AaveAdapter.conf).
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
 *
 * Storage: the Adapter's `borrowNonce`, `proxyOf` and `accountOf` are read through their views; no hooks.
 *
 * Summaries: the Lock by LockModel; the MarketRegistry by RegistryModel's freeze, breaker and debt-reserve reads plus
 * a pause state and reason per Hub, with every other registry view (market, Spoke, debt reserve, Hub of a Spoke)
 * counted as a read; the RiskModule's checks recorded with their arguments and a step number (the RiskModule's own
 * behaviour is proved on the RiskModule); Collateralization's `pledge`, `recredit`, `release`, `releasePartial`,
 * `releaseZeroCredit` and `collectFees` recorded with the `requireRescue` flag and a step number, returning arbitrary
 * values; a PositionProxy's `execute` is dispatched to the real logic-free PositionProxy, so each Spoke call the
 * Adapter makes through a proxy reaches the Aave model with the proxy as caller, and `borrow` and `withdraw` on the
 * Spoke are recorded with a step number, the Spoke and the account; the Spoke's `getUserAccountData` returns a ghost
 * borrow count per account, which no summarised call changes within a rule; vault tokens and ERC-20s by Erc20Model
 * with every `transferFrom` counted and the last `transfer` recorded; the ProxyManager, VaultTokenFactory, the
 * LPVault's `collectFees` and LPVaultSwap `deleverage` are uninterpreted or recorded; ParameterStore reads are counted.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/AaveModel.spec";
import "setup/RegistryModel.spec";

methods {
    function borrow(uint256, uint256, uint256, address, uint256, uint256, uint256) external returns (uint256);
    function withdraw(uint256, PositionRef, uint256, uint256, uint256) external;
    function removeLiquidity(uint256, PositionRef, uint128, uint256[], uint256, uint256) external returns (uint256[]);
    function repay(address, uint256, uint256, uint256, bool, uint256) external returns (uint256);
    function repayAllAndWithdraw(uint256, PositionRef, uint256, uint256[], uint256[], uint256) external;
    function pledge(uint256, PositionRef, uint256) external returns (address, uint256, uint128);
    function recredit(uint256, PositionRef, bytes, uint256) external returns (uint128);
    function repayWithCollateral(RepayWithCollateralParams) external returns (uint256, uint256);
    function burnSeized(uint256, address, uint256) external;
    function borrowNonce(address) external returns (uint256) envfree;
    function proxyOf(address, uint256) external returns (address) envfree;
    function accountOf(address) external returns (address, uint256, address, uint256) envfree;

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;

    // MarketRegistry
    function _.pauseState(address hub) external => registryHubPauseState(hub) expect PauseState;
    function _.pauseReason(address hub) external => registryHubPauseReason(hub) expect PauseReason;
    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
    function _.marketBreaker(uint256 m) external => registryMarketBreaker(m) expect (uint32, uint64);
    function _.debtBreaker(address s, uint256 r) external => registryDebtBreaker(s, r) expect (uint32, uint64);
    function _.isApprovedDebtReserve(address s, uint256 r) external => registryApprovedDebtReserve(s, r) expect bool;
    function _.getSpoke(address s) external => regSpokeDef(s) expect SpokeDef;
    function _.hubOf(address s) external => regHubOfSpoke(s) expect address;
    function _.marketOfVaultToken(address vt) external => regMarketOfVaultToken(vt) expect uint256;
    function _.getMarket(uint256 m) external => regMarketDef(m) expect Market;
    function _.getDebtReserve(address s, uint256 r) external => regDebtReserveDef(s, r) expect DebtReserveDef;

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
    function _.pledge(address d, address p, address vt, bytes32 key, bool rescue) external => collPledge(rescue) expect (uint256, uint128);
    function _.recredit(address d, address p, address vt, bytes32 key, bytes topUp, bool rescue) external => collRecredit(rescue) expect (uint128, uint128);
    function _.release(address p, address vt, bytes32 key, uint256 u) external => collRelease() expect void;
    function _.releasePartial(address p, address vt, bytes32 key, uint128 u, uint256[] mins) external => collReleasePartial() expect (uint128, uint256[]);
    function _.releaseZeroCredit(address d, address vt, bytes32 key) external => collReleaseZeroCredit() expect void;
    function _.collectFees(address d, address vt, bytes32 key) external => feesPaid() expect uint256[];
    function _.getTotalCredited(address vt) external => collTotalCredited(vt) expect uint256;
    function _.getPending(address vt) external => collPending(vt) expect Pending;

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

    // LPVaultSwap and ParameterStore
    function _.deleverage(DeleverageRequest) external => swapDeleverage() expect (uint256, uint256);
    function _.minPledgeUsd(uint256) external => psRead() expect uint256;
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
ghost collTotalCreditedOf(address) returns uint256;
ghost collPendingUnitsOf(address) returns uint256;
ghost pmProxyOf(address, address, uint256) returns address;
ghost postHealthHf(address) returns uint256;

persistent ghost mapping(address => mapping(address => uint256)) borrowCountOf;

// Pause state and reason per Hub (the MarketRegistry keys every pause by Hub).
persistent ghost mapping(address => PauseState) hubPause;
persistent ghost mapping(address => PauseReason) hubPauseReason;

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
    resetRegistryReads();
}

function nextStep() returns mathint {
    step = step + 1;
    return step;
}

function registryHubPauseState(address hub) returns PauseState {
    regPauseStateReads = regPauseStateReads + 1;
    regAnyReads = regAnyReads + 1;
    // pauseReason(hub) == None exactly when the Hub is not Paused (PROP-041).
    require (hubPause[hub] == PauseState.Paused) == (hubPauseReason[hub] != PauseReason.None);
    return hubPause[hub];
}

function registryHubPauseReason(address hub) returns PauseReason {
    regPauseReasonReads = regPauseReasonReads + 1;
    regAnyReads = regAnyReads + 1;
    require (hubPause[hub] == PauseState.Paused) == (hubPauseReason[hub] != PauseReason.None);
    return hubPauseReason[hub];
}

function regSpokeDef(address s) returns SpokeDef {
    regAnyReads = regAnyReads + 1;
    SpokeDef d;
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

function regMarketDef(uint256 m) returns Market {
    regAnyReads = regAnyReads + 1;
    Market mk;
    require mk.hub == regMarketHub(m) && mk.spoke == regMarketSpoke(m) && mk.vaultToken == regMarketVaultToken(m);
    return mk;
}

function regDebtReserveDef(address s, uint256 r) returns DebtReserveDef {
    regAnyReads = regAnyReads + 1;
    DebtReserveDef d;
    require d.approved == regApprovedDebtReserve(s, r) && d.fundingHub == regFundingHub(s, r);
    return d;
}

// The Hub every source names for a market: the MarketRegistry's market record, its CDP Spoke's home Hub and its vault
// token's Hub agree.
function requireMarketHub(uint256 m, address hub) {
    require hub == regMarketHub(m) && regSpokeHub(regMarketSpoke(m)) == hub && vtHubOf(regMarketVaultToken(m)) == hub;
}

// A bound proxy's stored account agrees with the MarketRegistry's market record.
function requireBinding(address proxy, uint256 m) {
    require proxy != 0 => (boundSpoke(proxy) == regMarketSpoke(m) && boundMarket(proxy) == m);
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

function psRead() returns uint256 {
    psReads = psReads + 1;
    uint256 v;
    return v;
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

function collPledge(bool rescue) returns (uint256, uint128) {
    collPledgeCalls = collPledgeCalls + 1;
    collPledgeRescue = rescue;
    uint256 id;
    uint128 credited;
    return (id, credited);
}

function collRecredit(bool rescue) returns (uint128, uint128) {
    collPledgeCalls = collPledgeCalls + 1;
    collPledgeRescue = rescue;
    uint128 added;
    uint128 rescueUnits;
    return (added, rescueUnits);
}

function collRelease() {
    collDebitStep = nextStep();
}

function collReleasePartial() returns (uint128, uint256[]) {
    collDebitStep = nextStep();
    uint128 remaining;
    uint256[] amounts;
    return (remaining, amounts);
}

function collReleaseZeroCredit() {
    nextStep();
}

function feesPaid() returns uint256[] {
    uint256[] fees;
    return fees;
}

function collTotalCredited(address vt) returns uint256 {
    return collTotalCreditedOf(vt);
}

function collPending(address vt) returns Pending {
    Pending p;
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

function swapDeleverage() returns (uint256, uint256) {
    deleverageCalls = deleverageCalls + 1;
    uint256 repaid;
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
    PauseState marketHubState = hubPause[hub];
    PauseState fundingHubState = hubPause[fundingHub];
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
    assert marketHubState == PauseState.None && fundingHubState == PauseState.None,
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
rule withdrawLeavingDebtEnforcesFloor(uint256 marketId, PositionRef position, uint256 units, uint256 deadline,
                                      uint256 minHf, address hub) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    address spoke = boundSpoke(proxy);
    requireBinding(proxy, marketId);
    requireMarketHub(marketId, hub);
    require borrowCountOf[spoke][proxy] > 0;
    PauseState state = hubPause[hub];
    bool callerFrozen = regFrozen[e.msg.sender];

    withdraw(e, marketId, position, units, deadline, minHf);

    assert state != PauseState.Paused, "a withdrawal that leaves debt ran while the market's Hub was Paused";
    assert !callerFrozen, "a withdrawal that leaves debt ran for a frozen caller";
    assert preWithdrawStep > 0 && preWithdrawStep < spokeWithdrawStep && preWithdrawProxy == proxy,
        "preWithdrawCheck did not run for the account before the Spoke withdrawal";
    assert postHealthStep > collDebitStep && collDebitStep > 0, "postHealthCheck did not run after Collateralization's debit";
    assert postHealthProxy == proxy && postHealthMinHf == minHf, "postHealthCheck ran for another account or minimum";
}

// PROP-031 verifies: INV-025, Q-229
// PROP-067 verifies: INV-082, Q-253
rule removeLiquidityLeavingDebtEnforcesFloor(uint256 marketId, PositionRef position, uint128 units, uint256[] minAmounts,
                                             uint256 deadline, uint256 minHf, address hub) {
    env e;
    resetScene();
    address proxy = proxyOf(e.msg.sender, marketId);
    address spoke = boundSpoke(proxy);
    requireBinding(proxy, marketId);
    requireMarketHub(marketId, hub);
    require borrowCountOf[spoke][proxy] > 0;
    PauseState state = hubPause[hub];
    bool callerFrozen = regFrozen[e.msg.sender];

    removeLiquidity(e, marketId, position, units, minAmounts, deadline, minHf);

    assert state != PauseState.Paused, "a partial removal that leaves debt ran while the market's Hub was Paused";
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
rule debtFreeWithdrawMakesNoPolicyRead(uint256 marketId, PositionRef position, uint256 units, uint256 deadline,
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
rule debtFreeRemovalMakesNoPolicyRead(uint256 marketId, PositionRef position, uint128 units, uint256[] minAmounts,
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
rule repayAllAndWithdrawMakesNoPolicyRead(uint256 marketId, PositionRef position, uint256 units, uint256[] ids,
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
    require forall address h. hubPause[h] == PauseState.Paused && hubPauseReason[h] == PauseReason.MintPathSuspect;
    require regFrozen[e.msg.sender] && regFrozen[borrower];
    repay(e, borrower, marketId, r, maxSpend, all, deadline);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Pause-state effects (PROP-057)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-057 verifies: INV-043, INV-044, INV-045, INV-046, INV-049, INV-050, INV-067, Q-227, Q-252, Q-254
rule pledgePauseEffects(uint256 marketId, PositionRef position, uint256 deadline, address hub) {
    env e;
    resetScene();
    requireMarketHub(marketId, hub);
    PauseState state = hubPause[hub];
    PauseReason reason = hubPauseReason[hub];
    address proxyBefore = proxyOf(e.msg.sender, marketId);
    requireBinding(proxyBefore, marketId);
    bool callerFrozen = regFrozen[e.msg.sender];
    bool noDebt = proxyBefore == 0 || borrowCountOf[regMarketSpoke(marketId)][proxyBefore] == 0;

    pledge(e, marketId, position, deadline);

    assert !(state == PauseState.Frozen && noDebt), "a pledge by an account with no debt ran while the market's Hub was Frozen";
    assert !(state == PauseState.Paused && reason == PauseReason.MintPathSuspect),
        "a pledge ran while the market's Hub was Paused(MintPathSuspect)";
    assert collPledgeCalls == 1, "pledge did not call Collateralization.pledge exactly once";
    assert ((state == PauseState.Paused && reason == PauseReason.General) || callerFrozen) => collPledgeRescue,
        "a pledge under Paused(General) or by a frozen caller was not limited to a rescue top-up";
}

// PROP-057 verifies: INV-043, INV-044, INV-046, INV-049, INV-067, Q-227, Q-252, Q-254
rule recreditPauseEffects(uint256 marketId, PositionRef position, bytes topUp, uint256 deadline, address hub) {
    env e;
    resetScene();
    requireMarketHub(marketId, hub);
    PauseState state = hubPause[hub];
    PauseReason reason = hubPauseReason[hub];
    address proxy = proxyOf(e.msg.sender, marketId);
    requireBinding(proxy, marketId);
    bool callerFrozen = regFrozen[e.msg.sender];
    bool noDebt = borrowCountOf[boundSpoke(proxy)][proxy] == 0;

    recredit(e, marketId, position, topUp, deadline);

    assert !(state == PauseState.Frozen && noDebt), "a re-credit for an account with no debt ran while the market's Hub was Frozen";
    assert !(state == PauseState.Paused && reason == PauseReason.MintPathSuspect),
        "a re-credit ran while the market's Hub was Paused(MintPathSuspect)";
    assert ((state == PauseState.Paused && reason == PauseReason.General) || callerFrozen) => collPledgeRescue,
        "a re-credit under Paused(General) or by a frozen caller was not limited to a rescue top-up";
}

// A Frozen market Hub admits a top-up of an indebted account (no rescue requirement).
// PROP-057 verifies: INV-044, Q-227
rule topUpIsReachableWhileFrozen(uint256 marketId, PositionRef position, uint256 deadline, address hub) {
    env e;
    requireMarketHub(marketId, hub);
    require hubPause[hub] == PauseState.Frozen;
    address proxy = proxyOf(e.msg.sender, marketId);
    requireBinding(proxy, marketId);
    require proxy != 0 && borrowCountOf[boundSpoke(proxy)][proxy] > 0;
    pledge(e, marketId, position, deadline);
    satisfy true;
}

// A rescue top-up while the market's Hub is Paused(General) is reachable.
// PROP-057 verifies: INV-067, Q-252
rule rescueTopUpIsReachableUnderGeneralPause(uint256 marketId, PositionRef position, uint256 deadline, address hub) {
    env e;
    requireMarketHub(marketId, hub);
    require hubPause[hub] == PauseState.Paused && hubPauseReason[hub] == PauseReason.General;
    pledge(e, marketId, position, deadline);
    satisfy collPledgeRescue;
}

// PROP-057 verifies: INV-043, INV-049, INV-050, Q-227, Q-255
rule repayWithCollateralRefusesMintPathPause(RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    require hubPause[hub] == PauseState.Paused && hubPauseReason[hub] == PauseReason.MintPathSuspect;
    repayWithCollateral@withrevert(e, p);
    assert lastReverted, "repayWithCollateral ran while the market's Hub was Paused(MintPathSuspect)";
}

// PROP-057 verifies: INV-043, INV-049, Q-227, Q-255
rule repayWithCollateralIsReachableUnderGeneralPause(RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    require hubPause[hub] == PauseState.Paused && hubPauseReason[hub] == PauseReason.General;
    repayWithCollateral(e, p);
    satisfy deleverageCalls == 1;
}

// PROP-057 verifies: INV-043, INV-049, Q-227, Q-255
rule repayWithCollateralIsReachableWhileFrozen(RepayWithCollateralParams p, address hub) {
    env e;
    requireMarketHub(p.marketId, hub);
    require hubPause[hub] == PauseState.Frozen;
    repayWithCollateral(e, p);
    satisfy deleverageCalls == 1;
}
