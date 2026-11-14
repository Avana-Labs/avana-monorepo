import type { LendAssetGroup, LendFeaturedAsset, LendFeaturedAssetId } from "@/app/lib/data/lend-rows"
import type { LendFeaturedSnapshot } from "@/app/lib/lend-system/read-model"

export type LendMarket = {
  symbol: string
  name: string
  apy: number
  apyChange24h: number
  tvl: string
  /** Raw USD TVL — the hero aggregates this directly instead of re-parsing `tvl`. */
  tvlUsd?: number
  utilization: number
  type: string
  protocol: string
  color: string
  bg: string
  soon: boolean
  event: string | null
}

export type LendPageData = {
  markets: ReadonlyArray<LendMarket>
  featuredAssets: Readonly<Record<string, LendFeaturedAsset>>
  featuredSequence: ReadonlyArray<LendFeaturedAssetId>
  featuredSnapshots: ReadonlyArray<LendFeaturedSnapshot>
  assetGroups: ReadonlyArray<LendAssetGroup>
}
