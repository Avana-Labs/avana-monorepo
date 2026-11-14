import { describe, expect, it } from "vitest"
import { buildMultiplyPageData } from "@/app/lib/multiply-system/read-model"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"

describe("multiply page data", () => {
  it("renders all 20 catalog markets in the explore table rows", () => {
    const page = buildMultiplyPageData("demo-wallet")
    expect(page.lendRows).toHaveLength(20)
    expect(page.lendRows[0]?.protocol).toBeTruthy()
    expect(page.lendRows.some((row) => row.href.includes("wsteth-eth"))).toBe(true)
    expect(MULTIPLY_MARKET_CATALOG).toHaveLength(20)
  })

  it("hero Total Liquidity reconciles with the sum of every market's available liquidity", () => {
    const page = buildMultiplyPageData("demo-wallet")
    const expectedTotal = MULTIPLY_MARKET_CATALOG.reduce(
      (sum, market) => sum + market.economics.availableLiquidityUsd,
      0,
    )
    expect(page.heroMetrics.marketCount).toBe(20)
    // The headline must be the full catalog total ($137.5M), not a 5-market sample.
    expect(page.heroMetrics.totalLiquidityUsd).toBe(expectedTotal)
    expect(page.heroMetrics.totalLiquidityUsd).toBeGreaterThan(100_000_000)
    expect(page.heroMetrics.averageMaxLeverage).toBeGreaterThan(1)
    expect(page.heroMetrics.averageMaxApy).toBeGreaterThan(0)
  })
})
