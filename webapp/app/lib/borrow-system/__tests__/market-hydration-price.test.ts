import { describe, expect, it } from "vitest"
import { borrowAssetFromSnapshot, type ConvexMarketSnapshot } from "../market-hydration"

const asset = (over: Partial<ConvexMarketSnapshot>): ConvexMarketSnapshot => ({
  slug: "usdc",
  scope: "asset",
  symbol: "USDC",
  suppliedUsd: 0,
  borrowedUsd: 0,
  availableUsd: 0,
  utilizationPct: 0,
  supplyApyPct: 0,
  borrowAprPct: 0,
  tvlUsd: 0,
  volumeUsd: 0,
  feesUsd: 0,
  ...over,
})

describe("borrowAssetFromSnapshot", () => {
  it("prices the debt asset from the price snapshot, and leaves it unpriced without one", () => {
    expect(borrowAssetFromSnapshot(asset({ assetPriceUsd: 0.9998 }), []).snapshot.priceUsd6).toBe(999_800n)
    expect(borrowAssetFromSnapshot(asset({}), []).snapshot.priceUsd6).toBe(0n)
  })
})
