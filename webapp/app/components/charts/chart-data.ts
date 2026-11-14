import type { ChartPoint, ChartRangeData, ChartRangeOption } from "./types"
import { CHART_RANGE_OPTIONS } from "./types"

const RANGE_LENGTH: Record<ChartRangeOption, number> = {
  "1D": 63,
  "1W": 63,
  "1M": 63,
  "3M": 63,
  "1Y": 63,
  All: 63,
}

export const CHART_RANGE_LABELS: Record<ChartRangeOption, string[]> = {
  "1D": ["11:00 AM", "2:00 PM", "5:00 PM", "8:00 PM", "11:00 PM", "2:00 AM", "5:00 AM", "8:00 AM"],
  "1W": ["Mon", "Tue", "Wed", "Thu", "Fri"],
  "1M": ["Week 1", "Week 2", "Week 3", "Week 4", "Now"],
  "3M": ["Month 1", "Month 2", "Month 3", "Now"],
  "1Y": ["Jan", "Apr", "Jul", "Oct", "Now"],
  All: ["2022", "2023", "2024", "2025", "Now"],
}

const RANGE_SEED: Record<ChartRangeOption, number> = {
  "1D": 0,
  "1W": 73,
  "1M": 131,
  "3M": 163,
  "1Y": 197,
  All: 251,
}

function seededRandom(seed: number): () => number {
  let state = seed % 2147483647
  if (state <= 0) {
    state += 2147483646
  }
  return () => {
    state = (state * 16807) % 2147483647
    return (state - 1) / 2147483646
  }
}

/**
 * Mean-reverting random walk that trends toward `base * (1 + drift)`.
 * A positive `drift` ends higher than it started (green), negative ends lower
 * (red). The noise keeps the line jagged like real market data.
 */
function generateSeries(base: number, variance: number, count: number, seed: number, drift: number): number[] {
  const random = seededRandom(seed)
  const points: number[] = []
  let value = base
  let velocity = 0
  for (let i = 0; i < count; i++) {
    const progress = count > 1 ? i / (count - 1) : 0
    const target = base + drift * base * progress
    const meanReversion = (target - value) * 0.08
    velocity = velocity * 0.8 + meanReversion + (random() - 0.5) * variance * 0.5
    value += velocity
    points.push(Math.round(value * 100) / 100)
  }
  return points
}

function buildChartPoints(values: number[], labels: string[]): ChartPoint[] {
  const tickIndexes = labels.map((_, index) => Math.round((index / (labels.length - 1)) * (values.length - 1)))

  return values.map((value, index) => {
    const labelIndex = tickIndexes.findIndex((tickIndex, tickPosition) => {
      const nextTick = tickIndexes[tickPosition + 1] ?? values.length
      return index >= tickIndex && index < nextTick
    })

    return {
      time: index,
      value,
      label: labels[labelIndex] ?? labels[labels.length - 1],
    }
  })
}

/**
 * Build demo range data for hero charts. Pass real series per range on live pages.
 * Each range gets a deterministic up/down bias so some windows render green and
 * others red — mirroring how a real market dips on some timeframes.
 */
export function buildRangeData(base: number, variance: number): ChartRangeData {
  return CHART_RANGE_OPTIONS.reduce((accumulator, range) => {
    const rangeVariance = range === "All" || range === "1Y" ? variance * 1.6 : variance
    const seed = Math.round(base * 7 + variance * 13) + RANGE_SEED[range] + 1
    const direction = seed % 2 === 0 ? 1 : -1
    const magnitude = 0.02 + (seed % 5) * 0.009 // ~2%..~5.6% net move over the window
    const drift = direction * magnitude
    const values = generateSeries(base, rangeVariance, RANGE_LENGTH[range], seed, drift)
    accumulator[range] = buildChartPoints(values, CHART_RANGE_LABELS[range])
    return accumulator
  }, {} as ChartRangeData)
}

export function getChartTickIndexes(activeRange: ChartRangeOption, pointCount: number): number[] {
  const labels = CHART_RANGE_LABELS[activeRange]
  return labels.map((_, index) => Math.round((index / (labels.length - 1)) * (pointCount - 1)))
}

/** Trend tone for a series: green when it ends at/above its start, red otherwise. */
export function resolveSeriesTone(points: ChartPoint[]): "positive" | "negative" {
  if (points.length < 2) return "positive"
  return points[points.length - 1].value >= points[0].value ? "positive" : "negative"
}

/** First→last change for a series, as absolute value delta + percent. */
export function resolveSeriesChange(points: ChartPoint[]): { changeAbs: number; pct: number } {
  if (points.length < 2) return { changeAbs: 0, pct: 0 }
  const first = points[0].value
  const last = points[points.length - 1].value
  const changeAbs = Math.abs(last - first)
  const pct = first ? ((last - first) / first) * 100 : 0
  return { changeAbs, pct }
}

/** Distinct sample points in a series (by time+value), ignoring repeated stamps. */
function distinctPointCount(points: ChartPoint[]): number {
  const seen = new Set<string>()
  for (const point of points) seen.add(`${point.time}:${point.value}`)
  return seen.size
}

/**
 * The range tabs worth showing for a feed. A short range is hidden when it can't
 * carry meaningful data — fewer than 3 distinct points AND a longer range has
 * strictly more. This drops the misleading duplicate 2-point 1H/1D lines on
 * daily-granularity feeds while leaving richer feeds (all ranges populated)
 * untouched. Always keeps at least one range so the selector never disappears.
 */
export function resolveAvailableRanges(rangeData: ChartRangeData): ChartRangeOption[] {
  const counts = new Map<ChartRangeOption, number>()
  let richest = 0
  for (const range of CHART_RANGE_OPTIONS) {
    const count = distinctPointCount(rangeData[range] ?? [])
    counts.set(range, count)
    if (count > richest) richest = count
  }

  const available = CHART_RANGE_OPTIONS.filter((range) => {
    const count = counts.get(range) ?? 0
    if (count < 2) return false
    return count >= 3 || count >= richest
  })

  if (available.length > 0) return available
  // Degenerate feed (every range sparse): fall back to the range with the most points.
  const best = CHART_RANGE_OPTIONS.reduce((a, b) => ((counts.get(b) ?? 0) > (counts.get(a) ?? 0) ? b : a))
  return [best]
}
