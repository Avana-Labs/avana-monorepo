/**
 * Every hero chart reads from a `get*HeroFeed` here and gets the same `ChartFeed` contract
 * that `MarketHeroChart` renders. Data is seeded deterministic mock, so swapping in a real
 * fetch that maps into `ChartFeed` needs no UI change.
 */

import {
  buildRangeData,
  formatChartValue,
  type ChartFeed,
  type ChartPoint,
  type ChartRangeData,
  type ChartRangeOption,
  type ChartValueFormat,
} from "@/app/components/charts"

function hashString(input: string): number {
  let hash = 2166136261
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return Math.abs(hash)
}

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
// Portfolio
// ---------------------------------------------------------------------------

type PortfolioFeedInput = {
  /** Pre-formatted balance, e.g. "$883.74". */
  balance: string
  /** Pre-formatted delta, e.g. "$6.89 (0.78%) today". */
  delta: string
  chartBase: number
  chartVariance: number
}

/** @swap-to-api Replace with `GET /dashboard/{wallet}/chart?network=…`. */
export function getPortfolioHeroFeed(input: PortfolioFeedInput): ChartFeed {
  return {
    headlineValue: input.balance,
    headlineDelta: input.delta,
    deltaTone: input.delta.includes("-") ? "negative" : "positive",
    rangeData: buildRangeData(input.chartBase, input.chartVariance),
    valueFormat: "usd",
  }
}

// ---------------------------------------------------------------------------
// Borrow — pool (TVL)
// ---------------------------------------------------------------------------

/** @swap-to-api Replace with `GET /pools/{poolId}/chart`. */
export function getPoolHeroFeed(poolId: string): ChartFeed {
  const seed = hashString(poolId)
  // Base TVL between ~$40M and ~$760M, deterministic per pool.
  const base = 40_000_000 + (seed % 720) * 1_000_000
  const variance = base * 0.05
  const pct = (seed % 900) / 100 - 4 // ~ -4%..+5%
  const format: ChartValueFormat = "usdCompact"

  return {
    headlineValue: formatChartValue(format, base),
    headlineDelta: `${Math.abs(pct).toFixed(2)}%`,
    deltaTone: deltaTone(pct),
    headlineMeta: todayLabel(),
    rangeData: buildRangeData(base, variance),
    valueFormat: format,
  }
}

// ---------------------------------------------------------------------------
// Lend — market (total supplied)
// ---------------------------------------------------------------------------

/** @swap-to-api Local fallback for the lend hero; Convex supplies `buildHeroFeedFromConvexSeries`. */
export function getLendMarketHeroFeed(marketId: string): ChartFeed {
  const seed = hashString(`lend:${marketId}`)
  // Base supplied between ~$3M and ~$120M, deterministic per market.
  const base = 3_000_000 + (seed % 780) * 150_000
  const variance = base * 0.05
  const pct = (seed % 800) / 100 - 3.5 // ~ -3.5%..+4.5%

  return {
    headlineValue: formatChartValue("usdCompact", base),
    headlineDelta: `${Math.abs(pct).toFixed(2)}%`,
    deltaTone: deltaTone(pct),
    headlineMeta: todayLabel(),
    rangeData: buildRangeData(base, variance),
    valueFormat: "usdCompact",
  }
}

// ---------------------------------------------------------------------------
// Convex-backed hero feed (daily series → ChartFeed)
// ---------------------------------------------------------------------------

/**
 * Build a hero `ChartFeed` from a Convex daily series (`{t: "YYYY-MM-DD", v}`). Daily
 * granularity can't carry a real intraday window, so `1D` is SYNTHESIZED around the latest
 * value while every other range slices real history. Null when there's no data, so callers can
 * fall back to the mock feed.
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
  // Synthetic intraday 1D anchored on the latest value so the default range is
  // a rich line rather than a two-point stub from daily samples.
  const intradayBase = last || first || 1
  const rangeData: ChartRangeData = {
    "1D": buildRangeData(intradayBase, Math.max(1, Math.abs(intradayBase) * 0.02))["1D"],
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

// ---------------------------------------------------------------------------
// Borrow — asset (price)
// ---------------------------------------------------------------------------

/** @swap-to-api Replace with `GET /assets/{assetId}/chart`. */
export function getAssetHeroFeed(assetId: string): ChartFeed {
  const seed = hashString(assetId)
  // Spread bases so different assets look distinct (stables ~$1, blue chips higher).
  const tier = seed % 4
  const base =
    tier === 0
      ? 1 + (seed % 50) / 1000
      : tier === 1
        ? 20 + (seed % 400)
        : tier === 2
          ? 1500 + (seed % 1200)
          : 60_000 + (seed % 9000)
  const variance = base * 0.045
  const pct = (seed % 700) / 100 - 3
  const format: ChartValueFormat = "price"

  return {
    headlineValue: formatChartValue(format, base),
    headlineDelta: `${Math.abs(pct).toFixed(2)}%`,
    deltaTone: deltaTone(pct),
    headlineMeta: todayLabel(),
    rangeData: buildRangeData(base, variance),
    valueFormat: format,
  }
}
