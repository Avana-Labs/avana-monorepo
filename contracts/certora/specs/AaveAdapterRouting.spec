/*
 * AaveAdapter routing (src/adapter/DESIGN.md decision 2): a pledge names only the NFT, and
 * `RiskModule.routeOf(pool, tickLower, tickUpper)` picks its market. AaveAdapterAccounts.spec proves the adapter pledges
 * into exactly that market and reverts on 0. Verified on RiskModuleHarness (test/utils/harness/RiskModuleHarness.sol),
 * which is the RiskModule unchanged plus a view.
 *
 *   routeFullRangeToFullMarket   ticks equal to the Full range band route to the pool's Full range market
 *   routeInsideCustomToCustom    any other ticks fully inside the Custom range band route to the Custom range market
 *   routeOtherwiseNone           anything else, or an unlisted pool, routes to 0 (the adapter reverts NoMarketFits)
 *
 * No summaries: routeOf reads only the RiskModule's own storage.
 */

methods {
    function routeOf(bytes32, int24, int24) external returns (uint256) envfree;
}

definition fullOf(bytes32 pool) returns uint256 = currentContract._poolMarkets[pool].fullRange;
definition customOf(bytes32 pool) returns uint256 = currentContract._poolMarkets[pool].customRange;

definition isFullRange(bytes32 pool, int24 lower, int24 upper) returns bool =
    lower == currentContract._markets[fullOf(pool)].bandLower && upper == currentContract._markets[fullOf(pool)].bandUpper;

definition insideCustom(bytes32 pool, int24 lower, int24 upper) returns bool =
    currentContract._markets[customOf(pool)].pool != to_bytes32(0)
        && currentContract._markets[customOf(pool)].bandLower <= lower && lower < upper
        && upper <= currentContract._markets[customOf(pool)].bandUpper;

rule routeFullRangeToFullMarket(bytes32 pool, int24 lower, int24 upper) {
    require fullOf(pool) != 0;
    require isFullRange(pool, lower, upper);
    assert routeOf(pool, lower, upper) == fullOf(pool), "a full-range position left the Full range market";
}

rule routeInsideCustomToCustom(bytes32 pool, int24 lower, int24 upper) {
    require fullOf(pool) != 0;
    require !isFullRange(pool, lower, upper);
    require insideCustom(pool, lower, upper);
    assert routeOf(pool, lower, upper) == customOf(pool), "a position inside the Custom band left its market";
}

rule routeOtherwiseNone(bytes32 pool, int24 lower, int24 upper) {
    require fullOf(pool) == 0 || (!isFullRange(pool, lower, upper) && !insideCustom(pool, lower, upper));
    assert routeOf(pool, lower, upper) == 0, "a position that fits no market was routed";
}
