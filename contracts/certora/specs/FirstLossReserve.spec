/*
 * FirstLossReserve (src/coverage/first-loss-reserve/FirstLossReserve.sol, interface IFirstLossReserve.sol, design
 * DESIGN.md): Avana's first-loss layer and the DAO deficit offset of one (Hub, asset), holding Hub added shares.
 *
 *   onlyAuthorizedCallerCoversDeficit     coverDeficit succeeds only for a caller the AccessManager authorizes
 *   onlyAuthorizedCallerWithdraws         withdraw succeeds only for a caller the AccessManager authorizes
 *   delayedWithdrawalConsumesSchedule     WITHDRAWAL_DELAY is 14 days, and a caller whose role carries an execution
 *                                         delay withdraws only by consuming its scheduled operation, which the
 *                                         AccessManager releases only after the delay
 *   withdrawalWaitsWhileDeficitOutstanding a withdrawal succeeds only when no allowed Spoke of the Hub has a deficit
 *   coverOnlyAllowedSpoke                 coverage burns shares only for an allowed Spoke, on the reserve's own asset
 *   coverPaysAtMostRecordedDeficit        coverage is positive and at most the Spoke's recorded deficit (rounded up to
 *                                         a whole unit), the caller's cap and the funded balance
 *
 * Summaries: the Hub's deficit, Spoke list and added-assets reads are ghosts; `eliminateDeficit` records its
 * arguments; `consumeScheduledOp` records its caller; `remove`, `add`, the first-loss layer's reads and token calls
 * are NONDET. The AccessManager's `canCall` decision is the ghost AuthorityModel (setup/AuthorityModel.spec), bound
 * by sighash because the low-level STATICCALL of `restricted` has no resolvable target.
 */

import "setup/AuthorityModel.spec";

methods {
    function coverDeficit(address, uint256) external returns (uint256, uint256);
    function withdraw(uint256, address) external returns (uint256);
    function isAllowedSpoke(address) external returns (bool) envfree;
    function WITHDRAWAL_DELAY() external returns (uint32) envfree;
    function ASSET_ID() external returns (uint256) envfree;

    function _.canCall(address caller, address target, bytes4 selector) external
        => authorityCanCall(caller, target, selector) expect (bool, uint32);
    function _.consumeScheduledOp(address caller, bytes) external => recordConsume(caller) expect void;

    // Hub
    function _.getSpokeDeficitRay(uint256, address spoke) external => deficitRay[spoke] expect uint256;
    function _.getSpokeAddedAssets(uint256, address) external => fundedGhost expect uint256;
    function _.getSpokeCount(uint256) external => spokeCount expect uint256;
    function _.getSpokeAddress(uint256, uint256 i) external => spokeAt[i] expect address;
    function _.eliminateDeficit(uint256 assetId, uint256 amount, address spoke) external => recordCover(assetId, amount, spoke) expect (uint256, uint256);
    function _.remove(uint256, uint256, address) external => NONDET;
    function _.add(uint256, uint256) external => NONDET;
    function _.fundedBalance() external => NONDET;
}

definition RAY() returns mathint = 10^27;

ghost mapping(address => uint256) deficitRay;
ghost uint256 fundedGhost;
ghost uint256 spokeCount;
ghost mapping(uint256 => address) spokeAt;

persistent ghost bool consumed;
persistent ghost address consumedFor;
persistent ghost bool covered;
persistent ghost uint256 coverAssetId;
persistent ghost uint256 coverAmount;
persistent ghost address coverSpoke;

function recordConsume(address caller) {
    consumed = true;
    consumedFor = caller;
}

function recordCover(uint256 assetId, uint256 amount, address spoke) returns (uint256, uint256) {
    covered = true;
    coverAssetId = assetId;
    coverAmount = amount;
    coverSpoke = spoke;
    uint256 shares;
    uint256 assets;
    return (shares, assets);
}

// ---------------------------------------------------------------------------------------------------------------------
// Only authorized callers pay out
// ---------------------------------------------------------------------------------------------------------------------

rule onlyAuthorizedCallerCoversDeficit(address spoke, uint256 maxAmount) {
    env e;
    bytes4 selector = to_bytes4(sig:coverDeficit(address, uint256).selector);

    coverDeficit@withrevert(e, spoke, maxAmount);

    assert !lastReverted => authorized(e.msg.sender, currentContract, selector),
        "a caller the AccessManager does not authorize covered a deficit";
}

rule onlyAuthorizedCallerWithdraws(uint256 amount, address to) {
    env e;
    bytes4 selector = to_bytes4(sig:withdraw(uint256, address).selector);

    withdraw@withrevert(e, amount, to);

    assert !lastReverted => authorized(e.msg.sender, currentContract, selector),
        "a caller the AccessManager does not authorize withdrew";
}

// ---------------------------------------------------------------------------------------------------------------------
// The 14-day withdrawal delay
// ---------------------------------------------------------------------------------------------------------------------

rule delayedWithdrawalConsumesSchedule(uint256 amount, address to) {
    env e;
    require !consumed;
    bytes4 selector = to_bytes4(sig:withdraw(uint256, address).selector);

    withdraw(e, amount, to);

    assert WITHDRAWAL_DELAY() == 1209600, "WITHDRAWAL_DELAY is not 14 days";
    assert !authImmediate[e.msg.sender][currentContract][selector] => (consumed && consumedFor == e.msg.sender),
        "a delayed caller withdrew without consuming its scheduled operation";
}

rule withdrawalWaitsWhileDeficitOutstanding(uint256 amount, address to, uint256 i) {
    env e;
    require spokeCount <= 2;
    withdraw(e, amount, to);
    assert i < spokeCount => !(isAllowedSpoke(spokeAt[i]) && deficitRay[spokeAt[i]] != 0),
        "a withdrawal went through while an allowed Spoke had a deficit";
}

// ---------------------------------------------------------------------------------------------------------------------
// Pays only real deficits
// ---------------------------------------------------------------------------------------------------------------------

rule coverOnlyAllowedSpoke(address spoke, uint256 maxAmount) {
    env e;
    require !covered;
    coverDeficit(e, spoke, maxAmount);
    assert isAllowedSpoke(spoke), "covered a Spoke the reserve does not allow";
    assert covered && coverSpoke == spoke && coverAssetId == ASSET_ID(), "covered another Spoke or asset";
}

rule coverPaysAtMostRecordedDeficit(address spoke, uint256 maxAmount) {
    env e;
    require !covered;
    coverDeficit(e, spoke, maxAmount);
    assert covered && coverAmount > 0, "no positive coverage";
    assert coverAmount * RAY() < deficitRay[spoke] + RAY(), "coverage exceeds the recorded deficit";
    assert coverAmount <= maxAmount && coverAmount <= fundedGhost, "coverage exceeds the cap or the funded balance";
}
