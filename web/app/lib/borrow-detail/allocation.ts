/**
 * Shared helpers that compute cross-cutting facts used by both detail pages:
 * - risk premium bucketing (keeps the pools-table column consistent with the
 *   detail page risk card)
 * - allocation breakdown: for a given asset id, where is it deployed across
 *   the pool catalog?
 * - formatters that wrap the existing ones in borrow-sim.ts
 */

import { BORROW_POOL_CATALOG, type BorrowAssetVisual, type BorrowPoolRow, getDexById } from "@/app/lib/borrow-sim"
import type { SpokeBorrowableRecord } from "@/app/lib/borrow-system/registry"
import type { AllocationRow, RiskLevel } from "./types"
import { formatPercent } from "@/app/lib/format"

/**
 * Maps a risk premium (bps) to a qualitative bucket. The bounds are kept in
 * one place so the table pill, the detail gauge, and the breakdown card never
 * disagree. Numbers are inclusive on the lower bound.
 */
export function riskLevelFromBps(bps: number): RiskLevel {
  if (bps < 40) return "low"
  if (bps < 100) return "moderate"
  if (bps < 180) return "elevated"
  return "high"
}

/** Human label for the risk bucket. */
export function riskLevelLabel(level: RiskLevel): string {
  switch (level) {
    case "low":
      return "Low"
    case "moderate":
      return "Moderate"
    case "elevated":
      return "Elevated"
    case "high":
      return "High"
  }
}

/**
 * Gauge score (0..100). Clamped so visual designers can trust the bounds.
 * 25 bps → ~12, 90 bps → ~45, 180 bps → ~70, 300+ bps → ~92.
 */
export function riskScoreFromBps(bps: number): number {
  const mapped = 100 * (1 - Math.exp(-bps / 160))
  return Math.round(Math.max(2, Math.min(98, mapped)))
}

/**
 * Allocation row that keeps its source `pool` — the seed needs the pool slug to key
 * `assetPoolAllocationDaily`, and sharing this shape keeps seeded and fallback allocations equal.
 */
type AssetAllocationRow = {
  pool: BorrowPoolRow
  sharePct: number
  valueUsd: number
  utilizationPct: number
  borrowAprPct: number
}

/**
 * Per-pool share-of-asset-TVL, utilization and APR for a borrowable asset.
 * The top-N rows are re-scaled so the percentages sum to exactly 100.
 */
export function computeAssetAllocationRows(
  asset: SpokeBorrowableRecord,
  pools: BorrowPoolRow[] = BORROW_POOL_CATALOG,
  limit = 6,
): AssetAllocationRow[] {
  const candidates = pools.filter((pool) => asset.marketIds.includes(pool.id))
  if (candidates.length === 0) return []

  const weighted = candidates.map((pool) => {
    const apr = (pool.aprMin + pool.aprMax) / 2
    // Real utilization from the pool's own economics: borrowed / total, where
    // borrowed = total liquidity minus what is still available. Previously this
    // was fabricated (`maxLtv*0.92 + (apr*2)%18`), which presented an invented
    // number as a live figure. Fall back to 0 for an empty/unfunded pool.
    const utilization = pool.tvlUsd > 0 ? Math.round(((pool.tvlUsd - pool.availableUsd) / pool.tvlUsd) * 100) : 0
    return {
      pool,
      weight: pool.availableUsd,
      utilization,
      apr,
    }
  })

  weighted.sort((a, b) => b.weight - a.weight)
  const top = weighted.slice(0, limit)
  const totalWeight = top.reduce((sum, row) => sum + row.weight, 0) || 1
  const rows: AssetAllocationRow[] = top.map(({ pool, weight, utilization, apr }) => {
    const sharePct = (weight / totalWeight) * 100
    const valueUsd = (asset.totalBorrowedUsd + asset.availableUsd) * (weight / totalWeight)
    return {
      pool,
      sharePct: Math.round(sharePct * 100) / 100,
      valueUsd: Math.round(valueUsd),
      utilizationPct: Math.min(100, Math.max(0, utilization)),
      borrowAprPct: Math.round(apr * 100) / 100,
    }
  })

  const sumShare = rows.reduce((sum, row) => sum + row.sharePct, 0)
  if (sumShare !== 0) {
    const scale = 100 / sumShare
    for (const row of rows) {
      row.sharePct = Math.round(row.sharePct * scale * 100) / 100
    }
  }
  return rows
}

/** Venue label for an allocation pool (dex label, falling back to the venue string). */
export function allocationVenueLabel(pool: BorrowPoolRow): string {
  const dex = getDexById(pool.dexes[0]?.id as Parameters<typeof getDexById>[0])
  return dex?.label ?? pool.venue
}

/**
 * Maps the shared rows into the UI's `AllocationRow[]` (hydrating `visuals` +
 * display labels). Identical output to the original procedural builder.
 */
export function computeAssetAllocation(
  asset: SpokeBorrowableRecord,
  pools: BorrowPoolRow[] = BORROW_POOL_CATALOG,
  limit = 6,
): AllocationRow[] {
  return computeAssetAllocationRows(asset, pools, limit).map(
    ({ pool, sharePct, valueUsd, utilizationPct, borrowAprPct }) => {
      const visuals: [BorrowAssetVisual, BorrowAssetVisual] = pool.visuals
      return {
        id: `${asset.id}-${pool.id}`,
        poolName: pool.name,
        venueLabel: allocationVenueLabel(pool),
        visuals,
        sharePct,
        valueUsd,
        utilizationPct,
        borrowAprPct,
        feeTier: pool.feeTier,
        tvlUsd: pool.tvlUsd,
      }
    },
  )
}

// -------------------------------------------------------------------------
// Compact formatters (wrap borrow-sim helpers with extra cases)
// -------------------------------------------------------------------------

/** Compact percentage label with fixed digits (e.g. "68.4%"). */
export function formatPct(value: number, digits = 1): string {
  return formatPercent(value, { dp: digits })
}

/** Compact bps label (e.g. "+0.80%"). */
export function formatBpsAsPct(bps: number): string {
  if (!Number.isFinite(bps)) return "—"
  return `${bps >= 0 ? "+" : ""}${(bps / 100).toFixed(2)}%`
}
