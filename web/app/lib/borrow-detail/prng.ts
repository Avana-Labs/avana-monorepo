/**
 * Deterministic PRNG helpers for the mock data layer: same id in, same chart out.
 * mulberry32 seeded from a string hash, so charts never flake between runs.
 */

import { SANDBOX_NOW } from "@/app/lib/deterministic"
import type { Point, Series, TimeRangeId } from "./types"

/** FNV-1a string → 32-bit uint. Deterministic across environments; never use `Math.random`. */
export function hashString(input: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i)
    h = Math.imul(h, 0x01000193)
  }
  return h >>> 0
}

/** Creates a seeded PRNG (mulberry32) returning floats in `[0, 1)`. */
export function createPrng(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** Convenience: creates a PRNG from a string seed (any length). */
export function prngFromString(seed: string): () => number {
  return createPrng(hashString(seed))
}

/** Samples rendered per range. Kept small for perf. */
const SAMPLES_BY_RANGE: Record<TimeRangeId, number> = {
  "1D": 24,
  "1W": 28,
  "1M": 30,
  "3M": 36,
  "1Y": 52,
  ALL: 60,
}

/** Days covered by each range (used to stretch the x-axis). */
const DAYS_BY_RANGE: Record<TimeRangeId, number> = {
  "1D": 1,
  "1W": 7,
  "1M": 30,
  "3M": 90,
  "1Y": 365,
  ALL: 720,
}

type SeriesShape = {
  /** Starting value of the series (pre-noise). */
  base: number
  /** End-of-period multiplier applied linearly across the samples. */
  driftMultiplier?: number
  /** Noise amplitude as a fraction of base (0..1). */
  noise?: number
  /** If set, adds a smooth sinusoidal wave with the given relative amplitude. */
  wave?: number
  /** Clamps all points >= 0 when true (money/volume). */
  nonNegative?: boolean
  /** Optional fixed-point rounding (e.g. 2 for 2 decimal places). */
  roundTo?: number
}

/** Produces a deterministic `Series` for the given seed + range + shape. */
export function buildSeries(seed: string, range: TimeRangeId, label: string, shape: SeriesShape): Series {
  const rand = prngFromString(`${seed}:${range}`)
  const samples = SAMPLES_BY_RANGE[range]
  const days = DAYS_BY_RANGE[range]
  const drift = shape.driftMultiplier ?? 1
  const noise = shape.noise ?? 0.04
  const wave = shape.wave ?? 0.06
  const points: Point[] = []
  const now = SANDBOX_NOW
  const msPerStep = (days * 24 * 60 * 60 * 1000) / Math.max(1, samples - 1)
  for (let i = 0; i < samples; i++) {
    const progress = samples === 1 ? 1 : i / (samples - 1)
    const trend = shape.base * (1 + (drift - 1) * progress)
    const sine = Math.sin((progress * Math.PI * 2 + rand()) * 1.5) * shape.base * wave
    const jitter = (rand() * 2 - 1) * shape.base * noise
    let v = trend + sine + jitter
    if (shape.nonNegative) v = Math.max(0, v)
    if (shape.roundTo !== undefined) {
      const factor = 10 ** shape.roundTo
      v = Math.round(v * factor) / factor
    }
    const at = new Date(now - (samples - 1 - i) * msPerStep)
    // Keep full ISO for intraday (1D) so chart x-axis can show times; daily ranges stay date-only.
    const ts = days <= 1 ? at.toISOString() : at.toISOString().slice(0, 10)
    points.push({ t: ts, v })
  }
  const aggregate = points.reduce((sum, p) => sum + p.v, 0) / points.length
  return {
    id: `${seed}:${range}`,
    label,
    points,
    aggregate,
  }
}

/** Generates a series family keyed by TimeRangeId (one series per range). */
export function buildSeriesFamily(seed: string, label: string, shape: SeriesShape): Record<TimeRangeId, Series> {
  const out = {} as Record<TimeRangeId, Series>
  for (const range of ["1D", "1W", "1M", "3M", "1Y", "ALL"] as TimeRangeId[]) {
    out[range] = buildSeries(`${seed}:${range}`, range, label, shape)
  }
  return out
}
