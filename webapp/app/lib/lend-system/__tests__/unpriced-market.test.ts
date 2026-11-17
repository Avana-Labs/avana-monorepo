import { describe, expect, it } from "vitest"
import { lendMarketFromSnapshot } from "../market-hydration"
import { catalogMarketToRow } from "../read-model"

const snap = (assetPriceUsd?: number) => ({
  slug: "weth-core",
  scope: "lend",
  symbol: "WETH",
  ...(assetPriceUsd === undefined ? {} : { assetPriceUsd }),
  suppliedUsd: 3_000_000,
  borrowedUsd: 1_000_000,
  availableUsd: 2_000_000,
  utilizationPct: 33,
  supplyApyPct: 2,
})

describe("a Lend market without a price", () => {
  it("keeps the reported USD figures and leaves token amounts unknown instead of pricing the asset at $1", () => {
    const market = lendMarketFromSnapshot(snap(), 1, 0)
    expect(market.assetPriceUsd).toBeNaN()
    expect(market.totalSupplied).toBeNaN()
    expect(market.totalSuppliedUsd).toBe(3_000_000)
    expect(catalogMarketToRow(market).totalSuppliedLabel).toBe("$3.0M")
  })

  it("derives token amounts from the price when there is one", () => {
    const market = lendMarketFromSnapshot(snap(3000), 1, 0)
    expect(market.totalSupplied).toBe(1000)
    expect(catalogMarketToRow(market).availableLiquidityLabel).toBe("$2.0M")
  })
})
