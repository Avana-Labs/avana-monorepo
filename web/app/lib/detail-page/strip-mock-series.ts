import "server-only"
import { ALL_TIME_RANGES, type Series, type TimeRangeId } from "@/app/lib/borrow-detail/types"
import { resolveDataSourceMode } from "@/app/lib/data/providers/source-mode"

/** Empty series stub — keeps UI contracts without shipping PRNG chart blobs (C05). */
export function emptySeries(id: string, label: string): Series {
  return { id, label, points: [] }
}

export function emptySeriesFamily(seed: string, label: string): Record<TimeRangeId, Series> {
  const out = {} as Record<TimeRangeId, Series>
  for (const range of ALL_TIME_RANGES) {
    out[range] = emptySeries(`${seed}:${range}`, label)
  }
  return out
}

/** Live path only — mock catalog still ships full PRNG families for offline/demo. */
export function shouldStripMockSeriesForLive(): boolean {
  return resolveDataSourceMode() === "live"
}
