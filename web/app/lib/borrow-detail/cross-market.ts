/**
 * Cross-market reference lists for borrow detail pages.
 *
 * Pool (collateral market) → assets you can borrow against it.
 * Asset (borrowable) → collateral markets that unlock borrowing it.
 * Both are built from the markets services/convex reports, passed in by the caller.
 */

import type { BorrowAssetVisual, BorrowPoolRow } from "@/app/lib/borrow-market-rows"
import type { SpokeBorrowableRecord } from "./types"
import { borrowAssetDetailPath, borrowMarketDetailPath } from "@/app/lib/borrow-routes"

export type BorrowableAssetRef = {
  id: string
  name: string
  symbol: string
  visual: BorrowAssetVisual
  /** Borrow APY percent (e.g. 4.2). */
  apy: number
  /** Total supply-side liquidity in USD (borrowed + available) — for the "… Supply" sub-label. */
  tvlUsd?: number
  href: string
}

type CollateralMarketRef = {
  id: string
  name: string
  venue: string
  visuals: [BorrowAssetVisual, BorrowAssetVisual]
  /** Max LTV / collateral factor as a percent (e.g. 78). */
  collateralFactorPct: number
  href: string
}

/** Borrowable assets unlocked by a specific collateral market. */
export function resolveBorrowablesForPool(
  pool: Pick<BorrowPoolRow, "id" | "spoke">,
  borrowables: readonly SpokeBorrowableRecord[] = [],
): BorrowableAssetRef[] {
  return borrowables
    .filter((asset) => asset.spokeId === pool.spoke && asset.marketIds.includes(pool.id))
    .map((asset) => ({
      id: asset.id,
      name: asset.name,
      symbol: asset.symbol,
      visual: asset.visual,
      apy: asset.borrowApr,
      tvlUsd: asset.totalBorrowedUsd + asset.availableUsd,
      href: borrowAssetDetailPath(asset.id),
    }))
    .sort((a, b) => a.name.localeCompare(b.name))
}

/** Collateral markets that can be used to borrow a specific asset. */
export function resolveCollateralForAsset(
  asset: Pick<SpokeBorrowableRecord, "id" | "marketIds">,
  pools: readonly BorrowPoolRow[] = [],
): CollateralMarketRef[] {
  return pools
    .filter((pool) => asset.marketIds.includes(pool.id))
    .map((pool) => ({
      id: pool.id,
      name: pool.name,
      venue: pool.venue,
      visuals: pool.visuals,
      collateralFactorPct: pool.ltv,
      href: borrowMarketDetailPath(pool.id),
    }))
    .sort((a, b) => b.collateralFactorPct - a.collateralFactorPct || a.name.localeCompare(b.name))
}

/**
 * Restrict a collateral-pool list to the markets that unlock borrowing an asset (its
 * `marketIds`). Used by the asset-detail borrow picker.
 */
export function filterPoolsForSpokeAsset<T extends { id: string }>(marketIds: readonly string[] | undefined, pools: T[]): T[] {
  if (!marketIds) return []
  const allowed = new Set(marketIds)
  return pools.filter((pool) => allowed.has(pool.id))
}
