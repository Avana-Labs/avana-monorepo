import { describe, expect, it } from "vitest"
import { catalogMarketToRow } from "@/app/lib/multiply-system/read-model"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import { resolveMultiplyMarketDisplayMaxLeverage } from "@/app/lib/multiply-system/leverage-limits"

describe("multiply max leverage column", () => {
  it("p1-15: max leverage column drops Recommended max under Max label", () => {
    const market = MULTIPLY_MARKET_CATALOG.find((entry) => entry.id === "aave-gho")!
    const row = catalogMarketToRow(market)
    const expected = resolveMultiplyMarketDisplayMaxLeverage(market.risk.publicMaxMultiplier)

    expect(row.rewardRows).toHaveLength(1)
    expect(row.rewardRows?.[0]?.value).toBe(`${expected.toFixed(2)}x`)
    expect(JSON.stringify(row.rewardRows)).not.toMatch(/Recommended max/i)
  })
})
