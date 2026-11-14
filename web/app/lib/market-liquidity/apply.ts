import type { MarketLiquidityDelta } from "@/app/lib/convex/market-liquidity-provider"
import type { BorrowSystemState } from "@/app/lib/credit-engine/types"
import { parseFixed } from "@/app/lib/credit-engine/units"

/**
 * Single source of truth for layering shared-ledger liquidity deltas onto the
 * static catalog base. Every borrow surface (list, hero, asset/pool detail) reads
 * through these helpers so the same market shows the same numbers everywhere, and
 * those numbers move together as borrow/repay/supply/withdraw activity is recorded
 * (see `useMarketLiquidity`).
 *
 * Keying convention:
 *   - borrowable-asset liquidity → keyed by ASSET id  (borrowedDeltaUsd)
 *   - pool / market supplied TVL  → keyed by MARKET id (suppliedDeltaUsd)
 */

export type DeltaMap = Map<string, MarketLiquidityDelta>

type BorrowableLiquidity = {
  totalBorrowedUsd: number
  availableUsd: number
  utilization: number
}

/**
 * Apply the borrowed delta for a borrowable asset: borrowing moves USD from
 * available → borrowed (repaying does the reverse). Total liquidity (the sum) is
 * conserved, so utilization is recomputed from the moved amounts.
 */
export function applyBorrowableAssetLiquidity<T extends BorrowableLiquidity>(
  asset: T,
  delta?: MarketLiquidityDelta,
): T {
  if (!delta || delta.borrowedDeltaUsd === 0) return asset
  const totalLiquidityUsd = asset.totalBorrowedUsd + asset.availableUsd
  const totalBorrowedUsd = Math.max(0, asset.totalBorrowedUsd + delta.borrowedDeltaUsd)
  const availableUsd = Math.max(0, asset.availableUsd - delta.borrowedDeltaUsd)
  const utilization = totalLiquidityUsd > 0 ? (totalBorrowedUsd / totalLiquidityUsd) * 100 : asset.utilization
  return { ...asset, totalBorrowedUsd, availableUsd, utilization }
}

/** Convenience: look the delta up by the asset's own id, then apply it. */
export function applyBorrowableAssetDelta<T extends BorrowableLiquidity & { id: string }>(
  asset: T,
  deltas: DeltaMap,
): T {
  return applyBorrowableAssetLiquidity(asset, deltas.get(asset.id))
}

function usdNumberToUsd6(deltaUsd: number): bigint {
  if (!Number.isFinite(deltaUsd) || deltaUsd === 0) return 0n
  return parseFixed(Math.abs(deltaUsd).toFixed(6), 6)
}

/**
 * Layer shared-ledger borrow deltas onto credit-engine asset snapshots before a
 * borrow simulate/execute so available liquidity matches what the UI lists.
 */
export function applyBorrowLiquidityDeltasToEngineState(state: BorrowSystemState, deltas: DeltaMap): BorrowSystemState {
  if (deltas.size === 0) return state

  let touched = false
  const assets: BorrowSystemState["assets"] = { ...state.assets }
  for (const [assetId, asset] of Object.entries(state.assets)) {
    const delta = deltas.get(assetId)
    if (!delta || delta.borrowedDeltaUsd === 0) continue

    touched = true
    const deltaUsd6 = usdNumberToUsd6(delta.borrowedDeltaUsd)
    const borrowedDeltaUsd6 = delta.borrowedDeltaUsd >= 0 ? deltaUsd6 : -deltaUsd6
    const nextAvailable = asset.snapshot.availableLiquidityUsd6 - borrowedDeltaUsd6
    const nextBorrowed = asset.snapshot.totalBorrowedUsd6 + borrowedDeltaUsd6
    assets[assetId] = {
      ...asset,
      snapshot: {
        ...asset.snapshot,
        availableLiquidityUsd6: nextAvailable > 0n ? nextAvailable : 0n,
        totalBorrowedUsd6: nextBorrowed > 0n ? nextBorrowed : 0n,
      },
    }
  }

  return touched ? { ...state, assets } : state
}
