/*
 * First-Loss Reserve (src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol against
 * src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol, spec 2.14 First-Loss Reserve).
 *
 * `coverDeficit(borrowSpoke, maxAmount)` calls `Hub.eliminateDeficit` at most once, only on its own `(HUB(),
 * ASSET_ID())`, only for a Borrow Spoke on its DAO-set allowlist, and only for
 * `amount <= min(maxAmount, ceil(deficitRay / RAY), fundedBalance())` (SPEC-FLR-001); `fund(amount)` moves exactly
 * `amount` of `ASSET()` from the caller to `HUB()` and adds it on `ASSET_ID()` only, so a reserve spends and receives
 * only its own asset (PROP-039, PROP-060).
 *
 * The First-Loss Reserve is a supply-only Spoke on one asset of one Hub, written by Avana and controlled by the Aave DAO
 * through its own AccessManager; certora/conf/AvanaFirstLossReserve.conf runs this spec. Storage assumption: `allowedBorrowSpoke` as in the 2.14 Storage table.
 *
 * Summaries: the Hub's `eliminateDeficit` and `add` record their arguments; `getSpokeDeficitRay`, the Spoke list
 * (`getSpokeCount`, `getSpokeAddress`, read by `executeWithdrawal`), added assets and added shares are ghost functions of
 * the Hub state, so `fundedBalance()` read in a rule and inside `coverDeficit` in
 * the same state agree; tokens by the ERC-20 model. The `COVERAGE_ROLE` check is OpenZeppelin `AccessManaged`
 * against the Aave DAO's AccessManager, whose interface is outside contracts/src; its `canCall` stays unresolved, so
 * the rules hold for every role decision and do not state who may call.
 */

import "setup/Erc20Model.spec";

methods {
    function coverDeficit(address, uint256) external returns (uint256, uint256);
    function fund(uint256) external returns (uint256);
    function fundedBalance() external returns (uint256);
    function ASSET() external returns (address) envfree;
    function HUB() external returns (address) envfree;
    function ASSET_ID() external returns (uint256) envfree;

    function _.eliminateDeficit(uint256 assetId, uint256 amount, address spoke) external => hubEliminateDeficit(calledContract, assetId, amount, spoke) expect (uint256, uint256);
    function _.add(uint256 assetId, uint256 amount) external => hubAdd(calledContract, assetId, amount) expect uint256;
    function _.getSpokeDeficitRay(uint256 assetId, address spoke) external => hubDeficitRayOf(calledContract, assetId, spoke) expect uint256;
    function _.getSpokeCount(uint256 a) external => hubSpokeCount(calledContract, a) expect uint256;
    function _.getSpokeAddress(uint256 a, uint256 i) external => hubSpokeAt(calledContract, a, i) expect address;
    function _.getSpokeAddedShares(uint256 a, address s) external => hubSpokeShares(calledContract, a, s) expect uint256;
    function _.getSpokeAddedAssets(uint256 a, address s) external => hubSpokeAssets(calledContract, a, s) expect uint256;
    function _.getAddedAssets(uint256 a) external => hubAssets(calledContract, a) expect uint256;
    function _.getAddedShares(uint256 a) external => hubShares(calledContract, a) expect uint256;
    function _.getAssetUnderlyingAndDecimals(uint256 a) external => NONDET;
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => erc20TransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.transfer(address to, uint256 a) external with (env e) => erc20Transfer(calledContract, e.msg.sender, to, a) expect bool;
}

// Hub state for the rule. Persistent: the only unsummarised call `coverDeficit` makes is the AccessManager's `canCall`
// (a STATICCALL through `restricted`), which cannot change the Hub, so the Hub reads inside the call agree with the
// reads the rule makes before it.
persistent ghost hubDeficitRayOf(address, uint256, address) returns uint256;
persistent ghost hubSpokeShares(address, uint256, address) returns uint256;
persistent ghost hubSpokeAssets(address, uint256, address) returns uint256;
persistent ghost hubAssets(address, uint256) returns uint256;
persistent ghost hubShares(address, uint256) returns uint256;
persistent ghost hubSpokeCount(address, uint256) returns uint256;
persistent ghost hubSpokeAt(address, uint256, uint256) returns address;

persistent ghost mathint eliminateCalls;
persistent ghost address lastHub;
persistent ghost uint256 lastAssetId;
persistent ghost address lastEliminateSpoke;
persistent ghost mathint lastEliminateAmount;
persistent ghost mathint lastDeficitRay;
persistent ghost mathint addCalls;
persistent ghost bool addOnOtherAsset;

function hubEliminateDeficit(address hub, uint256 assetId, uint256 amount, address spoke) returns (uint256, uint256) {
    eliminateCalls = eliminateCalls + 1;
    lastHub = hub;
    lastAssetId = assetId;
    lastEliminateSpoke = spoke;
    lastEliminateAmount = amount;
    lastDeficitRay = hubDeficitRayOf(hub, assetId, spoke);
    uint256 shares;
    uint256 eliminated;
    return (shares, eliminated);
}

function hubAdd(address hub, uint256 assetId, uint256 amount) returns uint256 {
    addCalls = addCalls + 1;
    if (hub != HUB() || assetId != ASSET_ID()) {
        addOnOtherAsset = true;
    }
    uint256 shares;
    return shares;
}

function resetCoverageModel() {
    eliminateCalls = 0;
    lastHub = 0;
    lastAssetId = 0;
    lastEliminateSpoke = 0;
    lastEliminateAmount = 0;
    lastDeficitRay = 0;
    addCalls = 0;
    addOnOtherAsset = false;
}

definition RAY() returns mathint = 10^27;

// PROP-039 verifies: INV-042, Q-101, Q-142, Q-190, Q-236
// PROP-060 verifies: INV-042, INV-071, Q-236
rule coverDeficitOnlyAllowlistedOwnAssetAndBounded(address borrowSpoke, uint256 maxAmount) {
    env e;
    resetCoverageModel();
    bool allowed = currentContract.allowedBorrowSpoke[borrowSpoke];
    mathint funded = fundedBalance(e);

    coverDeficit(e, borrowSpoke, maxAmount);

    assert eliminateCalls == 1, "coverDeficit did not eliminate exactly once";
    assert allowed && lastEliminateSpoke == borrowSpoke, "eliminateDeficit invoked for a Spoke that is not on the allowlist";
    assert lastHub == HUB() && lastAssetId == ASSET_ID(), "eliminateDeficit invoked on another Hub or asset";
    assert lastEliminateAmount > 0 && lastEliminateAmount <= to_mathint(maxAmount), "the covered amount exceeds maxAmount";
    assert lastEliminateAmount * RAY() <= lastDeficitRay + RAY() - 1, "the covered amount exceeds ceil(deficitRay / RAY)";
    assert lastEliminateAmount <= funded, "the covered amount exceeds fundedBalance()";
}

// PROP-039 verifies: INV-042, Q-101, Q-142
rule coverDeficitIsReachable(address borrowSpoke, uint256 maxAmount) {
    env e;
    resetCoverageModel();
    coverDeficit(e, borrowSpoke, maxAmount);
    satisfy lastEliminateAmount > 0;
}

// PROP-060 verifies: INV-042, INV-071, Q-236
rule fundAddsOnlyItsOwnAsset(uint256 amount, address token) {
    env e;
    resetCoverageModel();
    require e.msg.sender != HUB() && e.msg.sender != currentContract;
    address asset = ASSET();
    mathint callerBefore = erc20Bal[asset][e.msg.sender];
    mathint hubBefore = erc20Bal[asset][HUB()];
    require token != asset;
    mathint otherTokenBefore = erc20Bal[token][e.msg.sender];

    fund(e, amount);

    assert amount > 0, "fund accepted a zero amount";
    assert erc20Bal[asset][e.msg.sender] == callerBefore - amount && erc20Bal[asset][HUB()] == hubBefore + amount,
        "fund moved other than exactly amount of the asset from the caller to the Hub";
    assert erc20Bal[token][e.msg.sender] == otherTokenBefore, "fund moved another token";
    assert addCalls == 1 && !addOnOtherAsset, "fund added on another Hub or asset";
    assert eliminateCalls == 0, "fund eliminated a deficit";
}
