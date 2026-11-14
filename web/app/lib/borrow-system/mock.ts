import type {
  BorrowAssetRecord,
  BorrowMarketRecord,
  BorrowSystemState,
  BorrowVisual,
  UserCollateralPosition,
  UserDebtPosition,
  UserRewardPosition,
} from "@/app/lib/credit-engine"
import { RAY, clampMax, clampMin, parseFixed } from "@/app/lib/credit-engine"
import {
  BORROW_POOL_CATALOG,
  poolLpTokenPriceUsd,
  type BorrowAssetVisual,
  type BorrowPoolRow,
} from "@/app/lib/borrow-sim"
import { listSpokeBorrowables, type SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import { HOME_COLLATERAL_POOLS, HOME_CLAIM_POSITIONS } from "@/app/lib/borrow-system/home-contracts"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"

export const HOME_POOL_TO_MARKET_ID: Record<string, string> = {
  "eth-usdc": "uni-v3-bluechip-weth-usdc",
  "wbtc-eth": "uni-v3-bluechip-wbtc-weth",
  "usdc-usdt": "uni-v3-stable-usdc-usdt",
}

/**
 * Test-fixture initial debts, deliberately duplicated here rather than imported from home-sim so
 * that file can drop its copy. Never reaches a real wallet — authenticated flows seed empty
 * accounts and hydrate debts from Convex walletDebts.
 */
const MOCK_INITIAL_DEBTS: Record<string, number> = {
  "eth-usdc": 1_200,
  "usdc-usdt": 800,
  "wbtc-eth": 0,
}

export const HOME_POOL_TO_DEBT_ASSET_ID: Record<string, string> = {
  "eth-usdc": "usdc",
  "wbtc-eth": "weth",
  "usdc-usdt": "usdt",
}

const ASSET_PRICE_USD: Record<string, string> = {
  usdc: "1",
  usdt: "1",
  dai: "1",
  gho: "1",
  frax: "1",
  "usd+": "1",
  eurc: "1.08",
  usde: "1",
  sdai: "1.04",
  weth: "2021.44",
  eth: "2021.44",
  wbtc: "68422.18",
  cbbtc: "68455.10",
  steth: "2112.30",
  wsteth: "2210.80",
  reth: "2249.15",
  cbeth: "2148.09",
  weeth: "2066.42",
  link: "16.48",
  uni: "8.27",
  aave: "109.55",
  arb: "0.92",
  op: "2.11",
  crv: "0.61",
  ldo: "2.21",
  bal: "3.14",
  aura: "0.59",
}

const ASSET_PRICE_CHANGE_24H: Record<string, string> = {
  usdc: "0.0002",
  usdt: "0.0001",
  dai: "0.0001",
  gho: "0.0001",
  weth: "-0.0512",
  eth: "-0.0512",
  wbtc: "-0.0241",
  cbbtc: "-0.0234",
}

function usd6(value: number | string) {
  return parseFixed(typeof value === "number" ? value.toFixed(6) : value, 6)
}

function wadFromPct(value: number) {
  return parseFixed((value / 100).toFixed(18), 18)
}

function wadFromRatio(value: number) {
  return parseFixed(value.toFixed(18), 18)
}

function normalizeVisual(visual: BorrowAssetVisual): BorrowVisual {
  return {
    symbol: visual.symbol,
    shortLabel: visual.shortLabel,
    iconUrl: visual.iconUrl,
    bgClassName: visual.bgClass,
    textClassName: visual.textClass,
  }
}

function estimateRiskScoreWad(pool: BorrowPoolRow) {
  const estimated = pool.riskPremiumBps / 250
  return clampMax(clampMin(wadFromPct(estimated), parseFixed("0.08", 18)), parseFixed("0.9", 18))
}

function estimateLiquidationThresholdWad(pool: BorrowPoolRow) {
  // maxLtv + 10pp, capped 95% — via the shared helper so the credit engine, portfolio HF and the
  // Convex persist gate all use one liquidation-threshold basis.
  return wadFromRatio(liquidationThresholdPctFromMaxLtvPct(pool.ltv) / 100)
}

export function assetPriceUsd6(asset: SpokeBorrowableRecord) {
  // Canonical basis wins so the engine values debt/collateral at the same price the UI shows;
  // ASSET_PRICE_USD is only a fallback for tokens the canonical snapshot omits.
  const canonical = canonicalPriceUsd(asset.baseAssetId) ?? canonicalPriceUsd(asset.id)
  if (canonical !== undefined) return usd6(canonical)
  const byId = ASSET_PRICE_USD[asset.id]
  const byBaseAssetId = ASSET_PRICE_USD[asset.baseAssetId]
  const fallback = asset.category === "stable" ? "1" : asset.category === "btc" ? "68422.18" : "8.5"
  return usd6(byId ?? byBaseAssetId ?? fallback)
}

function assetPriceChangeWad(asset: SpokeBorrowableRecord) {
  const byId = ASSET_PRICE_CHANGE_24H[asset.id]
  const byBaseAssetId = ASSET_PRICE_CHANGE_24H[asset.baseAssetId]
  const fallback = asset.category === "stable" ? "0.0001" : asset.category === "btc" ? "-0.0241" : "-0.031"
  return parseFixed(byId ?? byBaseAssetId ?? fallback, 18)
}

function buildMarketRecord(pool: BorrowPoolRow, borrowAssetIdsBySymbol: Map<string, string>): BorrowMarketRecord {
  const avgApr = (pool.aprMin + pool.aprMax) / 2
  const totalBorrowedUsd = Math.max(pool.tvlUsd * 0.18, pool.availableUsd * 0.42)
  const volume24hUsd = Math.max(pool.availableUsd * 0.12, pool.tvlUsd * 0.035)
  const fees24hUsd = (pool.tvlUsd * (avgApr / 100)) / 365
  const lpTokenPriceUsd = poolLpTokenPriceUsd(pool)

  return {
    id: pool.id,
    spokeId: pool.spoke,
    display: {
      name: pool.name,
      lpSymbol: `${pool.venue.toUpperCase()} ${pool.name}`,
      venue: pool.venue,
      chain: "Ethereum",
      feeTier: pool.feeTier,
      subtitle: `${pool.name} LP collateral market on ${pool.venue}.`,
      visuals: pool.visuals.map(normalizeVisual) as [BorrowVisual, BorrowVisual],
    },
    riskConfig: {
      collateralFactorWad: wadFromPct(pool.ltv),
      liquidationThresholdWad: estimateLiquidationThresholdWad(pool),
      riskScoreWad: estimateRiskScoreWad(pool),
    },
    relations: {
      supportedBorrowAssetIds: pool.borrowableTokens
        .map((visual) => borrowAssetIdsBySymbol.get(visual.symbol.toUpperCase()))
        .filter((value): value is string => Boolean(value)),
      relatedMarketIds: BORROW_POOL_CATALOG.filter(
        (candidate) => candidate.id !== pool.id && candidate.spoke === pool.spoke,
      )
        .slice(0, 3)
        .map((candidate) => candidate.id),
    },
    snapshot: {
      lpTokenPriceUsd6: usd6(lpTokenPriceUsd),
      feeApyWad: wadFromPct(avgApr),
      totalLiquidityUsd6: usd6(pool.tvlUsd),
      totalBorrowedUsd6: usd6(totalBorrowedUsd),
      availableUsd6: usd6(pool.availableUsd),
      volume24hUsd6: usd6(volume24hUsd),
      fees24hUsd6: usd6(fees24hUsd),
      totalCollateralShares: parseFixed((pool.tvlUsd / lpTokenPriceUsd).toFixed(18), 18),
      supplyIndexRay: RAY,
    },
    detail: {
      about: `${pool.name} is supported as collateral through the ${pool.venue} ${pool.feeTier} route.`,
      faqs: [
        {
          question: `What is ${pool.name}?`,
          answer: `${pool.name} is an LP collateral market used to unlock borrow capacity across supported assets.`,
        },
        {
          question: "How is borrowing power determined?",
          answer:
            "Borrowing power is derived from collateral factor, liquidation threshold, account utilization, and current debt.",
        },
      ],
      parameterChanges: [
        { date: "2026-03-18", title: "Risk review completed", body: `Risk inputs for ${pool.name} were refreshed.` },
      ],
      governanceNotes: [
        {
          title: "Risk council note",
          body: `${pool.name} remains eligible for borrowing routes supported by the ${pool.spoke} market family.`,
          tone: "info",
        },
      ],
    },
    analytics: {
      keyMetrics: {},
      cashflow: {
        label: "Cashflow",
        unit: "usd",
        points: [],
      },
      engagement: {
        label: "Engagement",
        unit: "count",
        points: [],
      },
    },
  }
}

function buildAssetRecord(asset: SpokeBorrowableRecord): BorrowAssetRecord {
  return {
    id: asset.id,
    baseAssetId: asset.baseAssetId,
    spokeId: asset.spokeId,
    marketIds: [...asset.marketIds],
    slug: asset.slug,
    contextLabel: asset.contextLabel,
    symbol: asset.symbol,
    display: {
      name: asset.name,
      subtitle: asset.subtitle,
      chain: "Ethereum",
      category: asset.category,
      visual: normalizeVisual(asset.visual),
    },
    borrowConfig: {
      baseBorrowAprWad: wadFromPct(asset.borrowApr),
    },
    snapshot: {
      priceUsd6: assetPriceUsd6(asset),
      priceChange24hWad: assetPriceChangeWad(asset),
      availableLiquidityUsd6: usd6(asset.availableUsd),
      totalBorrowedUsd6: usd6(asset.totalBorrowedUsd),
      totalDebtSharesUsd6: usd6(asset.totalBorrowedUsd),
    },
    detail: {
      about: `${asset.name} is a borrowable asset within the ${asset.spokeLabel} spoke.`,
      faqs: [
        {
          question: `What is ${asset.symbol}?`,
          answer: `${asset.name} can be borrowed only from collateral supplied inside the ${asset.spokeLabel} spoke.`,
        },
      ],
    },
    analytics: {
      utilization: {
        label: "Utilization",
        unit: "pct",
        points: [],
      },
      supplyBorrow: {},
    },
  }
}

function collateralPositionFromHomePool(
  walletId: string,
  poolId: string,
  collateralUsd: number,
  markets: Record<string, BorrowMarketRecord>,
): UserCollateralPosition | null {
  const marketId = HOME_POOL_TO_MARKET_ID[poolId]
  if (!marketId) return null
  const market = markets[marketId]
  if (!market) return null
  const lpTokenPriceUsd = Number(market.snapshot.lpTokenPriceUsd6) / 1_000_000
  const tokenAmountLabel = (collateralUsd / Math.max(lpTokenPriceUsd, 0.000001)).toFixed(18)

  return {
    id: `${walletId}:${marketId}`,
    marketId,
    collateralShares: parseFixed(tokenAmountLabel, 18),
    principalTokenAmount: parseFixed(tokenAmountLabel, 18),
    collateralEnabled: true,
  }
}

function debtPositionFromHomePool(
  walletId: string,
  poolId: string,
  debtUsd: number,
  markets: Record<string, BorrowMarketRecord>,
  assets: Record<string, BorrowAssetRecord>,
): UserDebtPosition | null {
  const assetId = HOME_POOL_TO_DEBT_ASSET_ID[poolId]
  if (!assetId || debtUsd <= 0) return null
  const marketId = HOME_POOL_TO_MARKET_ID[poolId]
  if (!marketId) return null
  const market = markets[marketId]
  if (!market) return null
  const scopedAssetId = `${market.spokeId}:${assetId}`
  const asset = assets[scopedAssetId]
  if (!asset) return null
  return {
    id: `${walletId}:${scopedAssetId}`,
    assetId: scopedAssetId,
    baseAssetId: asset.baseAssetId,
    spokeId: market.spokeId,
    marketId,
    debtSharesUsd6: usd6(debtUsd),
    debtIndexRay: RAY,
    borrowRateWad: asset.borrowConfig.baseBorrowAprWad,
    principalBorrowedUsd6: usd6(debtUsd),
  }
}

export function rewardPositionsFromHomeClaims(
  walletId: string,
  markets: Record<string, BorrowMarketRecord>,
): UserRewardPosition[] {
  return HOME_CLAIM_POSITIONS.map((position) => {
    const marketId = HOME_POOL_TO_MARKET_ID[position.poolId]
    if (!marketId || !markets[marketId]) return null
    return {
      id: position.id,
      marketId,
      claimableUsd6: usd6(position.totalUsd),
      earnedUsd6: usd6(position.totalUsd),
    }
  }).filter((position): position is UserRewardPosition => Boolean(position))
}

function walletLpBalancesFromHomePools() {
  // Seed an LP balance for every catalog market so any listed market can be
  // pledged in the sandbox (home pools keep their larger seeded balances).
  const homeBalances = new Map<string, bigint>()
  for (const pool of HOME_COLLATERAL_POOLS) {
    const marketId = HOME_POOL_TO_MARKET_ID[pool.id]
    if (marketId) homeBalances.set(marketId, usd6(pool.collateralUsd * 2))
  }
  const balances: Record<string, bigint> = {}
  for (const pool of BORROW_POOL_CATALOG) {
    balances[pool.id] = homeBalances.get(pool.id) ?? usd6(25_000)
  }
  return balances
}

function buildMockBorrowCatalog() {
  const spokeBorrowables = listSpokeBorrowables()
  const borrowAssetIdsBySpoke = new Map<string, string>()
  for (const asset of spokeBorrowables) {
    borrowAssetIdsBySpoke.set(`${asset.spokeId}:${asset.symbol.toUpperCase()}`, asset.id)
  }
  const markets: Record<string, BorrowMarketRecord> = {}
  for (const pool of BORROW_POOL_CATALOG) {
    const borrowAssetIdsBySymbol = new Map<string, string>()
    for (const visual of pool.borrowableTokens) {
      borrowAssetIdsBySymbol.set(
        visual.symbol.toUpperCase(),
        borrowAssetIdsBySpoke.get(`${pool.spoke}:${visual.symbol.toUpperCase()}`) ?? "",
      )
    }
    markets[pool.id] = buildMarketRecord(pool, borrowAssetIdsBySymbol)
  }
  const assets: Record<string, BorrowAssetRecord> = {}
  for (const asset of spokeBorrowables) {
    assets[asset.id] = buildAssetRecord(asset)
  }
  return { markets, assets }
}

export function buildMockBorrowSystemState(walletId = "demo-wallet"): BorrowSystemState {
  const { markets, assets } = buildMockBorrowCatalog()
  const collateralPositions = HOME_COLLATERAL_POOLS.map((pool) =>
    collateralPositionFromHomePool(walletId, pool.id, pool.collateralUsd, markets),
  ).filter((position): position is UserCollateralPosition => Boolean(position))
  // home-demo-wallet is the unauthenticated landing demo, deliberately debt-free. Every other
  // walletId here is a test fixture; authenticated wallets use buildConvexBorrowSessionSeed.
  const initialDebts = walletId === "home-demo-wallet" ? {} : MOCK_INITIAL_DEBTS
  const debtPositions = Object.entries(initialDebts)
    .map(([poolId, debtUsd]) => debtPositionFromHomePool(walletId, poolId, debtUsd, markets, assets))
    .filter((position): position is UserDebtPosition => Boolean(position))
  const rewardPositions = rewardPositionsFromHomeClaims(walletId, markets)

  return {
    now: Date.UTC(2026, 5, 19),
    markets,
    assets,
    accounts: {
      [walletId]: {
        walletId,
        walletBalanceUsd6: usd6(12_500),
        walletLpBalancesUsd6: walletLpBalancesFromHomePools(),
        walletReturnedLpBalancesUsd6: {},
        interestSettledUsd6: 0n,
        lastUpdatedAt: Date.UTC(2026, 5, 18, 12),
        collateralPositions,
        debtPositions,
        rewardPositions,
      },
    },
    transactions: [],
  }
}

export function buildBorrowCatalogBaselineState(walletId = "catalog"): BorrowSystemState {
  return buildMockBorrowSystemState(walletId)
}
