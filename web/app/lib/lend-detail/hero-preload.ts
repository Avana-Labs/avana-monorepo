import "server-only"
import { preloadQuery, preloadedQueryResult } from "convex/nextjs"
import type { Preloaded } from "convex/react"
import { api } from "@/convex/_generated/api"
import { buildHeroFeedFromConvexSeries } from "@/app/lib/chart-feeds"
import type { ChartFeed } from "@/app/components/charts"

/**
 * Server-side hero-series handoff for lend detail pages. Lend has a single hero metric
 * (supply). Preloads it once and builds the `heroFeed` from the preloaded value (no second
 * fetch); the page merges `feeds` into `detail` on the server. The `Preloaded` token is not
 * passed to client components. `preloads: null` when no deployment URL is set.
 */
export type LendHeroPreloads = { supply: Preloaded<typeof api.markets.getLendHeroSeries> }

function hasConvexUrl() {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  return Boolean(url && /^https?:\/\//.test(url))
}

export async function preloadLendHero(
  slug: string,
): Promise<{ preloads: LendHeroPreloads | null; feeds: { heroFeed?: ChartFeed } }> {
  if (!hasConvexUrl()) return { preloads: null, feeds: {} }
  try {
    const supply = await preloadQuery(api.markets.getLendHeroSeries, { slug, metric: "supply", range: "ALL" })
    const points = preloadedQueryResult(supply)?.points ?? []
    return {
      preloads: { supply },
      feeds: { heroFeed: buildHeroFeedFromConvexSeries(points, "usdCompact") ?? undefined },
    }
  } catch {
    return { preloads: null, feeds: {} }
  }
}
