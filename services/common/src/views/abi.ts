// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The view functions the snapshot reader calls, as human-readable ABI fragments that mirror the Solidity
// declarations field for field: the RiskModule's market and draw-cap coverage views, the LPOracle, the First-Loss
// Reserve's balance, the Aave V4 Hub and Spoke views at the pinned release, the asset rate strategy and the Spoke's
// AaveOracle. Struct fields are decoded by position, so a field added in the middle of a struct must be
// added here in the same place.
// services/indexer/test/views-abi.test.ts checks every selector against the ABIs generated in packages/protocol.

import { parseAbi } from "viem";

/**
 * The RiskModule's market record and draw-cap coverage (contracts/src/interfaces/IRiskModule.sol). The market
 * struct decodes by position, so a field added in the middle must be added here in the same place.
 */
export const riskModuleViewsAbi = parseAbi([
  "struct Market { bytes32 pool; address spoke; address vaultToken; address lpOracle; uint256 reserveId; uint256 priceReserveId0; uint256 priceReserveId1; int24 bandLower; int24 bandUpper; uint16 ltvBps; uint8 unitDecimals; uint8 kind; bool active; }",
  "function getMarket(uint256 marketId) view returns (Market market)",
  "function coverage(address hub, address asset) view returns (uint256 drawCapSum, uint256 required, uint256 funded)",
]);

/** The market's LPOracle: the Spoke's price of one whole vault token. */
export const lpOracleViewsAbi = parseAbi(["function latestAnswer() view returns (int256)", "function decimals() view returns (uint8)"]);

/** A First-Loss Reserve's funded balance. */
export const firstLossReserveViewsAbi = parseAbi(["function fundedBalance() view returns (uint256 balance)"]);

/** ERC-20 metadata of pool tokens and vault tokens. */
export const erc20ViewsAbi = parseAbi(["function decimals() view returns (uint8)", "function symbol() view returns (string)"]);

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
  "struct DynamicReserveConfig { uint16 collateralFactor; uint32 maxLiquidationBonus; uint16 liquidationFee; }",
  "function getLiquidationConfig() view returns (LiquidationConfig)",
  "function getDynamicReserveConfig(uint256 reserveId, uint32 dynamicConfigKey) view returns (DynamicReserveConfig)",
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

/**
 * Uniswap v4 PoolManager events: one singleton per chain holds every pool, keyed by PoolId (topic 1). A swap's
 * amounts are the swapper's deltas, so the input side is negative. Not part of packages/protocol.
 */
export const uniswapV4PoolManagerAbi = parseAbi([
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
  "event Donate(bytes32 indexed id, address indexed sender, uint256 amount0, uint256 amount1)",
]);
