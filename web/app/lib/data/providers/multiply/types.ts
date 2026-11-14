import { MULTIPLY_MARKET_ROWS, MULTIPLY_TOKEN_LOGOS } from "@/app/lib/data/catalog/multiply"
import type { MultiplyTrendingSnapshot } from "@/app/lib/multiply-system/read-model"

export type MultiplyMarket = {
  symbol: string
  name: string
  price: number
  funding: number
  change: number
  volume: number
  maxLeverage: number
  longOi: number
  shortOi: number
}

/**
 * Headline metrics for the multiply hero, aggregated across every loop market so
 * the figures reconcile with the markets table below (the table lists each loop's
 * available liquidity; the hero shows their sum). Computed once in the read-model.
 */
export type MultiplyHeroMetrics = {
  /** Σ available liquidity across all loop markets — reconciles with the table. */
  totalLiquidityUsd: number
  /** Number of loop markets in the catalog. */
  marketCount: number
  /** Mean estimated max APY (0..1) across loop markets. */
  averageMaxApy: number
  /** Mean public max leverage across loop markets. */
  averageMaxLeverage: number
}

export type MultiplyPageData = {
  markets: ReadonlyArray<MultiplyMarket>
  heroMetrics: MultiplyHeroMetrics
  lendRows: ReadonlyArray<(typeof MULTIPLY_MARKET_ROWS)[number]>
  trendingSnapshots: ReadonlyArray<MultiplyTrendingSnapshot>
  pageSize: number
  tokenLogos: typeof MULTIPLY_TOKEN_LOGOS
}
