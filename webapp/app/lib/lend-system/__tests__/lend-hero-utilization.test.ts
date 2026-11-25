import { describe, expect, it } from "vitest"
import { aggregateLendHeroFromMarkets } from "../lend-hero-aggregates"
import { lendMarketFromSnapshot } from "../market-hydration"
import type { LendSystemState } from "../model/types"
import { buildLendPageData } from "../read-model"

const snap = (slug: string, suppliedUsd: number, borrowedUsd: number) => ({
  slug,
  scope: "lend",
  symbol: "GHO",
  hubId: `hub-${slug}`,
  hubLabel: slug,
  category: "stable",
  assetPriceUsd: 1,
  suppliedUsd,
  borrowedUsd,
  availableUsd: suppliedUsd - borrowedUsd,
  utilizationPct: (borrowedUsd / suppliedUsd) * 100,
  supplyApyPct: 0,
})

describe("the Lend hero utilization", () => {
  it("weights each market's unrounded utilization by TVL, so markets under 0.5% still count", () => {
    // 0.4% on $10M and 0.1% on $30M: the TVL-weighted average is 0.175%.
    const a = lendMarketFromSnapshot(snap("gho-a", 10_000_000, 40_000), 1, 0)
    const b = lendMarketFromSnapshot(snap("gho-b", 30_000_000, 30_000), 2, 0)
    const state: LendSystemState = {
      now: 0,
      markets: { [a.marketId]: a, [b.marketId]: b },
      positions: {},
      walletBalances: {},
      transactions: [],
    }

    const { weightedUtilization } = aggregateLendHeroFromMarkets(buildLendPageData("guest", state).markets)

    expect(weightedUtilization).toBeCloseTo(0.175, 6)
  })
})
