import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const queries: Record<string, unknown> = {}

vi.mock("convex/browser", () => ({
  ConvexHttpClient: class {
    async query(ref: unknown) {
      return queries[String((ref as { _name?: string })?._name ?? ref)]
    }
  },
}))
vi.mock("@/convex/_generated/api", () => ({
  api: {
    markets: { listLendMarketSnapshots: { _name: "lend" } },
    prices: { getPriceSnapshot: { _name: "prices" } },
  },
}))

describe("fetchLendMarketSnapshots", () => {
  beforeEach(() => {
    vi.stubEnv("NEXT_PUBLIC_CONVEX_URL", "http://127.0.0.1:3210")
    queries.lend = [
      {
        slug: "ethereum-gho",
        scope: "lend",
        name: "Gho Token",
        symbol: "GHO",
        category: "stable",
        chainId: 31337,
        hubId: "0xfca00efc152761b68fd1e00276d2694bb08952dd",
        hubLabel: "Avana Ethereum Hub",
        suppliedUsd: 100,
        borrowedUsd: 10,
        availableUsd: 90,
        utilizationPct: 10,
        supplyApyPct: 1,
      },
    ]
    queries.prices = { prices: [], status: { invalidAfterMs: 0 } }
  })
  afterEach(() => vi.unstubAllEnvs())

  it("keeps each market's category, Hub and chain for the list grouping", async () => {
    const { fetchLendMarketSnapshots } = await import("../market-hydration-server")
    const [row] = await fetchLendMarketSnapshots()
    expect(row).toMatchObject({
      category: "stable",
      chainId: 31337,
      hubId: "0xfca00efc152761b68fd1e00276d2694bb08952dd",
      hubLabel: "Avana Ethereum Hub",
    })
  })
})
