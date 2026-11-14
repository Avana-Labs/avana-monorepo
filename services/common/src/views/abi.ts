// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The view functions the snapshot reader calls, as human-readable ABI fragments that mirror the Solidity
// declarations field for field: the Lens market, exposure and speed-limit views (contracts/src/lens/lens/), the MarketRegistry
// Hub, Spoke and credit-line views, the Aave V4 Hub and Spoke views at the pinned release, the asset rate strategy and
// the Spoke's AaveOracle. Struct fields are decoded by position, so a field added in the middle of a struct must be
// added here in the same place.
// services/indexer/test/views-abi.test.ts checks every selector against the ABIs generated in packages/protocol.

import { parseAbi } from "viem";

export const lensViewsAbi = parseAbi([
  "struct MarketView { uint256 blockNumber; uint256 timestamp; uint256 marketId; uint64 chainId; uint8 status; address pool; bytes32 poolId; address[] tokens; uint8[] tokenDecimals; uint24 feeTier; int24 tickLower; int24 tickUpper; uint32 integrationId; bytes32 ammProtocol; address vaultToken; string name; string symbol; address lpOracle; address hub; address spoke; uint256 reserveId; uint256 hubAssetId; uint256 acceptedPrice; uint8 priceState; uint256 suppliedUnits; uint256 suppliedUsd; uint256 collateralFactorBps; uint256 liquidationThresholdBps; uint256 maxLiquidationBonusBps; uint256 marketHeadroomUsd; uint256 sliceHeadroomUsd; uint256 addHeadroom; uint8 pauseState; uint32 breakerReasons; uint256 collateralRiskBps; uint256 liquidationFeeBps; uint256 targetHealthFactor; uint256 healthFactorForMaxBonus; uint256 liquidationBonusFactorBps; uint256 hardHealthFloor; uint256 marketUsdCap; uint256 topUpSliceUsd; uint256 depositorUsdCap; uint256[] tokenUsdCaps; uint256 addCap; uint256[] debtReserveIds; uint256[] borrowRatesRay; }",
  "struct DebtReserveView { uint256 blockNumber; uint256 timestamp; address spoke; uint256 reserveId; address asset; uint8 decimals; uint256 price; bool fixedPrice; address hub; uint256 hubAssetId; uint256 added; uint256 drawn; uint256 premium; uint256 liquidity; uint256 utilizationBps; uint256 drawnRateRay; uint256 supplyRateRay; uint256 liquidityFeeBps; uint256 optimalUsageBps; uint256 baseDrawnRateBps; uint256 rateGrowthBeforeOptimalBps; uint256 rateGrowthAfterOptimalBps; uint256 drawCap; uint256 drawHeadroom; bool paused; bool frozen; bool borrowable; uint32 breakerReasons; uint8 pauseState; }",
  "struct SpokeDraw { address spoke; address homeHub; uint256 drawCap; uint256 drawn; uint256 deficit; uint8 kind; uint256 added; uint256 addedShares; uint256 addCap; uint256 drawnOwed; uint256 premiumOwed; uint256 drawnShares; uint256 premiumShares; bool active; bool halted; }",
  "struct HubAssetExposureView { uint256 blockNumber; uint256 timestamp; address hub; address asset; address firstLossReserve; uint256 fundedBalance; uint256 line; bool coverageBoundHolds; uint256 uncovered; uint256 priceAdj; SpokeDraw[] spokes; address deficitOffset; uint256 offsetFunded; }",
  "struct SpeedView { uint256 limit; uint256 used; uint256 available; uint64 moreAt; uint256 moreAmount; bool unavailable; }",
  "struct BorrowSpeedView { SpeedView market; SpeedView debt; uint256 availableNow; uint64 moreAt; }",
  "function LENS_MAX_PAGE() view returns (uint256 maxPage)",
  "function getMarkets(uint256 offset, uint256 limit) view returns (MarketView[] markets)",
  "function getDebtReserves(address spoke) view returns (DebtReserveView[] reserves)",
  "function getHubAssetExposure(address hub, address asset) view returns (HubAssetExposureView view_)",
  "function getApplicationState(address hub) view returns (uint8 state)",
  "function getBorrowSpeed(uint256 marketId, uint256 debtReserveId) view returns (BorrowSpeedView speed)",
  "function getPledgeSpeed(uint256 marketId) view returns (SpeedView pledge)",
]);

/**
 * `FIRST_LOSS_LAYER()` of a DAO deficit offset (DaoDeficitOffset): the First-Loss Reserve it stands behind. Any other
 * Spoke reverts, so discovery reads it with failures allowed.
 */
export const deficitOffsetViewsAbi = parseAbi(["function FIRST_LOSS_LAYER() view returns (address layer)"]);

/**
 * MarketRegistry views that name every recorded Hub, every approved CDP Spoke and the Hub-to-Hub credit lines, so a
 * Hub or CDP Spoke listed after start-up is read at the next snapshot without a deployment change.
 */
export const registryViewsAbi = parseAbi([
  "function getHubs() view returns (address[] hubs)",
  "function getSpokes() view returns (address[] spokes)",
  "function hubOf(address spoke) view returns (address hub)",
  "function hubTier(address hub) view returns (uint8 tier)",
  "function isRecordedHub(address account) view returns (bool recorded)",
  "function firstLossReserveOf(address hub, address asset) view returns (address firstLossReserve)",
  "function crossHubLineCap(address fundingHub, address asset, address spoke) view returns (uint256 cap)",
  "function crossHubLineTotal(address fundingHub, address asset) view returns (uint256 total)",
  "function crossHubLinesEnabled() view returns (bool enabled)",
]);

export const hubViewsAbi = parseAbi([
  "struct AssetConfig { address feeReceiver; uint16 liquidityFee; address irStrategy; address reinvestmentController; }",
  "struct SpokeData { uint120 drawnShares; uint120 premiumShares; int200 premiumOffsetRay; uint120 addedShares; uint40 addCap; uint40 drawCap; uint24 riskPremiumThreshold; bool active; bool halted; uint200 deficitRay; }",
  "function getAssetCount() view returns (uint256)",
  "function getAddedAssets(uint256 assetId) view returns (uint256)",
  "function getAddedShares(uint256 assetId) view returns (uint256)",
  "function getAssetOwed(uint256 assetId) view returns (uint256, uint256)",
  "function getAssetLiquidity(uint256 assetId) view returns (uint256)",
  "function getAssetDeficitRay(uint256 assetId) view returns (uint256)",
  "function getAssetAccruedFees(uint256 assetId) view returns (uint256)",
  "function getAssetDrawnRate(uint256 assetId) view returns (uint256)",
  "function getAssetDrawnIndex(uint256 assetId) view returns (uint256)",
  "function getAssetConfig(uint256 assetId) view returns (AssetConfig)",
  "function getAssetUnderlyingAndDecimals(uint256 assetId) view returns (address, uint8)",
  "function getSpokeCount(uint256 assetId) view returns (uint256)",
  "function getSpokeAddress(uint256 assetId, uint256 index) view returns (address)",
  "function getSpoke(uint256 assetId, address spoke) view returns (SpokeData)",
  "function getSpokeAddedAssets(uint256 assetId, address spoke) view returns (uint256)",
  "function getSpokeTotalOwed(uint256 assetId, address spoke) view returns (uint256)",
]);

export const spokeViewsAbi = parseAbi([
  "struct Reserve { address underlying; address hub; uint16 assetId; uint8 decimals; uint24 collateralRisk; uint8 flags; uint32 dynamicConfigKey; }",
  "struct ReserveConfig { uint24 collateralRisk; bool paused; bool frozen; bool borrowable; bool receiveSharesEnabled; }",
  "struct LiquidationConfig { uint128 targetHealthFactor; uint64 healthFactorForMaxBonus; uint16 liquidationBonusFactor; }",
  "function ORACLE() view returns (address)",
  "function getReserveCount() view returns (uint256)",
  "function getReserve(uint256 reserveId) view returns (Reserve)",
  "function getReserveConfig(uint256 reserveId) view returns (ReserveConfig)",
  "function getLiquidationConfig() view returns (LiquidationConfig)",
  "function getUserSuppliedAssets(uint256 reserveId, address user) view returns (uint256)",
  "function getUserDebt(uint256 reserveId, address user) view returns (uint256, uint256)",
]);

/** The asset's interest-rate strategy (`ILensRateStrategy`, same ABI as the pinned release). */
export const rateStrategyAbi = parseAbi([
  "struct InterestRateData { uint16 optimalUsageRatio; uint32 baseDrawnRate; uint32 rateGrowthBeforeOptimal; uint32 rateGrowthAfterOptimal; }",
  "function getInterestRateData(uint256 assetId) view returns (InterestRateData)",
]);

/** The Lend Spoke's AaveOracle: the one USD price of every Hub asset on every page. */
export const aaveOracleAbi = parseAbi([
  "function decimals() view returns (uint8)",
  "function getReservePrice(uint256 reserveId) view returns (uint256)",
]);

/**
 * Concentrated-liquidity pool events and views; Uniswap v3 and Aerodrome Slipstream pools share these signatures.
 * Not Avana or Aave contracts, so they are not part of packages/protocol.
 */
export const clPoolAbi = parseAbi([
  "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
  "event Mint(address sender, address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
  "event Burn(address indexed owner, int24 indexed tickLower, int24 indexed tickUpper, uint128 amount, uint256 amount0, uint256 amount1)",
  "function fee() view returns (uint24)",
]);
