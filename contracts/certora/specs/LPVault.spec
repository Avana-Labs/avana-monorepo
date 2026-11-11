/*
 * LPVault (interface src/custody/lp-vault/ILPVault.sol, which extends IAmmIntegration and IAmmIntegrationHooks; spec
 * 2.2), verified on both concentrated-liquidity LPVaults: the Uniswap v3 LPVault
 * src/amm/uniswap-v3/UniswapV3Integration.sol (LPVault.conf) and the Aerodrome Slipstream LPVault
 * src/amm/slipstream/SlipstreamIntegration.sol (LPVaultSlipstream.conf), whose custody code is the shared base
 * src/amm/concentrated-liquidity/ClLPVaultCustody.sol. One immutable LPVault serves one AMM protocol on one chain.
 *
 * Position custody: a position comes only from its owner and is recorded against that owner (`receivePosition`); it
 * leaves only to its depositor of record (`returnPosition`, called by Collateralization under the Lock) or, as a stray
 * with no depositor of record, to the address the timelock names (`returnStray`); `unwind` and `releaseToDepositor`
 * lower the position's units by exactly the amount asked and collect exactly the removed principal, so every accrued
 * fee stays owed to the position; `releaseToDepositor` pays only the depositor of record; `collectFees` pays only the
 * depositor of record and runs only while the AaveAdapter holds the Lock. The LPVault keeps no record, total or counter;
 * Collateralization.spec proves the ledger.
 *
 * Storage assumption: `_depositorOf` and `_marketOfPosition` (`mapping(bytes32 positionKey => …)`, the custody maps of
 * the 2.2 Storage table, in ClLPVaultBase) and `_markets` (the write-once market table), read through direct storage
 * access; plain storage (immutable contract). The custody views revert while the Lock is held (REQ-VAULT-151), so rules
 * read storage.
 *
 * Position keys: rules name a position by its `bytes32` key. The LPVault resolves a key to one NFT, (position manager,
 * token ID): Uniswap v3 `bytes32(tokenId)` on the NFPM; Slipstream `bytes32((generation << 248) | tokenId)` on the
 * manager of that generation (SPEC-AMM-CORE-002). The position-manager model is therefore keyed by (called manager,
 * token ID), so the four Slipstream generations, whose token IDs overlap, are four independent NFT contracts. A rule
 * learns its key's NFT with `resolve(key)`: one `positionOwner(key)` call, in which the LPVault resolves the key exactly
 * as in every custody call and the `ownerOf` summary records the manager it was called on and the token ID. A key the
 * LPVault cannot resolve (a Slipstream generation byte of 4 or more) reverts in `positionOwner` and in every function
 * that takes it, so its paths are pruned.
 *
 * Distinct keys name distinct NFTs (`distinctNfts`): on Uniswap v3 the key is the token ID on the one NFPM; on
 * Slipstream the token ID is the low 248 bits and the four managers are distinct (the constructor reverts otherwise,
 * REQ-AMM-SLIP-006, TEST-108). The prover treats the managers as unknown immutables, so rules that call a function
 * with a second key require this of the pair.
 *
 * Summaries: the position manager by a ghost model of its owner, liquidity, owed amounts and approvals per (manager,
 * token ID): `transferFrom` moves the NFT when the caller is the owner or approved, `decreaseLiquidity(x)` lowers
 * liquidity by exactly `x` and adds the principal to the owed amounts, `collect` pays at most the owed amounts and at
 * most the cap to the named recipient. `positions` is NONDET: its 12-field layout differs between the two AMM protocols
 * (field 5 is `uint24 fee` on Uniswap v3 and `int24 tickSpacing` on Slipstream) and no rule reads a field it returns,
 * so every value the caller can decode is allowed (an over-approximation). Pool tokens by the ERC-20 model; the Lock by
 * its model, with `AAVE_ADAPTER()` a fixed ghost.
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";

methods {
    function COLLATERALIZATION() external returns (address) envfree;
    function LOCK() external returns (address) envfree;
    function TIMELOCK() external returns (address) envfree;
    function positionOwner(bytes32) external returns (address) envfree;
    function receivePosition(uint256, address, bytes32) external returns (uint128);
    function returnPosition(bytes32) external returns (address);
    function unwind(bytes32, uint128, uint256[], address) external returns (uint256[]);
    function releaseToDepositor(bytes32, uint128, uint256[]) external returns (uint256[]);
    function unitsOf(bytes32) external returns (uint128);
    function collectFees(bytes32, address) external returns (uint256[]);
    function returnStray(bytes32, address) external;

    // Position managers, keyed by the called contract
    function _.ownerOf(uint256 id) external => nfpmOwnerOf(calledContract, id) expect address;
    function _.transferFrom(address from, address to, uint256 id) external with (env e) => nfpmTransferFrom(calledContract, e.msg.sender, from, to, id) expect void;
    function _.positions(uint256 id) external => NONDET;
    function _.decreaseLiquidity(IClPositionManager.DecreaseLiquidityParams p) external with (env e) => nfpmDecreaseLiquidity(calledContract, e.msg.sender, p) expect (uint256, uint256);
    function _.collect(IClPositionManager.CollectParams p) external with (env e) => nfpmCollect(calledContract, e.msg.sender, p) expect (uint256, uint256);

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;
    function _.AAVE_ADAPTER() external => lockAdapterOf() expect address;
}

persistent ghost mapping(address => mapping(uint256 => mathint)) nfpmLiquidity;
persistent ghost mapping(address => mapping(uint256 => address)) nfpmOwner;
persistent ghost mapping(address => mapping(uint256 => mathint)) nfpmOwed0;
persistent ghost mapping(address => mapping(uint256 => mathint)) nfpmOwed1;
ghost nfpmToken0Of(address, uint256) returns address;
ghost nfpmToken1Of(address, uint256) returns address;
ghost nfpmApproved(address, uint256, address) returns bool;

// The Lock's AaveAdapter member, an immutable of the Lock.
persistent ghost address lockAdapter;

// The (manager, token ID) of the last `ownerOf` call, read by `resolve`.
persistent ghost address probedManager;
persistent ghost uint256 probedId;

// Bookkeeping of the current call.
persistent ghost mathint principalRemoved0;
persistent ghost mathint principalRemoved1;
persistent ghost mathint collected0;
persistent ghost mathint collected1;
persistent ghost mathint collectsToOthers;
persistent ghost address expectedRecipient;
persistent ghost mathint decreaseCalls;
persistent ghost address expectedManager;
persistent ghost uint256 expectedId;
persistent ghost mathint callsOnOtherNfts;

function nfpmOwnerOf(address m, uint256 id) returns address {
    probedManager = m;
    probedId = id;
    return nfpmOwner[m][id];
}

function nfpmTransferFrom(address m, address caller, address from, address to, uint256 id) {
    require nfpmOwner[m][id] == from;
    require caller == from || nfpmApproved(m, id, caller);
    nfpmOwner[m][id] = to;
}

function countOtherNft(address m, uint256 id) {
    if (m != expectedManager || id != expectedId) {
        callsOnOtherNfts = callsOnOtherNfts + 1;
    }
}

function nfpmDecreaseLiquidity(address m, address caller, IClPositionManager.DecreaseLiquidityParams p) returns (uint256, uint256) {
    require nfpmOwner[m][p.tokenId] == caller || nfpmApproved(m, p.tokenId, caller);
    require nfpmLiquidity[m][p.tokenId] >= to_mathint(p.liquidity);
    nfpmLiquidity[m][p.tokenId] = nfpmLiquidity[m][p.tokenId] - p.liquidity;
    uint256 a0;
    uint256 a1;
    require a0 <= max_uint128 && a1 <= max_uint128;
    require a0 >= p.amount0Min && a1 >= p.amount1Min;
    nfpmOwed0[m][p.tokenId] = nfpmOwed0[m][p.tokenId] + a0;
    nfpmOwed1[m][p.tokenId] = nfpmOwed1[m][p.tokenId] + a1;
    principalRemoved0 = principalRemoved0 + a0;
    principalRemoved1 = principalRemoved1 + a1;
    decreaseCalls = decreaseCalls + 1;
    countOtherNft(m, p.tokenId);
    return (a0, a1);
}

function nfpmCollect(address m, address caller, IClPositionManager.CollectParams p) returns (uint256, uint256) {
    require nfpmOwner[m][p.tokenId] == caller || nfpmApproved(m, p.tokenId, caller);
    mathint c0 = nfpmOwed0[m][p.tokenId] < to_mathint(p.amount0Max) ? nfpmOwed0[m][p.tokenId] : to_mathint(p.amount0Max);
    mathint c1 = nfpmOwed1[m][p.tokenId] < to_mathint(p.amount1Max) ? nfpmOwed1[m][p.tokenId] : to_mathint(p.amount1Max);
    require c0 >= 0 && c1 >= 0;
    nfpmOwed0[m][p.tokenId] = nfpmOwed0[m][p.tokenId] - c0;
    nfpmOwed1[m][p.tokenId] = nfpmOwed1[m][p.tokenId] - c1;
    erc20Credit(nfpmToken0Of(m, p.tokenId), p.recipient, require_uint256(c0));
    erc20Credit(nfpmToken1Of(m, p.tokenId), p.recipient, require_uint256(c1));
    collected0 = collected0 + c0;
    collected1 = collected1 + c1;
    if (p.recipient != expectedRecipient) {
        collectsToOthers = collectsToOthers + 1;
    }
    countOtherNft(m, p.tokenId);
    return (require_uint256(c0), require_uint256(c1));
}

function lockAdapterOf() returns address {
    return lockAdapter;
}

function resetCall(address recipient, address m, uint256 id) {
    principalRemoved0 = 0;
    principalRemoved1 = 0;
    collected0 = 0;
    collected1 = 0;
    collectsToOthers = 0;
    expectedRecipient = recipient;
    decreaseCalls = 0;
    expectedManager = m;
    expectedId = id;
    callsOnOtherNfts = 0;
}

// The NFT the LPVault resolves `key` to: `positionOwner` calls `ownerOf` once, on the key's manager with the key's token
// ID, and the summary records both. Reverts (and so prunes the path) for a key the LPVault cannot resolve.
function resolve(bytes32 key) returns (address, uint256) {
    positionOwner(key);
    return (probedManager, probedId);
}

// Distinct keys name distinct NFTs (header): Uniswap v3 keys are token IDs of one NFPM; Slipstream keys of different
// generations name different managers (REQ-AMM-SLIP-006), and keys of one generation differ in the token ID.
function distinctNfts(bytes32 key, address m, uint256 id, bytes32 key2) {
    address m2;
    uint256 id2;
    m2, id2 = resolve(key2);
    require key2 == key || m2 != m || id2 != id;
}

// Calls `f`, passing `key2` as the position key of every function that takes one.
function callOnKey(method f, env e, bytes32 key2) {
    if (f.selector == sig:returnPosition(bytes32).selector) {
        returnPosition(e, key2);
    } else if (f.selector == sig:returnStray(bytes32, address).selector) {
        address strayRecipient;
        returnStray(e, key2, strayRecipient);
    } else if (f.selector == sig:receivePosition(uint256, address, bytes32).selector) {
        uint256 marketId;
        address owner;
        receivePosition(e, marketId, owner, key2);
    } else if (f.selector == sig:unwind(bytes32, uint128, uint256[], address).selector) {
        uint128 unwindUnits;
        uint256[] unwindMins;
        address unwindRecipient;
        unwind(e, key2, unwindUnits, unwindMins, unwindRecipient);
    } else if (f.selector == sig:releaseToDepositor(bytes32, uint128, uint256[]).selector) {
        uint128 releaseUnits;
        uint256[] releaseMins;
        releaseToDepositor(e, key2, releaseUnits, releaseMins);
    } else if (f.selector == sig:collectFees(bytes32, address).selector) {
        address feeDepositor;
        collectFees(e, key2, feeDepositor);
    } else {
        calldataarg args;
        f(e, args);
    }
}

// Scene setup shared by every rule: the LPVault is not the timelock or Collateralization, and the Lock's AaveAdapter is
// a non-zero address (the Lock's constructor refuses a zero member, Lock.spec PROP-075).
function setup() {
    require COLLATERALIZATION() != currentContract && TIMELOCK() != currentContract;
    require lockAdapter != 0;
}

definition isCollateralizationOnly(method f) returns bool =
    f.selector == sig:receivePosition(uint256, address, bytes32).selector
    || f.selector == sig:returnPosition(bytes32).selector
    || f.selector == sig:unwind(bytes32, uint128, uint256[], address).selector
    || f.selector == sig:releaseToDepositor(bytes32, uint128, uint256[]).selector
    || f.selector == sig:collectFees(bytes32, address).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Custody (PROP-002, PROP-003, PROP-038)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-002 verifies: INV-002, Q-066, Q-067, Q-240
// The LPVault holds every position that has a depositor of record. Stated as the inductive step over every non-view
// function, with `key2` the key of any key-taking call: the constructor writes no custody entry, so the property holds
// in the initial state, and this rule shows that every call preserves it for every key.
rule recordedPositionsAreHeld(method f, bytes32 key, bytes32 key2) filtered { f -> !f.isView } {
    env e;
    setup();
    require e.msg.sender != currentContract;
    address m;
    uint256 id;
    m, id = resolve(key);
    distinctNfts(key, m, id, key2);
    require currentContract._depositorOf[key] != 0 => nfpmOwner[m][id] == currentContract;

    callOnKey(f, e, key2);

    assert currentContract._depositorOf[key] != 0 => nfpmOwner[m][id] == currentContract,
        "a position with a depositor of record is not held by the LPVault";
}

// PROP-038 verifies: INV-007, Q-030, Q-104, Q-105, Q-134, Q-224, Q-228
rule positionLeavesOnlyToDepositorOrAsStray(method f, bytes32 key, bytes32 key2) filtered { f -> !f.isView } {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    distinctNfts(key, m, id, key2);
    require nfpmOwner[m][id] == currentContract;
    address depositor = currentContract._depositorOf[key];

    callOnKey(f, e, key2);

    bool left = nfpmOwner[m][id] != currentContract;
    assert left => (
        (f.selector == sig:returnPosition(bytes32).selector && key2 == key && e.msg.sender == COLLATERALIZATION()
            && depositor != 0 && nfpmOwner[m][id] == depositor)
        || (f.selector == sig:returnStray(bytes32, address).selector && key2 == key && e.msg.sender == TIMELOCK()
            && depositor == 0)),
        "a position left the LPVault other than to its depositor through Collateralization or as a stray through the timelock";
}

// PROP-003 verifies: INV-005, INV-007, Q-067, Q-104, Q-134, Q-240
rule strayReturnNeverMovesRecordedPosition(bytes32 key, address recipient) {
    env e;
    setup();
    require currentContract._depositorOf[key] != 0;

    returnStray@withrevert(e, key, recipient);

    assert lastReverted, "a position with a depositor of record was returned through the stray path";
}

// PROP-038 verifies: INV-007, Q-104, Q-228
// PROP-034 verifies: INV-051, Q-226, Q-228
rule returnStrayIsTimelockAndStray(bytes32 key, address recipient) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    address ownerBefore = nfpmOwner[m][id];
    address depositorBefore = currentContract._depositorOf[key];

    returnStray(e, key, recipient);

    assert e.msg.sender == TIMELOCK(), "returnStray ran for a caller other than the timelock";
    assert ownerBefore == currentContract && depositorBefore == 0, "returnStray moved a position that was not stray";
    assert recipient != 0 && recipient != currentContract && nfpmOwner[m][id] == recipient,
        "stray position not sent to the named recipient";
}

// PROP-038 verifies: INV-007, Q-105, Q-224
rule receivePositionRecordsTheOwnerItPulledFrom(uint256 marketId, address owner, bytes32 key) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    address ownerBefore = nfpmOwner[m][id];

    receivePosition(e, marketId, owner, key);

    assert ownerBefore == owner && owner != currentContract, "custody taken from an address other than the owner";
    assert nfpmOwner[m][id] == currentContract && currentContract._depositorOf[key] == owner,
        "the depositor of record is not the wallet the position came from";
}

// PROP-002 verifies: INV-005, Q-292, Q-359
// A position is received only on its market's pinned position manager (Slipstream: the key's generation is the
// market's, REQ-AMM-SLIP-007) and is recorded against that market.
rule receivePositionKeepsTheMarketsPositionManager(uint256 marketId, address owner, bytes32 key) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);

    receivePosition(e, marketId, owner, key);

    assert m == currentContract._markets[marketId].cfg.positionManager,
        "a position of another position manager was received into the market";
    assert currentContract._marketOfPosition[key] == marketId, "the position is recorded against another market";
}

// ---------------------------------------------------------------------------------------------------------------------
// Unwinds, releases and fees (PROP-002, PROP-038; SPEC-BACK-008 principal-capped collect)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-002 verifies: INV-002, Q-066, Q-131
// PROP-038 verifies: INV-007, Q-030, Q-224
rule unwindTakesExactlyAndCollectsPrincipal(bytes32 key, uint128 l, uint256[] minAmounts, address recipient) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    mathint liquidityBefore = nfpmLiquidity[m][id];
    mathint owed0Before = nfpmOwed0[m][id];
    mathint owed1Before = nfpmOwed1[m][id];
    resetCall(recipient, m, id);

    unwind(e, key, l, minAmounts, recipient);

    assert nfpmLiquidity[m][id] == liquidityBefore - l, "units not lowered by exactly the amount asked";
    assert collected0 == principalRemoved0 && collected1 == principalRemoved1,
        "collect took other than the removed principal";
    assert nfpmOwed0[m][id] == owed0Before && nfpmOwed1[m][id] == owed1Before, "an unwind collected owed fees";
    assert collectsToOthers == 0 && recipient != 0 && recipient != currentContract,
        "principal paid to an address other than the named recipient";
    assert callsOnOtherNfts == 0, "an unwind removed or collected on another NFT";
}

// PROP-038 verifies: INV-007, Q-224, Q-254
// PROP-065 verifies: INV-088, Q-254
rule releaseToDepositorPaysOnlyTheDepositor(bytes32 key, uint128 l, uint256[] minAmounts) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    address depositor = currentContract._depositorOf[key];
    mathint liquidityBefore = nfpmLiquidity[m][id];
    mathint owed0Before = nfpmOwed0[m][id];
    mathint owed1Before = nfpmOwed1[m][id];
    resetCall(depositor, m, id);

    releaseToDepositor(e, key, l, minAmounts);

    assert depositor != 0, "released units of a position not in custody";
    assert nfpmLiquidity[m][id] == liquidityBefore - l, "units not lowered by exactly the amount asked";
    assert collected0 == principalRemoved0 && collected1 == principalRemoved1,
        "collect took other than the removed principal";
    assert nfpmOwed0[m][id] == owed0Before && nfpmOwed1[m][id] == owed1Before, "a partial removal collected owed fees";
    assert collectsToOthers == 0, "principal of a partial removal went to an address other than the depositor of record";
    assert callsOnOtherNfts == 0, "a partial removal removed or collected on another NFT";
}

// PROP-038 verifies: INV-007, Q-030, Q-104, Q-105, Q-134
// PROP-032 verifies: Q-122, Q-158, Q-209
// Collateralization passes the wallet that called `AaveAdapter.collectFees` as `depositor`.
rule collectFeesPaysOnlyDepositor(bytes32 key, address depositor) {
    env e;
    setup();
    address m;
    uint256 id;
    m, id = resolve(key);
    address recordDepositor = currentContract._depositorOf[key];
    mathint liquidityBefore = nfpmLiquidity[m][id];
    resetCall(recordDepositor, m, id);

    collectFees(e, key, depositor);

    assert depositor == recordDepositor && recordDepositor != 0,
        "fees collected for a wallet other than the depositor of record";
    assert collectsToOthers == 0, "fees were collected to an address other than the depositor of record";
    assert nfpmLiquidity[m][id] == liquidityBefore && decreaseCalls == 0, "fee collection changed liquidity";
    assert callsOnOtherNfts == 0, "fee collection collected on another NFT";
}

// PROP-038 verifies: INV-007, Q-030
rule collectFeesIsReachableAtZeroCredit(bytes32 key, address depositor) {
    env e;
    setup();
    require currentContract._depositorOf[key] == depositor;
    collectFees(e, key, depositor);
    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Callers and the Lock (PROP-037)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-037 verifies: INV-054, Q-148, Q-223
rule custodyEntryPointsNeedCollateralizationUnderLock(method f) filtered { f -> isCollateralizationOnly(f) } {
    env e;
    calldataarg args;
    setup();
    address holderBefore = lockHolder;

    f(e, args);

    assert e.msg.sender == COLLATERALIZATION() && holderBefore != 0,
        "a custody, unwind or fee entry point ran for a caller other than Collateralization or without the lock";
}

// PROP-037 verifies: INV-054, Q-148, Q-296
// Fee collection runs only inside the AaveAdapter's Lock session (REQ-VAULT-064), never under LPVaultSwap's.
rule collectFeesNeedsTheAaveAdapterLock(bytes32 key, address depositor) {
    env e;
    setup();
    address holderBefore = lockHolder;

    collectFees(e, key, depositor);

    assert e.msg.sender == COLLATERALIZATION() && holderBefore == lockAdapter,
        "fees were collected outside a Lock session held by the AaveAdapter";
}
