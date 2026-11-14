import type { LendMarket, LendMarketCategory, LendSystemState } from "@/app/lib/lend-system/model"
import { INITIAL_LIQUIDITY_INDEX } from "@/app/lib/lend-system/model/constants"

/**
 * One lend row from services/convex `markets.listMarketSnapshots` (scope === "lend"): one Hub
 * asset. Loose `scope: string` so the raw query result (which also carries asset/pool rows) is
 * assignable without a cast.
 */
export type LendConvexSnapshot = {
  slug: string
  scope: string
  name?: string
  symbol?: string
  chainId?: number
  category?: string
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

function finite(value: number | undefined): number | undefined {
  return value !== undefined && Number.isFinite(value) ? value : undefined
}

function categoryOf(value: string | undefined): LendMarketCategory {
  return value === "stable" ? "stable" : "crypto"
}

/**
 * One Lend market built only from what services/convex reports. Amounts are kept in USD terms
 * when the row carries no price (price 1), so supplied/borrowed/available stay consistent with
 * the row; nothing is filled from a static catalog.
 */
export function lendMarketFromSnapshot(snap: LendConvexSnapshot, rank: number, now: number): LendMarket {
  const livePrice = finite(snap.assetPriceUsd)
  const price = livePrice !== undefined && livePrice > 0 ? livePrice : 1
  const supplyApy = (finite(snap.supplyApyPct) ?? 0) / 100
  const rewardsApy = (finite(snap.rewardsApyPct) ?? 0) / 100
  const symbol = snap.symbol?.trim() || snap.slug.toUpperCase()
  return {
    marketId: snap.slug,
    chainId: snap.chainId ?? 0,
    rank,
    asset: { symbol, name: snap.name?.trim() || symbol, priceUsd: price },
    assetPriceUsd: price,
    supplyApy,
    rewardsApy,
    totalApy: supplyApy + rewardsApy,
    totalSupplied: snap.suppliedUsd / price,
    totalBorrowed: snap.borrowedUsd / price,
    availableLiquidity: snap.availableUsd / price,
    utilization: (finite(snap.utilizationPct) ?? 0) / 100,
    reserveFactor: (finite(snap.reserveFactorPct) ?? 0) / 100,
    status: "active",
    riskTier: "low",
    category: categoryOf(snap.category),
    liquidityIndex: INITIAL_LIQUIDITY_INDEX,
    lastAccrualTimestamp: now,
    priceUpdatedAt: finite(snap.priceUpdatedAt) ?? now,
  }
}

/**
 * Replace the Lend markets of a state with the Hub assets services/convex reports. Wallet
 * positions are untouched. Returns the SAME state reference when nothing changed.
 */
export function mergeConvexLendSnapshots(
  state: LendSystemState,
  snapshots: readonly LendConvexSnapshot[],
): LendSystemState {
  const rows = snapshots.filter((snap) => snap.scope === "lend")
  if (rows.length === 0) return state
  const now = Date.now()
  const markets: Record<string, LendMarket> = {}
  rows.forEach((snap, index) => {
    const next = lendMarketFromSnapshot(snap, index + 1, now)
    const existing = state.markets[snap.slug]
    // Keep the previous object when only the timestamps differ, so memoized readers stay stable.
    markets[snap.slug] =
      existing &&
      JSON.stringify({ ...existing, lastAccrualTimestamp: 0, priceUpdatedAt: 0 }) ===
        JSON.stringify({ ...next, lastAccrualTimestamp: 0, priceUpdatedAt: 0 })
        ? existing
        : next
  })
  const sameKeys =
    Object.keys(markets).length === Object.keys(state.markets).length &&
    Object.entries(markets).every(([key, market]) => state.markets[key] === market)
  return sameKeys ? state : { ...state, markets }
}
