import type { ChartPoint } from "./types"

/** Continuous scrub sample along the hero area path (not snapped to a discrete index). */
export type HeroScrubSample = {
  /** Plot X in SVG coordinates. */
  x: number
  /** Plot Y in SVG coordinates. */
  y: number
  /** Interpolated series value at this X. */
  value: number
  /** Label from the floor sample (timestamp / bucket). */
  label: string
  /** Time from the floor sample. */
  time: number
  /** Index of the segment start (floor). */
  indexFloor: number
  /** 0–1 progress within the floor→ceil segment. */
  progress: number
}

export type ScrubPlotPoint = ChartPoint & { x: number; y: number }

/**
 * Map a pointer X (relative to the chart shell) into a 0–1 plot ratio,
 * clamped to the drawable plot region.
 */
export function scrubRatioFromPointer(clientX: number, shellLeft: number, plotLeft: number, plotWidth: number): number {
  const width = Math.max(1, plotWidth)
  return Math.min(1, Math.max(0, (clientX - shellLeft - plotLeft) / width))
}

/**
 * Continuous scrub along the plotted points: find the segment under `ratio` by screen X and
 * linearly interpolate value + screen Y, so the crosshair and dot sit exactly under the pointer.
 *
 * Points are positioned by time, and daily series can have uneven gaps (a missing stretch of
 * days). Mapping the ratio to a point *index* assumed equal spacing and drew the dot left or
 * right of the pointer wherever the dates were uneven; searching by X is exact either way.
 */
export function interpolateScrubSample(points: ScrubPlotPoint[], ratio: number): HeroScrubSample | null {
  if (points.length === 0) return null
  if (points.length === 1) {
    const only = points[0]!
    return {
      x: only.x,
      y: only.y,
      value: only.value,
      label: only.label,
      time: only.time,
      indexFloor: 0,
      progress: 0,
    }
  }

  const clamped = Math.min(1, Math.max(0, ratio))
  const first = points[0]!
  const last = points[points.length - 1]!
  const targetX = first.x + (last.x - first.x) * clamped

  // Last point whose X is at or left of the target (points are sorted by X).
  let lo = 0
  let hi = points.length - 2
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1
    if (points[mid]!.x <= targetX) lo = mid
    else hi = mid - 1
  }
  const indexFloor = lo
  const left = points[indexFloor]!
  const right = points[indexFloor + 1]!
  const span = right.x - left.x
  const progress = span > 0 ? Math.min(1, Math.max(0, (targetX - left.x) / span)) : 0

  return {
    x: targetX,
    y: left.y + (right.y - left.y) * progress,
    value: left.value + (right.value - left.value) * progress,
    label: progress < 0.5 ? left.label : right.label,
    time: progress < 0.5 ? left.time : right.time,
    indexFloor,
    progress,
  }
}
