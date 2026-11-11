/*
 * MarketRegistry listing reachability probe (MarketRegistryListingProbe.conf): satisfy rules that show how far
 * listCollateralMarket gets in the MarketRegistry.spec scene, through flags set by view summaries along its path. It
 * locates a check that no path passes, which makes the listCollateralMarket step of the parametric rules vacuous.
 */
import "MarketRegistry.spec";

methods {
    function _.marketKeyOf(uint32 i, address p, bytes32 k, MarketRegistry.PositionShape s) external => probeKey() expect bytes32;
    function _.tokenOf(address s, bytes32 k) external => probeTokenOf() expect address;
    function _.marketKey() external => probeVtKey() expect bytes32;
    function _.MIN_ALLOWED_UNDERLYING_DECIMALS() external => probeMinDec() expect uint8;
    function _.latestAnswer() external => probeAnswer() expect int256;
}

persistent ghost bool pKey;
persistent ghost bool pTokenOf;
persistent ghost bool pVtKey;
persistent ghost bool pMinDec;
persistent ghost bool pAnswer;

function probeKey() returns bytes32 { pKey = true; bytes32 x; return x; }
function probeTokenOf() returns address { pTokenOf = true; address x; return x; }
function probeVtKey() returns bytes32 { pVtKey = true; bytes32 x; return x; }
function probeMinDec() returns uint8 { pMinDec = true; uint8 x; return x; }
function probeAnswer() returns int256 { pAnswer = true; int256 x; return x; }

function resetProbe() {
    pKey = false; pTokenOf = false; pVtKey = false; pMinDec = false; pAnswer = false; aaveConfigChecked = false;
}

definition isListCM(method f) returns bool = f.selector == sig:listCollateralMarket(MarketRegistry.MarketDef).selector;

rule p1_shapeChecked(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy pKey; }
rule p2_preflightDone(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy pTokenOf; }
rule p3_boundAndTokenChecked(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy pVtKey; }
rule p4_tokensChecked(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy pMinDec; }
rule p5_oracleSeed(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy pAnswer; }
rule p6_aaveConfig(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy aaveConfigChecked; }
rule p7_succeeds(method f) filtered { f -> isListCM(f) } { env e; calldataarg a; resetProbe(); f@withrevert(e, a); satisfy !lastReverted; }
