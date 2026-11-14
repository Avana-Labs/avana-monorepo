"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import type { MultiplyPageData } from "@/app/lib/data/providers/multiply"
import type { MultiplyMarketRecord } from "@/app/lib/multiply-engine"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { getMultiplyMarketById, MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import { MultiplyHero } from "./components/multiply-hero"
import { ExploreLoopsMarketsTable } from "./components/explore-loops-markets-table"

function resolveMarketFromRowHref(href: string): MultiplyMarketRecord | null {
  const marketId = href.split("/").pop()
  if (!marketId) return null
  return getMultiplyMarketById(marketId.toLowerCase())
}

export function MultiplyClient({ pageData }: { pageData: MultiplyPageData }) {
  const router = useRouter()

  // Render the server-provided page data as-is. It already carries live Convex
  // market snapshots AND live token parameters (see the multiply page source), so
  // the first paint is real. The list intentionally does NOT rebuild from the
  // wallet session on mount — that swapped every row + carousel card to a
  // slightly different (session-derived) dataset, which read as a flicker.
  // Wallet-specific liquidity is surfaced on the detail/action pages instead.
  const handleOpenMultiply = React.useCallback(
    (marketId: string) => {
      const market = getMultiplyMarketById(marketId.toLowerCase())
      if (!market) return
      router.push(actionPagePath("multiply", "multiply", { market: market.id }))
    },
    [router],
  )

  return (
    <main className="container mx-auto px-4 py-8">
      <h1 className="sr-only">Multiply markets</h1>
      <div className="mx-auto max-w-[1152px]">
        <MultiplyHero metrics={pageData.heroMetrics} />
        <ExploreLoopsMarketsTable
          rows={pageData.lendRows}
          trendingSnapshots={pageData.trendingSnapshots}
          pageSize={pageData.pageSize}
          tokenLogos={pageData.tokenLogos}
          onOpenMultiply={(href) => {
            const market = resolveMarketFromRowHref(href)
            if (market) handleOpenMultiply(market.id)
          }}
        />
      </div>
    </main>
  )
}

export { MULTIPLY_MARKET_CATALOG }
