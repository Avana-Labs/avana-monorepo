/**
 * Allocation queries — powers `AllocationBreakdownCard` on the asset page.
 *
 * Reads from `assetPoolAllocationDaily` joined to `markets` (for pool display
 * names). Returns the raw rows (incl. `poolSlug`); the server fetcher hydrates
 * token `visuals` from the catalog and maps to `AllocationRow[]`
 * (`app/lib/borrow-detail/types.ts`) — icon assets are a client concern.
 */

import { v } from "convex/values"
import type { QueryCtx } from "./_generated/server"
import { query } from "./_generated/server"

/**
 * Latest allocation snapshot per pool for a given asset.
 */
export async function readAllocationForAsset(ctx: QueryCtx, slug: string) {
  const asset = await ctx.db
    .query("markets")
    .withIndex("by_scope_slug", (q) => q.eq("scope", "asset").eq("slug", slug))
    .unique()
  if (!asset) return []

  const today = new Date().toISOString().slice(0, 10)
  const rows = await ctx.db
    .query("assetPoolAllocationDaily")
    .withIndex("by_asset_day", (q) => q.eq("assetId", asset._id).lte("day", today))
    .order("desc")
    .take(64)

  const latestByPool = new Map<string, (typeof rows)[number]>()
  for (const row of rows) {
    if (!latestByPool.has(row.poolId)) latestByPool.set(row.poolId, row)
  }

  const out = await Promise.all(
    [...latestByPool.values()].map(async (row) => {
      const pool = await ctx.db.get(row.poolId)
      if (!pool) return null
      return {
        id: String(row.poolId),
        /** Catalog pool id — the server uses it to hydrate token `visuals`. */
        poolSlug: pool.slug,
        poolName: pool.name,
        venueLabel: pool.venueLabel ?? "",
        sharePct: row.sharePct,
        valueUsd: row.valueUsd,
        utilizationPct: row.utilizationPct,
        borrowAprPct: row.borrowAprPct,
      }
    }),
  )
  return out.filter((r): r is NonNullable<typeof r> => r !== null).sort((a, b) => b.sharePct - a.sharePct)
}

export const getForAsset = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => readAllocationForAsset(ctx, slug),
})
