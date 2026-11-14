/**
 * Curated token price curves — smooth trend + natural micro-moves (Tokens-style).
 */

import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { createPrng, hashString } from "./prng"
import type { Point, Series, TimeRangeId } from "./types"

const ETH_DAILY: Point[] = [
  { t: "2026-05-28", v: 2024.8 },
  { t: "2026-05-29", v: 1980.2 },
  { t: "2026-05-30", v: 2000.8 },
  { t: "2026-05-31", v: 2024.9 },
  { t: "2026-06-01", v: 1990.4 },
  { t: "2026-06-02", v: 1972.1 },
  { t: "2026-06-03", v: 1791.81 },
]

const CURATED_DAILY: Record<string, Point[]> = {
  eth: ETH_DAILY,
}

export function buildCuratedPriceFamily(assetId: string, label: string): Record<TimeRangeId, Series> | null {
  const daily = CURATED_DAILY[assetId]
  if (!daily) return null

  const ranges: TimeRangeId[] = ["1D", "1W", "1M", "3M", "1Y", "ALL"]
  const out = {} as Record<TimeRangeId, Series>

  for (const range of ranges) {
    const points = buildWalkSeries(daily, range, assetId)
    out[range] = {
      id: `${assetId}:price:${range}`,
      label,
      points,
      aggregate: points.reduce((sum, p) => sum + p.v, 0) / points.length,
    }
  }

  return out
}

/**
 * Re-anchor a price series family to the canonical basis: rescale every range so its TERMINAL
 * (latest) point equals `canonicalPriceUsd(symbol)` — the exact number the detail-page "Price"
 * tile shows (it reads the same baseline via injectBaselinePrice). The whole curve is scaled by a
 * single factor per range, so the SHAPE (trend / volatility / dates / point count) is preserved and
 * only the level moves; the chart therefore ends where the tile sits. Returns the family unchanged
 * when the symbol is not in the canonical snapshot.
 */
export function anchorPriceFamilyToCanonical(
  family: Record<TimeRangeId, Series>,
  symbol: string,
): Record<TimeRangeId, Series> {
  const canonical = canonicalPriceUsd(symbol)
  if (canonical === undefined) return family

  const out = {} as Record<TimeRangeId, Series>
  for (const range of Object.keys(family) as TimeRangeId[]) {
    const series = family[range]
    const lastIdx = series.points.length - 1
    const terminal = lastIdx >= 0 ? series.points[lastIdx].v : 0
    const scale = terminal > 0 ? canonical / terminal : 1
    const points = series.points.map((p, i) =>
      // Pin the terminal to the exact canonical value; scale the rest to keep the shape.
      i === lastIdx ? { ...p, v: canonical } : { ...p, v: Math.round(p.v * scale * 100) / 100 },
    )
    out[range] = {
      ...series,
      points,
      aggregate: points.reduce((sum, p) => sum + p.v, 0) / points.length,
    }
  }
  return out
}

/** Mean-reverting random walk hugging the daily anchor curve. */
function buildWalkSeries(daily: Point[], range: TimeRangeId, assetId: string): Point[] {
  const endMs = parseTs(daily[daily.length - 1].t).getTime() + 20 * 60 * 60 * 1000
  const intervalMs =
    range === "1D"
      ? 10 * 60 * 1000
      : range === "1W"
        ? 30 * 60 * 1000
        : range === "1M"
          ? 2 * 60 * 60 * 1000
          : 6 * 60 * 60 * 1000

  const spanMs =
    range === "1D"
      ? 24 * 60 * 60 * 1000
      : range === "1W"
        ? 7 * 24 * 60 * 60 * 1000
        : range === "1M"
          ? 30 * 24 * 60 * 60 * 1000
          : range === "3M"
            ? 90 * 24 * 60 * 60 * 1000
            : range === "1Y"
              ? 365 * 24 * 60 * 60 * 1000
              : 720 * 24 * 60 * 60 * 1000

  const startMs = endMs - spanMs
  const rand = createPrng(hashString(`${assetId}:${range}:walk`))
  const stepNoise = range === "1W" ? 0.85 : range === "1D" ? 1.2 : 4.5

  let price = interpolateDaily(daily, startMs)
  const points: Point[] = []

  for (let ms = startMs; ms <= endMs; ms += intervalMs) {
    const anchor = interpolateDaily(daily, ms)
    const pull = (anchor - price) * 0.12
    const noise = (rand() - 0.5) * stepNoise
    price = price + pull + noise
    if (ms >= endMs - intervalMs) price = daily[daily.length - 1].v
    points.push({ t: new Date(ms).toISOString(), v: Math.round(price * 100) / 100 })
  }

  return points
}

function interpolateDaily(daily: Point[], ms: number): number {
  const days = daily.map((p) => ({ ms: parseTs(p.t).getTime(), v: p.v }))
  if (ms <= days[0].ms) return days[0].v
  if (ms >= days[days.length - 1].ms) return days[days.length - 1].v
  for (let i = 0; i < days.length - 1; i++) {
    const a = days[i]
    const b = days[i + 1]
    if (ms >= a.ms && ms <= b.ms) {
      const ratio = (ms - a.ms) / (b.ms - a.ms)
      return a.v + (b.v - a.v) * ratio
    }
  }
  return days[days.length - 1].v
}

function parseTs(raw: string) {
  if (raw.includes("T")) return new Date(raw)
  return new Date(`${raw.slice(0, 10)}T12:00:00Z`)
}
