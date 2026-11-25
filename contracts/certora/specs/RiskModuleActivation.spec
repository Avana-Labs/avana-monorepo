/*
 * RiskModule listing, activation and governance (src/RiskModule.sol, Aave reads in libraries/AaveConfigLogic.sol,
 * design design/risk.md), through RiskModuleHarness (test/utils/harness/RiskModuleHarness.sol). The band rules
 * are in RiskModuleBands.spec.
 *
 * Listing:
 *   listPoolRecordsBothMarkets             listPool needs a registered Spoke and 0 < LTV < 100%, takes the next two
 *                                          market IDs, records both markets (pool, Spoke, LTV, price reserves, kind,
 *                                          unit decimals > 0, inactive, no vault token) and the pool's pair of markets
 *   listPoolPricesTheTokensFromTheirReserves the listing price reads each token from the price Spoke's reserve of that
 *                                          token, with the token's decimals
 *
 * Activation (AaveConfigLogic.checkActivation):
 *   activateMarketChecksTheVaultToken      only a listed, inactive market is activated; the vault token names the
 *                                          market, the Spoke's Hub, the LiquidationModule, the unit decimals and the
 *                                          same AccessManager; the market then records it, the oracle and the reserve
 *                                          and is active, every other field unchanged
 *   activateMarketChecksTheAaveReserve     the reserve is the Spoke's reserve of the vault token on that Hub, with no
 *                                          draw cap, receive-shares off, liquidation fee 0, collateral factor = the
 *                                          market's LTV and the LPOracle as Aave's price source; the LPOracle names the
 *                                          LPVault, the market, the unit decimals, the price Spoke and both reserves
 *   activationCopiesTheHigherTokenBonus    the reserve's max liquidation bonus is the higher of the two tokens'
 *                                          bonuses on the price Spoke, each at its reserve's current dynamic config
 *                                          (PR 359)
 *   activationCopiesTheLiquidationConfig   the CDP Spoke's liquidation bonus factor, health factor for max bonus and
 *                                          target health factor are the price Spoke's
 *   activeMarketNeverChanges               a market becomes active only by activateMarket, never becomes inactive,
 *                                          and an active market's vault token, oracle, reserve, pool, Spoke and LTV
 *                                          never change
 *
 * Who may change what:
 *   everyChangeIsAuthorized                every state-changing function succeeds only for a caller the AccessManager
 *                                          authorizes for it (setAuthority: only the AccessManager itself)
 *   registeredSpokeKeepsHubAndPriceSpoke   a Spoke changes only by registerSpoke, and once registered keeps its Hub
 *                                          and price Spoke
 *   settingsChangeOnlyByTheirSetter        the coverage ratio (at most 100%) only by setCoverageRatio, the fee (share
 *                                          at most 50%, recipient not zero) only by setFee, keepers only by
 *                                          addKeeper/removeKeeper, debt reserves only by setDebtReserve/
 *                                          removeDebtReserve, markets only by listPool/activateMarket
 *
 * Not checked on chain, left to the DAO's listing (trust-model notes, not rules): the market's LTV is the lower of its
 * two tokens' collateral factors on the price Spoke (design/risk.md decision 2; script/deploy/09_ListMarkets.s.sol `_ltv`
 * computes it, `listPool` accepts any 0 < LTV < 100% and activation checks only that the reserve's collateral factor
 * equals it), and the decimals Aave records for the vault-token reserve (finding F4 of the step 9 review).
 *
 * Summaries, and why each is sound:
 *  - Aave V4 reads are ghosts per (called address, arguments): the Spoke's `getReserve`, `getReserveConfig`,
 *    `getDynamicReserveConfig`, `getLiquidationConfig`, `getReserveId`, `ORACLE`; the Hub's `getAssetId` and
 *    `getSpokeConfig`; AaveOracle's `getReserveSource`, `decimals`, `spoke`, `getReservePrice`. Every one is a view of
 *    Aave state, and the RiskModule makes no call between two reads that could change it, so one value per address and
 *    arguments is what the real calls return within one transaction. `ORACLE` is immutable on the Spoke.
 *  - The vault token's and LPOracle's views (`marketId`, `hub`, `liquidationModule`, `decimals`, `authority`,
 *    `lpVault`, `unitDecimals`, `priceSpoke`, `reserveIds`) are ghosts per address, for the same reason.
 *  - The LPVault's `listMarket` is NONDET (it writes only the LPVault); its `getMarket` returns ghost tokens per ID.
 *  - The listing-price and tick arithmetic is summarised as in RiskModuleBands.spec: `ClTickMath.getTickAtSqrtPrice`
 *    and `LPPriceMath.sqrtPriceX96` are ghost functions of their inputs, `BandMath.unitDecimals` is NONDET
 *    (over-approximations: any real result is among the summarised ones).
 *  - Coverage and First-Loss reads (`fundedBalance`, `MAX_ALLOWED_SPOKE_CAP`, the reserve's `ASSET`/`HUB`,
 *    `isSpokeListed`) are NONDET views. The AccessManager's decision is the ghost AuthorityModel, bound at
 *    `AuthorityUtils.canCallWithDelay` (the helper through which `restricted` asks it) and recorded with the caller,
 *    target and selector asked; `consumeScheduledOp` is NONDET.
 */

import "setup/AuthorityModel.spec";

methods {
    function getMarket(uint256) external returns (IRiskModule.Market) envfree;
    function getSpoke(address) external returns (IRiskModule.SpokeConfig) envfree;
    function marketsOf(bytes32) external returns (IRiskModule.PoolMarkets) envfree;
    function getDebtReserve(address, uint256) external returns (IRiskModule.DebtReserve) envfree;
    function coverageRatioBps() external returns (uint256) envfree;
    function feeShareBps() external returns (uint256) envfree;
    function feeRecipient() external returns (address) envfree;
    function isKeeper(address) external returns (bool) envfree;
    function LP_VAULT() external returns (address) envfree;
    function LIQUIDATION_MODULE() external returns (address) envfree;
    function authority() external returns (address) envfree;
    function listPool(IRiskModule.ListPoolParams) external returns (uint256, uint256);
    function activateMarket(uint256, address, address) external;

    // The AccessManager decision, bound at AccessManaged's own helper rather than at the external `canCall`, whose
    // summary read another selector and target than the call's in the parametric rules.
    function AuthorityUtils.canCallWithDelay(address, address caller, address target, bytes4 selector) internal
        returns (bool, uint32) => checkedCanCall(caller, target, selector);
    function _.consumeScheduledOp(address, bytes) external => NONDET;

    // LPVault
    function _.listMarket(uint256, bytes32, int24, int24) external => NONDET;
    function _.getMarket(uint256 id) external => vaultMarket(id) expect (ILPVault.Market);

    // Aave V4 Spoke (CDP and price Spoke)
    function _.getReserve(uint256 id) external => reserveOf(calledContract, id) expect (IAaveV4Spoke.Reserve);
    function _.getReserveConfig(uint256 id) external => reserveConfigOf(calledContract, id) expect (IAaveV4Spoke.ReserveConfig);
    function _.getDynamicReserveConfig(uint256 id, uint32 key) external => dynamicConfigOf(calledContract, id, key) expect (IAaveV4Spoke.DynamicReserveConfig);
    function _.getLiquidationConfig() external => liquidationConfigOf(calledContract) expect (IAaveV4Spoke.LiquidationConfig);
    function _.getReserveId(address hub, uint256 assetId) external => spokeReserveId[calledContract][hub][assetId] expect (uint256);
    function _.ORACLE() external => spokeOracle[calledContract] expect (address);
    // Aave V4 Hub
    function _.getAssetId(address asset) external => hubAssetId[calledContract][asset] expect (uint256);
    function _.getSpokeConfig(uint256 assetId, address spoke) external => hubSpokeConfig(calledContract, assetId, spoke) expect (IAaveV4Hub.SpokeConfig);
    function _.MAX_ALLOWED_SPOKE_CAP() external => NONDET;
    function _.isSpokeListed(uint256, address) external => NONDET;
    // AaveOracle
    function _.getReserveSource(uint256 id) external => reserveSource[calledContract][id] expect (address);
    function _.getReservePrice(uint256 id) external => reservePrice[calledContract][id] expect (uint256);
    function _.spoke() external => oracleSpoke[calledContract] expect (address);
    // Tokens, vault token, LPOracle
    function _.decimals() external => decimalsOf[calledContract] expect (uint8);
    function _.marketId() external => marketIdOf[calledContract] expect (uint256);
    function _.hub() external => hubOf[calledContract] expect (address);
    function _.liquidationModule() external => liquidationModuleOf[calledContract] expect (address);
    function _.authority() external => authorityOf[calledContract] expect (address);
    function _.lpVault() external => lpVaultOf[calledContract] expect (address);
    function _.unitDecimals() external => unitDecimalsOf[calledContract] expect (uint8);
    function _.priceSpoke() external => priceSpokeOf[calledContract] expect (address);
    function _.reserveIds() external => oracleReserveIds(calledContract) expect (uint256, uint256);
    // First-Loss Reserve
    function _.fundedBalance() external => NONDET;
    function _.ASSET() external => NONDET;
    function _.HUB() external => NONDET;

    // Listing-price and tick arithmetic, as in RiskModuleBands.spec (over-approximations).
    function ClTickMath.getTickAtSqrtPrice(uint160 sqrtPriceX96) internal returns (int24) => tickAtSqrtPrice(sqrtPriceX96);
    function BandMath.unitDecimals(uint160, int24, int24, uint256, uint256, uint8, uint8) internal returns (uint8) => NONDET;
    function LPPriceMath.sqrtPriceX96(uint256 p0, uint256 p1, uint8 d0, uint8 d1) internal returns (uint160) => sqrtPriceOf(p0, p1, d0, d1);
}

// The decision `restricted` read in the current call, and for which caller, target and selector.
persistent ghost bool authChecked;
persistent ghost address checkedCaller;
persistent ghost address checkedTarget;
persistent ghost bytes4 checkedSelector;

function checkedCanCall(address caller, address target, bytes4 selector) returns (bool, uint32) {
    authChecked = true;
    checkedCaller = caller;
    checkedTarget = target;
    checkedSelector = selector;
    bool immediate;
    uint32 delay;
    immediate, delay = authorityCanCall(caller, target, selector);
    return (immediate, delay);
}

definition BPS() returns mathint = 10000;

ghost sqrtPriceOf(uint256, uint256, uint8, uint8) returns uint160;
ghost tickAtSqrtPrice(uint160) returns int24;

// Spoke
ghost mapping(address => mapping(uint256 => address)) resUnderlying;
ghost mapping(address => mapping(uint256 => address)) resHub;
ghost mapping(address => mapping(uint256 => uint8)) resDecimals;
ghost mapping(address => mapping(uint256 => uint32)) resConfigKey;
ghost mapping(address => mapping(uint256 => bool)) resReceiveShares;
ghost mapping(address => mapping(uint256 => mapping(uint32 => uint16))) dynCollateralFactor;
ghost mapping(address => mapping(uint256 => mapping(uint32 => uint32))) dynMaxBonus;
ghost mapping(address => mapping(uint256 => mapping(uint32 => uint16))) dynLiquidationFee;
ghost mapping(address => uint128) liqTargetHf;
ghost mapping(address => uint64) liqHfForMaxBonus;
ghost mapping(address => uint16) liqBonusFactor;
ghost mapping(address => mapping(address => mapping(uint256 => uint256))) spokeReserveId;
ghost mapping(address => address) spokeOracle;
// Hub
ghost mapping(address => mapping(address => uint256)) hubAssetId;
ghost mapping(address => mapping(uint256 => mapping(address => uint40))) hubDrawCap;
// AaveOracle
ghost mapping(address => mapping(uint256 => address)) reserveSource;
ghost mapping(address => mapping(uint256 => uint256)) reservePrice;
ghost mapping(address => address) oracleSpoke;
// Tokens, vault token, LPOracle
ghost mapping(address => uint8) decimalsOf;
ghost mapping(address => uint256) marketIdOf;
ghost mapping(address => address) hubOf;
ghost mapping(address => address) liquidationModuleOf;
ghost mapping(address => address) authorityOf;
ghost mapping(address => address) lpVaultOf;
ghost mapping(address => uint8) unitDecimalsOf;
ghost mapping(address => address) priceSpokeOf;
ghost mapping(address => uint256) oracleReserveId0;
ghost mapping(address => uint256) oracleReserveId1;
// LPVault
ghost mapping(uint256 => address) vaultToken0;
ghost mapping(uint256 => address) vaultToken1;

function reserveOf(address spoke, uint256 id) returns IAaveV4Spoke.Reserve {
    IAaveV4Spoke.Reserve r;
    require r.underlying == resUnderlying[spoke][id] && r.hub == resHub[spoke][id];
    require r.decimals == resDecimals[spoke][id] && r.dynamicConfigKey == resConfigKey[spoke][id];
    return r;
}

function reserveConfigOf(address spoke, uint256 id) returns IAaveV4Spoke.ReserveConfig {
    IAaveV4Spoke.ReserveConfig c;
    require c.receiveSharesEnabled == resReceiveShares[spoke][id];
    return c;
}

function dynamicConfigOf(address spoke, uint256 id, uint32 key) returns IAaveV4Spoke.DynamicReserveConfig {
    IAaveV4Spoke.DynamicReserveConfig c;
    require c.collateralFactor == dynCollateralFactor[spoke][id][key];
    require c.maxLiquidationBonus == dynMaxBonus[spoke][id][key];
    require c.liquidationFee == dynLiquidationFee[spoke][id][key];
    return c;
}

function liquidationConfigOf(address spoke) returns IAaveV4Spoke.LiquidationConfig {
    IAaveV4Spoke.LiquidationConfig c;
    require c.targetHealthFactor == liqTargetHf[spoke];
    require c.healthFactorForMaxBonus == liqHfForMaxBonus[spoke];
    require c.liquidationBonusFactor == liqBonusFactor[spoke];
    return c;
}

function hubSpokeConfig(address hub, uint256 assetId, address spoke) returns IAaveV4Hub.SpokeConfig {
    IAaveV4Hub.SpokeConfig c;
    require c.drawCap == hubDrawCap[hub][assetId][spoke];
    return c;
}

function oracleReserveIds(address oracle) returns (uint256, uint256) {
    return (oracleReserveId0[oracle], oracleReserveId1[oracle]);
}

function vaultMarket(uint256 id) returns ILPVault.Market {
    ILPVault.Market m;
    require m.token0 == vaultToken0[id] && m.token1 == vaultToken1[id];
    return m;
}

// The bonus the price Spoke `ps` pays for reserve `id` at its current dynamic config.
function tokenBonus(address ps, uint256 id) returns mathint {
    return dynMaxBonus[ps][id][resConfigKey[ps][id]];
}

definition isListPool(method f) returns bool =
    f.selector == sig:listPool(IRiskModule.ListPoolParams).selector;
definition isActivate(method f) returns bool = f.selector == sig:activateMarket(uint256, address, address).selector;

// ---------------------------------------------------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------------------------------------------------

rule listPoolRecordsBothMarkets(IRiskModule.ListPoolParams p) {
    env e;
    uint256 next = currentContract._nextMarketId;
    requireInvariant marketsFromNextIdUnlisted(next);
    requireInvariant marketsFromNextIdUnlisted(require_uint256(next + 1));
    IRiskModule.SpokeConfig sc = getSpoke(p.spoke);

    uint256 full;
    uint256 custom;
    full, custom = listPool(e, p);

    assert sc.kind != IRiskModule.SpokeKind.None, "listed on an unregistered Spoke";
    assert p.ltvBps > 0 && p.ltvBps < BPS(), "listed with an LTV of 0 or at least 100%";
    assert full == next && to_mathint(custom) == next + 1 && to_mathint(currentContract._nextMarketId) == next + 2,
        "the listing did not take the next two market IDs";
    IRiskModule.Market f = getMarket(full);
    IRiskModule.Market c = getMarket(custom);
    assert f.pool == p.pool && c.pool == p.pool && f.spoke == p.spoke && c.spoke == p.spoke, "pool or Spoke not recorded";
    assert f.ltvBps == p.ltvBps && c.ltvBps == p.ltvBps, "LTV not recorded";
    assert f.priceReserveId0 == p.reserveId0 && f.priceReserveId1 == p.reserveId1
        && c.priceReserveId0 == p.reserveId0 && c.priceReserveId1 == p.reserveId1, "price reserves not recorded";
    assert f.kind == IRiskModule.MarketKind.FullRange && c.kind == IRiskModule.MarketKind.CustomRange, "kinds swapped";
    assert f.unitDecimals > 0 && c.unitDecimals > 0, "a market without unit decimals";
    assert !f.active && !c.active && f.vaultToken == 0 && c.vaultToken == 0, "a market was listed active";
    IRiskModule.PoolMarkets pm = marketsOf(p.pool);
    assert pm.fullRange == full && pm.customRange == custom, "the pool's markets are not the new pair";
}

rule listPoolPricesTheTokensFromTheirReserves(IRiskModule.ListPoolParams p) {
    env e;
    uint256 full;
    uint256 custom;
    full, custom = listPool(e, p);
    address ps = getSpoke(p.spoke).priceSpoke;
    address t0 = vaultToken0[full];
    address t1 = vaultToken1[full];
    assert resUnderlying[ps][p.reserveId0] == t0 && resDecimals[ps][p.reserveId0] == decimalsOf[t0],
        "token0 was priced from another reserve";
    assert resUnderlying[ps][p.reserveId1] == t1 && resDecimals[ps][p.reserveId1] == decimalsOf[t1],
        "token1 was priced from another reserve";
    address oracle = spokeOracle[ps];
    assert oracleSpoke[oracle] == ps && decimalsOf[oracle] == 8, "the price came from another oracle than the price Spoke's";
}

// ---------------------------------------------------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------------------------------------------------

rule activateMarketChecksTheVaultToken(uint256 id, address vt, address oracle) {
    env e;
    IRiskModule.Market m0 = getMarket(id);
    address hub = getSpoke(m0.spoke).hub;

    activateMarket(e, id, vt, oracle);

    IRiskModule.Market m1 = getMarket(id);
    assert m0.pool != to_bytes32(0) && !m0.active, "activated an unlisted or active market";
    assert marketIdOf[vt] == id && hubOf[vt] == hub && liquidationModuleOf[vt] == LIQUIDATION_MODULE(),
        "the vault token names another market, Hub or LiquidationModule";
    assert decimalsOf[vt] == m0.unitDecimals && authorityOf[vt] == authority(),
        "the vault token has other decimals or another AccessManager";
    assert m1.active && m1.vaultToken == vt && m1.lpOracle == oracle, "the market was not activated with these";
    assert m1.pool == m0.pool && m1.spoke == m0.spoke && m1.ltvBps == m0.ltvBps && m1.unitDecimals == m0.unitDecimals
        && m1.kind == m0.kind && m1.priceReserveId0 == m0.priceReserveId0 && m1.priceReserveId1 == m0.priceReserveId1
        && m1.bandLower == m0.bandLower && m1.bandUpper == m0.bandUpper, "activation changed a listing field";
}

rule activateMarketChecksTheAaveReserve(uint256 id, address vt, address oracle) {
    env e;
    IRiskModule.Market m0 = getMarket(id);
    address spoke = m0.spoke;
    address hub = getSpoke(spoke).hub;
    address ps = getSpoke(spoke).priceSpoke;

    activateMarket(e, id, vt, oracle);

    uint256 r = getMarket(id).reserveId;
    uint256 assetId = hubAssetId[hub][vt];
    uint32 key = resConfigKey[spoke][r];
    assert r == spokeReserveId[spoke][hub][assetId], "the reserve is not the Spoke's reserve of the vault token's asset";
    assert resUnderlying[spoke][r] == vt && resHub[spoke][r] == hub, "the reserve is of another token or Hub";
    assert hubDrawCap[hub][assetId][spoke] == 0, "the vault-token asset has a draw cap";
    assert !resReceiveShares[spoke][r], "receive-shares is on";
    assert dynLiquidationFee[spoke][r][key] == 0, "the liquidation fee is not 0";
    assert dynCollateralFactor[spoke][r][key] == m0.ltvBps, "the collateral factor is not the market's LTV";
    assert reserveSource[spokeOracle[spoke]][r] == oracle, "Aave's price source is not the LPOracle";
    assert lpVaultOf[oracle] == LP_VAULT() && marketIdOf[oracle] == id && unitDecimalsOf[oracle] == m0.unitDecimals
        && priceSpokeOf[oracle] == ps && oracleReserveId0[oracle] == m0.priceReserveId0
        && oracleReserveId1[oracle] == m0.priceReserveId1, "the LPOracle names another vault, market or price";
}

rule activationCopiesTheHigherTokenBonus(uint256 id, address vt, address oracle) {
    env e;
    IRiskModule.Market m0 = getMarket(id);
    address spoke = m0.spoke;
    address ps = getSpoke(spoke).priceSpoke;

    activateMarket(e, id, vt, oracle);

    uint256 r = getMarket(id).reserveId;
    mathint bonus = dynMaxBonus[spoke][r][resConfigKey[spoke][r]];
    mathint b0 = tokenBonus(ps, m0.priceReserveId0);
    mathint b1 = tokenBonus(ps, m0.priceReserveId1);
    assert bonus == (b0 > b1 ? b0 : b1), "the max liquidation bonus is not the higher token's";
}

rule activationCopiesTheLiquidationConfig(uint256 id, address vt, address oracle) {
    env e;
    IRiskModule.Market m0 = getMarket(id);
    address spoke = m0.spoke;
    address ps = getSpoke(spoke).priceSpoke;

    activateMarket(e, id, vt, oracle);

    assert liqBonusFactor[spoke] == liqBonusFactor[ps], "the liquidation bonus factor is not the price Spoke's";
    assert liqHfForMaxBonus[spoke] == liqHfForMaxBonus[ps], "the health factor for max bonus is not the price Spoke's";
    assert liqTargetHf[spoke] == liqTargetHf[ps], "the target health factor is not the price Spoke's";
}

rule activeMarketNeverChanges(method f, uint256 id) filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    requireInvariant marketsFromNextIdUnlisted(id);
    IRiskModule.Market m0 = getMarket(id);

    f(e, args);

    IRiskModule.Market m1 = getMarket(id);
    assert !m0.active && m1.active => isActivate(f), "a market became active other than by activateMarket";
    assert m0.active => (m1.active && m1.vaultToken == m0.vaultToken && m1.lpOracle == m0.lpOracle
        && m1.reserveId == m0.reserveId && m1.pool == m0.pool && m1.spoke == m0.spoke && m1.ltvBps == m0.ltvBps),
        "an active market changed";
}

invariant marketsFromNextIdUnlisted(uint256 id)
    id >= currentContract._nextMarketId => currentContract._markets[id].pool == to_bytes32(0)
        && !currentContract._markets[id].active && currentContract._markets[id].vaultToken == 0
    filtered { f -> f.contract == currentContract }

// ---------------------------------------------------------------------------------------------------------------------
// Who may change what
// ---------------------------------------------------------------------------------------------------------------------

// Each function is called with explicit arguments: in a call through `calldataarg` the Prover leaves the calldata's
// first four bytes free, so `restricted` (which reads the selector from msg.data) would ask about any selector.
rule everyChangeIsAuthorized(method f) filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    address manager = authority();
    require !authChecked;
    callDirectly(e, f);
    if (f.selector == sig:setAuthority(address).selector) {
        assert e.msg.sender == manager, "a caller other than the AccessManager replaced it";
    } else {
        assert authChecked && checkedCaller == e.msg.sender && checkedTarget == currentContract
            && checkedSelector == selectorOf(f), "the AccessManager was not asked about this call";
        assert authorized(e.msg.sender, currentContract, checkedSelector),
            "a caller the AccessManager does not authorize changed the RiskModule";
    }
}

function callDirectly(env e, method f) {
    address a1;
    address a2;
    address a3;
    uint256 u1;
    uint256 u2;
    if (f.selector == sig:registerSpoke(address, address, IRiskModule.SpokeKind, address).selector) {
        IRiskModule.SpokeKind kind;
        registerSpoke(e, a1, a2, kind, a3);
    } else if (f.selector == sig:setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width).selector) {
        IRiskModule.SpokeKind kind;
        IRiskModule.Width w;
        setSpokeWidth(e, kind, w);
    } else if (isListPool(f)) {
        IRiskModule.ListPoolParams p;
        listPool(e, p);
    } else if (isActivate(f)) {
        activateMarket(e, u1, a1, a2);
    } else if (f.selector == sig:setDebtReserve(address, uint256, address).selector) {
        setDebtReserve(e, a1, u1, a2);
    } else if (f.selector == sig:removeDebtReserve(address, uint256).selector) {
        removeDebtReserve(e, a1, u1);
    } else if (f.selector == sig:setCoverageRatio(uint256).selector) {
        setCoverageRatio(e, u1);
    } else if (f.selector == sig:setFee(uint256, address).selector) {
        setFee(e, u1, a1);
    } else if (f.selector == sig:addKeeper(address).selector) {
        addKeeper(e, a1);
    } else if (f.selector == sig:removeKeeper(address).selector) {
        removeKeeper(e, a1);
    } else {
        calldataarg args;
        f(e, args);
    }
}

function selectorOf(method f) returns bytes4 {
    if (f.selector == sig:registerSpoke(address, address, IRiskModule.SpokeKind, address).selector) {
        return to_bytes4(sig:registerSpoke(address, address, IRiskModule.SpokeKind, address).selector);
    } else if (f.selector == sig:setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width).selector) {
        return to_bytes4(sig:setSpokeWidth(IRiskModule.SpokeKind, IRiskModule.Width).selector);
    } else if (isListPool(f)) {
        return to_bytes4(sig:listPool(IRiskModule.ListPoolParams).selector);
    } else if (isActivate(f)) {
        return to_bytes4(sig:activateMarket(uint256, address, address).selector);
    } else if (f.selector == sig:setDebtReserve(address, uint256, address).selector) {
        return to_bytes4(sig:setDebtReserve(address, uint256, address).selector);
    } else if (f.selector == sig:removeDebtReserve(address, uint256).selector) {
        return to_bytes4(sig:removeDebtReserve(address, uint256).selector);
    } else if (f.selector == sig:setCoverageRatio(uint256).selector) {
        return to_bytes4(sig:setCoverageRatio(uint256).selector);
    } else if (f.selector == sig:setFee(uint256, address).selector) {
        return to_bytes4(sig:setFee(uint256, address).selector);
    } else if (f.selector == sig:addKeeper(address).selector) {
        return to_bytes4(sig:addKeeper(address).selector);
    }
    return to_bytes4(sig:removeKeeper(address).selector);
}

rule registeredSpokeKeepsHubAndPriceSpoke(method f, address spoke)
    filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    requireInvariant registeredSpokeHasKind(spoke);
    IRiskModule.SpokeConfig s0 = getSpoke(spoke);

    f(e, args);

    IRiskModule.SpokeConfig s1 = getSpoke(spoke);
    assert (s1.hub != s0.hub || s1.kind != s0.kind || s1.priceSpoke != s0.priceSpoke)
        => f.selector == sig:registerSpoke(address, address, IRiskModule.SpokeKind, address).selector,
        "a Spoke changed other than by registerSpoke";
    assert s0.hub != 0 => (s1.hub == s0.hub && s1.priceSpoke == s0.priceSpoke && s1.kind != IRiskModule.SpokeKind.None),
        "a registered Spoke changed its Hub or price Spoke";
}

invariant registeredSpokeHasKind(address spoke)
    (getSpoke(spoke).hub != 0) == (getSpoke(spoke).kind != IRiskModule.SpokeKind.None)
    filtered { f -> f.contract == currentContract }

rule settingsChangeOnlyByTheirSetter(method f, address keeper, address spoke, uint256 reserveId, uint256 id)
    filtered { f -> f.contract == currentContract && !f.isView } {
    env e;
    calldataarg args;
    uint256 ratio0 = coverageRatioBps();
    uint256 share0 = feeShareBps();
    address recipient0 = feeRecipient();
    bool keeper0 = isKeeper(keeper);
    IRiskModule.DebtReserve d0 = getDebtReserve(spoke, reserveId);
    IRiskModule.Market m0 = getMarket(id);

    f(e, args);

    IRiskModule.DebtReserve d1 = getDebtReserve(spoke, reserveId);
    IRiskModule.Market m1 = getMarket(id);
    assert coverageRatioBps() != ratio0
        => (f.selector == sig:setCoverageRatio(uint256).selector && coverageRatioBps() <= BPS()),
        "the coverage ratio changed other than by setCoverageRatio, or above 100%";
    assert (feeShareBps() != share0 || feeRecipient() != recipient0)
        => (f.selector == sig:setFee(uint256, address).selector && feeShareBps() <= 5000 && feeRecipient() != 0),
        "the fee changed other than by setFee, or above 50% or to no recipient";
    assert isKeeper(keeper) != keeper0
        => (f.selector == sig:addKeeper(address).selector || f.selector == sig:removeKeeper(address).selector),
        "a keeper changed other than by addKeeper or removeKeeper";
    assert (d1.hub != d0.hub || d1.asset != d0.asset || d1.assetId != d0.assetId || d1.firstLossReserve != d0.firstLossReserve)
        => (f.selector == sig:setDebtReserve(address, uint256, address).selector
            || f.selector == sig:removeDebtReserve(address, uint256).selector),
        "a debt reserve changed other than by setDebtReserve or removeDebtReserve";
    assert (m1.pool != m0.pool || m1.active != m0.active || m1.vaultToken != m0.vaultToken || m1.ltvBps != m0.ltvBps)
        => (isListPool(f) || isActivate(f)), "a market changed other than by listPool or activateMarket";
}
