// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {MarketStatus} from "../../../policy/market-registry/types/MarketRegistryTypes.sol";
import {SpeedView} from "../../../policy/risk-module/types/RiskModuleTypes.sol";
import {AccountGateStatus} from "../../../types/MarketTypes.sol";
import {PriceState} from "../../../types/OracleTypes.sol";
import {PledgePreview} from "../../../types/PositionTypes.sol";

/// @notice An account's liquidation price and borrow rates.
/// @dev `liquidationPrice` USD 8 decimals per whole vault token, rounded up; rates RAY per year, rounded up.
struct AccountRiskView {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 liquidationPrice;
    uint256[] reserveIds;
    uint256[] borrowRatesRay;
}

/// @notice Account view of one wallet's PositionProxy for one market.
/// @dev An undeployed proxy reports the predicted address, no markets and zero debt.
struct AccountView {
    uint256 blockNumber;
    uint256 timestamp;
    address wallet;
    address spoke;
    uint256 marketId;
    address proxy;
    bool deployed;
    uint256 borrowNonce;
    uint256 healthFactor;
    uint256 totalCollateralValue;
    uint256 totalDebtValueRay;
    uint256 avgCollateralFactor;
    uint256 riskPremium;
    uint256 activeCollateralCount;
    uint256 borrowCount;
    AccountGateStatus gateStatus;
    uint32 breakerReasons;
    DebtPosition[] debts;
    MarketPosition[] markets;
}

/// @notice An account before and after one action at the block's prices.
/// @dev Health factors WAD rounded down; liquidation prices USD 8 decimals per whole vault token, rounded up.
struct ActionPreview {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 amount;
    uint256 healthFactorBefore;
    uint256 healthFactorAfter;
    uint256 liquidationPriceBefore;
    uint256 liquidationPriceAfter;
    uint256 collateralValueAfter;
    uint256 debtValueAfterRay;
}

/// @notice Market-level backing and Aave configuration check: raw values and pass/fail flags.
/// @dev Hub values are the market's home Hub's; `stranded` never counts as backing.
struct BackingView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    address hub;
    address vaultToken;
    uint256 assetId;
    uint256 reserveId;
    uint256 totalSupply;
    uint256 totalCredited;
    uint256 pendingUnits;
    uint256[] pendingAmounts;
    uint256 unsettledSeizedUnits;
    uint256 hubBalance;
    uint256 hubLiquidity;
    uint256 stranded;
    uint256 addedAssets;
    uint256 addedShares;
    uint256 drawnShares;
    bool supplyEqualsCredited;
    bool hubHoldsSupplied;
    bool sharesEqualAssets;
    bool noDrawnShares;
    bool noDrawCap;
    bool singleBorrowSpoke;
    bool noLiquidityFee;
    bool noReinvestment;
    bool reserveFlags;
}

/// @notice The amount available to borrow now for one market and debt reserve.
struct BorrowSpeedView {
    // The market window, 8-decimal USD, as the RiskModule reports it.
    SpeedView market;
    // The (funding Hub, asset) window, asset base units, as the RiskModule reports it.
    SpeedView debt;
    // The smaller of both windows, asset base units; 0 when either window is unavailable.
    uint256 availableNow;
    // The earlier non-zero moreAt of the two windows, or 0.
    uint64 moreAt;
}

/// @notice One debt of an account to repay before it closes.
struct DebtClose {
    uint256 reserveId;
    address asset;
    // `getUserTotalDebt`, base units.
    uint256 total;
    // `quoteRepayAll` for the same deadline: the spend cap and approval of `repayAll`.
    uint256 maxRepaySpend;
}

/// @notice One record an account withdraws when it closes.
struct RecordClose {
    bytes32 positionKey;
    // Credited units after reconciliation, the `units` of `AaveAdapter.withdraw`.
    uint256 units;
    // The record's token amounts at the oracle prices (`composition`), pool order.
    uint256[] amounts;
}

/// @notice Everything an account repays and withdraws to close.
/// @dev Repay and debt-free withdrawal are open in every state, so an account can always close.
struct CloseAccountView {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    DebtClose[] debts;
    RecordClose[] records;
}

/// @notice An account's debt on one approved debt reserve of its CDP Spoke.
/// @dev Amounts in debt-asset base units. `priceFresh` uses the stricter borrow age limit.
struct DebtPosition {
    uint256 reserveId;
    address asset;
    uint256 drawn;
    uint256 premium;
    uint256 total;
    bool paused;
    bool priceFresh;
    uint32 breakerReasons;
}

/// @notice Price report of one debt reserve.
/// @dev Prices USD 8 decimals; freshness flags follow execution's rules.
struct DebtPriceView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 debtReserveId;
    address source;
    uint256 price;
    PriceState state;
    uint256 acceptedPrice;
    uint256 updatedAt;
    uint256 age;
    bool fixedPrice;
    bool borrowFresh;
    bool liquidationFresh;
    bool stressPriced;
}

/// @notice One enabled debt reserve with its Hub totals, rates and rate curve.
/// @dev Rates RAY per year; strategy parameters bps; `utilizationBps` and `supplyRateRay` rounded down.
struct DebtReserveView {
    uint256 blockNumber;
    uint256 timestamp;
    address spoke;
    uint256 reserveId;
    address asset;
    uint8 decimals;
    uint256 price;
    bool fixedPrice;
    address hub;
    uint256 hubAssetId;
    uint256 added;
    uint256 drawn;
    uint256 premium;
    uint256 liquidity;
    uint256 utilizationBps;
    uint256 drawnRateRay;
    uint256 supplyRateRay;
    uint256 liquidityFeeBps;
    uint256 optimalUsageBps;
    uint256 baseDrawnRateBps;
    uint256 rateGrowthBeforeOptimalBps;
    uint256 rateGrowthAfterOptimalBps;
    uint256 drawCap;
    uint256 drawHeadroom;
    bool paused;
    bool frozen;
    bool borrowable;
    uint32 breakerReasons;
}

/// @notice The smallest repay with collateral of one record that brings an account to a target health factor.
/// @dev `reachable` false (amounts 0) when the call is closed or the target cannot be reached.
struct DeleverageSizing {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    bool reachable;
    uint256 units;
    uint256 debtRepaid;
    uint256 debtAssetToWallet;
    uint256 healthFactorAfter;
}

/// @notice Aave `drawCap` headroom of a CDP Spoke on one approved debt reserve.
/// @dev Debt-asset base units; max for an unlimited cap. Rounding never overstates headroom.
struct DrawHeadroom {
    uint256 reserveId;
    uint256 headroom;
}

/// @notice One Spoke's slice of a Hub asset: its draw on the (Hub, asset) line and its supply.
/// @dev Amounts in the asset's base units, shares as the Hub stores them.
struct SpokeDraw {
    address spoke;
    address homeHub;
    uint256 drawCap;
    uint256 drawn;
    uint256 deficit;
    SpokeKind kind;
    // Added assets (`getSpokeAddedAssets`), rounded down.
    uint256 added;
    uint256 addedShares;
    // Add cap, whole asset units as the Hub stores it (`type(uint40).max` means none).
    uint256 addCap;
    // Drawn part of `drawn` (`getSpokeOwed`).
    uint256 drawnOwed;
    // Premium part of `drawn` (`getSpokeOwed`).
    uint256 premiumOwed;
    uint256 drawnShares;
    uint256 premiumShares;
    bool active;
    bool halted;
}

/// @notice Exposure of one (Hub, asset) pair across every Spoke that draws on it, with its first-loss coverage.
/// @dev `uncovered` is `ILensRisk.uncoveredDeficit(hub, asset)`; `priceAdj` is the deficit-adjusted share price.
struct HubAssetExposureView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address asset;
    address firstLossReserve;
    uint256 fundedBalance;
    // Summed live Aave draw caps of every CDP Spoke with an enabled debt reserve of the pair, whole tokens.
    uint256 drawCapSum;
    bool coverageBoundHolds;
    uint256 uncovered;
    uint256 priceAdj;
    SpokeDraw[] spokes;
    address deficitOffset;
    uint256 offsetFunded;
}

/// @notice One Hub asset with its totals, rates, rate curve, price and one slice per Spoke.
/// @dev Amounts in the asset's base units; rates RAY per year; `priceUsd8` from the Lend Spoke's AaveOracle.
struct HubAssetView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    uint256 assetId;
    address underlying;
    uint8 decimals;
    uint256 added;
    uint256 addedShares;
    uint256 drawn;
    uint256 premium;
    uint256 owed;
    uint256 drawnShares;
    uint256 premiumShares;
    uint256 liquidity;
    uint256 swept;
    uint256 deficit;
    uint256 accruedFees;
    uint256 utilizationBps;
    uint256 drawnRateRay;
    uint256 supplyRateRay;
    uint256 liquidityFeeBps;
    address feeReceiver;
    address irStrategy;
    uint256 optimalUsageBps;
    uint256 baseDrawnRateBps;
    uint256 rateGrowthBeforeOptimalBps;
    uint256 rateGrowthAfterOptimalBps;
    address lendSpoke;
    uint256 priceUsd8;
    SpokeDraw[] spokes;
}

/// @notice A concentrated-liquidity position: the 12 static fields of `positions(tokenId)`.
/// @dev `poolParam` is the Uniswap v3 fee tier or the Slipstream tick spacing.
struct LensClPosition {
    uint96 nonce;
    address operator;
    address token0;
    address token1;
    int24 poolParam;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}

/// @notice A Uniswap v3 tick: the 8 fields of `ticks(tick)`.
struct LensV3Tick {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}

/// @notice A Slipstream tick: the 10 fields of `ticks(tick)`.
struct LensSlipstreamTick {
    uint128 liquidityGross;
    int128 liquidityNet;
    int128 stakedLiquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    uint256 rewardGrowthOutsideX128;
    int56 tickCumulativeOutside;
    uint160 secondsPerLiquidityOutsideX128;
    uint32 secondsOutside;
    bool initialized;
}

/// @notice Liquidation gates, Aave sizing and ready-to-send parameters for one account and one debt reserve.
/// @dev Advisory; `params.debtToCover` may exceed `expectedDebtRepaid` near Aave's dust threshold.
struct LiquidationPreview {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 marketId;
    address vaultToken;
    uint256 reserveId;
    uint256 debtReserveId;
    address debtAsset;
    uint256 healthFactor;
    bool aaveLiquidatable;
    uint256 bonusBps;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactor;
    uint256 suppliedUnits;
    bool pricesUsable;
    bool feedsDisagree;
    bool debtPriceFresh;
    bool stressValued;
    bool inGrace;
    bool sharesEqualAssets;
    RouteStatus[] routeUsable;
    uint256 activeKeeperCount;
    bool vaultTokenReservePaused;
    bool debtReservePaused;
    uint256 slippageBps;
    uint256 minOutPerWholeToken;
    LiquidationParams params;
    uint256 expectedDebtRepaid;
    uint256 expectedUnitsSeized;
    uint256 recoveryFloor;
    uint256 expectedPayout;
    uint256 expectedNetPayout;
    uint256 expectedAvanaFee;
    uint256 expectedBorrowerSurplus;
    uint256 expectedCallerLoss;
}

/// @notice One collateral market of an account.
/// @dev `shortfall` are units seized on Aave and not yet reconciled; `rescueUnits` never support new debt.
struct MarketPosition {
    address vaultToken;
    uint256 reserveId;
    uint256 suppliedShares;
    uint256 suppliedAssets;
    bool collateralEnabled;
    uint256 credited;
    uint256 recordCount;
    uint256 shortfall;
    PriceState priceState;
    uint32 breakerReasons;
    uint256 rescueUnits;
}

/// @notice One market for the app's market list, with its risk configuration.
/// @dev Prices and caps USD 8 decimals; health factors WAD; rates RAY per year.
struct MarketView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    uint64 chainId;
    MarketStatus status;
    address pool;
    bytes32 poolId;
    address[] tokens;
    uint8[] tokenDecimals;
    uint24 feeTier;
    int24 tickLower;
    int24 tickUpper;
    uint32 integrationId;
    bytes32 ammProtocol;
    address vaultToken;
    string name;
    string symbol;
    address lpOracle;
    address hub;
    address spoke;
    uint256 reserveId;
    uint256 hubAssetId;
    uint256 acceptedPrice;
    PriceState priceState;
    uint256 suppliedUnits;
    uint256 suppliedUsd;
    uint256 collateralFactorBps;
    uint256 liquidationThresholdBps;
    uint256 maxLiquidationBonusBps;
    uint256 marketHeadroomUsd;
    uint256 sliceHeadroomUsd;
    uint256 addHeadroom;
    uint32 breakerReasons;
    uint256 collateralRiskBps;
    uint256 liquidationFeeBps;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactorBps;
    uint256 marketUsdCap;
    uint256 topUpSliceUsd;
    uint256[] tokenUsdCaps;
    uint256 addCap;
    uint256[] debtReserveIds;
    uint256[] borrowRatesRay;
}

/// @notice `RiskModule.previewPledge` with the block it was read at.
struct PledgePreviewView {
    uint256 blockNumber;
    uint256 timestamp;
    PledgePreview preview;
}

/// @notice Uncollected fees of one position.
/// @dev `amounts` are what `collectFees` would pay in the same block, pool order; all zero when unsupported.
struct PositionFeesView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    bytes32 positionKey;
    // The AMM protocol has a fee reader and the position belongs to the market's pool.
    bool supported;
    bool inCustody;
    // Depositor of record, address(0) out of custody.
    address depositor;
    uint128 liquidity;
    // Fees already credited to the position (`tokensOwed`), pool order.
    uint256[] tokensOwed;
    uint256[] amounts;
}

/// @notice One Chainlink input of a market's price.
/// @dev Freshness flags follow execution's `LPPriceMath` rules; a future timestamp is never borrow-fresh.
struct PriceInput {
    address feed;
    uint256 updatedAt;
    uint256 age;
    uint256 borrowPriceMaxAge;
    uint256 liquidationPriceMaxAge;
    bool borrowFresh;
    bool liquidationFresh;
}

/// @notice Custody and live liquidity against credited units for one open record of a market.
/// @dev `backed` is `inCustody && liveUnits >= credited`.
struct RecordBackingView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 recordId;
    uint32 integrationId;
    bytes32 positionKey;
    uint256 credited;
    uint256 liveUnits;
    bool inCustody;
    bool backed;
}

/// @notice One record of an account's seizure list.
/// @dev `creditedAfterReconcile` is the `units` a borrower passes to `AaveAdapter.withdraw`.
struct RecordView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 recordId;
    uint32 integrationId;
    bytes32 positionKey;
    address depositor;
    uint256 credited;
    uint256 liveUnits;
    uint256 creditedAfterReconcile;
}

/// @notice One record's withdrawal against a target health factor.
struct RecordRemoval {
    bytes32 positionKey;
    // Credited units after reconciliation: what `AaveAdapter.withdraw` takes for the record.
    uint256 units;
    // Withdrawing the record alone keeps the account at or above the target and passes the withdrawal gates.
    bool fits;
}

/// @notice The largest collateral removal that keeps an account at or above a target health factor.
/// @dev `bestIndex` is the fitting record with the most units, `type(uint256).max` when none fits.
struct RemovalSizing {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 target;
    uint256 maxUnits;
    uint256 bestIndex;
    RecordRemoval[] records;
}

/// @notice Usability of one swap route a liquidation of the previewed account would use.
/// @dev `routeKind` 0 is the primary, 1 the backup; a pool token equal to the debt asset has no entry.
struct RouteStatus {
    address token;
    address debtAsset;
    uint8 routeKind;
    bool usable;
}

/// @notice The role of a Spoke registered on a Hub asset.
enum SpokeKind {
    Lend,
    Cdp,
    Coverage,
    FeeReceiver,
    Other,
    DeficitOffset
}

/// @notice Cap-based tail coverage of the First-Loss Reserve of one (funding Hub, debt asset) pair.
/// @dev USD values 8 decimals; `ratioBps` measures `funded` alone, max when `tailUsd == 0`.
struct TailCoverageView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address debtAsset;
    address firstLossReserve;
    uint256 funded;
    uint256 minimum;
    uint256 fundedUsd;
    uint256 drawCapUsd;
    address worstToken;
    uint256 tailUsd;
    uint256 ratioBps;
    address deficitOffset;
    uint256 offsetFunded;
}

/// @notice The outcome of withdrawing a record or part of it.
/// @dev `healthFactorAfter` WAD, rounded down; `allowed` is conservative.
struct WithdrawPreview {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 units;
    uint256 healthFactorAfter;
    bool allowed;
}
