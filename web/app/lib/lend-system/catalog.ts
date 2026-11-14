import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend/asset-groups"
import { calculateAvailableLiquidity, calculateTotalApy, calculateUtilization } from "@/app/lib/lend-engine/formulas"
import { INITIAL_LIQUIDITY_INDEX } from "@/app/lib/lend-engine/constants"
import type { LendMarket, LendMarketCategory, LendRiskTier } from "@/app/lib/lend-engine/types"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"

const SPEC_UTILIZATION: Record<string, number> = {
  USDC: 0.32,
  USDT: 0.3183,
  EURC: 0.298,
  FRXUSD: 0.1537,
  GHO: 0.6411,
  USDG: 0.1643,
  ETH: 0.6133,
  WSTETH: 0.6571,
  CBBTC: 0.6333,
  WBTC: 0.6778,
  AAVE: 0.5851,
  UNI: 0.6125,
}

const SPEC_SUPPLY_APY: Record<string, number> = {
  USDC: 0.0485,
  USDT: 0.048,
  EURC: 0.0049,
  GHO: 0.0299,
  ETH: 0.0382,
  WSTETH: 0.0514,
  CBBTC: 0.0425,
  WBTC: 0.0348,
  AAVE: 0.076,
  UNI: 0.064,
}

const SPEC_REWARDS_APY: Record<string, number> = {
  FRXUSD: 0.01,
  USDG: 0.0125,
}

function reserveFactorForGroup(title: string): number {
  if (title === "Stablecoins") return 0.1
  if (title === "Ethereum-Based") return 0.15
  if (title === "Bitcoin Based") return 0.2
  return 0.2
}

function riskTierForGroup(title: string): LendRiskTier {
  if (title === "Stablecoins") return "low"
  if (title === "Ethereum-Based") return "medium"
  if (title === "Bitcoin Based") return "medium"
  return "high"
}

function categoryForGroup(title: string): LendMarketCategory {
  if (title === "Stablecoins") return "stable"
  if (title === "Coinbase & Robinhood Stocks") return "stock"
  return "crypto"
}

function toMarketId(symbol: string) {
  return symbol.toLowerCase().replace(/[^a-z0-9]/g, "")
}

function buildMarketFromRow(
  row: (typeof LEND_ASSET_GROUPS)[number]["rows"][number],
  rank: number,
  groupTitle: string,
  now: number,
): LendMarket {
  const symbol = row.symbol.toUpperCase()
  const marketId = toMarketId(row.symbol)
  const assetPriceUsd = sandboxBaselinePriceUsd(symbol)
  // Catalog deposit/liquidity figures are USD TVL in thousands (e.g. 120400 → $120.40M).
  // Convert to token amounts so `totalSupplied * price` reconciles to that USD TVL for
  // every asset (stable or volatile), keeping the list, detail, and Convex seed in sync
  // at a realistic $M scale instead of the raw ~$120K the unscaled value produced.
  const suppliedUsd = row.totalDepositsValue * 1_000
  const availableUsd = row.availableLiquidityValue * 1_000
  const totalSupplied = suppliedUsd / assetPriceUsd
  // When a spec utilization is pinned, it is the authoritative figure: derive
  // borrowed (and therefore available) FROM it so the list's "Available" matches
  // the detail page, which computes available = supplied·(1 − utilization). The
  // raw catalog `availableLiquidityValue` was authored as the borrowed amount for
  // these markets, so trusting it here surfaced borrowed as "Available" (#19).
  const specUtilization = SPEC_UTILIZATION[symbol]
  const totalBorrowed =
    specUtilization !== undefined
      ? totalSupplied * specUtilization
      : Math.max(0, totalSupplied - availableUsd / assetPriceUsd)
  const utilization = specUtilization ?? calculateUtilization(totalBorrowed, totalSupplied)
  const rewardsApy = SPEC_REWARDS_APY[symbol] ?? 0
  const totalDisplayApy = row.apyValue / 100
  const supplyApy = SPEC_SUPPLY_APY[symbol] ?? Math.max(0, totalDisplayApy - rewardsApy)
  const totalApy = calculateTotalApy(supplyApy, rewardsApy)

  return {
    marketId,
    chainId: 1,
    rank,
    asset: { symbol: row.symbol, name: row.name, priceUsd: assetPriceUsd },
    assetPriceUsd,
    supplyApy,
    rewardsApy,
    totalApy,
    totalSupplied,
    totalBorrowed,
    availableLiquidity: calculateAvailableLiquidity(totalSupplied, totalBorrowed),
    utilization,
    reserveFactor: reserveFactorForGroup(groupTitle),
    status: "active",
    riskTier: riskTierForGroup(groupTitle),
    category: categoryForGroup(groupTitle),
    liquidityIndex: INITIAL_LIQUIDITY_INDEX,
    lastAccrualTimestamp: now,
    priceUpdatedAt: now,
  }
}

const NOW = Date.UTC(2026, 5, 19)

export const LEND_MARKET_CATALOG: LendMarket[] = []
for (const group of LEND_ASSET_GROUPS) {
  for (const row of group.rows) {
    LEND_MARKET_CATALOG.push(buildMarketFromRow(row, LEND_MARKET_CATALOG.length + 1, group.title, NOW))
  }
}

export function buildLendCatalogMarketsRecord(now = NOW): Record<string, LendMarket> {
  const markets: Record<string, LendMarket> = {}
  let rank = 1
  for (const group of LEND_ASSET_GROUPS) {
    for (const row of group.rows) {
      const market = buildMarketFromRow(row, rank, group.title, now)
      markets[market.marketId] = market
      rank += 1
    }
  }
  return markets
}

export function getLendMarketById(marketId: string) {
  return LEND_MARKET_CATALOG.find((market) => market.marketId === marketId.toLowerCase()) ?? null
}

export function resolveLendMarketId(symbol: string) {
  return symbol.toLowerCase().replace(/[^a-z0-9]/g, "")
}
