/**
 * Public types and helpers of the borrow / lend detail pages. UI imports from this module only;
 * the server builders that fill a page from services/convex live in `./convex-detail.ts`.
 */

export type { PoolDetail, AssetDetail } from "./types"
export type {
  AllocationRow,
  AboutCard,
  CashflowCard,
  CashflowTrend,
  ChartMetricId,
  KeyMetricId,
  PerfTab,
  PerfPeriod,
  PerfTabDataset,
  PoolDetailHero,
  AssetDetailHero,
  QuickStat,
  DeltaStat,
  RiskAssessment,
  RiskBreakdownItem,
  RiskLevel,
  RiskMetric,
  Series,
  Point,
  TimeRangeId,
  TxHistoryRow,
  AssetChartMetricId,
  SpokeBorrowableRecord,
} from "./types"
export {
  ALL_TIME_RANGES,
  ALL_CHART_METRICS,
  ALL_KEY_METRICS,
  ALL_PERF_TABS,
  ALL_PERF_PERIODS,
  ALL_ASSET_CHART_METRICS,
} from "./types"
export { formatBpsAsPct, formatPct, riskLevelFromBps, riskLevelLabel, riskScoreFromBps } from "./allocation"
export {
  borrowAssetDetailPath,
  borrowMarketDetailPath,
  normalizeBorrowAssetRouteId,
  normalizeBorrowMarketRouteId,
} from "@/app/lib/borrow-routes"
