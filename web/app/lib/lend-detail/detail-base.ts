import { formatCompactUsd } from "@/app/lib/borrow-market-rows"
import type { QuickStat, RiskAssessment } from "@/app/lib/borrow-detail"
import { formatPct } from "@/app/lib/borrow-detail/allocation"
import { buildLendFaqs } from "@/app/lib/borrow-detail/content-model"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"
import { chainLabel } from "@/app/lib/borrow-system/market-hydration"
import type { LendMarket } from "@/app/lib/lend-system/model/types"
import type { LendMarketDetail, LendTokenVisual } from "./types"

// The empty shape of a Lend detail page, built from its services/convex row. Values without a
// source are "—" or empty; `convex-detail.ts` fills what services/convex serves.

const UNAVAILABLE = "—"

function getVisual(symbol: string): LendTokenVisual {
  return {
    symbol,
    shortLabel: symbol.slice(0, 2).toUpperCase(),
    bgClass: "bg-surface-inset",
    textClass: "text-foreground",
    iconUrl: getLocalAssetIcon(symbol),
  }
}

export type LendDetailReference = {
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
  borrowAprPct: number
}

function pct(value: number | undefined, digits = 2) {
  return value !== undefined && Number.isFinite(value) ? formatPct(value, digits) : UNAVAILABLE
}

/** Lend market page shape from its market and services/convex reference values. */
export function buildLendMarketDetail(market: LendMarket, ref: LendDetailReference): LendMarketDetail {
  const quickStats: QuickStat[] = [
    { id: "price", label: "Price", value: UNAVAILABLE },
    { id: "available", label: "Available Liquidity", value: formatCompactUsd(ref.availableUsd) },
    { id: "supplyApy", label: "Supply APY", value: pct(ref.supplyApyPct) },
    {
      id: "rewardsApy",
      label: "Rewards APY",
      value: market.rewardsApy > 0 ? formatPct(market.rewardsApy * 100, 2) : UNAVAILABLE,
    },
    { id: "borrowApy", label: "Borrow APY", value: pct(ref.borrowAprPct) },
    {
      id: "reserveFactor",
      label: "Reserve Factor",
      value: market.reserveFactor > 0 ? formatPct(market.reserveFactor * 100, 0) : UNAVAILABLE,
    },
  ]
  const isStable = market.category === "stable"
  return {
    id: market.marketId,
    hero: {
      visual: getVisual(market.asset.symbol),
      name: market.asset.name,
      symbol: market.asset.symbol,
      subtitle: `${market.asset.name} (${market.asset.symbol}) is a single-asset supply market on Avana.`,
      chain: chainLabel(market.chainId || undefined),
      category: isStable ? "stable" : "crypto",
      venue: "Avana Lend",
    },
    quickStats,
    utilizationPct: ref.utilizationPct,
    borrowAprPct: ref.borrowAprPct,
    protocolParameters: [],
    supplyBorrow: {
      supplied: { id: `${market.marketId}:sb:supplied`, label: "Supplied", points: [] },
      borrowed: { id: `${market.marketId}:sb:borrowed`, label: "Borrowed", points: [] },
      utilization: { id: `${market.marketId}:sb:utilization`, label: "Utilization", points: [] },
    },
    cashflow: { bars: [], rows: [], periodLabel: "" },
    risk: EMPTY_RISK_ASSESSMENT,
    about: { description: "", stats: [], history: [] },
    faqs: buildLendFaqs(market.asset.symbol, market.asset.name),
    transactions: [],
    row: market,
  }
}

/** Keep the risk card's Supply APY metric equal to the headline quick stat. */
export function alignRiskSupplyApyMetric(risk: RiskAssessment, quickStats: QuickStat[]): RiskAssessment {
  const headline = quickStats.find((stat) => stat.id === "supplyApy")?.value
  if (!headline || !risk.metrics.some((metric) => metric.id === "supplyApy" && metric.value !== headline)) {
    return risk
  }
  return {
    ...risk,
    metrics: risk.metrics.map((metric) => (metric.id === "supplyApy" ? { ...metric, value: headline } : metric)),
  }
}
