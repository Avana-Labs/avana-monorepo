/*
 * FirstLossReserve (src/FirstLossReserve.sol, interface IFirstLossReserve.sol, design
 * design/reserve.md): Avana's first-loss layer and the DAO deficit offset of one (Hub, asset), holding Hub added shares.
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
 *   coverAmountIsExact                    coverage is exactly the least of the caller's cap, the part of the Spoke's
 *                                         recorded deficit (rounded up to a whole unit) beyond what the first-loss
 *                                         layer in front holds, and the funded balance, in one eliminateDeficit call
 *   offsetPaysOnlyBeyondFrontLayer        the waterfall by amount: a reserve behind a first-loss layer (the DAO offset)
 *                                         pays at most the deficit less what that layer holds while it is active on
 *                                         the Hub; Avana's reserve (no layer) pays the whole deficit. So the order is
 *                                         Avana's reserve, then the DAO offset, then what is left stays recorded on
 *                                         the Hub
 *   oneWeiCannotBlockTheOffset            while the layer in front holds less than the deficit, an authorized cover of
 *                                         an allowed Spoke with a positive cap and funds goes through: a deposit into
 *                                         the front layer (`fund` is open) lowers the offset's part but cannot stop it
 *                                         (finding F5 of the step 9 review, fixed in PR 378)
 *   noDoublePayment                       two coverages of one Spoke pay together at most its recorded deficit
 *                                         rounded up, and once a coverage cancelled the whole deficit the next one
 *                                         reverts
 *
 * Summaries: the Hub's deficit, Spoke list and added-assets reads are ghosts; `eliminateDeficit` records its
 * arguments and applies Aave V4's own arithmetic (Hub.eliminateDeficit at a3ef63e): it cancels `amount` whole units
 * of the Spoke's deficit, or the whole deficit when `amount` reaches it rounded up, and returns the units cancelled
 * rounded up; the Hub's Spoke config of the first-loss layer (`active`) and the layer's `fundedBalance` are ghosts
 * per address; `consumeScheduledOp` records its caller; `remove`, `add` and token calls are NONDET. The AccessManager's `canCall` decision is the ghost AuthorityModel (setup/AuthorityModel.spec), bound
 * by sighash because the low-level STATICCALL of `restricted` has no resolvable target.
 */

import "setup/AuthorityModel.spec";
import "setup/TransientModel.spec";

methods {
    function coverDeficit(address, uint256) external returns (uint256, uint256);
    function withdraw(uint256, address) external returns (uint256);
    function isAllowedSpoke(address) external returns (bool) envfree;
    function WITHDRAWAL_DELAY() external returns (uint32) envfree;
    function ASSET_ID() external returns (uint256) envfree;
    function FIRST_LOSS_LAYER() external returns (address) envfree;

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
    function _.fundedBalance() external => layerFunded[calledContract] expect uint256;
    function _.getSpokeConfig(uint256, address spoke) external => hubSpokeConfig(spoke) expect (IAaveV4Hub.SpokeConfig);
}

definition RAY() returns mathint = 10^27;

ghost mapping(address => uint256) deficitRay;
ghost uint256 fundedGhost;
ghost uint256 spokeCount;
ghost mapping(uint256 => address) spokeAt;

ghost mapping(address => bool) spokeActive;
ghost mapping(address => uint256) layerFunded;
persistent ghost mathint coverCalls;

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

function hubSpokeConfig(address spoke) returns IAaveV4Hub.SpokeConfig {
    IAaveV4Hub.SpokeConfig c;
    require c.active == spokeActive[spoke];
    return c;
}

// floor and ceiling of x / RAY.
function ceilRay(mathint x) returns mathint {
    return (x + RAY() - 1) / RAY();
}

// Hub.eliminateDeficit (Aave V4 a3ef63e): deficitAmountRay = amount < ceil(deficitRay / RAY) ? amount * RAY : deficitRay;
// the Spoke's deficit falls by it and the Hub returns ceil(deficitAmountRay / RAY) units with the shares it burned.
function recordCover(uint256 assetId, uint256 amount, address spoke) returns (uint256, uint256) {
    covered = true;
    coverAssetId = assetId;
    coverAmount = amount;
    coverSpoke = spoke;
    coverCalls = coverCalls + 1;
    mathint d = deficitRay[spoke];
    mathint eliminated = to_mathint(amount) < ceilRay(d) ? amount * RAY() : d;
    deficitRay[spoke] = require_uint256(d - eliminated);
    uint256 shares;
    return (shares, require_uint256(ceilRay(eliminated)));
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
    mathint deficit = deficitRay[spoke];
    coverDeficit(e, spoke, maxAmount);
    assert covered && coverAmount > 0, "no positive coverage";
    assert coverAmount * RAY() < deficit + RAY(), "coverage exceeds the recorded deficit";
    assert coverAmount <= maxAmount && coverAmount <= fundedGhost, "coverage exceeds the cap or the funded balance";
}

rule coverAmountIsExact(address spoke, uint256 maxAmount) {
    env e;
    require !covered;
    require coverCalls == 0;
    mathint front = frontBalance();
    mathint deficit = ceilRay(deficitRay[spoke]) - front;
    mathint funded = fundedGhost;

    coverDeficit(e, spoke, maxAmount);

    mathint capped = maxAmount < deficit ? maxAmount : deficit;
    mathint least = capped < funded ? capped : funded;
    assert coverCalls == 1, "coverage did not make exactly one eliminateDeficit call";
    assert to_mathint(coverAmount) == least, "coverage is not the least of the cap, the deficit and the funded balance";
}

// ---------------------------------------------------------------------------------------------------------------------
// The waterfall and no double payment
// ---------------------------------------------------------------------------------------------------------------------

// What the first-loss layer in front holds while it is active on the Hub; 0 for Avana's own reserve.
function frontBalance() returns mathint {
    address layer = FIRST_LOSS_LAYER();
    return (layer != 0 && spokeActive[layer]) ? to_mathint(layerFunded[layer]) : 0;
}

rule offsetPaysOnlyBeyondFrontLayer(address spoke, uint256 maxAmount) {
    env e;
    require !covered;
    mathint front = frontBalance();
    mathint owed = ceilRay(deficitRay[spoke]);
    coverDeficit(e, spoke, maxAmount);
    assert coverAmount + front <= owed, "the offset paid part of the deficit the first-loss layer in front holds";
}

rule oneWeiCannotBlockTheOffset(address spoke, uint256 maxAmount) {
    env e;
    transientStorageEmpty();
    require e.msg.value == 0;
    require isAllowedSpoke(spoke);
    require authImmediate[e.msg.sender][currentContract][to_bytes4(sig:coverDeficit(address, uint256).selector)];
    require frontBalance() < ceilRay(deficitRay[spoke]);
    require maxAmount > 0 && fundedGhost > 0;

    coverDeficit@withrevert(e, spoke, maxAmount);

    assert !lastReverted, "a cover was refused while the front layer held less than the deficit";
}

rule noDoublePayment(address spoke, uint256 max1, uint256 max2) {
    env e1;
    env e2;
    require !covered;
    mathint deficit = ceilRay(deficitRay[spoke]);

    uint256 shares1;
    uint256 paid1;
    shares1, paid1 = coverDeficit(e1, spoke, max1);
    mathint amount1 = coverAmount;
    bool settled = deficitRay[spoke] == 0;

    uint256 shares2;
    uint256 paid2;
    shares2, paid2 = coverDeficit@withrevert(e2, spoke, max2);
    bool reverted = lastReverted;
    mathint amount2 = reverted ? 0 : to_mathint(coverAmount);

    assert to_mathint(paid1) == amount1, "the Hub cancelled another amount than the reserve paid";
    assert amount1 + amount2 <= deficit, "two coverages paid more than the recorded deficit";
    assert settled => reverted, "a coverage paid a deficit already cancelled";
}
