import { formatCompactUsd, type BorrowPoolRow } from "@/app/lib/borrow-market-rows"
import type { BorrowAssetRecord, BorrowSystemState } from "@/app/lib/borrow-system/model"
import { formatFixed } from "@/app/lib/borrow-system/model"
import { EMPTY_RISK_ASSESSMENT } from "@/app/lib/detail-page/empty-risk-assessment"
import { buildAssetFaqs, buildPoolFaqs } from "./content-model"
import { formatPct } from "./allocation"
import type {
  AboutCard,
  AssetChartMetricId,
  AssetDetail,
  CashflowCard,
  CashflowTrend,
  ChartMetricId,
  DeltaStat,
  PerfPeriod,
  PerfTabDataset,
  PoolDetail,
  QuickStat,
  Series,
  SpokeBorrowableRecord,
  TimeRangeId,
} from "./types"
import { ALL_ASSET_CHART_METRICS, ALL_CHART_METRICS, ALL_PERF_PERIODS, ALL_TIME_RANGES } from "./types"

// The empty shape of a Borrow detail page, built from the market's services/convex row. Every
// section keeps its place in the layout; values without a source are "—" or empty series, and
// `convex-detail.ts` fills what services/convex serves.

const UNAVAILABLE = "—"
const FLAT: DeltaStat = { value: 0, direction: "flat", label: "" }

const EMPTY_CASHFLOW_CARD: CashflowCard = { bars: [], rows: [], periodLabel: "" }
const EMPTY_CASHFLOW_TREND: CashflowTrend = {
  totalLabel: "",
  periodLabel: "",
  series: { id: "cashflow-trend", label: "", points: [] },
}

function emptySeries(id: string, label: string): Series {
  return { id, label, points: [] }
}

function emptyFamily(id: string, label: string): Record<TimeRangeId, Series> {
  return Object.fromEntries(ALL_TIME_RANGES.map((range) => [range, emptySeries(`${id}:${range}`, label)])) as Record<
    TimeRangeId,
    Series
  >
}

function pctOrUnavailable(value: number | undefined, digits = 2) {
  return value !== undefined && Number.isFinite(value) && value > 0 ? formatPct(value, digits) : UNAVAILABLE
}

function emptyAbout(description: string): AboutCard {
  return { description, stats: [], history: [] }
}

const POOL_METRIC_LABELS: Record<ChartMetricId, string> = {
  tvl: "Supplied",
  borrowed: "Borrowed",
  utilization: "Utilization",
}

/** Pool (collateral market) page shape from its list row. */
export function buildPoolDetail(row: BorrowPoolRow): PoolDetail {
  const series = Object.fromEntries(
    ALL_CHART_METRICS.map((metric) => [metric, emptyFamily(`${row.id}:${metric}`, POOL_METRIC_LABELS[metric])]),
  ) as PoolDetail["heroMetric"]["series"]
  const quickStats: QuickStat[] = [
    { id: "price", label: "Price", value: UNAVAILABLE },
    { id: "available", label: "Available Liquidity", value: formatCompactUsd(row.availableUsd) },
    // The LP's trading-fee APR needs pool-wide in-range liquidity, which no source serves yet.
    { id: "supplyApy", label: "LP APR", value: pctOrUnavailable(row.aprMin) },
    { id: "rewardsApy", label: "Rewards APY", value: UNAVAILABLE },
    { id: "borrowApy", label: "Borrow APR", value: UNAVAILABLE },
    { id: "reserveFactor", label: "Reserve Factor", value: UNAVAILABLE },
  ]
  return {
    id: row.id,
    hero: {
      visuals: row.visuals,
      name: row.name,
      venue: row.venue,
      marketLabel: row.spokeLabel,
      subtitle: row.venue ? `${row.name} on ${row.venue}` : row.name,
      feeTier: row.feeTier || undefined,
      chain: row.chain ?? UNAVAILABLE,
    },
    heroMetric: { metricId: "tvl", valueLabel: formatCompactUsd(row.tvlUsd), delta: FLAT, series },
    quickStats,
    protocolParameters: [],
    cashflow: EMPTY_CASHFLOW_CARD,
    risk: EMPTY_RISK_ASSESSMENT,
    about: emptyAbout(""),
    faqs: buildPoolFaqs(row.name),
    transactions: [],
    row,
  }
}

const ASSET_METRIC_LABELS: Record<AssetChartMetricId, string> = {
  price: "Price",
  supply: "Total Supplied",
  borrow: "Total Borrowed",
  utilization: "Utilization",
  apy: "Borrow APY",
}

function emptyInterestGenerated(id: string): Record<PerfPeriod, PerfTabDataset> {
  return Object.fromEntries(
    ALL_PERF_PERIODS.map((period) => [
      period,
      { headline: UNAVAILABLE, series: emptySeries(`${id}:int:${period}`, "Interest"), breakdown: [] },
    ]),
  ) as unknown as Record<PerfPeriod, PerfTabDataset>
}

/** Borrow asset (CDP Spoke debt reserve) page shape from its record. */
export function buildAssetDetail(asset: SpokeBorrowableRecord, chain?: string): AssetDetail {
  const series = Object.fromEntries(
    ALL_ASSET_CHART_METRICS.map((metric) => [
      metric,
      emptyFamily(`${asset.id}:${metric}`, ASSET_METRIC_LABELS[metric]),
    ]),
  ) as AssetDetail["heroMetric"]["series"]
  const quickStats: QuickStat[] = [
    { id: "price", label: "Price", value: UNAVAILABLE },
    { id: "available", label: "Available Liquidity", value: formatCompactUsd(asset.availableUsd) },
    { id: "supplyApy", label: "Supply APY", value: UNAVAILABLE },
    { id: "rewardsApy", label: "Rewards APY", value: UNAVAILABLE },
    { id: "borrowApy", label: "Borrow APR", value: pctOrUnavailable(asset.borrowApr) },
    { id: "reserveFactor", label: "Reserve Factor", value: UNAVAILABLE },
  ]
  return {
    id: asset.id,
    hero: {
      visual: asset.visual,
      name: asset.name,
      symbol: asset.symbol,
      subtitle: asset.subtitle ? `${asset.name} — ${asset.subtitle}.` : asset.name,
      chain: chain ?? UNAVAILABLE,
      category: asset.category === "stable" ? "stable" : "crypto",
    },
    heroMetric: { metricId: "price", valueLabel: UNAVAILABLE, delta: FLAT, series },
    quickStats,
    protocolParameters: [],
    supplyBorrow: {
      supplied: emptySeries(`${asset.id}:sb:supplied`, "Supplied"),
      borrowed: emptySeries(`${asset.id}:sb:borrowed`, "Borrowed"),
      utilization: emptySeries(`${asset.id}:sb:utilization`, "Utilization"),
    },
    interestGenerated: emptyInterestGenerated(asset.id),
    historicalUtilization: emptySeries(`${asset.id}:historical-utilization`, "Utilization"),
    cashflowTrend: EMPTY_CASHFLOW_TREND,
    allocation: [],
    cashflow: EMPTY_CASHFLOW_CARD,
    risk: EMPTY_RISK_ASSESSMENT,
    about: emptyAbout(""),
    faqs: buildAssetFaqs(asset.symbol, asset.name),
    transactions: [],
    row: asset,
  }
}

function fixedToNumber(value: bigint, decimals: number) {
  return Number.parseFloat(formatFixed(value, decimals))
}

/** The asset page record of a debt reserve in a Borrow state. */
export function spokeBorrowableFromRecord(asset: BorrowAssetRecord): SpokeBorrowableRecord {
  const available = fixedToNumber(asset.snapshot.availableLiquidityUsd6, 6)
  const borrowed = fixedToNumber(asset.snapshot.totalBorrowedUsd6, 6)
  const total = available + borrowed
  return {
    id: asset.id,
    symbol: asset.symbol,
    name: asset.display.name,
    subtitle: asset.display.subtitle,
    borrowApr: fixedToNumber(asset.borrowConfig.baseBorrowAprWad, 18) * 100,
    totalBorrowedUsd: borrowed,
    utilization: total > 0 ? (borrowed / total) * 100 : 0,
    availableUsd: available,
    walletBalanceLabel: UNAVAILABLE,
    hasWalletBalance: false,
    visual: {
      symbol: asset.display.visual.symbol,
      shortLabel: asset.display.visual.shortLabel,
      iconUrl: asset.display.visual.iconUrl ?? undefined,
      bgClass: asset.display.visual.bgClassName,
      textClass: asset.display.visual.textClassName,
    },
    trendUp: true,
    category: asset.display.category,
    baseAssetId: asset.baseAssetId,
    spokeId: asset.spokeId,
    spokeSlug: asset.spokeId,
    spokeLabel: asset.contextLabel || asset.spokeId,
    slug: asset.slug,
    contextLabel: asset.contextLabel,
    marketIds: asset.marketIds,
  }
}

/** Every debt reserve of a Borrow state as asset page records. */
export function listSpokeBorrowables(state: BorrowSystemState): SpokeBorrowableRecord[] {
  return Object.values(state.assets).map(spokeBorrowableFromRecord)
}
