import type { LendSystemState } from "@/app/lib/lend-engine"
import { warnLiveFallback } from "@/app/lib/data/providers/hydration-telemetry"

/**
 * One lend row from convex/markets.ts `listMarketSnapshots` (scope === "lend").
 * Loose `scope: string` so the raw query result (which also carries asset/pool
 * rows) is assignable without a cast.
 */
export type LendConvexSnapshot = {
  slug: string
  scope: string
  name?: string
  symbol?: string
  reserveFactorPct?: number
  rewardsApyPct?: number
  assetPriceUsd?: number
  priceUpdatedAt?: number
  suppliedUsd: number
  borrowedUsd: number
  availableUsd: number
  utilizationPct: number
  supplyApyPct: number
}

/**
 * Fold Convex lend market reference data into a lend system state so the session
 * (list, hero overview, dashboard) reads the SAME numbers as the detail page and
 * the single source of truth. Overwrites supply/liquidity/rate fields plus identity,
 * reserve factor, and rewards when present on the snapshot.
 */
export function mergeConvexLendSnapshots(
  state: LendSystemState,
  snapshots: readonly LendConvexSnapshot[],
): LendSystemState {
  if (snapshots.length === 0) return state
  let changed = false
  const markets = { ...state.markets }

  for (const snap of snapshots) {
    if (snap.scope !== "lend") continue
    const existing = markets[snap.slug]
    if (!existing) continue
    const hasLivePrice =
      snap.assetPriceUsd !== undefined &&
      Number.isFinite(snap.assetPriceUsd) &&
      snap.assetPriceUsd > 0 &&
      snap.priceUpdatedAt !== undefined &&
      Number.isFinite(snap.priceUpdatedAt)
    const price = hasLivePrice ? snap.assetPriceUsd! : existing.assetPriceUsd || 1
    const supplyApy = snap.supplyApyPct / 100
    let rewardsApy: number
    if (snap.rewardsApyPct !== undefined && Number.isFinite(snap.rewardsApyPct)) {
      rewardsApy = snap.rewardsApyPct / 100
    } else {
      warnLiveFallback("lend", snap.slug, "rewardsApyPct")
      rewardsApy = existing.rewardsApy
    }
    let reserveFactor: number
    if (snap.reserveFactorPct !== undefined && Number.isFinite(snap.reserveFactorPct)) {
      reserveFactor = snap.reserveFactorPct / 100
    } else {
      warnLiveFallback("lend", snap.slug, "reserveFactorPct")
      reserveFactor = existing.reserveFactor
    }
    let assetName: string
    if (snap.name?.trim()) {
      assetName = snap.name
    } else {
      warnLiveFallback("lend", snap.slug, "name")
      assetName = existing.asset.name
    }
    let assetSymbol: string
    if (snap.symbol?.trim()) {
      assetSymbol = snap.symbol
    } else {
      warnLiveFallback("lend", snap.slug, "symbol")
      assetSymbol = existing.asset.symbol
    }
    const next = {
      ...existing,
      totalSupplied: snap.suppliedUsd / price,
      totalBorrowed: snap.borrowedUsd / price,
      availableLiquidity: snap.availableUsd / price,
      utilization: snap.utilizationPct / 100,
      supplyApy,
      rewardsApy,
      reserveFactor,
      totalApy: supplyApy + rewardsApy,
      assetPriceUsd: price,
      priceUpdatedAt: hasLivePrice ? snap.priceUpdatedAt! : existing.priceUpdatedAt,
      asset: {
        ...existing.asset,
        name: assetName,
        symbol: assetSymbol,
        priceUsd: price,
      },
    }
    if (
      existing.totalSupplied === next.totalSupplied &&
      existing.totalBorrowed === next.totalBorrowed &&
      existing.availableLiquidity === next.availableLiquidity &&
      existing.utilization === next.utilization &&
      existing.supplyApy === next.supplyApy &&
      existing.rewardsApy === next.rewardsApy &&
      existing.reserveFactor === next.reserveFactor &&
      existing.totalApy === next.totalApy &&
      existing.assetPriceUsd === next.assetPriceUsd &&
      existing.priceUpdatedAt === next.priceUpdatedAt &&
      existing.asset.name === next.asset.name &&
      existing.asset.symbol === next.asset.symbol &&
      existing.asset.priceUsd === next.asset.priceUsd
    ) {
      continue
    }
    markets[snap.slug] = next
    changed = true
  }

  return changed ? { ...state, markets } : state
}
