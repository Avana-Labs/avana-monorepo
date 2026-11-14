/**
 * Every hero chart gets the same `ChartFeed` contract that `MarketHeroChart` renders: built from
 * a services/convex series when one exists, otherwise the empty feed (no points, "—").
 */

import {
  formatChartValue,
  type ChartFeed,
  type ChartPoint,
  type ChartRangeData,
  type ChartRangeOption,
  type ChartValueFormat,
} from "@/app/components/charts"

function todayLabel(): string {
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" }).format(new Date())
}

function deltaTone(pct: number): "positive" | "negative" {
  return pct < 0 ? "negative" : "positive"
}

function formatConvexPointLabel(value: string, range: ChartRangeOption): string {
  const date = new Date(`${value}T00:00:00Z`)
  if (Number.isNaN(date.getTime())) return value
  if (range === "1Y" || range === "All") {
    // Full year ("Sep 2026"), never "Sep 26" — a 2-digit year reads as a day-of-month
    // next to the shorter ranges' "Sep 16" labels.
    return new Intl.DateTimeFormat("en-US", { month: "short", year: "numeric", timeZone: "UTC" }).format(date)
  }
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" }).format(date)
}

// ---------------------------------------------------------------------------
// Empty feed (no series yet)
// ---------------------------------------------------------------------------

const EMPTY_RANGE_DATA: ChartRangeData = { "1D": [], "1W": [], "1M": [], "3M": [], "1Y": [], All: [] }

/** The feed a hero shows while its series has no points: no line and an unavailable headline. */
export function emptyHeroFeed(valueFormat: ChartValueFormat = "usdCompact"): ChartFeed {
  return {
    headlineValue: "—",
    headlineDelta: "",
    deltaTone: "positive",
    rangeData: EMPTY_RANGE_DATA,
    valueFormat,
  }
}

/** Pool hero without a series. */
export function getPoolHeroFeed(_poolId: string): ChartFeed {
  return emptyHeroFeed("usdCompact")
}

/** Lend hero without a series. */
export function getLendMarketHeroFeed(_marketId: string): ChartFeed {
  return emptyHeroFeed("usdCompact")
}

/** Borrow asset hero without a series. */
export function getAssetHeroFeed(_assetId: string): ChartFeed {
  return emptyHeroFeed("price")
}

// ---------------------------------------------------------------------------
// Convex-backed hero feed (daily series → ChartFeed)
// ---------------------------------------------------------------------------

/**
 * Build a hero `ChartFeed` from a services/convex daily series (`{t: "YYYY-MM-DD", v}`). `1D` shows
 * the last two daily points (no intraday series is served). Null when there's no data, so callers
 * show the empty feed.
 */
export function buildHeroFeedFromConvexSeries(
  points: ReadonlyArray<{ t: string; v: number }>,
  valueFormat: ChartValueFormat,
): ChartFeed | null {
  if (!points || points.length === 0) return null
  const sorted = [...points].sort((a, b) => a.t.localeCompare(b.t))
  const toChartPoints = (slice: ReadonlyArray<{ t: string; v: number }>, range: ChartRangeOption): ChartPoint[] =>
    slice.map((p) => ({
      time: Date.parse(`${p.t}T00:00:00Z`),
      value: p.v,
      label: formatConvexPointLabel(p.t, range),
    }))
  const lastN = (n: number) => sorted.slice(Math.max(0, sorted.length - n))
  const last = sorted[sorted.length - 1]?.v ?? 0
  const first = sorted[0]?.v ?? last
  const rangeData: ChartRangeData = {
    "1D": toChartPoints(lastN(2), "1D"),
    "1W": toChartPoints(lastN(7), "1W"),
    "1M": toChartPoints(lastN(30), "1M"),
    "3M": toChartPoints(lastN(90), "3M"),
    "1Y": toChartPoints(lastN(365), "1Y"),
    All: toChartPoints(sorted, "All"),
  }
  const pct = first ? ((last - first) / first) * 100 : 0
  return {
    headlineValue: formatChartValue(valueFormat, last),
    headlineDelta: `${Math.abs(pct).toFixed(2)}%`,
    deltaTone: deltaTone(pct),
    headlineMeta: todayLabel(),
    rangeData,
    valueFormat,
  }
}
