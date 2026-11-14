import { describe, expect, it } from "vitest"
import { buildLendFeaturedSnapshots, catalogMarketToRow } from "@/app/lib/lend-system/read-model"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"
import { LEND_FEATURED_SEQUENCE } from "@/app/lib/data/catalog/lend/featured-assets"

describe("buildLendFeaturedSnapshots", () => {
  it("carries a live supply APY that matches the list-row supply APY for the same asset", () => {
    const markets = Object.values(buildMockLendSystemState("demo-wallet").markets)
    const snapshots = buildLendFeaturedSnapshots(markets)

    expect(snapshots).toHaveLength(LEND_FEATURED_SEQUENCE.length)

    for (const snapshot of snapshots) {
      const market = markets.find((entry) => entry.asset.symbol.toUpperCase() === snapshot.symbol.toUpperCase())
      expect(market).toBeDefined()

      const row = catalogMarketToRow(market!)
      // Featured card and list row must read the SAME supply APY source.
      expect(snapshot.supplyApyPct).toBeCloseTo(row.supplyApy * 100, 6)
    }
  })
})
