/*
 * RiskModule bands (src/policy/risk-module/RiskModule.sol, band arithmetic in libraries/BandMath.sol, design in
 * src/policy/risk-module/DESIGN.md decisions 1 and 3), through RiskModuleHarness
 * (test/utils/harness/RiskModuleHarness.sol), which adds `listingTickOf`: the tick of the Chainlink listing price that
 * `listPool` computes, by the same internal code path.
 *
 * `listPool` lists each pool as two band markets: Full range (the pool's usable tick range) and Custom range (a width
 * around the listing tick, from the Spoke kind's default or the listing's override). The rules:
 *
 *   marketsFromNextIdUnlisted                   no market at or past the next market ID is listed (so a listing never
 *                                               writes over a listed market)
 *   listedBandNeverChanges                      no function changes a listed market's pool or band ticks
 *   listPoolCustomBandContainsListingPrice      the Custom range band contains the tick of the Chainlink listing price
 *   listPoolCustomBandAtLeastMinWidth           the Custom range band spans at least MIN_BAND_SPACINGS (4) tick spacings
 *   listPoolCustomBandNarrowerThanFullRange     the Custom range band lies inside the Full range band and is not equal
 *   listPoolFullRangeIsUsableTicks              the Full range band is [MIN_TICK, MAX_TICK] rounded toward zero to the
 *                                               tick spacing: the pool's min and max usable ticks
 *   onlyAuthorizedCallerSetsSpokeWidth          setSpokeWidth succeeds only for a caller the AccessManager authorizes
 *                                               (the DAO's role)
 *   spokeWidthsChangeOnlyBySetSpokeWidth        no other function changes a Spoke kind's default width
 *
 * Summaries:
 *  - The LPVault's `listMarket` is NONDET (it records the market in the LPVault, not here); its `getMarket` returns a
 *    ghost market per ID, each token's and feed's `decimals` a ghost per address, and each Chainlink feed's
 *    `latestRoundData` a ghost answer per feed, so `listingTickOf` and `listPool` read the same listing price.
 *  - Other external reads (activation and coverage) are unresolved view calls: any return value.
 *  - The AccessManager is OpenZeppelin's v5.1.0 code for the authorization rule (`authority()` is required to be it);
 *    `consumeScheduledOp` is NONDET.
 */

using AccessManager as manager;

methods {
    function spokeWidth(IRiskModule.SpokeKind) external returns (IRiskModule.Width) envfree;
    function listPool(IRiskModule.ListPoolParams) external returns (uint256, uint256);
    function setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width) external;

    function manager.canCall(address, address, bytes4) external returns (bool, uint32);
    function _.consumeScheduledOp(address, bytes) external => NONDET;
    function _.listMarket(uint256, bytes32, int24, int24) external => NONDET;
    function _.getMarket(uint256 id) external => vaultMarket(id) expect (ILPVault.Market);
    function _.decimals() external => decimalsOf(calledContract) expect (uint8);
    function _.latestRoundData() external => feedRound(calledContract) expect (uint80, int256, uint256, uint256, uint80);
}

definition MAX_TICK() returns mathint = 887272;
definition MIN_SPACINGS() returns mathint = 4;

definition bandLowerOf(uint256 id) returns int24 = currentContract._markets[id].bandLower;
definition bandUpperOf(uint256 id) returns int24 = currentContract._markets[id].bandUpper;
definition poolOf(uint256 id) returns bytes32 = currentContract._markets[id].pool;

// ---------------------------------------------------------------------------------------------------------------------
// External reads, fixed per input so two reads of the listing price agree
// ---------------------------------------------------------------------------------------------------------------------

ghost mapping(uint256 => address) vaultToken0;
ghost mapping(uint256 => address) vaultToken1;
ghost mapping(address => uint8) decimalsGhost;
ghost mapping(address => int256) feedAnswer;

function vaultMarket(uint256 id) returns ILPVault.Market {
    ILPVault.Market m;
    require m.token0 == vaultToken0[id] && m.token1 == vaultToken1[id];
    return m;
}

function decimalsOf(address target) returns uint8 {
    return decimalsGhost[target];
}

function feedRound(address feed) returns (uint80, int256, uint256, uint256, uint80) {
    uint80 roundId;
    uint256 startedAt;
    uint256 updatedAt;
    uint80 answeredInRound;
    return (roundId, feedAnswer[feed], startedAt, updatedAt, answeredInRound);
}

// ---------------------------------------------------------------------------------------------------------------------
// A listed band is immutable
// ---------------------------------------------------------------------------------------------------------------------

invariant marketsFromNextIdUnlisted(uint256 id)
    id >= currentContract._nextMarketId => poolOf(id) == to_bytes32(0)
    filtered { f -> f.contract == currentContract }

rule listedBandNeverChanges(method f, uint256 id) filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    requireInvariant marketsFromNextIdUnlisted(id);
    bytes32 pool = poolOf(id);
    int24 lower = bandLowerOf(id);
    int24 upper = bandUpperOf(id);
    require pool != to_bytes32(0);

    f(e, args);

    assert poolOf(id) == pool, "a listed market's pool changed";
    assert bandLowerOf(id) == lower && bandUpperOf(id) == upper, "a listed market's band moved";
}

// ---------------------------------------------------------------------------------------------------------------------
// The listing checks
// ---------------------------------------------------------------------------------------------------------------------

rule listPoolCustomBandContainsListingPrice(IRiskModule.ListPoolParams p) {
    env e;
    int24 tick = listingTickOf(e, p, currentContract._nextMarketId);
    uint256 fullRange;
    uint256 customRange;
    fullRange, customRange = listPool(e, p);
    assert bandLowerOf(customRange) <= tick && tick < bandUpperOf(customRange),
        "the Custom range band excludes the listing price";
}

rule listPoolCustomBandAtLeastMinWidth(IRiskModule.ListPoolParams p) {
    env e;
    uint256 fullRange;
    uint256 customRange;
    fullRange, customRange = listPool(e, p);
    assert bandUpperOf(customRange) - bandLowerOf(customRange) >= MIN_SPACINGS() * p.tickSpacing,
        "the Custom range band spans fewer than MIN_BAND_SPACINGS tick spacings";
}

rule listPoolCustomBandNarrowerThanFullRange(IRiskModule.ListPoolParams p) {
    env e;
    uint256 fullRange;
    uint256 customRange;
    fullRange, customRange = listPool(e, p);
    assert bandLowerOf(fullRange) <= bandLowerOf(customRange) && bandUpperOf(customRange) <= bandUpperOf(fullRange),
        "the Custom range band leaves the Full range band";
    assert bandLowerOf(customRange) != bandLowerOf(fullRange) || bandUpperOf(customRange) != bandUpperOf(fullRange),
        "the Custom range band is the full range";
}

// MIN_TICK = -MAX_TICK and Solidity's division truncates toward zero, so the usable ticks are -/+ (MAX_TICK / s) * s.
rule listPoolFullRangeIsUsableTicks(IRiskModule.ListPoolParams p) {
    env e;
    uint256 fullRange;
    uint256 customRange;
    fullRange, customRange = listPool(e, p);
    assert p.tickSpacing > 0, "listed with a non-positive tick spacing";
    mathint usable = (MAX_TICK() / p.tickSpacing) * p.tickSpacing;
    assert bandLowerOf(fullRange) == -usable && bandUpperOf(fullRange) == usable,
        "the Full range band is not the pool's usable tick range";
}

// ---------------------------------------------------------------------------------------------------------------------
// Only the DAO changes the Spoke widths
// ---------------------------------------------------------------------------------------------------------------------

rule onlyAuthorizedCallerSetsSpokeWidth(IRiskModule.SpokeKind kind, IRiskModule.Width width) {
    env e;
    require authority(e) == manager;
    bool immediate;
    uint32 delay;
    immediate, delay = manager.canCall(
        e, e.msg.sender, currentContract, to_bytes4(sig:setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width).selector)
    );

    setSpokeWidth@withrevert(e, kind, width);

    assert !lastReverted => (immediate || delay > 0), "a caller the AccessManager does not authorize set a width";
}

rule spokeWidthsChangeOnlyBySetSpokeWidth(method f, IRiskModule.SpokeKind kind)
    filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    IRiskModule.Width before = spokeWidth(kind);

    f(e, args);

    IRiskModule.Width after = spokeWidth(kind);
    assert (after.below != before.below || after.above != before.above)
        => f.selector == sig:setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width).selector,
        "a Spoke width changed outside setSpokeWidth";
}
