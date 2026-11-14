import { describe, expect, it } from "vitest"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"
import { catalogMarketToRow } from "@/app/lib/lend-system/read-model"

describe("illiquid lend APY outliers", () => {
  it("p1-31: shows the real APY for low-TVL RLUSD instead of an 'illiquid' flag", () => {
    // RLUSD is no longer a ~$150 market (its catalog row was mis-sized); keep the low-TVL case
    // with a tiny copy of it.
    const rlusd = LEND_MARKET_CATALOG.find((market) => market.asset.symbol === "RLUSD")
    expect(rlusd).toBeDefined()
    const tiny = { ...rlusd!, totalSupplied: 150 / rlusd!.assetPriceUsd }

    const tvlUsd = tiny.totalSupplied * tiny.assetPriceUsd
    expect(tvlUsd).toBeCloseTo(150, 0)

    const row = catalogMarketToRow(tiny)
    expect(row.totalApyLabel).not.toMatch(/illiquid/i)
    expect(row.totalApyLabel).toMatch(/%/)
    expect(row.supplyApyLabel).not.toMatch(/illiquid/i)
  })
})
