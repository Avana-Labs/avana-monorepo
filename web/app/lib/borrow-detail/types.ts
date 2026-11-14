/**
 * Public types for the borrow / lend detail pages.
 *
 * These types model everything a detail page needs to render. The frontend
 * consumes these shapes via the public API in `./index.ts`; the mock layer
 * (`pool.mock.ts`, `asset.mock.ts`) is the only place that knows how the
 * numbers are produced today. When live data arrives the data seam swaps
 * implementations without changing the shapes — see `docs/borrow-detail-tests/HANDOFF.md`.
 *
 * ============================================================================
 * Convex mapping (future persistent layer)
 * ============================================================================
 * Every field below has an `@convex-source` JSDoc tag pointing at the table
 * (and usually the specific column) it should be hydrated from once
 * `convex/schema.ts` is wired up. High-level fan-out:
 *
 *   AssetDetail
 *     hero / heroMetric / quickStats    ← markets + marketDailyStats
 *     supplyBorrow / historicalUtilization ← marketDailyStats
 *     cashflowTrend / cashflow          ← borrowRevenueDaily
 *     engagement                        ← walletEvents
 *     allocation                        ← assetPoolAllocationDaily (+markets join)
 *     transactions                      ← walletEvents (raw feed)
 *     risk                              ← borrowRiskAssessments
 *
 *   PoolDetail
 *     hero / heroMetric / quickStats    ← markets + marketDailyStats
 *     keyMetrics / performance          ← marketDailyStats
 *     cashflow                          ← borrowRevenueDaily
 *     engagement                        ← walletEvents
 *     risk                              ← borrowRiskAssessments
 *
 * Query stubs for all of these live in:
 *   convex/engagement.ts, convex/cashflow.ts, convex/markets.ts,
 *   convex/allocation.ts  — each stub returns data shaped *exactly* like the
 *   corresponding view-model below, so the swap from mocks → live data is a
 *   one-line change in `./index.ts`.
 * ============================================================================
 */

import type { BorrowAssetVisual, BorrowPoolRow } from "@/app/lib/borrow-sim"
import type { SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import type { ChartFeed } from "@/app/components/charts"
import type { FaqContent } from "./content-model"
import type { ProtocolParameterRow } from "./protocol-parameters"

// -------------------------------------------------------------------------
// Primitive building blocks
// -------------------------------------------------------------------------

/**
 * A single (t, v) sample on a time-series chart.
 *
 * @convex-source Rows from `marketDailyStats.day` (UTC YYYY-MM-DD) or
 *   `walletEvents.at` bucketed to UTC day strings. Every numeric chart on
 *   both detail pages is fed by one of these two tables (see `convex/schema.ts`).
 */
export type Point = {
  /** ISO-8601 date (YYYY-MM-DD) or an ISO timestamp. */
  t: string
  v: number
}

/**
 * A named series of points (used by every chart primitive).
 *
 * @convex-source `id` mirrors `markets._id` + a metric key so the frontend
 *   can key React trees stably across fetches.
 */
export type Series = {
  id: string
  label: string
  points: Point[]
  /**
   * Optional aggregate value the series is summarized by (e.g. the number
   * displayed above the chart when this series is active).
   */
  aggregate?: number
  /** Optional unit used by formatters, e.g. "$" | "%" | "ETH". */
  unit?: string
}

export type ChangeDirection = "up" | "down" | "flat"

export type DeltaStat = {
  value: number
  direction: ChangeDirection
  /** Pre-formatted label e.g. "+2.4%" or "-$1.2M". */
  label: string
}

// -------------------------------------------------------------------------
// Risk
// -------------------------------------------------------------------------

/** Qualitative risk bucket for pools/assets — drives the gauge + pill. */
export type RiskLevel = "low" | "moderate" | "elevated" | "high"

/** Single-factor breakdown contributing to the overall Risk Premium. */
export type RiskBreakdownItem = {
  id: string
  /** Short factor title e.g. "Oracle", "Liquidity depth", "Volatility". */
  label: string
  /** Score in bps this factor contributes to the total risk premium. */
  bps: number
  /** Qualitative bucket for this single factor. */
  level: RiskLevel
  /** Plain-English explanation shown inside the accordion. */
  description: string
}

/** Single key/value metric shown in the risk card (e.g. "σ 30d", "$ depth"). */
export type RiskMetric = {
  id: string
  label: string
  value: string
  hint?: string
}

/**
 * Risk rating shown in the `RiskSection` on both detail pages.
 *
 * @convex-source Latest row in product-siloed `*RiskAssessments` for the given slug.
 *   Historical rows are retained for audit; the UI only reads the freshest.
 */
export type RiskAssessment = {
  /** Total risk premium in basis points (sum of breakdown items). */
  premiumBps: number
  /** Qualitative bucket derived from `premiumBps`. */
  level: RiskLevel
  /** Score 0..100 used to position the gauge needle. */
  score: number
  /** One-sentence summary shown next to the gauge. */
  headline: string
  /** A short paragraph explaining the rating. */
  summary: string
  /** Ordered list of contributing factors (rendered as accordion rows). */
  breakdown: RiskBreakdownItem[]
  /** Key quantitative inputs (depth, σ, dependencies, etc.). */
  metrics: RiskMetric[]
  /** Optional last-review date ISO string (when a committee last signed off). */
  lastReviewed?: string
}

// -------------------------------------------------------------------------
// Pool detail page
// -------------------------------------------------------------------------

export type TimeRangeId = "1D" | "1W" | "1M" | "3M" | "1Y" | "ALL"

/** Hero chart metric keys. `tvl` is the supplied/TVL series (Convex hero feed). */
export type ChartMetricId = "tvl" | "borrowed" | "utilization"

export type KeyMetricId =
  | "tvl"
  | "volume"
  | "fees"
  | "feesApr"
  | "rewards"
  | "utilization"
  | "borrowApr"
  | "incentives"
  | "depth2pct"
  | "volatility30d"
  | "impermanentLoss"
  | "oraclePremium"

export type PerfTab = "fees" | "pnl" | "composition" | "incentives"
export type PerfPeriod = "weekly" | "monthly" | "quarterly"

export type PerfTabDataset = {
  /** Aggregate headline for the active period (e.g. "$142,800"). */
  headline: string
  /** Secondary label, e.g. "vs last period +12%". */
  subLabel?: string
  series: Series
  /** Breakdown rows rendered under the chart. */
  breakdown: Array<{ label: string; value: string; delta?: DeltaStat }>
}

export type CashflowRow = {
  label: string
  reported: string
  yoy?: DeltaStat
  highlighted?: boolean
}

/**
 * Breakdown table + monthly bars shown under the main cashflow card.
 *
 * @convex-source `borrowRevenueDaily` rolled up to a 12-month window. `rows`
 *   are the TTM totals; `bars` are per-month series of the same columns.
 * @convex-query  `borrow.cashflow.getBreakdownForAsset({ slug })`
 * @convex-query  `borrow.cashflow.getBreakdownForPool({ slug })`
 */
export type CashflowCard = {
  bars: Series[]
  rows: CashflowRow[]
  /** Period the table is anchored to (displayed as a column header). */
  periodLabel: string
}

/**
 * Monthly revenue bar chart shown on the asset detail page — the gross
 * interest this asset generates (paid by borrowers).
 *
 * @convex-source `borrowRevenueDaily.interestFromBorrowersUsd`, grouped by
 *   UTC calendar month and zero-filled to 12 buckets.
 * @convex-query  `borrow.cashflow.getRevenueForAsset({ slug })`
 */
export type CashflowTrend = {
  /** Pre-formatted 12-month aggregate total. */
  totalLabel: string
  /** Period label displayed in the top-right pill (e.g. "Yearly"). */
  periodLabel: string
  /** 12 monthly points representing gross revenue. */
  series: Series
}

export type PoolDetailHero = {
  /** Token A/B visuals used for the big double-logo. */
  visuals: [BorrowAssetVisual, BorrowAssetVisual]
  /** Display name, e.g. "ETH / USDC". */
  name: string
  /** Short venue label, e.g. "Uniswap v3 · 0.3%". */
  venue: string
  /** Concise market-type label shown in the identity row, e.g. "Uniswap v3 Blue-Chip LPs". */
  marketLabel?: string
  /** Detailed description line shown under the name. */
  subtitle: string
  /** Fee tier label when applicable (e.g. "0.3%" or "Stable"). */
  feeTier?: string
  /** Chain / network tag (e.g. "Ethereum", "Arbitrum", "Base"). */
  chain: string
  /** Link to the source contract / external explorer. */
  explorerUrl?: string
  /** Official X profile when known. */
  xUrl?: string
}

export type QuickStat = {
  id: string
  label: string
  value: string
  delta?: DeltaStat
  tooltip?: string
}

export type AboutCard = {
  description: string
  stats: Array<{ label: string; value: string; href?: string }>
  history: Array<{ date: string; title: string; description?: string }>
  news?: Array<{ title: string; description?: string; source: string; time: string }>
  governanceParameters?: {
    parameters: Array<{
      id: string
      label: string
      value: string
      status?: string
      description?: string
      href?: string
    }>
    changelog: Array<{
      id: string
      parameter: string
      previous: string
      current: string
      date: string
      source: string
      executor: string
      /** Aave-style action group: "Risk Management" | "Domain Admin" | "Listing" | "Emergency". */
      category?: string
      href?: string
    }>
  }
}

export type PoolDetail = {
  id: string
  hero: PoolDetailHero
  /** Headline metric and chart (replaces the giant TVL number). */
  heroMetric: {
    metricId: ChartMetricId
    valueLabel: string
    delta: DeltaStat
    /** Time-series per metric keyed by metric id. */
    series: Record<ChartMetricId, Record<TimeRangeId, Series>>
  }
  quickStats: QuickStat[]
  protocolParameters: ProtocolParameterRow[]
  cashflow: CashflowCard
  risk: RiskAssessment
  about: AboutCard
  /** General FAQs (plain-text answers). @convex-query borrow.content.getContent */
  faqs: FaqContent[]
  transactions: TxHistoryRow[]
  /** Passthrough reference to the table row so sidebars can stay in sync. */
  row: BorrowPoolRow
  /**
   * Assets You Can Borrow — from product-siloed `borrowPoolBorrowables` when seeded.
   * @convex-query borrow.poolBorrowables.getPoolBorrowables
   */
  borrowableAssets?: import("./cross-market").BorrowableAssetRef[]
  /**
   * Liquidation Risk KPIs — from product-siloed `borrowLiquidationDaily` when seeded.
   * @convex-query borrow.liquidationRisk.getLiquidationRisk
   */
  liquidationRisk?: import("../detail-page/liquidation-risk").LiquidationRiskStat[]
  /** Convex-backed hero chart feed (TVL / total supplied). Set only by the
   * Convex detail builder; the hero falls back to the local feed when absent. */
  heroFeed?: ChartFeed
  /** Convex-backed borrowed series for the hero Borrowed tab. */
  heroBorrowedFeed?: ChartFeed
  /** Convex-backed utilization series for the hero Utilization tab. */
  heroUtilizationFeed?: ChartFeed
}

// -------------------------------------------------------------------------
// Asset detail page
// -------------------------------------------------------------------------

export type AssetChartMetricId = "price" | "supply" | "borrow" | "utilization" | "apy"

/**
 * One row in the asset's allocation breakdown table.
 *
 * @convex-source Latest row per `poolId` in `assetPoolAllocationDaily` joined
 *   to `markets` for `poolName` / `venueLabel`. `visuals` is hydrated by the
 *   frontend because icon assets are a client concern.
 * @convex-query  `allocation.getForAsset({ slug })`
 */
export type AllocationRow = {
  id: string
  /** Pool name, e.g. "USDC / USDT". */
  poolName: string
  /** Venue label, e.g. "Uniswap v3". */
  venueLabel: string
  visuals: [BorrowAssetVisual, BorrowAssetVisual]
  sharePct: number
  valueUsd: number
  utilizationPct: number
  borrowAprPct: number
  /**
   * Collateral factor % for this pool — from product-siloed `borrowRiskParameters`
   * when hydrated; AllocationBreakdownCard falls back to catalog if absent.
   */
  collateralFactorPct?: number
  /** Pool fee tier (e.g. "0.30%") — for the "Supported Collateral" sub-label. */
  feeTier?: string
  /** Pool TVL in USD — for the "Supported Collateral" sub-label. */
  tvlUsd?: number
}

/**
 * Row used by the detail-page activity tables.
 *
 * @convex-source Prefer sandbox `transactions` by `marketSlug`; fall back to
 *   seeded `walletEvents` when no live rows exist. `amountLabel` pre-formats
 *   `amountUsd` (sign based on `kind` is a UI concern).
 * @convex-query  `markets.getRecentTransactions({ scope, slug, limit })`
 */
export type TxHistoryRow = {
  id: string
  /** ISO timestamp. */
  at: string
  /** Short relative label shown in the transaction table. */
  timeLabel?: string
  kind: "supply" | "withdraw" | "borrow" | "repay" | "liquidation" | "rewards" | "cooldown"
  amountLabel: string
  tokenAmountLabel?: string
  tokenSymbol?: string
  tokenSymbolSecondary?: string
  token0AmountLabel?: string
  token1AmountLabel?: string
  counterpartyLabel?: string
  walletLabel?: string
  walletHref?: string
  txHashShort: string
  /** Live sandbox row vs seeded theater history. */
  source?: "sandbox" | "seed"
}

export type AssetDetailHero = {
  visual: BorrowAssetVisual
  name: string
  symbol: string
  subtitle: string
  chain: string
  category: "stable" | "crypto"
  contractLabel?: string
  contractAddress?: string
  websiteUrl?: string
  xUrl?: string
}

export type AssetDetail = {
  id: string
  hero: AssetDetailHero
  heroMetric: {
    metricId: AssetChartMetricId
    valueLabel: string
    delta: DeltaStat
    series: Record<AssetChartMetricId, Record<TimeRangeId, Series>>
  }
  quickStats: QuickStat[]
  protocolParameters: ProtocolParameterRow[]
  supplyBorrow: {
    supplied: Series
    borrowed: Series
    utilization: Series
  }
  interestGenerated: Record<PerfPeriod, PerfTabDataset>
  historicalUtilization: Series
  /** Monthly income / expense / savings bars shown after historical utilization. */
  cashflowTrend: CashflowTrend
  allocation: AllocationRow[]
  cashflow: CashflowCard
  risk: RiskAssessment
  about: AboutCard
  /** General FAQs (plain-text answers). @convex-query borrow.content.getContent */
  faqs: FaqContent[]
  transactions: TxHistoryRow[]
  /** Passthrough reference so sidebars can stay in sync. */
  row: SpokeBorrowableRecord
  /**
   * Interest rate model curve params — from product-siloed `borrowInterestRateModels`.
   * @convex-query borrow.interestRateModel.getInterestRateModel
   */
  interestRateModel?: {
    utilizationPct: number
    borrowAprPct: number
    optimalUtilizationPct: number
    slopeBelowOptimalPct: number
    slopeAboveOptimalPct: number
    baseBorrowRatePct: number
  }
  /** Convex-backed hero chart feed (Supplied). Set only by the Convex detail builder;
   * the hero falls back to the local feed when absent. */
  heroFeed?: ChartFeed
  /** Convex-backed Borrowed hero feed (Borrowed tab). Convex-only; PRNG fallback when absent. */
  heroBorrowedFeed?: ChartFeed
  /** Convex-backed Utilization hero feed (Utilization tab). Convex-only; PRNG fallback when absent. */
  heroUtilizationFeed?: ChartFeed
}

// -------------------------------------------------------------------------
// Convenience guards
// -------------------------------------------------------------------------

export const ALL_TIME_RANGES: TimeRangeId[] = ["1D", "1W", "1M", "3M", "1Y", "ALL"]
export const ALL_CHART_METRICS: ChartMetricId[] = ["tvl", "borrowed", "utilization"]
export const ALL_KEY_METRICS: KeyMetricId[] = [
  "tvl",
  "volume",
  "fees",
  "feesApr",
  "rewards",
  "utilization",
  "borrowApr",
  "incentives",
  "depth2pct",
  "volatility30d",
  "impermanentLoss",
  "oraclePremium",
]
export const ALL_PERF_TABS: PerfTab[] = ["fees", "pnl", "composition", "incentives"]
export const ALL_PERF_PERIODS: PerfPeriod[] = ["weekly", "monthly", "quarterly"]
export const ALL_ASSET_CHART_METRICS: AssetChartMetricId[] = ["price", "supply", "borrow", "utilization", "apy"]
