export const CHART_RANGE_OPTIONS = ["1D", "1W", "1M", "3M", "1Y", "All"] as const

export type ChartRangeOption = (typeof CHART_RANGE_OPTIONS)[number]

export type ChartPoint = {
  time: number
  value: number
  label: string
}

export type ChartRangeData = Record<ChartRangeOption, ChartPoint[]>

/** How raw chart values are rendered in the headline, tooltip, and Y-axis. */
export type ChartValueFormat = "usd" | "usdCompact" | "price" | "percent" | "ratio"

/**
 * A complete, render-ready payload for any hero chart (portfolio, pool, asset).
 * This is the single contract the data layer (`app/lib/chart-feeds`) produces
 * and the universal chart UI consumes. Keep it free of functions so it can be
 * returned verbatim from an API.
 */
export type ChartFeed = {
  /** Pre-formatted headline value, e.g. "$883.74" or "$312.4M". */
  headlineValue: string
  /** Pre-formatted delta, e.g. "$6.89 (0.78%) today" or "2.10%". */
  headlineDelta: string
  deltaTone: "positive" | "negative"
  /** Optional muted meta shown after the delta (e.g. a date). */
  headlineMeta?: string
  /** Chart samples keyed by range. */
  rangeData: ChartRangeData
  /** Controls value formatting in headline-on-hover, tooltip, and Y-axis. */
  valueFormat: ChartValueFormat
}
