// IMPORTANT: this barrel must stay recharts-FREE. Many engine/lib modules (chart-feeds,
// read-model, detail types, portfolio mappers) import only the lightweight utils/types below,
// and they sit on the app-entry (`/` Express) critical path. Re-exporting the recharts chart
// components here dragged all of recharts (~384KB) onto that path because barrels defeat
// tree-shaking. Import the chart components DIRECTLY from their files instead:
//   HeroAreaChart   → "@/app/components/charts/hero-area-chart"
//   MarketHeroChart → "@/app/components/charts/market-hero-chart"
//   HeroChartSection→ "@/app/components/charts/hero-chart-section"
export {
  buildRangeData,
  CHART_RANGE_LABELS,
  getChartTickIndexes,
  resolveSeriesChange,
  resolveSeriesTone,
} from "./chart-data"
export { ChartRangeSelector } from "./chart-range-selector"
export { formatChartAxis, formatChartPointLabel, formatChartValue } from "./format"
export { HeroBalanceDisplay, resolveDeltaTone } from "./hero-balance-display"
export { CHART_RANGE_OPTIONS } from "./types"
export type { ChartFeed, ChartPoint, ChartRangeData, ChartRangeOption, ChartValueFormat } from "./types"
