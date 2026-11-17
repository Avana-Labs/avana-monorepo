import { describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/data/providers/borrow", () => ({
  fetchBorrowPage: async () => ({
    poolCatalog: [{ id: "uniswap-v3-usdc-usdt-100-univ3stable", name: "USDC / USDT" }],
    borrowableAssets: [{ id: "gho", symbol: "GHO" }],
  }),
}))
vi.mock("@/app/lib/lend-system/market-hydration-server", () => ({
  fetchLendMarketSnapshots: async () => [
    {
      slug: "ethereum-gho",
      scope: "lend",
      name: "Gho Token",
      symbol: "GHO",
      category: "stable",
      suppliedUsd: 100,
      borrowedUsd: 10,
      availableUsd: 90,
      utilizationPct: 10,
      supplyApyPct: 3,
    },
  ],
}))

describe("buildSearchIndex", () => {
  it("lists the Borrow page's pools and assets and the Lend markets", async () => {
    const { buildSearchIndex } = await import("../search-index-server")
    const index = await buildSearchIndex()
    expect(index.pools.map((pool) => pool.id)).toEqual(["uniswap-v3-usdc-usdt-100-univ3stable"])
    expect(index.assets.map((asset) => asset.id)).toEqual(["gho"])
    expect(index.lendMarkets.map((market) => [market.marketId, market.asset.name])).toEqual([
      ["ethereum-gho", "Gho Token"],
    ])
  })
})
