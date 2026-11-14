import "server-only"
import { preloadQuery, preloadedQueryResult } from "convex/nextjs"
import type { Preloaded } from "convex/react"
import { api } from "@/convex/_generated/api"
import { buildHeroFeedFromConvexSeries } from "@/app/lib/chart-feeds"
import type { ChartFeed } from "@/app/components/charts"

/**
 * Server-side hero-series handoff for borrow pool/asset detail pages.
 *
 * Previously the composite detail builder fetched the three hero series (to build the
 * `heroFeed` props) AND the live hero re-subscribed the same series on the client — a
 * redundant fetch. Here we `preloadQuery` each series exactly once on the server and build
 * the `heroFeed` props from the preloaded value via `preloadedQueryResult` (no second
 * fetch). The page merges `feeds` into `detail` on the server; the `Preloaded` tokens are
 * NOT passed to client components (each would re-serialize the full series into the RSC
 * payload, and nothing on the client reads them).
 *
 * Returns `preloads: null` / empty `feeds` when no Convex deployment URL is configured
 * (CI/Lighthouse), so the hero falls back to its client-side deterministic feed.
 */
type PoolMetric = "tvl" | "borrowed" | "utilization"
type AssetMetric = "supply" | "borrow" | "utilization"

export type PoolHeroPreloads = Record<PoolMetric, Preloaded<typeof api.markets.getPoolHeroSeries>>
export type AssetHeroPreloads = Record<AssetMetric, Preloaded<typeof api.markets.getAssetHeroSeries>>

type HeroFeeds = { heroFeed?: ChartFeed; heroBorrowedFeed?: ChartFeed; heroUtilizationFeed?: ChartFeed }

/**
 * Server render window for the hero series. Every range is sliced from this one series (there is
 * no per-range client fetch), so it must be "ALL" for the 1Y/All tabs to show more than the
 * default view; a "3M" window made both of them repeat the last 90 days. Lend and Multiply
 * preload "ALL" for the same reason.
 */
const SSR_HERO_RANGE = "ALL" as const

function hasConvexUrl() {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  return Boolean(url && /^https?:\/\//.test(url))
}

function feedFrom(
  preloaded: { points?: ReadonlyArray<{ t: string; v: number }> } | null,
  format: "usdCompact" | "percent",
) {
  return buildHeroFeedFromConvexSeries(preloaded?.points ?? [], format) ?? undefined
}

/** Preload the three pool hero series (tvl/borrowed/utilization) and build initial feeds. */
export async function preloadPoolHero(slug: string): Promise<{ preloads: PoolHeroPreloads | null; feeds: HeroFeeds }> {
  if (!hasConvexUrl()) return { preloads: null, feeds: {} }
  try {
    const [tvl, borrowed, utilization] = await Promise.all([
      preloadQuery(api.markets.getPoolHeroSeries, { slug, metric: "tvl", range: SSR_HERO_RANGE }),
      preloadQuery(api.markets.getPoolHeroSeries, { slug, metric: "borrowed", range: SSR_HERO_RANGE }),
      preloadQuery(api.markets.getPoolHeroSeries, { slug, metric: "utilization", range: SSR_HERO_RANGE }),
    ])
    return {
      preloads: { tvl, borrowed, utilization },
      feeds: {
        heroFeed: feedFrom(preloadedQueryResult(tvl), "usdCompact"),
        heroBorrowedFeed: feedFrom(preloadedQueryResult(borrowed), "usdCompact"),
        heroUtilizationFeed: feedFrom(preloadedQueryResult(utilization), "percent"),
      },
    }
  } catch {
    return { preloads: null, feeds: {} }
  }
}

/** Preload the three asset hero series (supply/borrow/utilization) and build initial feeds. */
export async function preloadAssetHero(
  slug: string,
): Promise<{ preloads: AssetHeroPreloads | null; feeds: HeroFeeds }> {
  if (!hasConvexUrl()) return { preloads: null, feeds: {} }
  try {
    const [supply, borrow, utilization] = await Promise.all([
      preloadQuery(api.markets.getAssetHeroSeries, { slug, metric: "supply", range: SSR_HERO_RANGE }),
      preloadQuery(api.markets.getAssetHeroSeries, { slug, metric: "borrow", range: SSR_HERO_RANGE }),
      preloadQuery(api.markets.getAssetHeroSeries, { slug, metric: "utilization", range: SSR_HERO_RANGE }),
    ])
    return {
      preloads: { supply, borrow, utilization },
      feeds: {
        heroFeed: feedFrom(preloadedQueryResult(supply), "usdCompact"),
        heroBorrowedFeed: feedFrom(preloadedQueryResult(borrow), "usdCompact"),
        heroUtilizationFeed: feedFrom(preloadedQueryResult(utilization), "percent"),
      },
    }
  } catch {
    return { preloads: null, feeds: {} }
  }
}
