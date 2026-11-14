import { formatPercent } from "@/app/lib/format"
/**
 * Pure helpers for overlaying siloed Convex market identity + key-stat leftovers
 * (reserve factor, rewards APY, available) onto Dual detail objects.
 */

type SiloedMarketIdentity = {
  name: string
  symbol: string
  venueLabel?: string
  explorerUrl?: string
  description?: string
  category?: "stable" | "crypto" | "stock"
  feeTier?: string
  iconUrl?: string
  reserveFactorPct?: number
  rewardsApyPct?: number
}

type OverlayQuickStat = {
  id: string
  value: string
}

/** Format rewards APY for Key Statistics (`"No rewards"` when zero/missing). */
export function formatRewardsApyLabel(rewardsApyPct: number | undefined | null): string {
  if (rewardsApyPct === undefined || rewardsApyPct === null || !Number.isFinite(rewardsApyPct) || rewardsApyPct <= 0) {
    return "No rewards"
  }
  return formatPercent(rewardsApyPct, { dp: 2 })
}

/** Overlay reserveFactor + rewardsApy quick stats from a siloed market row. */
export function injectSiloedMarketQuickStats<T extends OverlayQuickStat>(
  quickStats: T[],
  siloed: object | null | undefined,
): T[] {
  // services/convex may omit both fields; read them as optional.
  const market = siloed as Pick<SiloedMarketIdentity, "reserveFactorPct" | "rewardsApyPct"> | null | undefined
  if (!market) return quickStats
  return quickStats.map((stat) => {
    if (
      stat.id === "reserveFactor" &&
      market.reserveFactorPct !== undefined &&
      Number.isFinite(market.reserveFactorPct)
    ) {
      return { ...stat, value: formatPercent(market.reserveFactorPct, { dp: 0 }) }
    }
    if (stat.id === "rewardsApy" && market.rewardsApyPct !== undefined) {
      return { ...stat, value: formatRewardsApyLabel(market.rewardsApyPct) }
    }
    return stat
  })
}

/** Overlay available liquidity from a snapshot `availableUsd`. */
export function injectAvailableUsdQuickStat<T extends OverlayQuickStat>(
  quickStats: T[],
  availableUsd: number | null | undefined,
  formatUsd: (value: number) => string,
): T[] {
  if (availableUsd === undefined || availableUsd === null || !Number.isFinite(availableUsd)) return quickStats
  return quickStats.map((stat) => (stat.id === "available" ? { ...stat, value: formatUsd(availableUsd) } : stat))
}

type HeroNameFields = {
  name?: string
  symbol?: string
  venue?: string
  explorerUrl?: string | null
  feeTier?: string
  category?: string
  subtitle?: string
}

/** Prefer siloed market identity fields on a detail hero; keep catalog for missing fields. */
export function overlayHeroIdentity<T extends HeroNameFields>(
  hero: T,
  market: SiloedMarketIdentity | null | undefined,
): T {
  if (!market) return hero
  return {
    ...hero,
    ...(market.name ? { name: market.name } : null),
    ...(market.symbol && "symbol" in hero ? { symbol: market.symbol } : null),
    ...(market.venueLabel && "venue" in hero ? { venue: market.venueLabel } : null),
    ...(market.explorerUrl !== undefined && "explorerUrl" in hero ? { explorerUrl: market.explorerUrl } : null),
    ...(market.feeTier && "feeTier" in hero ? { feeTier: market.feeTier } : null),
    ...(market.category && "category" in hero ? { category: market.category } : null),
    ...(market.description && "subtitle" in hero ? { subtitle: market.description } : null),
  }
}
