import "server-only"
import { preloadedQueryResult } from "convex/nextjs"
import type { CashflowPreload } from "@/app/lib/detail-page/cashflow-preload"
import type { QuickStatsPreload } from "@/app/lib/detail-page/quick-stats-preload"
import type { DeltaStat } from "@/app/lib/borrow-detail/types"

/**
 * Read Convex rows already fetched via `preloadQuery` on the page so detail builders
 * do not HTTP-fetch the same `getQuickStats` / cashflow queries a second time (C03).
 */
export type PreloadedQuickStatRow = {
  id: string
  value: string
  delta?: DeltaStat
}

export function readPreloadedQuickStats(
  preload: QuickStatsPreload | null,
): ReadonlyArray<PreloadedQuickStatRow> | null {
  if (!preload) return null
  try {
    const rows = preloadedQueryResult(preload)
    return rows && rows.length > 0 ? (rows as ReadonlyArray<PreloadedQuickStatRow>) : null
  } catch {
    return null
  }
}

export function readPreloadedCashflow<T>(preload: CashflowPreload | null): T | null {
  if (!preload) return null
  try {
    return (preloadedQueryResult(preload) as T) ?? null
  } catch {
    return null
  }
}
