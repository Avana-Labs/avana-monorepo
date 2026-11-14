"use client"

import { useRouter } from "next/navigation"
import type { LendPageData } from "@/app/lib/data/providers/lend"
import { actionPagePath } from "@/app/lib/action-system/contracts"
import { LendHero } from "./components/lend-hero"
import { HotMarkets } from "./components/hot-markets"
import { LendAssetSpokes } from "./components/lend-asset-spokes"

export function LendClient({ pageData }: { pageData: LendPageData }) {
  const router = useRouter()
  // Render the server-provided (live Convex) page data directly — no client-side
  const { markets, featuredAssets, featuredSequence, featuredSnapshots, assetGroups } = pageData

  // Token prices come from the global TokenPricesProvider in ProductRuntimeProviders (seeded
  // with the live oracle on the server). A local provider here would shadow that seed with an
  // empty context and pin every price to the fixture.
  return (
    <div className="bg-background">
      <main className="py-8">
        <h1 className="sr-only">Lend markets</h1>
        <div className="container mx-auto px-4">
          <div className="mx-auto max-w-[1152px]">
            <LendHero markets={markets} />

            <div className="mt-7">
              <HotMarkets assets={featuredAssets} sequence={featuredSequence} snapshots={featuredSnapshots} />
            </div>

            <LendAssetSpokes
              groups={assetGroups}
              onDeposit={(marketId) => router.push(actionPagePath("lend", "deposit", { market: marketId }))}
            />
          </div>
        </div>
      </main>
    </div>
  )
}
