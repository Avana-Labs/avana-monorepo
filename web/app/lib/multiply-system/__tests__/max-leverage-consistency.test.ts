import { describe, expect, it } from "vitest"
import {
  buildMultiplyPageData,
  catalogMarketToRow,
  buildMultiplyTrendingSnapshots,
} from "@/app/lib/multiply-system/read-model"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import { resolveMultiplyMarketDisplayMaxLeverage } from "@/app/lib/multiply-system/leverage-limits"

function formatFactor(value: number) {
  return `${value.toFixed(2)}x`
}

describe("multiply max-leverage single source (#95)", () => {
  it("markets-table, explore-table primary row and trending card agree per market", () => {
    const page = buildMultiplyPageData("demo-wallet")

    for (const market of MULTIPLY_MARKET_CATALOG) {
      const expected = resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier)

      // Perp-style markets table value (rendered as `${maxLeverage}x`).
      const perpEntry = page.markets.find((entry) => entry.symbol === market.collateralAsset.symbol)
      expect(perpEntry?.maxLeverage).toBeDefined()

      // Explore table: the MAX LEVERAGE column shows the primary reward row.
      const row = catalogMarketToRow(market)
      expect(row.rewardRows?.[0]?.value).toBe(formatFactor(expected))
      expect(row.rewardRows?.[0]?.value).not.toMatch(/Recommended max/i)
    }
  })

  it("trending card leverage label matches the single-sourced public max", () => {
    const snapshots = buildMultiplyTrendingSnapshots(MULTIPLY_MARKET_CATALOG)
    for (const snapshot of snapshots) {
      const market = MULTIPLY_MARKET_CATALOG.find((entry) => entry.id === snapshot.marketId)!
      const expected = resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier)
      expect(snapshot.maxLeverageLabel).toBe(formatFactor(expected))
    }
  })

  it("spells out collateral and liquidation parameters", () => {
    const row = buildMultiplyPageData("demo-wallet").lendRows[0]!
    expect(row.rewardRows?.[0]?.label).toMatch(/^Collateral factor \d+% · Liquidation threshold \d+%$/)
    expect(row.rewardRows?.[0]?.label).not.toMatch(/\b(?:CF|LT)\b/)
  })

  it("the aave-gho market shows one leverage (1.80x), not 1.76x on some surfaces", () => {
    const market = MULTIPLY_MARKET_CATALOG.find((entry) => entry.id === "aave-gho")!
    const row = catalogMarketToRow(market)
    // Regression guard: the primary MAX LEVERAGE value must be the public max (1.80),
    // not the recommended cap (~1.76) that used to leak into the table column.
    expect(row.rewardRows?.[0]?.value).toBe("1.80x")
    expect(row.rewardRows?.[0]?.value).not.toMatch(/Recommended max/i)

    const snapshots = buildMultiplyTrendingSnapshots(MULTIPLY_MARKET_CATALOG)
    const trending = snapshots.find((entry) => entry.marketId === "aave-gho")
    if (trending) expect(trending.maxLeverageLabel).toBe("1.80x")

    const page = buildMultiplyPageData("demo-wallet")
    const perpEntry = page.markets.find((entry) => entry.symbol === market.collateralAsset.symbol)
    expect(perpEntry?.maxLeverage).toBe(1.8)
  })

  it("hero average leverage equals the mean of the single-sourced per-market maxes", () => {
    const page = buildMultiplyPageData("demo-wallet")
    const expectedAvg =
      MULTIPLY_MARKET_CATALOG.reduce(
        (sum, market) => sum + resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier),
        0,
      ) / MULTIPLY_MARKET_CATALOG.length
    expect(page.heroMetrics.averageMaxLeverage).toBeCloseTo(expectedAvg, 10)
  })
})
