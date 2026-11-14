import { formatCompactUsd } from "@/app/lib/borrow-sim"
import { formatActivityTokenAmount } from "@/app/lib/currency/format"
import { calculateMaxWithdrawable, calculateTotalApy } from "@/app/lib/lend-engine/formulas"
import type { LendMarket, LendSystemState } from "@/app/lib/lend-engine"
import type { LendPageData } from "@/app/lib/data/providers/lend/types"
import type { PortfolioLendTabData, PortfolioStrategyBucket } from "@/app/lib/data/providers/portfolio/types"
import { LEND_ASSET_GROUPS } from "@/app/lib/data/catalog/lend/asset-groups"
import { LEND_FEATURED_ASSETS, LEND_FEATURED_SEQUENCE } from "@/app/lib/data/catalog/lend/featured-assets"
import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"
import { LEND_MARKET_CATALOG } from "./catalog"
import { formatReliableLendApyLabel } from "./illiquid-apy"
import type { LendTransactionHistoryItem, LendWalletReadSnapshot, LendYieldSnapshot } from "./contracts"
import { formatPercent } from "@/app/lib/format"

function formatTokenQuantity(value: number, symbol: string) {
  if (value > 0 && value < 0.01) return `<0.01 ${symbol}`
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M ${symbol}`
  if (value >= 1_000) return `${(value / 1_000).toFixed(2)}K ${symbol}`
  return `${value.toLocaleString("en-US", { maximumFractionDigits: 2 })} ${symbol}`
}

function formatPositiveUsd(value: number) {
  return value > 0 && value < 0.01 ? "<$0.01" : formatCompactUsd(value)
}

export type LendFeaturedSnapshot = {
  marketId: string
  symbol: string
  displayName: string
  eyebrow: string
  apyLabel: string
  apyPct: number
  /** Supply APY as a percent — matches the list-row "Supply APY" column so the card and table agree. */
  supplyApyPct: number
  tone: "green" | "blue"
  iconUrl: string
  href: string
  sparklinePath?: string
}

type LendMarketRow = {
  marketId: string
  href: string
  asset: string
  assetName: string
  logoSrc?: string
  supplyApyLabel: string
  rewardsApyLabel: string
  totalApyLabel: string
  totalSuppliedLabel: string
  availableLiquidityLabel: string
  utilizationLabel: string
  reserveFactorLabel: string
  status: string
  supplyApy: number
  rewardsApy: number
  totalApy: number
  totalSupplied: number
  availableLiquidity: number
  utilization: number
  reserveFactor: number
}

export function buildLendFeaturedSnapshots(markets: LendMarket[]): LendFeaturedSnapshot[] {
  return LEND_FEATURED_SEQUENCE.map((featuredId) => {
    const featured = LEND_FEATURED_ASSETS[featuredId]
    const market = markets.find((entry) => entry.asset.symbol.toUpperCase() === featured.symbol.toUpperCase())
    const apy = market?.totalApy ?? featured.apy / 100
    const supplyApy = market?.supplyApy ?? featured.apy / 100
    return {
      marketId: market?.marketId ?? featuredId,
      symbol: featured.symbol,
      displayName: featured.displayName,
      eyebrow: featured.eyebrow,
      apyLabel: formatPercent(apy * 100),
      apyPct: apy * 100,
      supplyApyPct: supplyApy * 100,
      tone: featured.tone,
      iconUrl: featured.iconUrl,
      href: `/lend/markets/${market?.marketId ?? featuredId}`,
      sparklinePath: featured.path,
    }
  })
}

const formatFractionPct = (value: number) => formatPercent(value * 100)

function formatSandboxSupplyApyLabel(supplyApy: number, tvlUsd: number) {
  return formatReliableLendApyLabel(supplyApy, tvlUsd, formatFractionPct)
}

function formatTotalApyLabel(totalApy: number, tvlUsd: number) {
  return formatReliableLendApyLabel(totalApy, tvlUsd, formatFractionPct)
}

export function catalogMarketToRow(market: LendMarket): LendMarketRow {
  const tvlUsd = market.totalSupplied * market.assetPriceUsd
  return {
    marketId: market.marketId,
    href: `/lend/markets/${market.marketId}`,
    asset: market.asset.symbol,
    assetName: market.asset.name,
    logoSrc: getLocalAssetIcon(market.asset.symbol),
    supplyApyLabel: formatSandboxSupplyApyLabel(market.supplyApy, tvlUsd),
    rewardsApyLabel: market.rewardsApy > 0 ? formatPercent(market.rewardsApy * 100) : "No rewards",
    totalApyLabel: formatTotalApyLabel(market.totalApy, tvlUsd),
    totalSuppliedLabel: formatCompactUsd(market.totalSupplied * market.assetPriceUsd),
    availableLiquidityLabel: formatCompactUsd(market.availableLiquidity * market.assetPriceUsd),
    utilizationLabel: formatPercent(market.utilization * 100),
    reserveFactorLabel: formatPercent(market.reserveFactor * 100),
    status: market.status,
    supplyApy: market.supplyApy,
    rewardsApy: market.rewardsApy,
    totalApy: market.totalApy,
    totalSupplied: market.totalSupplied,
    availableLiquidity: market.availableLiquidity,
    utilization: market.utilization,
    reserveFactor: market.reserveFactor,
  }
}

export function buildLendPageData(_walletId: string, state?: LendSystemState): LendPageData {
  const markets = state ? Object.values(state.markets) : LEND_MARKET_CATALOG
  const assetGroups = LEND_ASSET_GROUPS.map((group) => ({
    ...group,
    rows: group.rows.map((row) => {
      const market = markets.find((entry) => entry.asset.symbol.toUpperCase() === row.symbol.toUpperCase())
      const rowMarket = market ? catalogMarketToRow(market) : null
      return {
        ...row,
        marketId: rowMarket?.marketId,
        href: rowMarket?.href,
        apy: rowMarket?.totalApyLabel ?? row.apy,
        apyValue: rowMarket
          ? rowMarket.totalApyLabel.includes("Illiquid")
            ? 0
            : rowMarket.totalApy * 100
          : row.apyValue,
        supplyApyLabel: rowMarket?.supplyApyLabel,
        rewardsApyLabel: rowMarket?.rewardsApyLabel ?? "No rewards",
        totalApyLabel: rowMarket?.totalApyLabel ?? row.apy,
        supplyApyValue: rowMarket?.supplyApy ?? row.apyValue / 100,
        rewardsApyValue: rowMarket?.rewardsApy ?? 0,
        totalDepositsLabel: market ? formatTokenQuantity(market.totalSupplied, market.asset.symbol) : undefined,
        totalDepositsSecondaryLabel: market
          ? formatPositiveUsd(market.totalSupplied * market.assetPriceUsd)
          : undefined,
        totalDepositsSortValue: market ? market.totalSupplied * market.assetPriceUsd : undefined,
        utilizationLabel: rowMarket?.utilizationLabel ?? "—",
        utilizationValue: rowMarket?.utilization ?? 0,
        availableLiquidityLabel: market
          ? formatTokenQuantity(market.availableLiquidity, market.asset.symbol)
          : undefined,
        availableLiquiditySecondaryLabel: market
          ? formatPositiveUsd(market.availableLiquidity * market.assetPriceUsd)
          : undefined,
        availableLiquiditySortValue: market ? market.availableLiquidity * market.assetPriceUsd : undefined,
        reserveFactorLabel: rowMarket?.reserveFactorLabel ?? "—",
        reserveFactorValue: rowMarket?.reserveFactor ?? 0,
        status: rowMarket?.status ?? "active",
      }
    }),
  }))

  return {
    markets: markets.map((market) => ({
      symbol: market.asset.symbol,
      name: market.asset.name,
      apy: market.totalApy * 100,
      apyChange24h: 0,
      tvl: formatCompactUsd(market.totalSupplied * market.assetPriceUsd),
      tvlUsd: market.totalSupplied * market.assetPriceUsd,
      utilization: Math.round(market.utilization * 100),
      type: market.riskTier,
      protocol: market.asset.symbol,
      color: "text-foreground",
      bg: "bg-card",
      soon: market.status !== "active",
      event: null,
    })),
    featuredAssets: LEND_FEATURED_ASSETS,
    featuredSequence: LEND_FEATURED_SEQUENCE,
    featuredSnapshots: buildLendFeaturedSnapshots(markets),
    assetGroups,
  }
}

const STRATEGY_TIERS = [
  {
    riskTier: "low" as const,
    tone: "conservative" as const,
    title: "Conservative Strategy",
    description: "Stable assets with lower risk",
  },
  {
    riskTier: "medium" as const,
    tone: "moderate" as const,
    title: "Moderate Strategy",
    description: "Balanced risk-reward ratio",
  },
  {
    riskTier: "high" as const,
    tone: "aggressive" as const,
    title: "Aggressive Strategy",
    description: "High risk, high potential returns",
  },
]

// Buckets by YIELD, not collateral risk tier: a "stable" asset paying 30% APY is not
// conservative, so bucketing by APY keeps the risk-reward narrative honest.
function strategyTierForApyPct(apyPct: number): "low" | "medium" | "high" {
  if (apyPct < 8) return "low"
  if (apyPct < 18) return "medium"
  return "high"
}

export function buildLendStrategyBuckets(markets: LendMarket[]): PortfolioStrategyBucket[] {
  const buckets: PortfolioStrategyBucket[] = []
  for (const tier of STRATEGY_TIERS) {
    const tierMarkets = markets
      .filter((market) => market.status !== "paused" && strategyTierForApyPct(market.totalApy * 100) === tier.riskTier)
      .sort((a, b) => b.totalApy - a.totalApy)
    if (tierMarkets.length === 0) continue

    const apys = tierMarkets.map((market) => market.totalApy * 100)
    const minApy = Math.min(...apys)
    const maxApy = Math.max(...apys)
    const apyRangeLabel =
      minApy === maxApy ? `${maxApy.toFixed(1)}% APY` : `${minApy.toFixed(1)}-${maxApy.toFixed(1)}% APY range`

    buckets.push({
      title: tier.title,
      description: tier.description,
      apyRangeLabel,
      tone: tier.tone,
      pools: tierMarkets.map((market) => ({
        name: `Aave ${market.asset.symbol}`,
        apyPct: market.totalApy * 100,
        tvlUsd: market.totalSupplied * market.assetPriceUsd,
        isUp: market.rewardsApy > 0,
        allocationUsd: 0,
      })),
    })
  }
  return buckets
}

export function buildPortfolioLendData(
  walletId: string,
  state: LendSystemState,
  history: LendTransactionHistoryItem[] = [],
): PortfolioLendTabData {
  const walletPositions = Object.values(state.positions).filter((position) => position.walletId === walletId)
  const positions = walletPositions.filter((position) => position.walletId === walletId && position.status === "active")
  const claimableRewardsUsd = walletPositions.reduce((sum, position) => sum + position.rewardsEarnedUsd, 0)
  const closedRewardsUsd = walletPositions
    .filter((position) => position.status === "closed")
    .reduce((sum, position) => sum + position.rewardsEarnedUsd, 0)

  const investments = positions.map((position) => {
    const market = state.markets[position.marketId]!
    const maxWithdrawable = calculateMaxWithdrawable(position.currentSuppliedAmount, market.availableLiquidity)
    const walletBalance = state.walletBalances[walletId]?.[position.marketId] ?? 0
    return {
      id: position.positionId,
      marketId: position.marketId,
      symbol: position.asset,
      name: market.asset.name,
      balance: position.currentSuppliedAmount,
      priceUsd: market.assetPriceUsd,
      suppliedUsd: position.suppliedValueUsd,
      principalUsd: position.principalAmount * market.assetPriceUsd,
      earnedUsd: position.interestEarned * market.assetPriceUsd + position.rewardsEarnedUsd,
      interestUsd: position.interestEarned * market.assetPriceUsd,
      rewardsEarnedUsd: position.rewardsEarnedUsd,
      // Supply APY, not totalApy, is the canonical lend rate — the same number /lend and the
      // deposit action show. Rewards are surfaced separately.
      dailyEarnedUsd: (position.suppliedValueUsd * market.supplyApy) / 365,
      apyPct: market.supplyApy * 100,
      principalAmount: position.principalAmount,
      interestEarned: position.interestEarned,
      availableToWithdraw: maxWithdrawable,
      walletBalance,
      status: position.status,
    }
  })

  return {
    investments,
    positions: investments,
    strategyBuckets: buildLendStrategyBuckets(Object.values(state.markets)),
    history: buildLendActivityHistory(walletId, history, state),
    rewardsSummary: {
      claimableUsd: claimableRewardsUsd,
      totalEarnedUsd: investments.reduce((sum, item) => sum + item.earnedUsd, 0) + closedRewardsUsd,
    },
  }
}

/**
 * Canonical Lend Net APY: supplied-weighted mean of each investment's apyPct, returned as a
 * percent. Weighting must stay supplied-based to match the server blend
 * (computePortfolioNetApyPct) and keep a $1 position from swaying the headline.
 */
export function lendNetApyPct(investments: ReadonlyArray<{ suppliedUsd: number; apyPct: number }>): number {
  const totalSuppliedUsd = investments.reduce((sum, item) => sum + item.suppliedUsd, 0)
  if (totalSuppliedUsd <= 0) return 0
  return investments.reduce((sum, item) => sum + item.apyPct * item.suppliedUsd, 0) / totalSuppliedUsd
}

export function buildLendWalletSnapshot(
  walletId: string,
  state: LendSystemState,
  transactionHistory: LendTransactionHistoryItem[],
): LendWalletReadSnapshot {
  const portfolio = buildPortfolioLendData(walletId, state, transactionHistory)
  const totalSuppliedUsd = portfolio.investments.reduce((sum, item) => sum + item.suppliedUsd, 0)
  const totalEarnedUsd =
    portfolio.rewardsSummary?.totalEarnedUsd ?? portfolio.investments.reduce((sum, item) => sum + item.earnedUsd, 0)
  const rewardsEarnedUsd =
    portfolio.rewardsSummary?.claimableUsd ??
    portfolio.investments.reduce((sum, item) => sum + (item.earnedUsd - (item.interestEarned ?? 0) * item.priceUsd), 0)
  // Supplied-weighted, matching the dashboard tab and the server blend. `currentApy` is a
  // fraction, hence /100.
  const averageApy = lendNetApyPct(portfolio.investments) / 100

  return {
    walletId,
    transactionHistory,
    metrics: {
      suppliedAmount: portfolio.investments.reduce((sum, item) => sum + item.balance, 0),
      suppliedValueUsd: totalSuppliedUsd,
      principalAmount: portfolio.investments.reduce((sum, item) => sum + (item.principalAmount ?? 0), 0),
      interestEarned: portfolio.investments.reduce((sum, item) => sum + (item.interestEarned ?? 0), 0),
      rewardsEarnedUsd,
      totalEarnedUsd,
      currentApy: averageApy,
    },
    yieldSnapshots: buildLendYieldSnapshots(state),
  }
}

function buildLendYieldSnapshots(state: LendSystemState): LendYieldSnapshot[] {
  return Object.values(state.markets).map((market) => ({
    marketId: market.marketId,
    asset: market.asset.symbol,
    supplyApy: market.supplyApy,
    rewardsApy: market.rewardsApy,
    totalApy: calculateTotalApy(market.supplyApy, market.rewardsApy),
    utilization: market.utilization,
    availableLiquidity: market.availableLiquidity,
    totalSupplied: market.totalSupplied,
    capturedAt: state.now,
  }))
}

export function buildLendActivityHistory(
  walletId: string,
  history: LendTransactionHistoryItem[],
  state?: LendSystemState,
): PortfolioLendTabData["history"] {
  return history
    .filter((item) => item.walletId === walletId)
    .map((item) => ({
      id: item.id,
      at: new Date(item.timestamp).toISOString(),
      product: "lend" as const,
      kind:
        item.kind === "deposit"
          ? ("supply" as const)
          : item.kind === "withdraw"
            ? ("withdraw" as const)
            : ("claim" as const),
      status: item.status === "success" ? ("confirmed" as const) : ("failed" as const),
      // The recorded USD when known: tokens × the price that happened to be loaded read the same
      // deposit as -$68.82 and then -$52.70.
      amountUsd:
        item.kind === "claim"
          ? item.amount
          : (item.amountUsd ?? item.amount * (state?.markets[item.marketId]?.assetPriceUsd ?? 0)),
      primaryLabel: item.asset,
      secondaryLabel:
        item.kind === "claim"
          ? `${item.amount.toFixed(2)} USD rewards`
          : formatActivityTokenAmount(item.amount, item.asset),
      txHash: item.hash,
      marketId: item.marketId,
    }))
}
