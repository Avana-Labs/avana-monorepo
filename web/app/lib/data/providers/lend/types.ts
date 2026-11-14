import { LEND_ASSET_GROUPS, LEND_FEATURED_ASSETS, LEND_FEATURED_SEQUENCE } from "@/app/lib/data/catalog/lend"
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
  featuredAssets: typeof LEND_FEATURED_ASSETS
  featuredSequence: ReadonlyArray<(typeof LEND_FEATURED_SEQUENCE)[number]>
  featuredSnapshots: ReadonlyArray<LendFeaturedSnapshot>
  assetGroups: ReadonlyArray<(typeof LEND_ASSET_GROUPS)[number]>
}
