/*
 * LPVaultSwap (planned implementation src/liquidation/lp-vault-swap/LPVaultSwap.sol, interface
 * src/liquidation/lp-vault-swap/ILPVaultSwap.sol, spec 2.11).
 *
 * What is proved, for the verified LPVaultSwap implementation (5.2 limitations):
 *   - entry gates of `liquidate`, the one liquidation entry point, for any caller: unfrozen caller, deadline, minimum
 *     payout, a proxy bound to the market and registered by its vault token, a debt reserve enabled in the
 *     MarketRegistry, HF below 1, the seized market's price neither Cached, Expired nor disagreeing and younger than
 *     `liquidationPriceMaxAge`, the repaid reserve's DebtOracle Live, the grace bound, `receiveShares == false`, at
 *     least one unit seized (PROP-022, PROP-049, PROP-074); the committed-operator registry gates no call and a
 *     liquidation leaves it unchanged (PROP-035);
 *   - no read of any Hub's pause state or pause reason or of the breakers, and no read of the freeze list other than
 *     the caller (PROP-057, PROP-066); no breaker write from any liquidation, pending settlement or deleverage, since
 *     LPVaultSwap has no breaker call (PROP-066, Q-399);
 *   - balance and allowance neutrality (PROP-016); the caller's funding `Kf` (0 < Kf <= debtToCover) passed to
 *     `liquidationCall` with D <= Kf, and the waterfall in the repaid debt asset with the Avana fee from oracle value,
 *     the keeper reward, the borrower surplus and the caller's shortfall top-up, with
 *     `keeperOut = Kf + R + shortfall - D - A - B >= 0` paid directly to the caller (PROP-015, PROP-053, PROP-069,
 *     Q-397, Q-404); every seized unit burned and settled (PROP-020, PROP-047); per-leg `minOut >= 1` and the
 *     SPEC-LIQ-018 value on pending settlement (PROP-068);
 *   - no pool token paid out of a liquidation other than route residue to the caller, since there is no in-kind
 *     settlement (PROP-021, Q-401); the limits that bind every caller: a working swap route per released token, the
 *     recovery floor, no Avana funds and no flash loan in a liquidation (PROP-053); pending settlement into the
 *     Coverage Spoke of the market's (funding Hub, debt asset) (PROP-051, PROP-060); repay with collateral (PROP-072);
 *   - the committed-operator registry, roles and the flash callback (PROP-034, PROP-035, PROP-036, PROP-070);
 *   - the settlement arithmetic of PROP-015, PROP-017, PROP-018, PROP-019, PROP-048, PROP-069 restated over unbounded
 *     integers (primary tool per 5.2: Halmos) and the overflow bounds of PROP-044 (primary: SMTChecker).
 *
 * Storage assumption: ERC-7201 namespaced storage (committed-operator list, shortfall clock, transient deleverage
 * context; 2.11 Storage); the rules read it only through the contract's own views.
 *
 * Summaries (5.2 rows): ERC-20s by the ERC-20 model (standard, no hooks, the listing rule), so the caller's funding
 * arrives in full (Kf == debtToCover); the Spoke's `liquidationCall` pulls D <= its `debtToCover` argument of the debt
 * asset and pays an arbitrary seizure c >= 0 (Aave model), and the spec records the amount LPVaultSwap passes;
 * `getUserAccountData` returns the ghost HF; LPOracle and DebtOracle states from the price-state model, with one
 * 8-decimal leg price per pool token; every Hub's pause state and reason as per-Hub ghosts, and the breakers, freeze
 * list and enabled debt set from the registry model (every read counted); markets (2 to 4 pool tokens,
 * distinct), debt reserves, Hubs, Coverage Spokes and swap routes as uninterpreted functions of their keys;
 * ParameterStore values as uninterpreted constants; `AaveAdapter.burnSeized` burns from the caller's balance;
 * Collateralization's `settleSeizure` and `settlePending` pay an arbitrary amount of each pool token (zero for zero
 * units); swap routes pull their input and pay an arbitrary amount of their output token >= their `minOut` (the
 * route's own check, proved in SettlementRoute.spec); a Coverage
 * Spoke's `fund` pulls exactly `amount` of its asset from the caller to its Hub; the PayoutEscrow's (payout escrow's) `deposit` pulls
 * exactly `amount` and credits the named account. Pool-token `transfer` goes through `swapTransfer`: a token may
 * refuse a recipient (`tokenRefuses`, a blocklisted or reverting receiver), in which case nothing moves and the call
 * reports failure; the gas-limited borrower transfer of REQ-SWAP-076 is a low-level call with the `transfer` selector,
 * resolved to the same summary.
 *
 * Flash funding: `liquidate` takes no flash loan. The caller funds it in the debt asset, from its own balance or
 * through a flash liquidation helper, which reaches LPVaultSwap as an ordinary caller; the helper's loan, premium and
 * top-up are outside LPVaultSwap (REQ-SWAP-012, Q-404), so every full-flow liquidation rule below covers direct and
 * helper-funded callers alike, and `liquidateTakesNoFlashLoan` shows that a liquidation reads neither the flash source
 * nor its quotes. `onFlashLoan` runs only inside `deleverage`, while the AaveAdapter holds the Lock. The flash source
 * is `MARKET_REGISTRY.flashSource()`, an `IFlashSource` (contracts/src/flash); `flashPremium` and `maxFlashLoan` are
 * summarised by uninterpreted functions. `flashLoan` stays unresolved, because its effect is a callback into
 * LPVaultSwap's own `onFlashLoan`, which a summary does not reproduce; the flash source's own checks are proved in
 * FlashSource.spec and the callback's own checks on `onFlashLoan` directly. `deleverage` always flash-borrows, so its
 * core is not reached by the model (certora/README.md).
 */

import "setup/Erc20Model.spec";
import "setup/LockModel.spec";
import "setup/AaveModel.spec";
import "setup/PriceStateModel.spec";
import "setup/RegistryModel.spec";

methods {
    // LPVaultSwap
    function liquidate(LiquidationParams) external returns (LiquidationResult);
    function settlePending(uint256, uint256) external returns (uint256, uint256[], uint256);
    function deleverage(DeleverageRequest) external returns (uint256, uint256);
    function onFlashLoan(address, uint256, uint256, bytes) external returns (bytes32);
    function initialize(address, address[]) external;
    function addKeeper(address) external;
    function removeKeeper(address) external;
    function isApprovedKeeper(address) external returns (bool) envfree;
    function approvedKeeperCount() external returns (uint256) envfree;
    function activeKeeperCount() external returns (uint256);
    function KEEPER_FLOOR() external returns (uint256) envfree;
    function APPLICATION_ADMIN() external returns (bytes32) envfree;
    function LOCK() external returns (address) envfree;
    function AAVE_ADAPTER() external returns (address) envfree;
    function TIMELOCK() external returns (address) envfree;
    function COLLATERALIZATION() external returns (address) envfree;
    function MARKET_REGISTRY() external returns (address) envfree;
    function PARAMETER_STORE() external returns (address) envfree;
    function PAYOUT_ESCROW() external returns (address) envfree;
    function hasRole(bytes32, address) external returns (bool) envfree;
    function getRoleAdmin(bytes32) external returns (bytes32) envfree;

    // ERC-20 (debt assets, vault tokens, pool tokens)
    function _.balanceOf(address a) external => erc20BalanceOf(calledContract, a) expect uint256;
    function _.allowance(address o, address s) external => erc20Allowance(calledContract, o, s) expect uint256;
    function _.approve(address s, uint256 a) external with (env e) => erc20Approve(calledContract, e.msg.sender, s, a) expect bool;
    function _.transfer(address to, uint256 a) external with (env e) => swapTransfer(calledContract, e.msg.sender, to, a) expect bool;
    function _.transferFrom(address from, address to, uint256 a) external with (env e) => swapTransferFrom(calledContract, e.msg.sender, from, to, a) expect bool;
    function _.decimals() external => tokenDecimals(calledContract) expect uint8;

    // Collateralization, the AaveAdapter and the PositionProxy
    function _.beginSeizure(address p, address vt) external => collBeginSeizure(p, vt) expect void;
    function _.settleSeizure(address p, address vt, uint256 u, uint256[] mins) external with (env e) => collSettleSeizure(e.msg.sender, vt, u) expect uint256[];
    function _.getPending(address vt) external => collGetPending(vt) expect Pending;
    function _.settlePending(address vt, uint256 u) external with (env e) => collSettlePending(e.msg.sender, vt, u) expect uint256[];
    function _.burnSeized(uint256 m, address vt, uint256 u) external with (env e) => adapterBurnSeized(e.msg.sender, vt, u) expect void;
    function _.deleverageRepay(address p, uint256 r, uint256 amount) external with (env e) => adapterDeleverageRepay(e.msg.sender, p, r, amount) expect uint256;
    function _.deleverageRelease(address p, PositionRef pos, uint128 u, uint256[] mins) external with (env e) => adapterDeleverageRelease(e.msg.sender, p, u) expect (uint256[], bool);
    function _.walletOf(address p) external => proxyWalletOf(p) expect address;
    function _.WALLET() external => proxyWalletOf(calledContract) expect address;
    function _.MARKET_ID() external => proxyMarketOf(calledContract) expect uint256;

    // Aave V4 CDP Spoke, Hub and AaveOracle
    function _.liquidationCall(uint256 c, uint256 d, address u, uint256 amt, bool rs) external with (env e) => swapLiquidationCall(calledContract, e.msg.sender, c, d, u, amt, rs) expect void;
    function _.getUserAccountData(address u) external => spokeGetUserAccountData(calledContract, u) expect IAaveV4Spoke.UserAccountData;
    function _.getUserReserveStatus(uint256 rid, address u) external => spokeGetUserReserveStatus(calledContract, rid, u) expect (bool, bool);
    function _.getUserSuppliedShares(uint256 rid, address u) external => spokeGetUserSuppliedShares(calledContract, rid, u) expect uint256;
    function _.getUserTotalDebt(uint256 rid, address u) external => spokeGetUserTotalDebt(calledContract, rid, u) expect uint256;
    function _.getReserveCount() external => spokeReserveCount(calledContract) expect uint256;
    function _.getReserveConfig(uint256 rid) external => spokeGetReserveConfig(calledContract, rid) expect IAaveV4Spoke.ReserveConfig;
    function _.getLiquidationBonus(uint256 rid, address u, uint256 hf) external => spokeBonusOf(calledContract, rid) expect uint256;
    function _.getReserve(uint256) external => NONDET;
    function _.getDynamicReserveConfig(uint256, uint32) external => NONDET;
    function _.getLiquidationConfig() external => NONDET;
    function _.ORACLE() external => spokeOracleOf(calledContract) expect address;
    function _.getAddedAssets(uint256 a) external => hubGetAddedAssets(calledContract, a) expect uint256;
    function _.getAddedShares(uint256 a) external => hubGetAddedShares(calledContract, a) expect uint256;
    function _.getReservePrice(uint256 rid) external => aavePrice(calledContract, rid) expect uint256;

    // LPOracles and DebtOracles
    function _.poke() external => oraclePoke(calledContract) expect PriceState;
    function _.getPriceState() external => priceStateViewOf(calledContract) expect PriceStateView;
    function _.getTokenPrices() external => swapTokenPrices(calledContract) expect (uint256[], uint64, PriceState);
    function _.latestAnswer() external => oracleLatestAnswer(calledContract) expect int256;

    // MarketRegistry
    function _.getMarket(uint256 m) external => registryMarket(m) expect Market;
    function _.getDebtReserve(address s, uint256 r) external => registryDebtReserve(s, r) expect DebtReserveDef;
    function _.isApprovedDebtReserve(address s, uint256 r) external => registryApprovedDebtReserve(s, r) expect bool;
    function _.getRoute(uint256 m, address tIn, address tOut, uint8 k) external => registryRoute(m, tIn, tOut, k) expect (address, bool);
    function _.flashSource() external => registryFlashSource() expect address;
    function _.hubOf(address s) external => registryHubOf(s) expect address;
    function _.coverageSpokeOf(address h, address a) external => registryCoverageSpokeOf(h, a) expect address;
    function _.isFrozenAddress(address a) external => registryIsFrozenAddress(a) expect bool;
    function _.pauseState(address h) external => swapHubPauseStateRead(h) expect PauseState;
    function _.pauseReason(address h) external => swapHubPauseReasonRead(h) expect PauseReason;
    function _.marketBreaker(uint256 m) external => registryMarketBreaker(m) expect (uint32, uint64);
    function _.debtBreaker(address s, uint256 r) external => registryDebtBreaker(s, r) expect (uint32, uint64);
    function _.recordBreach(bytes32, uint32) external => breakerRecord() expect void;
    function _.marketOfVaultToken(address vt) external => registryMarketOfVaultToken(vt) expect uint256;

    // ParameterStore
    function _.getMarketParams(uint256 m) external => psMarketParams(m) expect MarketParams;
    function _.feeRecipient() external => psFeeRecipient() expect address;
    function _.avanaFeeShareBps() external => psAvanaFeeShareBps() expect uint16;
    function _.floorRoundingAllowance(address asset) external => psFloorRoundingAllowance(asset) expect uint256;
    function _.maxFlashFeeBps() external => psMaxFlashFeeBps() expect uint16;
    function _.maxShortfallBps() external => psMaxShortfallBps() expect uint16;
    function _.graceHealthFactor() external => psGraceHealthFactor() expect uint256;
    function _.graceDuration() external => psGraceDuration() expect uint32;
    function _.liquidationPriceMaxAge(address f) external => psLiquidationMaxAge(f) expect uint32;
    function _.borrowPriceMaxAge(address f) external => psBorrowMaxAge(f) expect uint32;
    function _.minLiquidationBonus(address s) external => psMinBonus(s) expect uint16;

    // Vault-token immutables and registry
    function _.hub() external => vtHubOf(calledContract) expect address;
    function _.spoke() external => vtSpokeOf(calledContract) expect address;
    function _.marketId() external => vtMarketIdOf(calledContract) expect uint256;
    function _.lpOracle() external => vtLpOracleOf(calledContract) expect address;
    function _.isValidProxy(address a) external => vtIsValidProxy(calledContract, a) expect bool;

    // Flash source, swap routes, Coverage Spokes, PayoutEscrow (payout escrow)
    function _.flashPremium(address t, uint256 a) external => swapFlashPremium(calledContract, t, a) expect uint256;
    function _.maxFlashLoan(address t) external => swapMaxFlashLoan(calledContract, t) expect uint256;
    function _.swap(uint256 amountIn, uint256 minOut) external with (env e) => routeSwap(calledContract, e.msg.sender, amountIn, minOut) expect uint256;
    function _.tokenIn() external => routeTokenIn(calledContract) expect address;
    function _.tokenOut() external => routeTokenOut(calledContract) expect address;
    function _.fund(uint256 amount) external with (env e) => coverageFund(calledContract, e.msg.sender, amount) expect uint256;
    function _.deposit(address token, address b, uint256 amount) external with (env e) => escrowDeposit(calledContract, e.msg.sender, token, b, amount) expect void;

    // Lock
    function _.acquire() external with (env e) => lockAcquire(e.msg.sender) expect void;
    function _.release() external with (env e) => lockRelease(e.msg.sender) expect void;
    function _.holder() external => lockHolderOf() expect address;
    function _.isLocked() external => lockIsLocked() expect bool;
}

// ---------------------------------------------------------------------------------------------------------------------
// Scene: uninterpreted configuration
// ---------------------------------------------------------------------------------------------------------------------

definition MAX_TOKENS() returns mathint = 4;

ghost tokenDecimals(address) returns uint8;
ghost vtHubOf(address) returns address;
ghost vtSpokeOf(address) returns address;
ghost vtMarketIdOf(address) returns uint256;
ghost vtLpOracleOf(address) returns address;
ghost vtIsValidProxy(address, address) returns bool;
ghost proxyWalletOf(address) returns address;
ghost proxyMarketOf(address) returns uint256;
ghost spokeBonusOf(address, uint256) returns uint256;
ghost aavePrice(address, uint256) returns uint256;
// 8-decimal leg price of pool token i served by an LPOracle (SPEC-LIQ-012), fixed for the rule.
ghost legPrice(address, uint256) returns uint256 {
    axiom forall address o. forall uint256 i. legPrice(o, i) >= 1 && legPrice(o, i) < 2^64;
}
ghost oracleTokenCount(address) returns uint256;

// Markets (MarketRegistry.getMarket); the pool tokens of a market are distinct.
ghost mkToken(uint256, uint256) returns address {
    axiom forall uint256 m. forall uint256 i. forall uint256 j. i != j => mkToken(m, i) != mkToken(m, j);
}
ghost mkTokenCount(uint256) returns uint256;
ghost mkVaultToken(uint256) returns address;
ghost mkDecimals(uint256) returns uint8;
ghost mkLpOracle(uint256) returns address;
ghost mkSpoke(uint256) returns address;
ghost mkHubAssetId(uint256) returns uint256;
ghost mkReserveId(uint256) returns uint256;
// Home Hub of each CDP Spoke (MarketRegistry.hubOf).
ghost hubOfSpoke(address) returns address;
// Debt reserves (MarketRegistry.getDebtReserve).
ghost drAsset(address, uint256) returns address;
ghost drDecimals(address, uint256) returns uint8;
ghost drFundingHub(address, uint256) returns address;
ghost drPriceSource(address, uint256) returns address;
ghost drFixedPrice(address, uint256) returns bool;
// Coverage Spoke of each (Hub, debt asset) (MarketRegistry.coverageSpokeOf), its asset and its Hub.
ghost coverageOf(address, address) returns address;
ghost coverageAssetOf(address) returns address;
ghost coverageHubOf(address) returns address;
// Swap records (MarketRegistry.getRoute), keyed by (market, tokenIn, tokenOut, slot).
ghost routeOf(uint256, address, address, uint8) returns address;
ghost routeUsable(uint256, address, address, uint8) returns bool;
ghost routeTokenIn(address) returns address;
ghost routeTokenOut(address) returns address;
ghost registryMarketOfVaultToken(address) returns uint256;
// Flash source (MarketRegistry.flashSource) and its quotes.
ghost flashSourceAddr() returns address;
ghost flashPremiumOf(address, address, uint256) returns uint256;
ghost flashAvailableOf(address, address) returns uint256;
// ParameterStore.
ghost psSlippageBps(uint256) returns uint16;
ghost psFeeRecipient() returns address;
ghost psAvanaFeeShareBps() returns uint16;
ghost psFloorRoundingAllowance(address) returns uint256;
ghost psMaxFlashFeeBps() returns uint16;
ghost psMaxShortfallBps() returns uint16;
ghost psGraceHealthFactor() returns uint256;
ghost psGraceDuration() returns uint32;
ghost psLiquidationMaxAge(address) returns uint32;
ghost psBorrowMaxAge(address) returns uint32;
ghost psMinBonus(address) returns uint16;
// Token behaviour.
ghost tokenRefuses(address, address) returns bool;

// Pause state and reason of every Hub; pauseReason(hub) == None exactly when the Hub is not Paused (PROP-041).
persistent ghost mapping(address => LPVaultSwap.PauseState) swapHubPauseState;
persistent ghost mapping(address => LPVaultSwap.PauseReason) swapHubPauseReason;

function swapHubPauseStateRead(address hub) returns LPVaultSwap.PauseState {
    regPauseStateReads = regPauseStateReads + 1;
    regAnyReads = regAnyReads + 1;
    require (swapHubPauseState[hub] == LPVaultSwap.PauseState.Paused) == (swapHubPauseReason[hub] != LPVaultSwap.PauseReason.None);
    return swapHubPauseState[hub];
}

function swapHubPauseReasonRead(address hub) returns LPVaultSwap.PauseReason {
    regPauseReasonReads = regPauseReasonReads + 1;
    regAnyReads = regAnyReads + 1;
    require (swapHubPauseState[hub] == LPVaultSwap.PauseState.Paused) == (swapHubPauseReason[hub] != LPVaultSwap.PauseReason.None);
    return swapHubPauseReason[hub];
}

function registryMarket(uint256 m) returns LPVaultSwap.Market {
    regAnyReads = regAnyReads + 1;
    LPVaultSwap.Market mk;
    mathint n = mkTokenCount(m);
    require n >= 2 && n <= MAX_TOKENS();
    require mk.hub == hubOfSpoke(mkSpoke(m)) && mk.spoke == mkSpoke(m);
    require mk.vaultToken == mkVaultToken(m) && mk.decimals == mkDecimals(m) && mk.lpOracle == mkLpOracle(m);
    require mk.hubAssetId == mkHubAssetId(m) && mk.reserveId == mkReserveId(m);
    require to_mathint(mk.tokens.length) == n && to_mathint(mk.tokenDecimals.length) == n;
    require mk.tokens[0] == mkToken(m, 0) && mk.tokenDecimals[0] == tokenDecimals(mkToken(m, 0));
    require mk.tokens[1] == mkToken(m, 1) && mk.tokenDecimals[1] == tokenDecimals(mkToken(m, 1));
    require n > 2 => (mk.tokens[2] == mkToken(m, 2) && mk.tokenDecimals[2] == tokenDecimals(mkToken(m, 2)));
    require n > 3 => (mk.tokens[3] == mkToken(m, 3) && mk.tokenDecimals[3] == tokenDecimals(mkToken(m, 3)));
    require to_mathint(oracleTokenCount(mkLpOracle(m))) == n;
    require vtSpokeOf(mkVaultToken(m)) == mkSpoke(m) && vtHubOf(mkVaultToken(m)) == hubOfSpoke(mkSpoke(m));
    require vtMarketIdOf(mkVaultToken(m)) == m && vtLpOracleOf(mkVaultToken(m)) == mkLpOracle(m);
    require tokenDecimals(mkVaultToken(m)) == mkDecimals(m);
    require !isDebtOracle(mkLpOracle(m));
    return mk;
}

function registryDebtReserve(address s, uint256 r) returns LPVaultSwap.DebtReserveDef {
    regAnyReads = regAnyReads + 1;
    LPVaultSwap.DebtReserveDef d;
    require d.reserveId == r && d.asset == drAsset(s, r) && d.decimals == drDecimals(s, r);
    require d.fundingHub == drFundingHub(s, r) && d.crossHub == (drFundingHub(s, r) != hubOfSpoke(s));
    require d.priceSource == drPriceSource(s, r) && d.fixedPrice == drFixedPrice(s, r);
    require d.coverageSpoke == coverageOf(drFundingHub(s, r), drAsset(s, r)) && d.approved == regApprovedDebtReserve(s, r);
    require coverageAssetOf(coverageOf(drFundingHub(s, r), drAsset(s, r))) == drAsset(s, r);
    require tokenDecimals(drAsset(s, r)) == drDecimals(s, r);
    require !drFixedPrice(s, r) => isDebtOracle(drPriceSource(s, r));
    return d;
}

function registryRoute(uint256 m, address tIn, address tOut, uint8 k) returns (address, bool) {
    regAnyReads = regAnyReads + 1;
    address route = routeOf(m, tIn, tOut, k);
    require routeTokenIn(route) == tIn && routeTokenOut(route) == tOut;
    return (route, routeUsable(m, tIn, tOut, k));
}

// Reads of MARKET_REGISTRY.flashSource() and quotes from a flash source during the current call (REQ-SWAP-012).
persistent ghost mathint flashSourceReads;
persistent ghost mathint flashQuoteCalls;

function registryFlashSource() returns address {
    regAnyReads = regAnyReads + 1;
    flashSourceReads = flashSourceReads + 1;
    return flashSourceAddr();
}

function swapFlashPremium(address src, address t, uint256 a) returns uint256 {
    flashQuoteCalls = flashQuoteCalls + 1;
    return flashPremiumOf(src, t, a);
}

function swapMaxFlashLoan(address src, address t) returns uint256 {
    flashQuoteCalls = flashQuoteCalls + 1;
    return flashAvailableOf(src, t);
}

function registryHubOf(address s) returns address {
    regAnyReads = regAnyReads + 1;
    return hubOfSpoke(s);
}

function registryCoverageSpokeOf(address h, address a) returns address {
    regAnyReads = regAnyReads + 1;
    require coverageAssetOf(coverageOf(h, a)) == a;
    return coverageOf(h, a);
}

// LPOracle leg prices, one per pool token in market order, fixed per oracle for the rule (SPEC-LIQ-012), with the
// oracle's served state.
function swapTokenPrices(address o) returns (uint256[], uint64, LPVaultSwap.PriceState) {
    uint256[] prices;
    mathint n = oracleTokenCount(o);
    require to_mathint(prices.length) == n && n >= 2 && n <= MAX_TOKENS();
    require prices[0] == legPrice(o, 0) && prices[1] == legPrice(o, 1);
    require n > 2 => prices[2] == legPrice(o, 2);
    require n > 3 => prices[3] == legPrice(o, 3);
    return (prices, pvServedUpdatedAt[o], priceStateOf(o));
}

function psMarketParams(uint256 m) returns LPVaultSwap.MarketParams {
    LPVaultSwap.MarketParams p;
    require p.slippageAllowanceBps == psSlippageBps(m);
    return p;
}

// ---------------------------------------------------------------------------------------------------------------------
// Scene: bookkeeping of the current call
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost mapping(address => mathint) pendingUnits;
persistent ghost mathint seizuresBegun;
persistent ghost mathint settleSeizureCalls;
persistent ghost mathint settledUnits;
persistent ghost mathint settledPendingUnits;
persistent ghost mathint burnedSeized;
persistent ghost bool settleBeforeBurn;
persistent ghost mathint routeCalls;
persistent ghost mathint routeOut;
persistent ghost bool swapWithZeroMinOut;
persistent ghost mapping(address => bool) routeCalled;
persistent ghost mapping(address => mathint) swapAmountIn;
persistent ghost mapping(address => mathint) swapMinOut;
persistent ghost mathint coverageFunded;
persistent ghost address expectedCoverage;
persistent ghost bool fundedOtherThanExpected;
persistent ghost mathint escrowDeposits;
persistent ghost bool escrowedOutsideEscrow;
persistent ghost bool escrowedToOtherThanBorrower;
persistent ghost address escrowBorrower;
persistent ghost mapping(address => mathint) escrowCredited {
    init_state axiom forall address t. escrowCredited[t] == 0;
}
// Amount of each pool token the last unwind of the call released, keyed by token.
persistent ghost mapping(address => mathint) unwound;
persistent ghost mathint deleverageRepays;
persistent ghost mathint deleverageReleases;
// paidOut[token][to]: LPVaultSwap transferred `token` to `to` during the call.
persistent ghost mapping(address => mapping(address => bool)) paidOut;

function collBeginSeizure(address p, address vt) {
    seizuresBegun = seizuresBegun + 1;
}

// The market's LPVault releases an arbitrary amount of pool token `i` to `to`, zero for zero units.
function unwindLeg(uint256 m, uint256 i, address to, uint256 units, uint256 amount) {
    require units == 0 => amount == 0;
    erc20Credit(mkToken(m, i), to, amount);
    unwound[mkToken(m, i)] = amount;
}

// Pays the n pool tokens of market `m` released by the removal of `units` to `to`, in market token order.
function unwindTo(uint256 m, address to, uint256 units) returns uint256[] {
    uint256[] amounts;
    mathint n = mkTokenCount(m);
    require to_mathint(amounts.length) == n && n >= 2 && n <= MAX_TOKENS();
    unwindLeg(m, 0, to, units, amounts[0]);
    unwindLeg(m, 1, to, units, amounts[1]);
    if (n > 2) {
        unwindLeg(m, 2, to, units, amounts[2]);
    }
    if (n > 3) {
        unwindLeg(m, 3, to, units, amounts[3]);
    }
    return amounts;
}

// Collateralization debits `units` and has the market's LPVault remove exactly that liquidity and pay the pool tokens
// to the caller (LPVaultSwap); zero units release nothing.
function collSettleSeizure(address caller, address vt, uint256 units) returns uint256[] {
    if (to_mathint(units) > burnedSeized) {
        settleBeforeBurn = true;
    }
    settleSeizureCalls = settleSeizureCalls + 1;
    settledUnits = settledUnits + units;
    return unwindTo(vtMarketIdOf(vt), caller, units);
}

function collGetPending(address vt) returns LPVaultSwap.Pending {
    LPVaultSwap.Pending p;
    require pendingUnits[vt] >= 0 && to_mathint(p.units) == pendingUnits[vt];
    return p;
}

function collSettlePending(address caller, address vt, uint256 units) returns uint256[] {
    require units > 0 && to_mathint(units) <= pendingUnits[vt];
    if (to_mathint(units) > burnedSeized) {
        settleBeforeBurn = true;
    }
    pendingUnits[vt] = pendingUnits[vt] - units;
    settledPendingUnits = settledPendingUnits + units;
    return unwindTo(vtMarketIdOf(vt), caller, units);
}

// AaveAdapter.burnSeized burns `units` from its caller, LPVaultSwap (PROP-007 on the Adapter).
function adapterBurnSeized(address caller, address vt, uint256 units) {
    vaultTokenBurn(vt, caller, units);
    burnedSeized = burnedSeized + units;
}

function adapterDeleverageRepay(address caller, address p, uint256 r, uint256 amount) returns uint256 {
    deleverageRepays = deleverageRepays + 1;
    uint256 repaid;
    require repaid <= amount;
    return repaid;
}

function adapterDeleverageRelease(address caller, address p, uint128 units) returns (uint256[], bool) {
    deleverageReleases = deleverageReleases + 1;
    uint256[] amounts;
    bool closed;
    return (amounts, closed);
}

// The Spoke's liquidationCall (Aave model), recording the `debtToCover` argument LPVaultSwap passes: the measured
// caller funding Kf (REQ-SWAP-011, REQ-SWAP-017).
persistent ghost mathint liquidationAmountPassed;

function swapLiquidationCall(address spoke, address caller, uint256 collateralRid, uint256 debtRid, address user,
                             uint256 amount, bool receiveShares) {
    liquidationAmountPassed = amount;
    spokeLiquidationCall(spoke, caller, collateralRid, debtRid, user, amount, receiveShares);
}

function breakerRecord() {
    registryBreakerWrite();
}

// PROP-097: a transfer-fee token model. Off in every scene except `setupFeeScene`; when on, the fee of a pull into
// LPVaultSwap goes to `feeSink`, so LPVaultSwap receives `amount - fee`.
ghost bool feeTokens;
ghost address feeSink;
ghost transferFee(address, uint256) returns uint256 {
    axiom forall address t. forall uint256 a. transferFee(t, a) <= a;
}

// PROP-063, PROP-084: set by any persistent storage write of LPVaultSwap (transient writes are TransientModel's).
ghost bool lvsStorageWritten;
hook ALL_SSTORE(uint256 loc, uint256 v) {
    lvsStorageWritten = true;
}

function swapTransfer(address t, address from, address to, uint256 amount) returns bool {
    if (tokenRefuses(t, to)) {
        return false;
    }
    erc20Move(t, from, to, amount);
    if (from == currentContract) {
        paidOut[t][to] = true;
    }
    return true;
}

function swapTransferFrom(address t, address spender, address from, address to, uint256 amount) returns bool {
    bool ok = erc20TransferFrom(t, spender, from, to, amount);
    // PROP-097: with `feeTokens` on, a pull into LPVaultSwap delivers `amount - transferFee(t, amount)`.
    if (ok && feeTokens && to == currentContract && from != currentContract) {
        erc20Move(t, currentContract, feeSink, transferFee(t, amount));
    }
    if (from == currentContract) {
        paidOut[t][to] = true;
    }
    return ok;
}

// A swap route pulls exactly `amountIn` of its input from its caller and pays at least `minOut` of its output (or
// reverts MinOutNotMet).
function routeSwap(address route, address caller, uint256 amountIn, uint256 minOut) returns uint256 {
    bool pulled = erc20TransferFrom(routeTokenIn(route), route, caller, route, amountIn);
    require pulled;
    uint256 out;
    require out >= minOut;
    erc20Credit(routeTokenOut(route), caller, out);
    routeCalls = routeCalls + 1;
    routeOut = routeOut + out;
    routeCalled[route] = true;
    if (minOut == 0) {
        swapWithZeroMinOut = true;
    }
    swapAmountIn[routeTokenIn(route)] = swapAmountIn[routeTokenIn(route)] + amountIn;
    swapMinOut[routeTokenIn(route)] = minOut;
    return out;
}

// A Coverage Spoke's `fund` pulls exactly `amount` of its asset from the caller into its Hub.
function coverageFund(address coverage, address caller, uint256 amount) returns uint256 {
    require amount > 0;
    if (coverage != expectedCoverage) {
        fundedOtherThanExpected = true;
    }
    bool pulled = erc20TransferFrom(coverageAssetOf(coverage), coverage, caller, coverageHubOf(coverage), amount);
    require pulled;
    coverageFunded = coverageFunded + amount;
    uint256 shares;
    return shares;
}

function escrowDeposit(address escrow, address caller, address token, address b, uint256 amount) {
    require amount > 0;
    if (escrow != PAYOUT_ESCROW()) {
        escrowedOutsideEscrow = true;
    }
    if (b != escrowBorrower) {
        escrowedToOtherThanBorrower = true;
    }
    bool pulled = erc20TransferFrom(token, escrow, caller, escrow, amount);
    require pulled;
    escrowDeposits = escrowDeposits + 1;
    escrowCredited[token] = escrowCredited[token] + amount;
}

// Entry points start with the Lock free, as at the start of a transaction.
function setupSwapScene(env e) {
    setupSwapCall(e);
    require lockHolder == 0;
    require !feeTokens;
}

// PROP-097: the same scene with a debt token whose transfer into LPVaultSwap keeps any fee 0 <= fee(a) <= a.
function setupFeeScene(env e) {
    setupSwapCall(e);
    require lockHolder == 0;
    require feeTokens;
    require feeSink != currentContract && feeSink != e.msg.sender;
}

// `deleverage` runs inside the AaveAdapter's repayWithCollateral, which holds the Lock.
function setupDeleverageScene(env e) {
    setupSwapCall(e);
    require lockHolder == AAVE_ADAPTER() && AAVE_ADAPTER() != 0;
}

function setupSwapCall(env e) {
    require e.msg.sender != currentContract && e.msg.sender != 0;
    resetLiquidationModel();
    resetRegistryReads();
    seizuresBegun = 0;
    settleSeizureCalls = 0;
    settledUnits = 0;
    settledPendingUnits = 0;
    burnedSeized = 0;
    settleBeforeBurn = false;
    routeCalls = 0;
    routeOut = 0;
    swapWithZeroMinOut = false;
    coverageFunded = 0;
    fundedOtherThanExpected = false;
    escrowDeposits = 0;
    escrowedOutsideEscrow = false;
    escrowedToOtherThanBorrower = false;
    deleverageRepays = 0;
    deleverageReleases = 0;
    liquidationAmountPassed = 0;
    flashSourceReads = 0;
    flashQuoteCalls = 0;
    require forall address t. forall address a. !paidOut[t][a];
    require forall address r. !routeCalled[r];
    require forall address t. swapAmountIn[t] == 0;
    require forall address t. unwound[t] == 0;
}

definition WAD() returns mathint = 10^18;
definition ceilDiv(mathint a, mathint b) returns mathint = (a + b - 1) / b;
definition max0(mathint a) returns mathint = a > 0 ? a : 0;

// The seized market's own price is usable for liquidation: neither Cached nor Expired, no disagreement, fresh.
function seizedPriceUsable(env e, uint256 m) returns bool {
    address o = mkLpOracle(m);
    return !pvCached[o] && !pvExpired[o] && !pvDisagreementPause[o] && !pvDisagreementExpired[o]
        && to_mathint(e.block.timestamp) - to_mathint(pvServedUpdatedAt[o]) <= to_mathint(pvLiquidationMaxAge[o]);
}

// The repaid debt reserve has a fixed-price source, or its DebtOracle is Live and fresh.
function debtPriceUsable(env e, address s, uint256 r) returns bool {
    address o = drPriceSource(s, r);
    return drFixedPrice(s, r)
        || (pvIsLive(o) && to_mathint(e.block.timestamp) - to_mathint(pvServedUpdatedAt[o]) <= to_mathint(pvLiquidationMaxAge[o]));
}

// Pool token i of market m, i < mkTokenCount(m), is released (> 0) and is not the debt asset T: a leg the call swaps.
function isSwappedLeg(uint256 m, uint256 i, address T) returns mathint {
    return (to_mathint(i) < to_mathint(mkTokenCount(m)) && unwound[mkToken(m, i)] > 0 && mkToken(m, i) != T) ? 1 : 0;
}

// n', the number of legs the call swaps (SPEC-LIQ-018).
function legsSwapped(uint256 m, address T) returns mathint {
    return isSwappedLeg(m, 0, T) + isSwappedLeg(m, 1, T) + isSwappedLeg(m, 2, T) + isSwappedLeg(m, 3, T);
}

// ---------------------------------------------------------------------------------------------------------------------
// Entry gates (PROP-022, PROP-049, PROP-074, PROP-035)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-022 verifies: INV-030, INV-062, Q-053, Q-116, Q-213, Q-216, Q-242, Q-404
// The only caller conditions of a successful `liquidate` are the freeze, the deadline and the minimum payout; no
// registry or role of the caller is read (`liquidateIgnoresRegistry`).
rule liquidateCallerGates(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    bool frozen = regFrozen[e.msg.sender];

    LPVaultSwap.LiquidationResult r = liquidate(e, p);

    assert !frozen, "liquidate by a frozen caller";
    assert e.block.timestamp <= p.deadline, "liquidate after its deadline";
    assert r.keeperOut >= p.minPayout, "liquidate paid less than minPayout";
}

// PROP-022 verifies: INV-030, INV-062, Q-053, Q-116, Q-128, Q-154, Q-162, Q-208, Q-213, Q-216, Q-234, Q-238, Q-242,
// Q-247, Q-274, Q-404
// Holds for every caller, direct or through a flash liquidation helper.
rule liquidateAccountGates(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    address spoke = mkSpoke(p.marketId);
    address oracle = mkLpOracle(p.marketId);
    mathint hfBefore = spokeHealthFactor[spoke][p.proxy];

    LPVaultSwap.LiquidationResult r = liquidate(e, p);

    assert proxyMarketOf(p.proxy) == p.marketId && vtIsValidProxy(mkVaultToken(p.marketId), p.proxy),
        "liquidate of a proxy not bound to the market or not registered by its vault token";
    assert regApprovedDebtReserve(spoke, p.debtReserveId), "liquidate repaid a debt reserve outside the enabled set";
    assert hfBefore < WAD(), "liquidate of an account with HF >= 1";
    assert seizedPriceUsable(e, p.marketId), "liquidate on a Cached, Expired, disagreeing or old seized-market price";
    assert debtPriceUsable(e, spoke, p.debtReserveId), "liquidate repaid a reserve whose DebtOracle is not Live and fresh";
    assert pvInGrace[oracle] => hfBefore < to_mathint(psGraceHealthFactor()), "liquidate inside grace above graceHealthFactor";
    assert liquidationCalls == 1 && !liquidationReceiveShares, "liquidationCall not made once with receiveShares == false";
    assert lastSeizedUnits >= 1 && to_mathint(r.unitsSeized) == lastSeizedUnits, "liquidate completed without seizing a unit";
}

// PROP-049 verifies: INV-059, Q-162, Q-199, Q-208, Q-247, Q-248
// PROP-074 verifies: INV-055, INV-087, Q-247, Q-248
rule disagreementOrStressBlocksOnlyItsOwnReserve(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    address oracle = mkLpOracle(p.marketId);
    address debtOracle = drPriceSource(mkSpoke(p.marketId), p.debtReserveId);

    liquidate(e, p);

    assert !pvDisagreementPause[oracle] && !pvDisagreementExpired[oracle] && !pvExpired[oracle] && !pvCached[oracle],
        "liquidate seized a market whose oracle is not usable";
    assert !drFixedPrice(mkSpoke(p.marketId), p.debtReserveId) => pvIsLive(debtOracle),
        "liquidate repaid a reserve whose DebtOracle is not Live";
}

// PROP-049 verifies: INV-059, Q-247
// Liquidation of a fresh market is not restricted by a disagreement on another market of the same wallet.
rule otherMarketDisagreementDoesNotBlock(LPVaultSwap.LiquidationParams p, uint256 otherMarket) {
    env e;
    setupSwapScene(e);
    require otherMarket != p.marketId && mkLpOracle(otherMarket) != mkLpOracle(p.marketId);
    require pvDisagreementPause[mkLpOracle(otherMarket)] && pvExpired[mkLpOracle(otherMarket)];

    liquidate(e, p);

    satisfy true;
}

// PROP-074 verifies: INV-087, Q-247, Q-248, Q-255
rule deleverageNeedsLiveOracles(LPVaultSwap.DeleverageRequest r) {
    env e;
    setupDeleverageScene(e);

    deleverage(e, r);

    assert e.msg.sender == AAVE_ADAPTER(), "deleverage from a caller other than the AaveAdapter";
    assert seizedPriceUsable(e, r.marketId), "deleverage released units of a market whose price is not usable";
    assert debtPriceUsable(e, r.spoke, r.debtReserveId), "deleverage repaid a reserve whose DebtOracle is not Live";
}

// PROP-035 verifies: INV-048, Q-139, Q-155, Q-404
// The committed-operator registry gates no call: a caller that is not registered, and is not frozen, completes a
// liquidation, shown for PrimaryThenBackup (BackupOnly runs the same code with the primary route skipped).
rule liquidateIgnoresRegistry(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    require !isApprovedKeeper(e.msg.sender);
    require !regFrozen[e.msg.sender];

    liquidate(e, p);

    satisfy p.routeMode == LPVaultSwap.RouteMode.PrimaryThenBackup;
}

// PROP-035 verifies: INV-048, Q-139, Q-155, Q-404
// A liquidation leaves the registry as it found it, so liquidating never changes who is a committed operator or the
// count the RiskModule's borrowing halt reads.
rule liquidateLeavesRegistryUnchanged(LPVaultSwap.LiquidationParams p, address a) {
    env e;
    setupSwapScene(e);
    bool registeredBefore = isApprovedKeeper(a);
    mathint countBefore = approvedKeeperCount();

    liquidate(e, p);

    assert isApprovedKeeper(a) == registeredBefore, "liquidate changed the committed-operator registry";
    assert to_mathint(approvedKeeperCount()) == countBefore, "liquidate changed the committed-operator count";
}

// PROP-035 verifies: INV-048, Q-139, Q-155, Q-228
// PROP-071 is the MarketRegistry half (a freeze never takes activeKeeperCount below KEEPER_FLOOR).
rule removeKeeperKeepsFloor(address keeper) {
    env e;
    setupSwapScene(e);

    removeKeeper(e, keeper);

    assert to_mathint(activeKeeperCount(e)) >= to_mathint(KEEPER_FLOOR()), "removeKeeper left fewer than KEEPER_FLOOR active keepers";
    assert !isApprovedKeeper(keeper), "removeKeeper left the keeper approved";
    assert hasRole(APPLICATION_ADMIN(), e.msg.sender), "removeKeeper without APPLICATION_ADMIN";
}

// PROP-035 verifies: INV-048, Q-139, Q-155, Q-228
rule addKeeperNeedsAdminAndUnfrozenKeeper(address keeper) {
    env e;
    setupSwapScene(e);
    bool frozen = regFrozen[keeper];

    addKeeper(e, keeper);

    assert hasRole(APPLICATION_ADMIN(), e.msg.sender), "addKeeper without APPLICATION_ADMIN";
    assert keeper != 0 && !frozen && isApprovedKeeper(keeper), "addKeeper approved a zero or frozen address";
}

// ---------------------------------------------------------------------------------------------------------------------
// Roles (PROP-034, PROP-070)
// ---------------------------------------------------------------------------------------------------------------------

definition DEFAULT_ADMIN() returns bytes32 = to_bytes32(0);

definition isOpenEntry(method f) returns bool =
    f.selector == sig:liquidate(LiquidationParams).selector
    || f.selector == sig:settlePending(uint256, uint256).selector
    || f.selector == sig:onFlashLoan(address, uint256, uint256, bytes).selector
    || f.selector == sig:deleverage(DeleverageRequest).selector
    || f.selector == sig:initialize(address, address[]).selector
    || f.selector == sig:grantRole(bytes32, address).selector
    || f.selector == sig:revokeRole(bytes32, address).selector
    || f.selector == sig:renounceRole(bytes32, address).selector;

// PROP-034 verifies: INV-051, Q-226, Q-228
// Every other state-changing selector (addKeeper, removeKeeper, upgradeToAndCall) needs APPLICATION_ADMIN.
rule restrictedSelectorsNeedApplicationAdmin(method f) filtered { f -> !f.isView && !isOpenEntry(f) } {
    env e;
    calldataarg args;
    setupSwapScene(e);
    bool admin = hasRole(APPLICATION_ADMIN(), e.msg.sender);

    f(e, args);

    assert admin, "a restricted selector ran without APPLICATION_ADMIN";
}

// PROP-034 verifies: INV-051, Q-226
rule roleChangesNeedRoleAdmin(bytes32 role, address account) {
    env e;
    bool roleAdmin = hasRole(getRoleAdmin(role), e.msg.sender);

    grantRole(e, role, account);

    assert roleAdmin, "grantRole by a caller without the role's admin role";
}

// PROP-070 verifies: INV-084, Q-259
rule initializeGrantsAdminRolesOnlyToTimelock(address timelock, address[] keepers, address a) {
    env e;
    require !hasRole(DEFAULT_ADMIN(), a) && !hasRole(APPLICATION_ADMIN(), a);

    initialize(e, timelock, keepers);

    assert (hasRole(DEFAULT_ADMIN(), a) || hasRole(APPLICATION_ADMIN(), a)) => a == timelock,
        "initialize granted an admin role to an account other than the timelock";
}

// PROP-070 verifies: INV-084, Q-259
// With initializeGrantsAdminRolesOnlyToTimelock: one holder, and that holder is TIMELOCK().
invariant adminRolesHaveOneHolder(address a, address b)
    ((hasRole(DEFAULT_ADMIN(), a) || hasRole(APPLICATION_ADMIN(), a))
        && (hasRole(DEFAULT_ADMIN(), b) || hasRole(APPLICATION_ADMIN(), b))) => a == b
    filtered { f -> f.selector != sig:initialize(address, address[]).selector }

// PROP-070 verifies: INV-084, REQ-SWAP-040, Q-259
invariant adminRolesHeldOnlyByTimelock(address a)
    (hasRole(DEFAULT_ADMIN(), a) || hasRole(APPLICATION_ADMIN(), a)) => a == TIMELOCK()
    filtered { f -> f.selector != sig:initialize(address, address[]).selector }

// ---------------------------------------------------------------------------------------------------------------------
// Call graph: pause, breakers and freeze (PROP-057, PROP-066)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-057 verifies: INV-043, INV-045, INV-046, INV-067, Q-227, Q-252
// PROP-066 verifies: INV-030, INV-046, INV-081, Q-241, Q-242, Q-252
rule liquidationReadsNoPauseBreakerOrOtherFreeze(method f, address other) filtered {
    f -> f.selector == sig:liquidate(LiquidationParams).selector
            || f.selector == sig:settlePending(uint256, uint256).selector
} {
    env e;
    calldataarg args;
    setupSwapScene(e);
    require other != e.msg.sender;

    f(e, args);

    assert regPauseStateReads == 0 && regPauseReasonReads == 0, "a liquidation entry point read a Hub's pause state or reason";
    assert regBreakerReads == 0, "a liquidation entry point read a breaker";
    assert regFreezeReadsOf[other] == 0, "a liquidation entry point read the freeze status of an address other than its caller";
    assert f.selector == sig:settlePending(uint256, uint256).selector => regFreezeReads == 0, "settlePending read the freeze list";
}

// LPVaultSwap writes no breaker state (Q-399): breaches are recorded only by the RiskModule's pokeBreakers.
// PROP-066 verifies: INV-081, Q-241, Q-260, Q-399
rule liquidationWritesNoBreakerState(method f) filtered {
    f -> f.selector == sig:liquidate(LiquidationParams).selector
            || f.selector == sig:settlePending(uint256, uint256).selector
        || f.selector == sig:deleverage(DeleverageRequest).selector
} {
    env e;
    calldataarg args;
    if (f.selector == sig:deleverage(DeleverageRequest).selector) {
        setupDeleverageScene(e);
    } else {
        setupSwapScene(e);
    }

    f(e, args);

    assert regBreakerWrites == 0, "a liquidation, pending settlement or deleverage wrote breaker state";
}

// ---------------------------------------------------------------------------------------------------------------------
// Flash callback and lock (PROP-036, PROP-037)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-036 verifies: INV-040, Q-045, Q-148, Q-235, Q-404
// PROP-037 verifies: INV-054, Q-148, Q-223
// onFlashLoan runs only inside `deleverage`, where the AaveAdapter holds the Lock (REQ-SWAP-013).
rule onFlashLoanOnlyFromFlashSourceUnderLock(address asset, uint256 amount, uint256 premium, bytes context) {
    env e;

    onFlashLoan(e, asset, amount, premium, context);

    assert e.msg.sender == flashSourceAddr(), "onFlashLoan accepted a caller other than MARKET_REGISTRY.flashSource()";
    assert lockHolder == AAVE_ADAPTER() && AAVE_ADAPTER() != 0, "onFlashLoan ran while the AaveAdapter did not hold the lock";
    assert to_mathint(premium) * 10000 <= to_mathint(psMaxFlashFeeBps()) * to_mathint(amount), "onFlashLoan accepted a premium above maxFlashFeeBps";
}

// PROP-036 verifies: INV-040, Q-148, Q-404
// While LPVaultSwap itself holds the Lock (inside `liquidate`), the flash callback reverts whoever calls it.
rule onFlashLoanRefusedWhileLiquidating(address asset, uint256 amount, uint256 premium, bytes context) {
    env e;
    require lockHolder == currentContract;

    onFlashLoan@withrevert(e, asset, amount, premium, context);

    assert lastReverted, "onFlashLoan ran while LPVaultSwap held the lock";
}

// ---------------------------------------------------------------------------------------------------------------------
// Neutrality (PROP-016)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-016 verifies: INV-021, Q-097, Q-124, Q-213, Q-235, Q-404
// Every caller, direct or helper-funded: LPVaultSwap ends a liquidation with each token balance and allowance as it
// found them.
rule liquidateLeavesBalancesAndAllowances(LPVaultSwap.LiquidationParams p, address token, address spender) {
    env e;
    setupSwapScene(e);
    mathint balanceBefore = erc20Bal[token][currentContract];
    require erc20Allow[token][currentContract][spender] == 0;

    liquidate(e, p);

    assert erc20Bal[token][currentContract] == balanceBefore, "liquidate changed an LPVaultSwap token balance";
    assert erc20Allow[token][currentContract][spender] == 0, "liquidate left an allowance outstanding";
}

// PROP-016 verifies: INV-021, Q-124, Q-201
rule settlePendingLeavesBalancesAndAllowances(uint256 m, uint256 r, address token, address spender) {
    env e;
    setupSwapScene(e);
    mathint balanceBefore = erc20Bal[token][currentContract];
    require erc20Allow[token][currentContract][spender] == 0;

    uint256 units;
    uint256[] amounts;
    uint256 added;
    units, amounts, added = settlePending(e, m, r);

    mathint expected = token == mkVaultToken(m) ? balanceBefore - units : balanceBefore;
    assert erc20Bal[token][currentContract] == expected, "settlePending changed a balance other than burning the settled units";
    assert erc20Allow[token][currentContract][spender] == 0, "settlePending left an allowance outstanding";
}

// ---------------------------------------------------------------------------------------------------------------------
// Waterfall, fee, caller top-up and minimum outputs (PROP-015, PROP-047, PROP-068, PROP-069, PROP-020 caller side)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-015 verifies: INV-035, INV-036, Q-097, Q-127, Q-135, Q-190, Q-251, Q-256, Q-267, Q-337, Q-404
// PROP-069 verifies: INV-036, INV-086, Q-256
// Every caller, in the repaid debt asset T, with no flash term (Q-404): V = c * Pc * 10^dd / (10^dv * Pdebt)
// (SPEC-LIQ-004), R_f = max(R, minRec), shortfall = max(0, minRec - R) (SPEC-LIQ-019), R' = R + shortfall = R_f,
// S = max(0, R' - D), G = max(0, V - D), A = min(G * share / 10^4, S), kr = min(S, G) - A, B = S - A - kr
// (SPEC-LIQ-022), keeperOut = Kf + R' - D - A - B >= 0 (SPEC-LIQ-010), paid directly to the caller; no budget draw
// (Q-397).
rule waterfallWithOracleFee(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    address caller = e.msg.sender;
    address spoke = mkSpoke(p.marketId);
    address T = drAsset(spoke, p.debtReserveId);
    address recipient = psFeeRecipient();
    address wallet = proxyWalletOf(p.proxy);
    require recipient != caller && recipient != currentContract;
    require recipient != wallet && recipient != spokeHubOf(spoke);
    require caller != wallet && caller != spokeHubOf(spoke) && caller != PAYOUT_ESCROW();
    mathint feeBefore = erc20Bal[T][recipient];
    mathint selfBefore = erc20Bal[T][currentContract];
    mathint callerBefore = erc20Bal[T][caller];
    require mkVaultToken(p.marketId) != T;
    address aaveOracle = spokeOracleOf(spoke);
    mathint pc = aavePrice(aaveOracle, mkReserveId(p.marketId));
    mathint pDebt = aavePrice(aaveOracle, p.debtReserveId);
    require pDebt > 0;

    LPVaultSwap.LiquidationResult r = liquidate(e, p);

    mathint Kf = r.callerFunds;
    mathint D = r.debtRepaid;
    mathint V = (to_mathint(r.unitsSeized) * pc * 10^drDecimals(spoke, p.debtReserveId)) / (10^mkDecimals(p.marketId) * pDebt);
    mathint Rp = to_mathint(r.recovered) + to_mathint(r.shortfall);
    mathint S = max0(Rp - D);
    mathint G = max0(V - D);
    mathint feeByValue = (G * to_mathint(psAvanaFeeShareBps())) / 10000;
    mathint keeperOut = Kf + Rp - D - to_mathint(r.avanaFee) - to_mathint(r.borrowerSurplus);
    assert r.debtAsset == T, "the result names another debt asset than the repaid reserve's";
    assert Kf > 0 && Kf <= to_mathint(p.debtToCover), "the caller funding is not 0 < Kf <= debtToCover";
    assert liquidationAmountPassed == Kf && D == lastDebtRepaid && D <= Kf,
        "liquidationCall was not bounded by the measured caller funding Kf";
    assert to_mathint(r.shortfall) == max0(to_mathint(r.minOut) - to_mathint(r.recovered)),
        "the shortfall top-up differs from max(0, minRec - R)";
    assert Rp >= to_mathint(r.minOut), "R plus the shortfall top-up is below the recovery floor";
    assert r.shortfall <= p.maxShortfall, "the shortfall top-up exceeds maxShortfall";
    assert to_mathint(r.avanaFee) == (feeByValue < S ? feeByValue : S), "the Avana fee differs from min(fee on oracle gain, S)";
    assert to_mathint(r.keeperReward) == (S < G ? S : G) - to_mathint(r.avanaFee), "the keeper reward differs from min(S, G) - A";
    assert to_mathint(r.borrowerSurplus) == max0(S - G), "the borrower surplus differs from max(0, S - G)";
    assert keeperOut >= 0 && to_mathint(r.keeperOut) == keeperOut,
        "the debt-asset waterfall does not balance (Kf + R + shortfall = D + A + B + keeperOut)";
    assert Rp >= D => to_mathint(r.keeperOut) == Kf + to_mathint(r.keeperReward), "keeperOut differs from Kf + kr while R' >= D";
    assert erc20Bal[T][recipient] == feeBefore + r.avanaFee, "the fee recipient received other than the Avana fee";
    assert erc20Bal[T][caller] == callerBefore - Kf - to_mathint(r.shortfall) + to_mathint(r.keeperOut),
        "the caller was not paid keeperOut directly";
    assert erc20Bal[T][currentContract] == selfBefore, "LPVaultSwap kept or lost the debt asset";
}

// PROP-020 verifies: INV-037, Q-167, Q-236, Q-267, Q-397
// PROP-047 verifies: INV-038, Q-127, Q-167, Q-190, Q-397
// There is no settlement budget (Q-397): every seized unit is burned and settled, and the caller funds any gap.
rule everySeizedUnitIsBurnedAndSettled(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);

    liquidate@withrevert(e, p);
    bool succeeded = !lastReverted;

    assert succeeded => (lastSeizedUnits >= 1 && settledUnits == lastSeizedUnits && burnedSeized == settledUnits),
        "liquidate completed without burning and settling every seized unit";
    assert !settleBeforeBurn, "Collateralization debited units the Adapter had not burned";
}

// PROP-068 verifies: INV-034, INV-083, Q-250
rule everySwapCarriesAPositiveMinOut(method f) filtered {
    f -> f.selector == sig:liquidate(LiquidationParams).selector
            || f.selector == sig:settlePending(uint256, uint256).selector
        || f.selector == sig:deleverage(DeleverageRequest).selector
} {
    env e;
    calldataarg args;
    if (f.selector == sig:deleverage(DeleverageRequest).selector) {
        setupDeleverageScene(e);
    } else {
        setupSwapScene(e);
    }

    f(e, args);

    assert !swapWithZeroMinOut, "a swap route was called with minOut 0";
}

// PROP-068 verifies: INV-034, INV-083, Q-250
// settlePending: each swapped leg i runs at sLeg = min(slippageAllowanceBps, 30) and
// minOut_i = max(1, ceil(Vleg_i * (10000 - sLeg) / 10000) - Uleg_i - floor(floorRoundingAllowance(T) / n')), with
// Vleg_i = a_i * p_i * 10^dd / (10^d_i * Pdebt) and Uleg_i = ceil(p_i * 10^dd / (10^d_i * Pdebt)).
rule settlePendingLegMinimum(uint256 m, uint256 r, uint256 i) {
    env e;
    setupSwapScene(e);
    require to_mathint(i) < to_mathint(mkTokenCount(m));
    address spoke = mkSpoke(m);
    address T = drAsset(spoke, r);
    address t = mkToken(m, i);
    require t != T;
    mathint pi = legPrice(mkLpOracle(m), i);
    mathint pDebt = aavePrice(spokeOracleOf(spoke), r);
    require pDebt > 0;
    mathint dd = drDecimals(spoke, r);

    settlePending(e, m, r);

    mathint a = swapAmountIn[t];
    mathint scale = 10^tokenDecimals(t) * pDebt;
    mathint vLeg = (a * pi * 10^dd) / scale;
    mathint uLeg = ceilDiv(pi * 10^dd, scale);
    mathint sl = psSlippageBps(m);
    mathint sLeg = sl < 30 ? sl : 30;
    mathint n = legsSwapped(m, T);
    require n >= 1;
    mathint raw = ceilDiv(vLeg * (10000 - sLeg), 10000) - uLeg - to_mathint(psFloorRoundingAllowance(T)) / n;
    assert a > 0 => swapMinOut[t] == (raw > 1 ? raw : 1), "settlePending passed a leg minOut other than SPEC-LIQ-018";
}

// ---------------------------------------------------------------------------------------------------------------------
// No in-kind settlement (PROP-021, Q-401)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-021 verifies: INV-039, Q-213, Q-401
// There is no in-kind mode: `liquidate` pays the borrower and every other address no pool token other than the debt
// asset, and the escrow receives only a payout whose transfer failed.
rule liquidatePaysNoPoolTokensOut(LPVaultSwap.LiquidationParams p, uint256 i, address other) {
    env e;
    setupSwapScene(e);
    require to_mathint(i) < to_mathint(mkTokenCount(p.marketId));
    address spoke = mkSpoke(p.marketId);
    address token = mkToken(p.marketId, i);
    address T = drAsset(spoke, p.debtReserveId);
    require token != T;
    require other != currentContract && other != COLLATERALIZATION() && other != spokeHubOf(spoke);
    require other != e.msg.sender;
    mathint otherBalance = erc20Bal[token][other];

    liquidate(e, p);

    assert !escrowedOutsideEscrow, "a payout was deposited with a contract other than PAYOUT_ESCROW";
    assert !routeCalled[other] => erc20Bal[token][other] == otherBalance,
        "liquidate paid a pool token to an address other than a swap route or the caller (residue)";
}

// ---------------------------------------------------------------------------------------------------------------------
// One entry point for every caller (PROP-053)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-053 verifies: INV-037, INV-062, Q-213, Q-235, Q-401, Q-404
// Every caller, direct or through a flash liquidation helper: the borrower receives no pool token other than the debt
// asset, and the call settles at or above the recovery floor.
rule liquidatePaysTheBorrowerOnlyTheDebtAsset(LPVaultSwap.LiquidationParams p, uint256 i) {
    env e;
    setupSwapScene(e);
    require to_mathint(i) < to_mathint(mkTokenCount(p.marketId));
    address token = mkToken(p.marketId, i);
    address T = drAsset(mkSpoke(p.marketId), p.debtReserveId);
    address b = proxyWalletOf(p.proxy);
    require b != e.msg.sender && b != currentContract;
    mathint borrowerBalance = erc20Bal[token][b];

    LPVaultSwap.LiquidationResult r = liquidate(e, p);

    assert token != T => erc20Bal[token][b] == borrowerBalance, "liquidate paid pool tokens to the borrower";
    assert to_mathint(r.recovered) + to_mathint(r.shortfall) >= to_mathint(r.minOut),
        "liquidate settled below the recovery floor";
}

// PROP-053 verifies: INV-037, INV-062, Q-213, Q-333, Q-397, Q-404
// The caller's own funding covers the repayment: D <= Kf, so keeperOut = Kf + R' - D - A - B is never negative and
// InsufficientProceeds cannot fire; LPVaultSwap adds none of its own debt asset.
rule liquidateCallerCoversTheRepayment(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    address T = drAsset(mkSpoke(p.marketId), p.debtReserveId);
    mathint selfBefore = erc20Bal[T][currentContract];

    LPVaultSwap.LiquidationResult r = liquidate(e, p);

    mathint keeperOut = to_mathint(r.callerFunds) + to_mathint(r.recovered) + to_mathint(r.shortfall)
        - to_mathint(r.debtRepaid) - to_mathint(r.avanaFee) - to_mathint(r.borrowerSurplus);
    assert to_mathint(r.debtRepaid) <= to_mathint(r.callerFunds), "Aave repaid more than the caller funded";
    assert r.callerFunds > 0 && r.callerFunds <= p.debtToCover, "the caller funding is not 0 < Kf <= debtToCover";
    assert keeperOut >= 0 && to_mathint(r.keeperOut) == keeperOut,
        "keeperOut differs from Kf + R + shortfall - D - A - B or is negative";
    assert erc20Bal[T][currentContract] == selfBefore, "LPVaultSwap added or kept the debt asset";
}

// PROP-053 verifies: INV-062, Q-213, Q-235, Q-404
rule liquidateNeedsAWorkingRoute(LPVaultSwap.LiquidationParams p, uint256 i) {
    env e;
    setupSwapScene(e);
    require to_mathint(i) < to_mathint(mkTokenCount(p.marketId));
    address t = mkToken(p.marketId, i);
    address T = drAsset(mkSpoke(p.marketId), p.debtReserveId);

    liquidate(e, p);

    assert (unwound[t] > 0 && t != T) => (routeUsable(p.marketId, t, T, 0) || routeUsable(p.marketId, t, T, 1)),
        "liquidate settled a pool token with no usable swap route into the debt asset";
}

// PROP-053 verifies: INV-040, INV-062, Q-333, Q-404
// PROP-036 verifies: INV-040, Q-404
// A liquidation calls no flash source: it reads neither MARKET_REGISTRY.flashSource() nor a flash quote, so the
// caller is its only source of the debt asset (REQ-SWAP-012).
rule liquidateTakesNoFlashLoan(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);

    liquidate(e, p);

    assert flashSourceReads == 0, "liquidate read the flash source";
    assert flashQuoteCalls == 0, "liquidate asked a flash source for a quote";
}

// ---------------------------------------------------------------------------------------------------------------------
// Pending settlement (PROP-051, PROP-060)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-051 verifies: INV-053, INV-058, Q-201, Q-211, Q-224, Q-227, Q-236
// PROP-060 verifies: INV-042, INV-071, Q-236
rule settlePendingSendsProceedsOnlyToCoverage(uint256 m, uint256 r, address token, address other) {
    env e;
    setupSwapScene(e);
    address caller = e.msg.sender;
    address vt = mkVaultToken(m);
    address spoke = mkSpoke(m);
    address T = drAsset(spoke, r);
    address coverage = coverageOf(drFundingHub(spoke, r), T);
    require expectedCoverage == coverage;
    require caller != psFeeRecipient();
    require other != psFeeRecipient() && other != currentContract && other != caller;
    require other != coverageHubOf(coverage) && other != COLLATERALIZATION();
    mathint held = erc20Bal[vt][currentContract];
    mathint pending = pendingUnits[vt];
    mathint callerBalance = erc20Bal[token][caller];
    mathint otherBalance = erc20Bal[token][other];

    uint256 units;
    uint256[] amounts;
    uint256 added;
    units, amounts, added = settlePending(e, m, r);

    assert to_mathint(units) == (held < pending ? held : pending) && units > 0, "units settled differ from min(held, pending)";
    assert burnedSeized == to_mathint(units) && settledPendingUnits == to_mathint(units) && !settleBeforeBurn,
        "the Adapter did not burn the units before Collateralization settled them";
    assert token != vt => erc20Bal[token][caller] == callerBalance, "settlePending paid the caller";
    assert !routeCalled[other] => erc20Bal[token][other] == otherBalance,
        "pool tokens or the debt asset went to an address other than the swap routes called, the Coverage Spoke's Hub or the fee recipient";
    assert !fundedOtherThanExpected, "proceeds funded a Coverage Spoke other than that of the market's (funding Hub, debt asset)";
    assert to_mathint(added) == coverageFunded && coverageFunded == routeOut + unwound[T],
        "the debt asset released or returned by the routes did not all go to the Coverage Spoke";
    assert escrowDeposits == 0, "settlePending used the PayoutEscrow";
}

// PROP-051 verifies: INV-053, Q-201, Q-227, Q-241, Q-242
// Open to any caller, a frozen one included, in every pause state of the market's Hub and with every breaker tripped.
rule settlePendingOpenInEveryState(uint256 m, uint256 r) {
    env e;
    setupSwapScene(e);
    address hub = hubOfSpoke(mkSpoke(m));
    require regFrozen[e.msg.sender];
    require swapHubPauseState[hub] == LPVaultSwap.PauseState.Paused && swapHubPauseReason[hub] == LPVaultSwap.PauseReason.MintPathSuspect;
    require regMarketBreakerReasons[m] != 0;
    require !isApprovedKeeper(e.msg.sender);

    settlePending(e, m, r);

    satisfy true;
}

// ---------------------------------------------------------------------------------------------------------------------
// Repay with collateral, LPVaultSwap side (PROP-072)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-072 verifies: INV-089, Q-255
rule deleverageMakesNoDrawFeeOrBonusPayment(LPVaultSwap.DeleverageRequest r, address a) {
    env e;
    setupDeleverageScene(e);
    address spoke = r.spoke;
    address T = drAsset(spoke, r.debtReserveId);
    address recipient = psFeeRecipient();
    require recipient != r.wallet;
    mathint feeBefore = erc20Bal[T][recipient];
    mathint selfBalance = erc20Bal[T][currentContract];

    deleverage(e, r);

    assert e.msg.sender == AAVE_ADAPTER(), "deleverage from a caller other than the AaveAdapter";
    assert liquidationCalls == 0, "deleverage called liquidationCall";
    assert erc20Bal[T][recipient] == feeBefore, "deleverage paid the fee recipient";
    assert erc20Bal[T][currentContract] == selfBalance, "deleverage changed LPVaultSwap's debt-asset balance";
    assert paidOut[T][a] => (a == flashSourceAddr() || a == spoke || a == r.wallet),
        "deleverage paid the debt asset to an address other than the flash source, the debt Spoke or the wallet";
}

// ---------------------------------------------------------------------------------------------------------------------
// Settlement arithmetic restated over unbounded integers (primary tool per 5.2: Halmos)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-015 verifies: INV-035, INV-036, Q-097, Q-127, Q-135, Q-190, Q-231, Q-235, Q-251, Q-256, Q-267, Q-404 (primary tool per 5.2: Halmos)
// SPEC-LIQ-008 to SPEC-LIQ-010 and SPEC-LIQ-022, every amount in the repaid debt asset; no flash term (Q-404) and no
// budget draw (Q-397). Aave pulls D out of the caller funding, so D <= Kf, and keeperOut >= 0 follows.
rule waterfallBalances(mathint Kf, mathint R, mathint shortfall, mathint D, mathint V, mathint shareBps) {
    require Kf >= 0 && R >= 0 && shortfall >= 0 && D >= 0 && V >= 0;
    require Kf < 2^128 && R < 2^128 && shortfall < 2^128 && D < 2^128 && V < 2^128;
    require shareBps >= 0 && shareBps <= 10000;
    require D <= Kf;
    mathint Rp = R + shortfall;
    mathint S = max0(Rp - D);
    mathint G = max0(V - D);
    mathint feeByValue = (G * shareBps) / 10000;
    mathint A = feeByValue < S ? feeByValue : S;
    mathint kr = (S < G ? S : G) - A;
    mathint B = S - A - kr;
    mathint keeperOut = (Kf + Rp) - (D + A + B);

    assert keeperOut >= 0, "keeperOut is negative although D <= Kf";
    assert Kf + R + shortfall == D + A + B + keeperOut, "the waterfall does not balance";
    assert A <= S, "the Avana fee exceeds the realized surplus";
    assert kr >= 0 && B >= 0 && A + kr + B == S, "the fee, keeper reward and borrower surplus do not split S";
    assert B == max0(S - G), "the borrower surplus differs from max(0, S - G)";
    assert Rp >= D => keeperOut == Kf + kr, "keeperOut differs from Kf + kr while R' >= D";
    assert Rp < D => keeperOut == Kf - (D - Rp), "keeperOut differs from Kf - (D - R') while R' < D";
}

// PROP-015 verifies: INV-035, INV-036, Q-256, Q-337 (primary tool per 5.2: Halmos)
// The 2.11 examples, in units of 0.1 USDC (10^5 base units): Kf = D = 1,950, V 2,047.5. R 2,040.3 gives S 90.3,
// G 97.5, A 19.5, keeper reward 70.8, B 0 and keeperOut 2,020.8 = Kf + 70.8; R 2,052 gives S 102, A 19.5, keeper
// reward 78, B 4.5 and keeperOut 2,028.
rule waterfallExample() {
    mathint u = 10^5;
    mathint D = 19500 * u;
    mathint Kf = D;
    mathint V = 20475 * u;
    mathint G = V - D;
    mathint fee = (G * 2000) / 10000;

    mathint R1 = 20403 * u;
    mathint S1 = R1 - D;
    mathint A1 = fee < S1 ? fee : S1;
    mathint kr1 = (S1 < G ? S1 : G) - A1;
    mathint B1 = S1 - A1 - kr1;
    mathint out1 = (Kf + R1) - (D + A1 + B1);

    mathint R2 = 20520 * u;
    mathint S2 = R2 - D;
    mathint A2 = fee < S2 ? fee : S2;
    mathint kr2 = (S2 < G ? S2 : G) - A2;
    mathint B2 = S2 - A2 - kr2;
    mathint out2 = (Kf + R2) - (D + A2 + B2);

    assert S1 == 903 * u && G == 975 * u && A1 == 195 * u && kr1 == 708 * u && B1 == 0
        && out1 == 20208 * u && out1 == Kf + kr1, "the 2.11 waterfall example does not hold";
    assert S2 == 1020 * u && A2 == 195 * u && kr2 == 780 * u && B2 == 45 * u && out2 == 20280 * u,
        "the 2.11 borrower-surplus example does not hold";
}

// PROP-069 verifies: INV-036, INV-086, Q-256 (primary tool per 5.2: Halmos)
rule oracleFeeMonotoneAndIndependentOfProceeds(mathint V1, mathint V2, mathint Rp1, mathint Rp2, mathint D,
                                               mathint shareBps) {
    require V1 >= 0 && V2 >= V1 && Rp1 >= 0 && Rp2 >= 0 && D >= 0;
    require V2 < 2^128 && Rp1 < 2^128 && Rp2 < 2^128 && D < 2^128;
    require shareBps >= 0 && shareBps <= 10000;
    mathint g1 = max0(V1 - D);
    mathint g2 = max0(V2 - D);
    mathint f1 = (g1 * shareBps) / 10000;
    mathint f2 = (g2 * shareBps) / 10000;
    mathint S1 = max0(Rp1 - D);
    mathint S2 = max0(Rp2 - D);
    mathint A11 = f1 < S1 ? f1 : S1;
    mathint A21 = f2 < S1 ? f2 : S1;
    mathint A12 = f1 < S2 ? f1 : S2;

    assert A11 <= S1, "the fee exceeds S";
    assert A11 <= A21, "the fee falls when the oracle value rises";
    assert (S1 >= f1 && S2 >= f1) => A11 == A12, "the fee depends on the proceeds while S covers it";
}

// PROP-017 verifies: INV-034, Q-159, Q-190, Q-235 (primary tool per 5.2: Halmos)
// SPEC-LIQ-003: s = min(allowance, floor(10000 * (bNet - 10000 - costsBps) / bNet)) if bNet > 10000 + costsBps, else 0;
// then bNet * (10000 - s) >= 10000 * (10000 + costsBps), and the cap equals 10000 - ceil(10000 * (10000 + costsBps) / bNet).
rule effectiveSlippageCoversCosts(mathint b, mathint f, mathint allowance) {
    require b >= 10000 && b <= 20000 && f >= 0 && f <= 100 && allowance >= 0;
    mathint cap = b > 10000 + f ? (10000 * (b - 10000 - f)) / b : 0;
    mathint s = allowance < cap ? allowance : cap;
    assert b >= 10000 + f => b * (10000 - s) >= 10000 * (10000 + f), "the effective slippage exceeds what the bonus pays for";
    assert b > 10000 + f => cap == 10000 - ceilDiv(10000 * (10000 + f), b), "the two forms of the slippage cap differ";
}

// PROP-018 verifies: INV-034, Q-085, Q-159, Q-198 (primary tool per 5.2: Halmos)
rule recoveryFloorRoundsTowardSafety(mathint v, mathint s, mathint unitValue, mathint rounding) {
    require v >= 0 && v <= 10^26 && s >= 0 && s <= 10000 && unitValue >= 0 && rounding >= 0;
    mathint floorGross = ceilDiv(v * (10000 - s), 10000);
    mathint minRec = max0(floorGross - unitValue - rounding);
    assert floorGross * 10000 >= v * (10000 - s), "the ceiling is below the exact net value";
    assert minRec + unitValue + rounding >= floorGross, "the floor terms do not cover the gross floor";
}

// PROP-019 verifies: INV-039, Q-190, Q-235, Q-397, Q-404 (primary tool per 5.2: Halmos)
// SPEC-LIQ-019: there is no in-kind keeper share (Q-401). With D <= Kf and A + B <= S = max(0, R_f - D), where
// R_f = max(R, minRec), the settlement gap g = max(0, D + A + B - Kf - R) never exceeds the floor gap, so
// shortfall = max(0, minRec - R, g) = max(0, minRec - R) and the caller's top-up closes every gap.
rule callerTopUpClosesTheGap(mathint Kf, mathint R, mathint minRec, mathint D, mathint A, mathint B) {
    require Kf >= 0 && R >= 0 && minRec >= 0 && D >= 0 && A >= 0 && B >= 0;
    require D <= Kf;
    mathint floorGap = max0(minRec - R);
    mathint Rf = R + floorGap;
    require A + B <= max0(Rf - D);
    mathint g = max0(D + A + B - Kf - R);
    mathint shortfall = g > floorGap ? g : floorGap;

    assert g <= floorGap, "the settlement gap exceeds the floor gap";
    assert shortfall == floorGap, "the shortfall differs from max(0, minRec - R)";
    assert Kf + R + shortfall - (D + A + B) >= 0, "the top-up leaves the caller payout negative";
}

// PROP-048 verifies: INV-034, Q-159, Q-198 (primary tool per 5.2: Halmos)
rule floorNeverExceedsNetValueAndDustPasses(mathint v, mathint s, mathint unitValue, mathint rounding, mathint recovered) {
    require v >= 0 && v <= 10^26 && s >= 0 && s <= 10000 && unitValue >= 1 && rounding >= 1;
    mathint floorGross = ceilDiv(v * (10000 - s), 10000);
    mathint minRec = max0(floorGross - unitValue - rounding);
    // An unwind that loses at most one raw unit per leg recovers at least the net value less U.
    require recovered >= 0 && recovered * 10000 >= v * (10000 - s) - unitValue * 10000;
    assert minRec * 10000 <= v * (10000 - s), "the floor asks for more than the net oracle value";
    assert recovered >= minRec, "a dust liquidation fails the floor";
}

// PROP-044 verifies: Q-191, Q-235 (primary tool per 5.2: SMTChecker)
// Overflow bounds of SettlementMath inside the listing bounds.
rule settlementMathFitsIn256Bits(mathint c, mathint pc, mathint dd, mathint V, mathint s, mathint a, mathint p) {
    require c >= 0 && c < 2^120 && pc >= 0 && pc < 2^64 && dd >= 0 && dd <= 18;
    require V >= 0 && V < 2^200 && s >= 0 && s <= 10000 && a >= 0 && a < 2^128 && p >= 0 && p < 2^64;
    assert c * pc * 10^dd < 2^256, "SPEC-LIQ-004 numerator overflows";
    assert V * (10000 - s) < 2^256, "SPEC-LIQ-005 product overflows";
    assert a * p * 10^dd < 2^256, "SPEC-LIQ-012 numerator overflows";
}

// ---------------------------------------------------------------------------------------------------------------------
// Per-market isolation (PROP-063, PROP-084) and the balance-delta funding path (PROP-097)
// ---------------------------------------------------------------------------------------------------------------------

// PROP-063 verifies: INV-097, Q-167, Q-228, Q-236, Q-343, Q-397
// PROP-084 verifies: INV-097, Q-362, Q-397
// A liquidation writes no persistent storage of LPVaultSwap: no settlement allowance, reserve, window, counter or
// clock exists to be shared with another market, so what a liquidation in m' reads from LPVaultSwap is the same
// whatever liquidations in m ran before it (the Lock and the deleverage context are transient and end with the call).
rule liquidationWritesNoLPVaultSwapStorage(LPVaultSwap.LiquidationParams p) {
    env e;
    setupSwapScene(e);
    uint256 countBefore = approvedKeeperCount();
    require !lvsStorageWritten;
    liquidate(e, p);
    assert !lvsStorageWritten, "a liquidation wrote LPVaultSwap storage another market could read";
    assert approvedKeeperCount() == countBefore, "a liquidation changed the committed-operator registry";
}

// PROP-097 verifies: INV-095, Q-390, Q-404
// Balance-delta funding: with a debt token that keeps any fee 0 <= fee(a) <= a on the pull into LPVaultSwap, the
// caller funding Kf LPVaultSwap books is its measured balance increase, debtToCover - fee(debtToCover), and the
// amount passed to liquidationCall is that Kf (never debtToCover).
rule callerFundingIsTheMeasuredIncrease(LPVaultSwap.LiquidationParams p) {
    env e;
    setupFeeScene(e);
    address T = drAsset(mkSpoke(p.marketId), p.debtReserveId);
    mathint fee = transferFee(T, p.debtToCover);
    LPVaultSwap.LiquidationResult r = liquidate(e, p);
    assert to_mathint(r.callerFunds) == to_mathint(p.debtToCover) - fee,
        "the booked caller funding differs from LPVaultSwap's measured balance increase";
    assert liquidationAmountPassed == to_mathint(r.callerFunds), "liquidationCall was passed other than the measured Kf";
    assert to_mathint(r.debtRepaid) <= to_mathint(r.callerFunds), "Aave repaid more than LPVaultSwap received";
}

