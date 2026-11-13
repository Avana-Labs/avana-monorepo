/*
 * Collateralization (src/custody/collateralization/Collateralization.sol, interface
 * src/custody/collateralization/ICollateralization.sol, spec 2.3).
 *
 * The chain's one AMM-neutral backing ledger: records keyed by (integrationId, positionKey), the per-account and
 * per-market credited totals, the pending-settlement balance, the seizure list, the exposure counters, rescue units,
 * reconcile on exit, the seizure debit, pending settlement, partial removal, re-credit and the deleverage release, and
 * the lock and caller checks of every entry point. Collateralization is immutable, holds no position and has no mint
 * power: the AaveAdapter mints and burns, and each market's LPVault (the registered AMM integration of the vault
 * token's `integrationId()`) holds the positions.
 *
 * Storage assumption: hooks and direct reads use these names: `records` (`mapping(uint256 recordId =>
 * BackingRecord)`, fields as declared in types/BackingRecord.sol: `positionKey`, `depositor`, `integrationId`,
 * `marketId`, `inList`, `proxy`, `credited`, `originalUnits`, `rescueUnits`, `originalUsdCharge`, `currentUsdCharge`);
 * `_recordIdOf` (`mapping(uint32 integrationId => mapping(bytes32 positionKey => uint256))`); `_nextRecordId`;
 * `seizureList` (`mapping(address proxy => mapping(address vaultToken => uint256[]))`, the record IDs of the
 * account-market's seizure list in list order) and `zeroCreditList` (its records at 0 credited units; the two hold at most 16
 * together); `accountCredited`, `totalCredited`, `accountRescueUnits`
 * and `pending` keyed by vault token, `Pending` fields `units` and `amounts` (pool order); `marketUsd` keyed by
 * vault token and `Collateralization.Bucket`; `tokenUsd` and `depositorUsd` keyed by Hub. Plain storage. Views revert
 * while another member holds the Lock (REQ-VAULT-091), so rules read state directly.
 *
 * Summaries (certora/README.md): every LPVault by the custody model below, keyed by (LPVault, positionKey), whose own
 * behaviour is proved on the real LPVault in LPVault.spec: `receivePosition` pulls the position from its owner and
 * records the depositor, `returnPosition` returns it only to the depositor of record, `unwind` removes exactly the
 * units asked and pays the principal to the named recipient, `releaseToDepositor` does the same for the depositor of
 * record, `topUpPosition` adds arbitrary liquidity to a held position, `unitsOf` returns the live units, `collectFees` pays only the depositor of record, `marketOf` returns the
 * market's tokens and `checkReadSafe` is NONDET (the pool-lock check can only add reverts); a payout raises only the
 * recipient's pool-token balances, by arbitrary amounts. Vault tokens and pool tokens by the ERC-20 model, so the
 * vault-token supply is the model's ghost, which only Adapter mints and burns change (PROP-005, VaultToken.spec); the
 * Spoke and Hub by the Aave model; the Lock by its model; the RiskModule's `checkPledge` returns an arbitrary charge
 * and counts the call (any RiskModule implementation: every rule here must survive a hostile upgrade of it); the
 * LPOracle's `poke` is NONDET; the vault-token immutables and the VaultTokenFactory's registries are uninterpreted
 * functions. The factory registers one vault token per market and one LPVault per integration, so `vtMarketIdOf` and
 * the registered LPVaults are injective; a vault token's Hub is its market's Hub.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/AaveModel.spec";

methods {
    // Collateralization
    function ADAPTER() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function RISK_MODULE() external returns (address) envfree;
    function LOCK() external returns (address) envfree;
    function VAULT_TOKEN_FACTORY() external returns (address) envfree;
    function pledge(address, address, address, bytes32, bool) external returns (uint256, uint128);
    function recredit(address, address, address, bytes32, bytes, bool) external returns (uint128, uint128);
    function release(address, address, bytes32, uint256) external;
    function releasePartial(address, address, bytes32, uint128, uint256[]) external returns (uint128, uint256[]);
    function releaseForDeleverage(address, address, bytes32, uint128, uint256[]) external returns (uint256[], bool);
    function releaseZeroCredit(address, address, bytes32) external;
    function collectFees(address, address, bytes32) external returns (uint256[]);
    function beginSeizure(address, address) external;
    function settleSeizure(address, address, uint256, uint256[]) external returns (uint256[]);
    function settlePending(address, uint256) external returns (uint256[]);

    // Pool tokens and vault tokens (ERC-20 model)
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.totalSupply() external => erc20TotalSupply(calledContract) expect uint256;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;

    // Vault-token immutables and the VaultTokenFactory registries
    function _.hub() external => vtHubOf(calledContract) expect address;
    function _.spoke() external => vtSpokeOf(calledContract) expect address;
    function _.marketId() external => vtMarketIdOf(calledContract) expect uint256;
    function _.integrationId() external => vtIntegrationIdOf(calledContract) expect uint32;
    function _.integration() external => vtIntegrationOf(calledContract) expect address;
    function _.lpOracle() external => vtLpOracleOf(calledContract) expect address;
    function _.isValidProxy(address p) external => vtIsValidProxy(calledContract, p) expect bool;
    function _.isVaultToken(address v) external => factoryIsVaultToken(v) expect bool;
    function _.lpVaultOf(uint32 i) external => factoryLpVaultOf(i) expect address;

    // LPVault (custody model)
    function _.receivePosition(uint256 m, address owner, bytes32 k) external => lpvReceive(calledContract, owner, k) expect uint128;
    function _.returnPosition(bytes32 k) external => lpvReturn(calledContract, k) expect address;
    function _.unwind(bytes32 k, uint128 u, uint256[] mins, address to) external => lpvUnwind(calledContract, k, u, to) expect uint256[];
    function _.releaseToDepositor(bytes32 k, uint128 u, uint256[] mins) external => lpvReleaseToDepositor(calledContract, k, u) expect uint256[];
    function _.unitsOf(bytes32 k) external => lpvUnitsOf(calledContract, k) expect uint128;
    function _.collectFees(bytes32 k, address d) external => lpvCollectFees(calledContract, k, d) expect uint256[];
    function _.marketOf(uint256 m) external => lpvMarketOf(m) expect (address, bytes32, Collateralization.PositionShape, address[]);
    function _.checkReadSafe(uint256 m) external => NONDET;
    function _.topUpPosition(bytes32 k, address owner, bytes data) external => lpvTopUp(calledContract, k) expect uint128;

    // Aave V4 Spoke and Hub
    function _.getUserSuppliedShares(uint256 rid, address u) external => spokeGetUserSuppliedShares(calledContract, rid, u) expect uint256;
    function _.getReserveId(address hub, uint256 assetId) external => spokeReserveIdOf(calledContract, hub, assetId) expect uint256;
    function _.getAssetId(address t) external => hubAssetIdOf(calledContract, t) expect uint256;
    function _.getAddedAssets(uint256 a) external => hubGetAddedAssets(calledContract, a) expect uint256;
    function _.getAddedShares(uint256 a) external => hubGetAddedShares(calledContract, a) expect uint256;

    // Policy: any RiskModule; the LPOracle poke
    function _.checkPledge(address d, address p, uint256 m, uint32 i, bytes32 k, uint128 u, Collateralization.PledgeCounters c, bool rr) external => policyCharge(u, rr) expect Collateralization.PledgeCharge;
    function _.poke() external => NONDET;

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
}

// ---------------------------------------------------------------------------------------------------------------------
// External models of the Collateralization scene
// ---------------------------------------------------------------------------------------------------------------------

ghost vtSpokeOf(address) returns address;
ghost vtIntegrationIdOf(address) returns uint32;
ghost vtIntegrationOf(address) returns address;
ghost vtLpOracleOf(address) returns address;
ghost vtIsValidProxy(address, address) returns bool;
ghost factoryIsVaultToken(address) returns bool;

// One vault token per market.
ghost vtMarketIdOf(address) returns uint256 {
    axiom forall address a. forall address b. vtMarketIdOf(a) == vtMarketIdOf(b) => a == b;
}

// One LPVault per integration.
ghost factoryLpVaultOf(uint32) returns address {
    axiom forall uint32 i. forall uint32 j. (factoryLpVaultOf(i) == factoryLpVaultOf(j) && factoryLpVaultOf(i) != 0) => i == j;
}

// The Hub of a market; a vault token's Hub is its market's Hub.
ghost marketHubOf(uint256) returns address;

// The tokens of a market in pool order: `marketTokenCount(m)` tokens (2 to 8), distinct, `marketTokenIndex` is the
// position of a token in that order.
ghost marketTokenCount(uint256) returns uint256 {
    axiom forall uint256 m. marketTokenCount(m) >= 2 && marketTokenCount(m) <= 8;
}
ghost marketTokenAt(uint256, uint256) returns address;
ghost marketTokenIndex(uint256, address) returns uint256 {
    axiom forall uint256 m. forall uint256 i. i < marketTokenCount(m) => marketTokenIndex(m, marketTokenAt(m, i)) == i;
}

definition marketHasToken(uint256 m, address t) returns bool =
    marketTokenIndex(m, t) < marketTokenCount(m) && marketTokenAt(m, marketTokenIndex(m, t)) == t;

function vtHubOf(address vt) returns address {
    return marketHubOf(vtMarketIdOf(vt));
}

// LPVault custody model, keyed by (LPVault, positionKey): the address holding the position, the depositor of record
// (LPVault.depositorOf) and the live units.
persistent ghost mapping(address => mapping(bytes32 => address)) posHolder;
persistent ghost mapping(address => mapping(bytes32 => address)) lvDepositor;
persistent ghost mapping(address => mapping(bytes32 => mathint)) posUnits;

// Bookkeeping of the current call.
persistent ghost mathint policyCalls;
persistent ghost mathint positionReturns;
persistent ghost address lastPositionReturnedTo;
persistent ghost mathint unitsRemoved;
persistent ghost mathint removalsToOthers;
persistent ghost address removalRecipient;
persistent ghost mathint debitedInCall;
persistent ghost mathint partialDebitsInCall;
persistent ghost mathint creditIncreasesInCall;

// A payout raises only the recipient's balances, by arbitrary amounts.
function payOut(address to) {
    havoc erc20Bal assuming forall address t. forall address a.
        (a != to => erc20Bal@new[t][a] == erc20Bal@old[t][a]) && erc20Bal@new[t][to] >= erc20Bal@old[t][to];
}

function lpvReceive(address lpv, address owner, bytes32 k) returns uint128 {
    require posHolder[lpv][k] == owner && owner != lpv;
    posHolder[lpv][k] = lpv;
    lvDepositor[lpv][k] = owner;
    require posUnits[lpv][k] > 0 && posUnits[lpv][k] <= max_uint128;
    return require_uint128(posUnits[lpv][k]);
}

function lpvReturn(address lpv, bytes32 k) returns address {
    address d = lvDepositor[lpv][k];
    require d != 0 && posHolder[lpv][k] == lpv;
    posHolder[lpv][k] = d;
    lvDepositor[lpv][k] = 0;
    positionReturns = positionReturns + 1;
    lastPositionReturnedTo = d;
    return d;
}

function lpvRemove(address lpv, bytes32 k, uint128 u, address to) returns uint256[] {
    require posHolder[lpv][k] == lpv && lvDepositor[lpv][k] != 0;
    require to != 0 && to != lpv;
    require posUnits[lpv][k] >= to_mathint(u);
    posUnits[lpv][k] = posUnits[lpv][k] - u;
    unitsRemoved = unitsRemoved + u;
    if (to != removalRecipient) {
        removalsToOthers = removalsToOthers + 1;
    }
    payOut(to);
    uint256[] amounts;
    return amounts;
}

function lpvUnwind(address lpv, bytes32 k, uint128 u, address to) returns uint256[] {
    return lpvRemove(lpv, k, u, to);
}

function lpvReleaseToDepositor(address lpv, bytes32 k, uint128 u) returns uint256[] {
    return lpvRemove(lpv, k, u, lvDepositor[lpv][k]);
}

// A re-credit top-up adds an arbitrary amount of liquidity (pulled from the depositor) to the held position; the
// re-credit then credits the live units it reads next, not this report.
function lpvTopUp(address lpv, bytes32 k) returns uint128 {
    require posHolder[lpv][k] == lpv && lvDepositor[lpv][k] != 0;
    uint128 addedUnits;
    require posUnits[lpv][k] + addedUnits <= max_uint128;
    posUnits[lpv][k] = posUnits[lpv][k] + addedUnits;
    return addedUnits;
}

function lpvUnitsOf(address lpv, bytes32 k) returns uint128 {
    require posHolder[lpv][k] == lpv && lvDepositor[lpv][k] != 0;
    require posUnits[lpv][k] >= 0 && posUnits[lpv][k] <= max_uint128;
    return require_uint128(posUnits[lpv][k]);
}

function lpvCollectFees(address lpv, bytes32 k, address d) returns uint256[] {
    require d != 0 && lvDepositor[lpv][k] == d;
    payOut(d);
    uint256[] amounts;
    return amounts;
}

function lpvMarketOf(uint256 m) returns (address, bytes32, Collateralization.PositionShape, address[]) {
    address pool;
    bytes32 poolId;
    Collateralization.PositionShape shape;
    address[] tokens;
    uint256 n = marketTokenCount(m);
    require tokens.length == n;
    require tokens[0] == marketTokenAt(m, 0) && tokens[1] == marketTokenAt(m, 1);
    require n > 2 => tokens[2] == marketTokenAt(m, 2);
    require n > 3 => tokens[3] == marketTokenAt(m, 3);
    require n > 4 => tokens[4] == marketTokenAt(m, 4);
    require n > 5 => tokens[5] == marketTokenAt(m, 5);
    require n > 6 => tokens[6] == marketTokenAt(m, 6);
    require n > 7 => tokens[7] == marketTokenAt(m, 7);
    return (pool, poolId, shape, tokens);
}

function policyCharge(uint128 u, bool requireRescue) returns Collateralization.PledgeCharge {
    policyCalls = policyCalls + 1;
    Collateralization.PledgeCharge c;
    return c;
}

function lpvOfVt(address vt) returns address {
    return factoryLpVaultOf(vtIntegrationIdOf(vt));
}

function recordIdOfVt(address vt, bytes32 k) returns uint256 {
    return currentContract._recordIdOf[vtIntegrationIdOf(vt)][k];
}

function reserveOf(address vt) returns uint256 {
    return spokeReserveIdOf(vtSpokeOf(vt), vtHubOf(vt), hubAssetIdOf(vtHubOf(vt), vt));
}

function suppliedOf(address vt, address p) returns mathint {
    return spokeSupplied[vtSpokeOf(vt)][reserveOf(vt)][p];
}

function hubSharesEqualAssets(address vt) returns bool {
    uint256 assetId = hubAssetIdOf(vtHubOf(vt), vt);
    return hubAddedAssets[vtHubOf(vt)][assetId] == hubAddedShares[vtHubOf(vt)][assetId];
}

function resetCall(address recipient) {
    policyCalls = 0;
    positionReturns = 0;
    lastPositionReturnedTo = 0;
    unitsRemoved = 0;
    removalsToOthers = 0;
    removalRecipient = recipient;
    debitedInCall = 0;
    partialDebitsInCall = 0;
    creditIncreasesInCall = 0;
}

// Scene setup shared by every rule: no registered LPVault is Collateralization.
function setup() {
    require forall uint32 i. factoryLpVaultOf(i) != currentContract;
}

definition ceilDiv(mathint a, mathint b) returns mathint = (a + b - 1) / b;

definition isAdapterEntry(method f) returns bool =
    f.selector == sig:pledge(address, address, address, bytes32, bool).selector
    || f.selector == sig:recredit(address, address, address, bytes32, bytes, bool).selector
    || f.selector == sig:release(address, address, bytes32, uint256).selector
    || f.selector == sig:releasePartial(address, address, bytes32, uint128, uint256[]).selector
    || f.selector == sig:releaseForDeleverage(address, address, bytes32, uint128, uint256[]).selector
    || f.selector == sig:releaseZeroCredit(address, address, bytes32).selector
    || f.selector == sig:collectFees(address, address, bytes32).selector;

definition isSwapEntry(method f) returns bool =
    f.selector == sig:beginSeizure(address, address).selector
    || f.selector == sig:settleSeizure(address, address, uint256, uint256[]).selector
    || f.selector == sig:settlePending(address, uint256).selector;

definition isExit(method f) returns bool =
    f.selector == sig:release(address, address, bytes32, uint256).selector
    || f.selector == sig:releasePartial(address, address, bytes32, uint128, uint256[]).selector
    || f.selector == sig:releaseForDeleverage(address, address, bytes32, uint128, uint256[]).selector
    || f.selector == sig:releaseZeroCredit(address, address, bytes32).selector
    || f.selector == sig:settleSeizure(address, address, uint256, uint256[]).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Storage mirrors
// ---------------------------------------------------------------------------------------------------------------------

ghost mapping(uint256 => mathint) gCredited {
    init_state axiom forall uint256 i. gCredited[i] == 0;
}
ghost mapping(uint256 => mathint) gRescue {
    init_state axiom forall uint256 i. gRescue[i] == 0;
}
ghost mapping(uint256 => mathint) gCharge {
    init_state axiom forall uint256 i. gCharge[i] == 0;
}
ghost mapping(uint256 => uint256) gMarket {
    init_state axiom forall uint256 i. gMarket[i] == 0;
}
ghost mapping(uint256 => address) gProxy {
    init_state axiom forall uint256 i. gProxy[i] == 0;
}
ghost mapping(uint256 => address) gDepositor {
    init_state axiom forall uint256 i. gDepositor[i] == 0;
}
ghost mapping(uint256 => bytes32) gKeyOfRecord {
    init_state axiom forall uint256 i. gKeyOfRecord[i] == to_bytes32(0);
}
ghost mapping(uint256 => uint32) gIntegrationOfRecord {
    init_state axiom forall uint256 i. gIntegrationOfRecord[i] == 0;
}
ghost mapping(uint32 => mapping(bytes32 => uint256)) gRecordOf {
    init_state axiom forall uint32 i. forall bytes32 k. gRecordOf[i][k] == 0;
}
ghost mathint gNextRecordId {
    init_state axiom gNextRecordId == 0;
}

// Sums over records, keyed by market identifier.
ghost mapping(uint256 => mathint) sumCredited {
    init_state axiom forall uint256 m. sumCredited[m] == 0;
}
ghost mapping(address => mapping(uint256 => mathint)) sumCreditedAccount {
    init_state axiom forall address p. forall uint256 m. sumCreditedAccount[p][m] == 0;
}
ghost mapping(address => mapping(uint256 => mathint)) sumRescueAccount {
    init_state axiom forall address p. forall uint256 m. sumRescueAccount[p][m] == 0;
}
ghost mapping(uint256 => mathint) sumChargeMarket {
    init_state axiom forall uint256 m. sumChargeMarket[m] == 0;
}
ghost mapping(address => mapping(address => mathint)) sumChargeToken {
    init_state axiom forall address h. forall address t. sumChargeToken[h][t] == 0;
}
ghost mapping(address => mapping(address => mathint)) sumChargeDepositor {
    init_state axiom forall address h. forall address d. sumChargeDepositor[h][d] == 0;
}
ghost mapping(uint256 => mathint) gMarketUsd {
    init_state axiom forall uint256 m. gMarketUsd[m] == 0;
}

// A charge change `d` of a record in market `m` moves every (Hub of m, token of m) counter by `d`.
function addTokenCharge(uint256 m, mathint d) {
    havoc sumChargeToken assuming forall address h. forall address t.
        sumChargeToken@new[h][t] == sumChargeToken@old[h][t] + ((h == marketHubOf(m) && marketHasToken(m, t)) ? d : 0);
}

hook Sstore records[KEY uint256 id].credited uint128 newV (uint128 oldV) {
    sumCredited[gMarket[id]] = sumCredited[gMarket[id]] + newV - oldV;
    sumCreditedAccount[gProxy[id]][gMarket[id]] = sumCreditedAccount[gProxy[id]][gMarket[id]] + newV - oldV;
    gCredited[id] = newV;
    if (newV < oldV) {
        debitedInCall = debitedInCall + oldV - newV;
        if (newV > 0) {
            partialDebitsInCall = partialDebitsInCall + 1;
        }
    }
    if (newV > oldV && oldV > 0) {
        creditIncreasesInCall = creditIncreasesInCall + 1;
    }
}

hook Sload uint128 v records[KEY uint256 id].credited {
    require gCredited[id] == to_mathint(v);
}

hook Sstore records[KEY uint256 id].rescueUnits uint128 newV (uint128 oldV) {
    sumRescueAccount[gProxy[id]][gMarket[id]] = sumRescueAccount[gProxy[id]][gMarket[id]] + newV - oldV;
    gRescue[id] = newV;
}

hook Sload uint128 v records[KEY uint256 id].rescueUnits {
    require gRescue[id] == to_mathint(v);
}

hook Sstore records[KEY uint256 id].currentUsdCharge uint64 newC (uint64 oldC) {
    sumChargeMarket[gMarket[id]] = sumChargeMarket[gMarket[id]] + newC - oldC;
    addTokenCharge(gMarket[id], newC - oldC);
    sumChargeDepositor[marketHubOf(gMarket[id])][gDepositor[id]] =
        sumChargeDepositor[marketHubOf(gMarket[id])][gDepositor[id]] + newC - oldC;
    gCharge[id] = newC;
}

hook Sload uint64 c records[KEY uint256 id].currentUsdCharge {
    require gCharge[id] == to_mathint(c);
}

// Field writes in any order: moving a record between keys moves its contributions with it.
hook Sstore records[KEY uint256 id].marketId uint32 newM32 (uint32 oldM32) {
    uint256 oldM = gMarket[id];
    uint256 newM = newM32;
    sumCredited[oldM] = sumCredited[oldM] - gCredited[id];
    sumCredited[newM] = sumCredited[newM] + gCredited[id];
    sumCreditedAccount[gProxy[id]][oldM] = sumCreditedAccount[gProxy[id]][oldM] - gCredited[id];
    sumCreditedAccount[gProxy[id]][newM] = sumCreditedAccount[gProxy[id]][newM] + gCredited[id];
    sumRescueAccount[gProxy[id]][oldM] = sumRescueAccount[gProxy[id]][oldM] - gRescue[id];
    sumRescueAccount[gProxy[id]][newM] = sumRescueAccount[gProxy[id]][newM] + gRescue[id];
    sumChargeMarket[oldM] = sumChargeMarket[oldM] - gCharge[id];
    sumChargeMarket[newM] = sumChargeMarket[newM] + gCharge[id];
    addTokenCharge(oldM, 0 - gCharge[id]);
    addTokenCharge(newM, gCharge[id]);
    sumChargeDepositor[marketHubOf(oldM)][gDepositor[id]] = sumChargeDepositor[marketHubOf(oldM)][gDepositor[id]] - gCharge[id];
    sumChargeDepositor[marketHubOf(newM)][gDepositor[id]] = sumChargeDepositor[marketHubOf(newM)][gDepositor[id]] + gCharge[id];
    gMarket[id] = newM;
}

hook Sload uint32 m records[KEY uint256 id].marketId {
    require gMarket[id] == to_mathint(m);
}

hook Sstore records[KEY uint256 id].proxy address newP (address oldP) {
    sumCreditedAccount[oldP][gMarket[id]] = sumCreditedAccount[oldP][gMarket[id]] - gCredited[id];
    sumCreditedAccount[newP][gMarket[id]] = sumCreditedAccount[newP][gMarket[id]] + gCredited[id];
    sumRescueAccount[oldP][gMarket[id]] = sumRescueAccount[oldP][gMarket[id]] - gRescue[id];
    sumRescueAccount[newP][gMarket[id]] = sumRescueAccount[newP][gMarket[id]] + gRescue[id];
    gProxy[id] = newP;
}

hook Sload address p records[KEY uint256 id].proxy {
    require gProxy[id] == p;
}

hook Sstore records[KEY uint256 id].depositor address newD (address oldD) {
    address hub = marketHubOf(gMarket[id]);
    sumChargeDepositor[hub][oldD] = sumChargeDepositor[hub][oldD] - gCharge[id];
    sumChargeDepositor[hub][newD] = sumChargeDepositor[hub][newD] + gCharge[id];
    gDepositor[id] = newD;
}

hook Sload address d records[KEY uint256 id].depositor {
    require gDepositor[id] == d;
}

hook Sstore records[KEY uint256 id].positionKey bytes32 newKey (bytes32 oldKey) {
    gKeyOfRecord[id] = newKey;
}

hook Sload bytes32 k records[KEY uint256 id].positionKey {
    require gKeyOfRecord[id] == k;
}

hook Sstore records[KEY uint256 id].integrationId uint32 newI (uint32 oldI) {
    gIntegrationOfRecord[id] = newI;
}

hook Sload uint32 i records[KEY uint256 id].integrationId {
    require gIntegrationOfRecord[id] == i;
}

hook Sstore _recordIdOf[KEY uint32 i][KEY bytes32 k] uint256 newId (uint256 oldId) {
    gRecordOf[i][k] = newId;
}

hook Sload uint256 rid _recordIdOf[KEY uint32 i][KEY bytes32 k] {
    require gRecordOf[i][k] == rid;
}

hook Sstore _nextRecordId uint256 newNext (uint256 oldNext) {
    gNextRecordId = newNext;
}

hook Sload uint256 n _nextRecordId {
    require gNextRecordId == to_mathint(n);
}

// Mirror of the seizure lists: entries and lengths per (proxy, vault token).
ghost mapping(address => mapping(address => mapping(uint256 => uint256))) gList;
ghost mapping(address => mapping(address => uint256)) gListLen {
    init_state axiom forall address p. forall address v. gListLen[p][v] == 0;
}

hook Sstore seizureList[KEY address p][KEY address v][INDEX uint256 i] uint256 newId (uint256 oldId) {
    gList[p][v][i] = newId;
}

hook Sload uint256 x seizureList[KEY address p][KEY address v][INDEX uint256 i] {
    require gList[p][v][i] == x;
}

hook Sstore seizureList[KEY address p][KEY address v].length uint256 newLen (uint256 oldLen) {
    gListLen[p][v] = newLen;
}

hook Sload uint256 n seizureList[KEY address p][KEY address v].length {
    require gListLen[p][v] == n;
}

hook Sstore marketUsd[KEY address vt][KEY CollateralizationBase.Bucket b] uint256 newV (uint256 oldV) {
    gMarketUsd[vtMarketIdOf(vt)] = gMarketUsd[vtMarketIdOf(vt)] + newV - oldV;
}

// Stands for the Adapter's `burnSeized` between `beginSeizure` and `settleSeizure` (LPVaultSwap is havocked there).
function setVtSupply(address t, mathint s) {
    require s >= 0;
    erc20Supply[t] = s;
}

function gap(address vt) returns mathint {
    return to_mathint(currentContract.totalCredited[vt]) + to_mathint(currentContract.pending[vt].units) - erc20Supply[vt];
}

// ---------------------------------------------------------------------------------------------------------------------
// Record index and custody (PROP-002, PROP-003)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-003 verifies: INV-005, Q-067, Q-104, Q-134, Q-240
invariant recordsBeyondNextIdAreEmpty()
    forall uint256 r. to_mathint(r) >= gNextRecordId => gDepositor[r] == 0
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); } }

// Every seizure-list entry is the id of a record already opened: pledge pushes the id it takes from _nextRecordId and
// then raises it, and every other write moves or removes existing entries.
// PROP-014 verifies: INV-015, Q-194
invariant seizureListEntriesBelowNextId()
    forall address p. forall address v. forall uint256 i.
        to_mathint(i) < to_mathint(gListLen[p][v]) => to_mathint(gList[p][v][i]) < gNextRecordId
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); } }

// PROP-003 verifies: INV-005, Q-067, Q-104, Q-134, Q-240
invariant openRecordsIndexed()
    forall uint256 r. gDepositor[r] != 0 => gRecordOf[gIntegrationOfRecord[r]][gKeyOfRecord[r]] == r
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            setup();
            requireInvariant recordsBeyondNextIdAreEmpty();
        }
    }

// PROP-003 verifies: INV-005, Q-067, Q-104, Q-134, Q-240
invariant uniqueOpenRecordPerPosition(uint256 r1, uint256 r2)
    (currentContract.records[r1].depositor != 0 && currentContract.records[r2].depositor != 0
        && currentContract.records[r1].integrationId == currentContract.records[r2].integrationId
        && currentContract.records[r1].positionKey == currentContract.records[r2].positionKey) => r1 == r2
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            setup();
            requireInvariant openRecordsIndexed();
            requireInvariant recordsBeyondNextIdAreEmpty();
        }
    }

// PROP-003 verifies: INV-005, Q-067, Q-240
rule pledgeOfRecordedPositionReverts(address depositor, address proxy, address vt, bytes32 key, bool rr) {
    env e;
    setup();
    require recordIdOfVt(vt, key) != 0;

    pledge@withrevert(e, depositor, proxy, vt, key, rr);

    assert lastReverted, "a position with an open record was pledged again";
}

// PROP-002 verifies: INV-002, Q-066, Q-067, Q-240
invariant liveUnitsCoverCredit(uint256 id)
    currentContract.records[id].depositor != 0 => (
        posUnits[factoryLpVaultOf(currentContract.records[id].integrationId)][currentContract.records[id].positionKey]
            >= to_mathint(currentContract.records[id].credited)
        && posHolder[factoryLpVaultOf(currentContract.records[id].integrationId)][currentContract.records[id].positionKey]
            == factoryLpVaultOf(currentContract.records[id].integrationId)
        && lvDepositor[factoryLpVaultOf(currentContract.records[id].integrationId)][currentContract.records[id].positionKey]
            == currentContract.records[id].depositor)
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            setup();
            require forall uint32 i. factoryLpVaultOf(i) != e.msg.sender;
            requireInvariant openRecordsIndexed();
            requireInvariant recordsBeyondNextIdAreEmpty();
        }
    }

// ---------------------------------------------------------------------------------------------------------------------
// Backing ledger (PROP-001, PROP-045, PROP-065)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-001 verifies: INV-001, Q-066, Q-092, Q-201, Q-224, Q-257
invariant totalCreditedIsSumOfRecords(address vt)
    to_mathint(currentContract.totalCredited[vt]) == sumCredited[vtMarketIdOf(vt)]
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            setup();
            requireInvariant recordsBeyondNextIdAreEmpty();
        }
    }

// PROP-045 verifies: INV-001, INV-008, INV-058, Q-189, Q-201, Q-224, Q-257
invariant accountCreditedIsSumOfRecords(address p, address vt)
    to_mathint(currentContract.accountCredited[p][vt]) == sumCreditedAccount[p][vtMarketIdOf(vt)]
    filtered { f -> !f.isView }
    {
        preserved with (env e) {
            setup();
            requireInvariant recordsBeyondNextIdAreEmpty();
        }
    }

// PROP-001 verifies: INV-001, Q-201, Q-224, Q-257
// PROP-065 verifies: INV-001, INV-066, INV-080, Q-254, Q-255, Q-257
// Collateralization's side of the one-sided backing: no Collateralization function changes the vault-token supply,
// and the two functions that lower credit for units already burned keep `supply ≤ totalCredited + pending.units`.
rule collateralizationNeverMovesSupply(method f, address vt) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    mathint supplyBefore = erc20Supply[vt];

    f(e, args);

    assert erc20Supply[vt] == supplyBefore, "a Collateralization function changed the vault-token supply";
}

// PROP-045 verifies: INV-001, INV-058, Q-201, Q-224, Q-257
// PROP-065 verifies: INV-080, Q-257
rule settlePendingKeepsSupplyBacked(address vt, uint256 u) {
    env e;
    setup();

    settlePending(e, vt, u);

    assert erc20Supply[vt] <= to_mathint(currentContract.totalCredited[vt]) + to_mathint(currentContract.pending[vt].units),
        "settlePending left more vault tokens than credited plus pending units";
}

// The only call that lowers the backing gap: `settlePending(u)` lowers it by exactly `u` and never below 0. Within
// LPVaultSwap's settlement the Adapter's `burnSeized` of the same units first raised it by those units, so the net
// change is minus the units of `u` not burned in that call (SPEC-BACK-012).
// PROP-065 verifies: INV-080, SPEC-BACK-012, REQ-VAULT-139, Q-257
rule settlePendingLowersGapByItsUnits(address vt, uint256 u) {
    env e;
    setup();
    mathint gapBefore = gap(vt);

    settlePending(e, vt, u);

    assert gap(vt) == gapBefore - to_mathint(u), "settlePending changed the backing gap by other than its units";
    assert gap(vt) >= 0, "settlePending left the backing gap below 0";
}

// PROP-004 verifies: INV-014, Q-125, Q-160, Q-189, Q-224
// PROP-011 verifies: INV-014, Q-160, Q-165, Q-189, Q-224
// PROP-045 verifies: INV-001, INV-008, INV-058, Q-189, Q-201, Q-224
// PROP-065 verifies: INV-001, INV-080, Q-257
rule seizureDebitEqualsSnapshotDrop(address p, address vt, uint256 u, uint256[] minAmounts) {
    env eBegin;
    env eSettle;
    setup();
    address swap = LP_VAULT_SWAP();
    require eBegin.msg.sender == swap && eSettle.msg.sender == swap;
    setLockHolder(swap);

    beginSeizure(eBegin, p, vt);

    mathint sharesBefore = suppliedOf(vt, p);
    mathint creditedBefore = currentContract.accountCredited[p][vt];
    mathint pendingBefore = currentContract.pending[vt].units;
    mathint supplyBefore = erc20Supply[vt];
    mathint gapBefore = gap(vt);

    // Between the two calls LPVaultSwap (havocked) runs liquidationCall, which lowers the proxy's supplied shares,
    // and has the Adapter burn the units it received.
    mathint sharesAfter;
    require sharesAfter >= 0 && sharesAfter <= sharesBefore;
    setSpokeSupplied(vtSpokeOf(vt), reserveOf(vt), p, sharesAfter);
    mathint burned;
    require burned >= 0 && burned <= supplyBefore;
    setVtSupply(vt, supplyBefore - burned);

    settleSeizure(eSettle, p, vt, u, minAmounts);

    // Shares Aave's liquidation fee moved to its fee receiver inside the Hub: the share drop beyond the seized units
    // (SPEC-BACK-007). They count as a shortfall reconciled into the pending balance.
    mathint fee = sharesBefore - sharesAfter - u;
    mathint shortfall = (u > 0 && creditedBefore > sharesBefore - fee) ? creditedBefore - (sharesBefore - fee) : 0;

    assert to_mathint(u) <= sharesBefore - sharesAfter, "debit above the snapshot share drop";
    assert u == 0 => sharesAfter == sharesBefore, "a share drop with no seized units settled as a seizure";
    assert to_mathint(u) == burned, "debit differs from the supply drop since beginSeizure";
    assert to_mathint(currentContract.accountCredited[p][vt]) == creditedBefore - shortfall - u,
        "account credit not lowered by the shortfall (fee units included) and the seized units";
    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + shortfall,
        "pending units not raised by exactly the shortfall (fee units included)";
    assert gap(vt) == gapBefore, "a seizure settlement changed the backing gap";
    assert (u > 0 && creditedBefore >= sharesBefore) => to_mathint(currentContract.accountCredited[p][vt]) == sharesAfter,
        "supplied shares and credited units differ after the settlement";
}

// PROP-013 verifies: INV-015, Q-160, Q-189
rule debitAboveCreditFails(address p, address vt, uint256 u, uint256[] minAmounts) {
    env eBegin;
    env eSettle;
    setup();
    address swap = LP_VAULT_SWAP();
    require eBegin.msg.sender == swap && eSettle.msg.sender == swap;
    setLockHolder(swap);

    beginSeizure(eBegin, p, vt);

    mathint sharesBefore = suppliedOf(vt, p);
    require to_mathint(u) <= sharesBefore;
    require to_mathint(u) > to_mathint(currentContract.accountCredited[p][vt]);
    setSpokeSupplied(vtSpokeOf(vt), reserveOf(vt), p, sharesBefore - u);
    setVtSupply(vt, erc20Supply[vt] - u);

    settleSeizure@withrevert(eSettle, p, vt, u, minAmounts);

    assert lastReverted, "a debit above the account-market's credit did not revert";
}

// The seizure list is an array of record IDs; record x sits at index i, its predecessor at index i - 1.
// PROP-012 verifies: INV-015, Q-108, Q-170, Q-194, Q-201
rule seizureDebitWalksFromHead(address p, address vt, uint256 u, uint256[] minAmounts, uint256 i, uint256 y) {
    env eBegin;
    env eSettle;
    setup();
    address swap = LP_VAULT_SWAP();
    require eBegin.msg.sender == swap && eSettle.msg.sender == swap;
    setLockHolder(swap);

    beginSeizure(eBegin, p, vt);

    mathint sharesBefore = suppliedOf(vt, p);
    // No unsettled seizure: the call debits only the current seizure.
    require to_mathint(currentContract.accountCredited[p][vt]) <= sharesBefore;
    require to_mathint(u) <= sharesBefore;
    setSpokeSupplied(vtSpokeOf(vt), reserveOf(vt), p, sharesBefore - u);
    setVtSupply(vt, erc20Supply[vt] - u);

    require i < currentContract.seizureList[p][vt].length;
    uint256 x = currentContract.seizureList[p][vt][i];
    uint256 j;
    require i > 0 => to_mathint(j) == i - 1;
    uint256 predOfX = i > 0 ? currentContract.seizureList[p][vt][j] : 0;
    mathint creditX = currentContract.records[x].credited;
    mathint creditY = currentContract.records[y].credited;
    address proxyY = currentContract.records[y].proxy;
    mathint marketY = currentContract.records[y].marketId;
    resetCall(swap);

    settleSeizure(eSettle, p, vt, u, minAmounts);

    mathint creditXAfter = currentContract.records[x].credited;
    assert creditIncreasesInCall == 0, "a debit raised a credited value";
    assert debitedInCall == to_mathint(u), "the walk did not debit exactly u";
    assert unitsRemoved == to_mathint(u) && removalsToOthers == 0,
        "the LPVault unwound other than u units, or paid a recipient other than LPVaultSwap";
    assert (creditX > 0 && creditXAfter == 0) => (!currentContract.records[x].inList && currentContract.records[x].depositor != 0),
        "a record debited to 0 stayed in the list or was closed";
    assert partialDebitsInCall <= 1, "more than one record left partially debited";
    assert (proxyY != p || marketY != to_mathint(vtMarketIdOf(vt))) => to_mathint(currentContract.records[y].credited) == creditY,
        "a record of another account-market was touched";
    assert (creditXAfter < creditX && creditXAfter > 0) =>
        (currentContract.seizureList[p][vt].length > 0 && currentContract.seizureList[p][vt][0] == x),
        "the partially debited record left the head of the list";
    assert (creditXAfter < creditX && i > 0) => currentContract.records[predOfX].credited == 0,
        "a record was debited before its predecessor was exhausted";
}

// PROP-012 verifies: INV-015, Q-108, Q-170, Q-194, Q-201
// Reconcile on exit: `releaseZeroCredit` debits the account-market's shortfall C − S with the same walk and has the
// LPVault unwind exactly those units into Collateralization's pending balance.
rule reconcileDebitWalksFromHead(address depositor, address vt, bytes32 key, uint256 i, uint256 y) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    address p = currentContract.records[id].proxy;
    require to_mathint(currentContract.records[id].marketId) == to_mathint(vtMarketIdOf(vt));
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint supplied = suppliedOf(vt, p);
    require supplied <= credit;
    require i < currentContract.seizureList[p][vt].length;
    uint256 x = currentContract.seizureList[p][vt][i];
    require x != id;
    uint256 j;
    require i > 0 => to_mathint(j) == i - 1;
    uint256 predOfX = i > 0 ? currentContract.seizureList[p][vt][j] : 0;
    mathint creditX = currentContract.records[x].credited;
    mathint creditY = currentContract.records[y].credited;
    address proxyY = currentContract.records[y].proxy;
    mathint marketY = currentContract.records[y].marketId;
    resetCall(currentContract);

    releaseZeroCredit(e, depositor, vt, key);

    mathint creditXAfter = currentContract.records[x].credited;
    assert creditIncreasesInCall == 0, "a reconcile debit raised a credited value";
    assert debitedInCall == credit - supplied, "the reconcile walk did not debit exactly C - S";
    assert unitsRemoved == credit - supplied && removalsToOthers == 0,
        "the reconcile unwound other than C - S units, or not into Collateralization";
    assert partialDebitsInCall <= 1, "more than one record left partially debited";
    assert (proxyY != p || marketY != to_mathint(vtMarketIdOf(vt))) => to_mathint(currentContract.records[y].credited) == creditY,
        "a record of another account-market was touched";
    assert (creditXAfter < creditX && creditXAfter > 0) =>
        (currentContract.seizureList[p][vt].length > 0 && currentContract.seizureList[p][vt][0] == x),
        "the partially debited record left the head of the list";
    assert (creditXAfter < creditX && i > 0) => currentContract.records[predOfX].credited == 0,
        "a record was debited before its predecessor was exhausted";
    assert (creditX > 0 && creditXAfter == 0) => (!currentContract.records[x].inList && currentContract.records[x].depositor != 0),
        "a record debited to 0 stayed in the list or was closed";
}

// PROP-045 verifies: INV-001, INV-008, INV-058, Q-189, Q-201, Q-224, Q-257
// `release`: S is the proxy's current supply plus the units it just withdrew; the Adapter burned `units` before.
rule releaseReconcilesShortfall(address p, address vt, bytes32 key, uint256 units) {
    env e;
    setup();
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint s = suppliedOf(vt, p) + units;
    // Supply never exceeds credit: vault tokens reach the Hub only through the Adapter's mint and supply (INV-008).
    require s <= credit;
    mathint pendingBefore = currentContract.pending[vt].units;
    mathint gapBefore = gap(vt);

    release(e, p, vt, key, units);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + (credit - s),
        "pending units not raised by exactly C - S";
    assert to_mathint(currentContract.accountCredited[p][vt]) == suppliedOf(vt, p),
        "credited units differ from supplied shares after release";
    assert gap(vt) == gapBefore - units, "release lowered credit plus pending by other than the released units";
}

// `releasePartial` and `releaseForDeleverage`: S is the proxy's current supply plus the units it just withdrew
// (SPEC-BACK-011), as in `release`.
// PROP-045 verifies: INV-008, INV-058, SPEC-BACK-011, REQ-VAULT-140, Q-201, Q-254, Q-255
rule releasePartialReconcilesShortfall(address p, address vt, bytes32 key, uint128 units, uint256[] minAmounts) {
    env e;
    setup();
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint s = suppliedOf(vt, p) + units;
    require s <= credit;
    mathint pendingBefore = currentContract.pending[vt].units;

    releasePartial(e, p, vt, key, units, minAmounts);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + (credit - s),
        "pending units not raised by exactly C - S in releasePartial";
    assert to_mathint(currentContract.accountCredited[p][vt]) == suppliedOf(vt, p),
        "credited units differ from supplied shares after releasePartial";
}

// PROP-045 verifies: INV-008, INV-058, SPEC-BACK-011, REQ-VAULT-140, Q-201, Q-255
rule releaseForDeleverageReconcilesShortfall(address p, address vt, bytes32 key, uint128 units, uint256[] minAmounts) {
    env e;
    setup();
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint s = suppliedOf(vt, p) + units;
    require s <= credit;
    mathint pendingBefore = currentContract.pending[vt].units;

    releaseForDeleverage(e, p, vt, key, units, minAmounts);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + (credit - s),
        "pending units not raised by exactly C - S in releaseForDeleverage";
    assert to_mathint(currentContract.accountCredited[p][vt]) == suppliedOf(vt, p),
        "credited units differ from supplied shares after releaseForDeleverage";
}

// `recredit`: S is the proxy's current supply (SPEC-BACK-011); the shortfall is reconciled before `added` is credited.
// PROP-045 verifies: INV-008, INV-058, SPEC-BACK-011, REQ-VAULT-140, Q-201, Q-254
rule recreditReconcilesShortfall(address depositor, address p, address vt, bytes32 key, bytes topUp, bool rescue) {
    env e;
    setup();
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint s = suppliedOf(vt, p);
    require s <= credit;
    mathint pendingBefore = currentContract.pending[vt].units;
    uint128 added;
    uint128 ru;

    added, ru = recredit(e, depositor, p, vt, key, topUp, rescue);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + (credit - s),
        "pending units not raised by exactly C - S in recredit";
    assert to_mathint(currentContract.accountCredited[p][vt]) == s + to_mathint(added),
        "credited units after recredit differ from the supplied shares plus the added units";
}

// PROP-045 verifies: INV-008, INV-058, Q-189, Q-201
rule releaseZeroCreditReconcilesShortfall(address depositor, address vt, bytes32 key) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    address p = currentContract.records[id].proxy;
    require to_mathint(currentContract.records[id].marketId) == to_mathint(vtMarketIdOf(vt));
    require hubSharesEqualAssets(vt);
    mathint credit = currentContract.accountCredited[p][vt];
    mathint supplied = suppliedOf(vt, p);
    require supplied <= credit;
    mathint pendingBefore = currentContract.pending[vt].units;
    mathint gapBefore = gap(vt);

    releaseZeroCredit(e, depositor, vt, key);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore + (credit - supplied),
        "pending units not raised by exactly C - S";
    assert to_mathint(currentContract.accountCredited[p][vt]) == supplied,
        "credited units differ from supplied shares after the zero-credit release";
    assert gap(vt) == gapBefore, "a zero-credit release changed the backing gap";
}

// PROP-045 verifies: INV-058, Q-189, Q-201
rule noReconcileWhileSharesDifferFromAssets(method f, address vt) filtered {
    f -> isExit(f) || f.selector == sig:recredit(address, address, address, bytes32, bytes, bool).selector
} {
    env e;
    calldataarg args;
    setup();
    require !hubSharesEqualAssets(vt);
    mathint pendingBefore = currentContract.pending[vt].units;

    f(e, args);

    assert to_mathint(currentContract.pending[vt].units) == pendingBefore,
        "a reconcile debit happened while Hub shares differ from assets";
}

// Token k of the market: the last settlement pays its exact remainder, a partial one its pro-rata amount rounded down.
// PROP-045 verifies: INV-001, INV-058, Q-201, Q-224, Q-257
// PROP-037 verifies: INV-054, Q-148, Q-223
rule settlePendingChecksBurnAndPaysOnlyLpVaultSwap(address vt, uint256 u, address token, address other, uint256 k) {
    env e;
    setup();
    address swap = LP_VAULT_SWAP();
    require other != currentContract && other != swap;
    mathint units = currentContract.pending[vt].units;
    mathint tokenCount = currentContract.pending[vt].amounts.length;
    // k names one market token; settlePending pays one amount per market token from the same index of pending.
    require to_mathint(k) < tokenCount && to_mathint(k) < to_mathint(marketTokenCount(vtMarketIdOf(vt)));
    mathint amountK = currentContract.pending[vt].amounts[k];
    mathint supply = erc20Supply[vt];
    mathint credited = currentContract.totalCredited[vt];
    mathint otherBalance = erc20Bal[token][other];

    uint256[] outs = settlePending(e, vt, u);

    assert e.msg.sender == swap && lockHolder == swap, "settlePending ran outside LPVaultSwap holding the lock";
    assert u > 0 && to_mathint(u) <= units, "settled units outside (0, pending.units]";
    assert supply + u <= credited + units, "settlePending accepted units the Adapter had not burned";
    assert to_mathint(currentContract.pending[vt].units) == units - u, "pending units not lowered by u";
    assert erc20Bal[token][other] == otherBalance, "pool tokens went to an address other than LPVaultSwap";
    assert to_mathint(outs.length) == to_mathint(marketTokenCount(vtMarketIdOf(vt))),
        "settlePending returned other than one amount per market token";
    assert to_mathint(u) == units => to_mathint(outs[k]) == amountK,
        "the last settlement did not pay the exact remainder";
    assert to_mathint(u) < units => to_mathint(outs[k]) == (amountK * u) / units,
        "a partial settlement did not pay the pro-rata amount rounded down";
}

// PROP-045 verifies: INV-058, Q-189, Q-201
rule settlePendingRefusedDuringSeizure(address p, address vt, address vtPending, uint256 u) {
    env eBegin;
    env eSettle;
    setup();
    address swap = LP_VAULT_SWAP();
    require eBegin.msg.sender == swap && eSettle.msg.sender == swap;
    setLockHolder(swap);

    beginSeizure(eBegin, p, vt);
    settlePending@withrevert(eSettle, vtPending, u);

    assert lastReverted, "settlePending ran while a seizure snapshot was active";
}

// ---------------------------------------------------------------------------------------------------------------------
// Pledge, re-credit, partial removal and deleverage release (PROP-006, PROP-054, PROP-065)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-054 verifies: INV-001, INV-066, Q-224, Q-240
// PROP-006 verifies: INV-009, Q-092, Q-224
rule pledgeCreditsUnitsReadAfterCustody(address depositor, address proxy, address vt, bytes32 key, bool rr) {
    env e;
    setup();
    address lpv = lpvOfVt(vt);
    mathint creditedBefore = currentContract.totalCredited[vt];
    mathint accountBefore = currentContract.accountCredited[proxy][vt];
    resetCall(currentContract);

    uint256 id;
    uint128 credited;
    id, credited = pledge(e, depositor, proxy, vt, key, rr);

    assert to_mathint(credited) == posUnits[lpv][key] && credited > 0, "credited differs from the units read after custody";
    assert posHolder[lpv][key] == lpv && lvDepositor[lpv][key] == depositor,
        "the market's LPVault does not hold the position for the depositor";
    assert currentContract.records[id].proxy == proxy
        && to_mathint(currentContract.records[id].marketId) == to_mathint(vtMarketIdOf(vt))
        && currentContract.records[id].integrationId == vtIntegrationIdOf(vt)
        && currentContract.records[id].positionKey == key
        && currentContract.records[id].credited == credited && currentContract.records[id].originalUnits == credited,
        "the new record does not carry the credited units for the named position and account-market";
    assert to_mathint(currentContract.totalCredited[vt]) == creditedBefore + credited
        && to_mathint(currentContract.accountCredited[proxy][vt]) == accountBefore + credited,
        "totals not raised by exactly the credited units";
    assert policyCalls == 1, "pledge did not run the RiskModule check exactly once";
}

// PROP-054 verifies: INV-066, INV-088, Q-254
// PROP-065 verifies: INV-088, Q-254
// A re-credit tops the record up to the position's live units after reconcile, by exactly the `added` it returns.
rule recreditAddsUncreditedLiveUnits(address depositor, address proxy, address vt, bytes32 key, bytes topUp, bool rr) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    require hubSharesEqualAssets(vt);
    // No unsettled seizure on the account-market, so the reconcile step debits nothing.
    require to_mathint(currentContract.accountCredited[proxy][vt]) <= suppliedOf(vt, proxy);
    mathint creditBefore = currentContract.records[id].credited;
    mathint totalBefore = currentContract.totalCredited[vt];

    uint128 added;
    uint128 rescue;
    added, rescue = recredit(e, depositor, proxy, vt, key, topUp, rr);

    assert creditBefore > 0 && added > 0, "re-credit of a record at 0 credit or of nothing";
    assert currentContract.records[id].depositor == depositor && currentContract.records[id].proxy == proxy,
        "re-credit accepted a caller other than the depositor of record or a foreign proxy";
    assert to_mathint(currentContract.records[id].credited) == posUnits[lpvOfVt(vt)][key]
        && to_mathint(currentContract.records[id].credited) == creditBefore + added,
        "credited units after re-credit differ from the live units";
    assert to_mathint(currentContract.totalCredited[vt]) == totalBefore + added, "total credit not raised by added";
    assert rescue <= added, "re-credit booked more rescue units than it added";
}

// PROP-028 verifies: INV-027, Q-174
// SPEC-BACK-013 rebase: the new basis is (credited + added, currentCharge + usdCharge), so later exits release exactly
// the booked charge.
rule recreditRebasesChargeBasis(address depositor, address proxy, address vt, bytes32 key, bytes topUp, bool rr) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    require to_mathint(currentContract.accountCredited[proxy][vt]) <= suppliedOf(vt, proxy);
    mathint chargeBefore = currentContract.records[id].currentUsdCharge;

    uint128 added;
    uint128 rescue;
    added, rescue = recredit(e, depositor, proxy, vt, key, topUp, rr);

    assert currentContract.records[id].originalUnits == currentContract.records[id].credited,
        "re-credit did not rebase originalUnits to the credited units";
    assert currentContract.records[id].originalUsdCharge == currentContract.records[id].currentUsdCharge,
        "re-credit did not rebase the charge basis to the current charge";
    assert to_mathint(currentContract.records[id].currentUsdCharge) > chargeBefore,
        "re-credit did not add the added units' charge";
}

// PROP-065 verifies: INV-088, Q-254
// PROP-054 verifies: INV-066, Q-254
rule releasePartialDebitsUnitsAndPaysDepositor(address p, address vt, bytes32 key, uint128 units, uint256[] minAmounts) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    address depositor = currentContract.records[id].depositor;
    require hubSharesEqualAssets(vt);
    // The Adapter withdrew `units` from the proxy first; with no unsettled seizure the reconcile step debits nothing.
    require to_mathint(currentContract.accountCredited[p][vt]) <= suppliedOf(vt, p) + units;
    mathint creditBefore = currentContract.records[id].credited;
    mathint totalBefore = currentContract.totalCredited[vt];
    resetCall(depositor);

    uint128 remaining;
    uint256[] amounts;
    remaining, amounts = releasePartial(e, p, vt, key, units, minAmounts);

    assert units > 0 && to_mathint(units) < creditBefore, "partial removal outside 0 < units < credited";
    assert to_mathint(remaining) == creditBefore - units && currentContract.records[id].depositor == depositor,
        "the record was not left open with credited − units";
    assert to_mathint(currentContract.totalCredited[vt]) == totalBefore - units, "total credit not lowered by units";
    assert unitsRemoved == to_mathint(units) && removalsToOthers == 0,
        "the LPVault removed other than units, or paid someone other than the depositor of record";
    assert positionReturns == 0, "a partial removal returned the position";
    assert policyCalls == 0, "a partial removal called the RiskModule";
}

// PROP-065 verifies: INV-089, Q-255
// PROP-072 verifies: INV-089, Q-255
rule releaseForDeleveragePaysLpVaultSwap(address p, address vt, bytes32 key, uint128 units, uint256[] minAmounts) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    address depositor = currentContract.records[id].depositor;
    require hubSharesEqualAssets(vt);
    require to_mathint(currentContract.accountCredited[p][vt]) <= suppliedOf(vt, p) + units;
    mathint creditBefore = currentContract.records[id].credited;
    mathint totalBefore = currentContract.totalCredited[vt];
    resetCall(LP_VAULT_SWAP());

    uint256[] amounts;
    bool closed;
    amounts, closed = releaseForDeleverage(e, p, vt, key, units, minAmounts);

    assert units > 0 && to_mathint(units) <= creditBefore, "deleverage release outside 0 < units ≤ credited";
    assert to_mathint(currentContract.totalCredited[vt]) == totalBefore - units, "total credit not lowered by units";
    assert unitsRemoved == to_mathint(units) && removalsToOthers == 0,
        "the LPVault unwound other than units, or paid someone other than LPVaultSwap";
    assert closed <=> to_mathint(units) == creditBefore, "closed differs from 'no credited units remain'";
    assert closed => (positionReturns == 1 && lastPositionReturnedTo == depositor),
        "a closed record's position did not go to its depositor";
    assert !closed => positionReturns == 0, "an open record's position left custody";
    assert policyCalls == 0, "a deleverage release called the RiskModule";
}

// ---------------------------------------------------------------------------------------------------------------------
// Seizure list order (PROP-014)
// ---------------------------------------------------------------------------------------------------------------------

// The new record sits at index k of the account-market's list; index 0 is the head.
// PROP-014 verifies: INV-015, Q-194
rule pledgeInsertsInOrder(address depositor, address proxy, address vt, bytes32 key, bool rr, uint256 k) {
    env e;
    setup();
    mathint lengthBefore = currentContract.seizureList[proxy][vt].length;
    // Every seizure-list entry is a record opened earlier, so it differs from the id this pledge takes.
    requireInvariant seizureListEntriesBelowNextId();

    uint256 id;
    uint128 credited;
    id, credited = pledge(e, depositor, proxy, vt, key, rr);

    mathint lengthAfter = currentContract.seizureList[proxy][vt].length;
    assert currentContract.records[id].inList && lengthAfter == lengthBefore + 1, "a new record is not in the seizure list";
    require to_mathint(k) < lengthAfter && currentContract.seizureList[proxy][vt][k] == id;
    uint256 prevIndex;
    require k > 0 => to_mathint(prevIndex) == k - 1;
    uint256 nextIndex;
    require to_mathint(nextIndex) == k + 1;
    assert k > 0 => currentContract.records[currentContract.seizureList[proxy][vt][prevIndex]].credited >= credited,
        "inserted after a smaller record";
    assert to_mathint(nextIndex) < lengthAfter =>
        currentContract.records[currentContract.seizureList[proxy][vt][nextIndex]].credited < credited,
        "inserted before a record that is not smaller";
}

// Records a and b, both other than the released one, keep their relative order.
// PROP-014 verifies: INV-015, Q-194
rule releaseUnlinksWithoutReordering(address p, address vt, bytes32 key, uint256 units, uint256 i, uint256 j,
                                     uint256 i2, uint256 j2) {
    env e;
    setup();
    uint256 id = recordIdOfVt(vt, key);
    // No reconcile debit in this call: the account-market's supply covers its credit.
    require suppliedOf(vt, p) + units >= to_mathint(currentContract.accountCredited[p][vt]);
    require i < j && j < currentContract.seizureList[p][vt].length;
    uint256 a = currentContract.seizureList[p][vt][i];
    uint256 b = currentContract.seizureList[p][vt][j];
    require a != id && b != id;

    release(e, p, vt, key, units);

    require i2 < currentContract.seizureList[p][vt].length && currentContract.seizureList[p][vt][i2] == a;
    require j2 < currentContract.seizureList[p][vt].length && currentContract.seizureList[p][vt][j2] == b;
    assert i2 < j2, "release reordered the remaining records";
}

// ---------------------------------------------------------------------------------------------------------------------
// Exposure counters (PROP-028, PROP-029)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-029 verifies: INV-027, Q-158, Q-174, Q-240
invariant marketExposureMatchesRecords(uint256 marketId)
    gMarketUsd[marketId] == sumChargeMarket[marketId]
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); requireInvariant recordsBeyondNextIdAreEmpty(); } }

// PROP-029 verifies: INV-027, Q-158, Q-174, Q-240
invariant tokenExposureMatchesRecords(address hub, address token)
    to_mathint(currentContract.tokenUsd[hub][token]) == sumChargeToken[hub][token]
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); requireInvariant recordsBeyondNextIdAreEmpty(); } }

// PROP-029 verifies: INV-027, Q-158, Q-174, Q-240
invariant depositorExposureMatchesRecords(address hub, address depositor)
    to_mathint(currentContract.depositorUsd[hub][depositor]) == sumChargeDepositor[hub][depositor]
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); requireInvariant recordsBeyondNextIdAreEmpty(); } }

// PROP-028 verifies: INV-027, Q-174
rule exitChargeFollowsFixedBasis(method f, uint256 id) filtered { f -> isExit(f) } {
    env e;
    calldataarg args;
    setup();
    require currentContract.records[id].depositor != 0;
    mathint units0 = currentContract.records[id].originalUnits;
    mathint charge0 = currentContract.records[id].originalUsdCharge;
    mathint chargeBefore = currentContract.records[id].currentUsdCharge;
    mathint creditBefore = currentContract.records[id].credited;
    require units0 > 0;

    f(e, args);

    bool open = currentContract.records[id].depositor != 0;
    mathint remaining = currentContract.records[id].credited;
    assert (open && remaining != creditBefore) =>
        to_mathint(currentContract.records[id].currentUsdCharge) == ceilDiv(charge0 * remaining, units0),
        "remaining charge is not ceil(V0 x remaining / U0)";
    assert open => to_mathint(currentContract.records[id].currentUsdCharge) <= chargeBefore,
        "an exit raised a record's charge";
    assert (open && remaining == 0) => currentContract.records[id].currentUsdCharge == 0,
        "an exit to 0 credited units left a charge";
}

// ---------------------------------------------------------------------------------------------------------------------
// Rescue units (PROP-067 input, SPEC-BACK-014)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-067 verifies: INV-082, Q-253
invariant rescueUnitsWithinCredited(uint256 id)
    currentContract.records[id].rescueUnits <= currentContract.records[id].credited
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); } }

// PROP-067 verifies: INV-082, Q-253
invariant accountRescueUnitsIsSumOfRecords(address p, address vt)
    to_mathint(currentContract.accountRescueUnits[p][vt]) == sumRescueAccount[p][vtMarketIdOf(vt)]
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); requireInvariant recordsBeyondNextIdAreEmpty(); } }

// ---------------------------------------------------------------------------------------------------------------------
// Position exits, policy isolation, lock and callers (PROP-032, PROP-033, PROP-037, PROP-038)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-038 verifies: INV-007, Q-030, Q-105, Q-224
rule positionReturnsOnlyToDepositorOnClose(method f, uint32 integrationId, bytes32 key) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    setup();
    requireInvariant openRecordsIndexed();
    address lpv = factoryLpVaultOf(integrationId);
    require lpv != 0;
    uint256 id = currentContract._recordIdOf[integrationId][key];
    address depositor = currentContract.records[id].depositor;
    require posHolder[lpv][key] == lpv;
    resetCall(currentContract);

    f(e, args);

    assert posHolder[lpv][key] != lpv => (posHolder[lpv][key] == depositor && depositor != 0),
        "a position left custody to an address other than its depositor of record";
    assert posHolder[lpv][key] != lpv => currentContract._recordIdOf[integrationId][key] == 0,
        "a position left custody while its record stayed open";
    assert positionReturns > 0 => (f.selector == sig:release(address, address, bytes32, uint256).selector
        || f.selector == sig:releaseZeroCredit(address, address, bytes32).selector
        || f.selector == sig:releaseForDeleverage(address, address, bytes32, uint128, uint256[]).selector),
        "a position was returned outside a withdrawal, a zero-credit release or a closing deleverage release";
}

// The Adapter passes the wallet that called `AaveAdapter.releaseZeroCredit` as `depositor`.
// PROP-033 verifies: INV-016, Q-093, Q-223
rule releaseZeroCreditOnlyByDepositor(address depositor, address vt, bytes32 key) {
    env e;
    setup();
    address recordDepositor = currentContract.records[recordIdOfVt(vt, key)].depositor;

    releaseZeroCredit(e, depositor, vt, key);

    assert depositor == recordDepositor && recordDepositor != 0,
        "a zero-credit release for a wallet other than the depositor of record";
}

// PROP-032 verifies: Q-122, Q-158, Q-180, Q-209, Q-254, Q-260
// Exits, seizure and pending settlement never consult the RiskModule (and Collateralization reads no MarketRegistry
// state on any path, REQ-VAULT-087), so their success does not depend on any policy implementation.
rule exitsMakeNoPolicyCall(method f) filtered {
    f -> isExit(f)
        || f.selector == sig:settlePending(address, uint256).selector
        || f.selector == sig:beginSeizure(address, address).selector
} {
    env e;
    calldataarg args;
    setup();
    resetCall(currentContract);

    f(e, args);

    assert policyCalls == 0, "an exit or settlement called the RiskModule";
}

// PROP-037 verifies: INV-054, Q-148, Q-223
rule innerEntryPointsRequireLockAndCaller(method f) filtered { f -> isAdapterEntry(f) || isSwapEntry(f) } {
    env e;
    calldataarg args;
    setup();
    address holderBefore = lockHolder;

    f(e, args);

    assert isAdapterEntry(f) => (e.msg.sender == ADAPTER() && holderBefore == ADAPTER()),
        "an Adapter entry point ran without the Adapter holding the lock";
    assert isSwapEntry(f) => (e.msg.sender == LP_VAULT_SWAP() && holderBefore == LP_VAULT_SWAP()),
        "a seizure or pending entry point ran without LPVaultSwap holding the lock";
}

// ---------------------------------------------------------------------------------------------------------------------
// Arithmetic bounds (PROP-043; SMTChecker is the 5.2 tool)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-043 verifies: Q-049, Q-092, Q-226
invariant creditedWithinOriginalUnits(uint256 id)
    currentContract.records[id].credited <= currentContract.records[id].originalUnits
        && to_mathint(currentContract.records[id].originalUnits) < 2^120
    filtered { f -> !f.isView }
    { preserved with (env e) { setup(); } }

// ---------------------------------------------------------------------------------------------------------------------
// Reachability
// ---------------------------------------------------------------------------------------------------------------------

// PROP-001 verifies: INV-001, Q-066, Q-224
rule pledgeIsReachable(address depositor, address proxy, address vt, bytes32 key, bool rr) {
    env e;
    setup();
    uint256 id;
    uint128 credited;
    id, credited = pledge(e, depositor, proxy, vt, key, rr);
    satisfy credited > 0;
}

// PROP-065 verifies: INV-088, Q-254
rule releasePartialIsReachable(address p, address vt, bytes32 key, uint128 units, uint256[] minAmounts) {
    env e;
    setup();
    uint128 remaining;
    uint256[] amounts;
    remaining, amounts = releasePartial(e, p, vt, key, units, minAmounts);
    satisfy remaining > 0;
}
