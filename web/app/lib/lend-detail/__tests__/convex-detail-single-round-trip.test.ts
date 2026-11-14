import { describe, expect, it, vi } from "vitest"

vi.mock("server-only", () => ({}))

const { calls } = vi.hoisted(() => ({ calls: [] as string[] }))

vi.mock("@/app/lib/lend-system/market-hydration-server", () => {
  return {
    fetchLendDetailHydration: async () => {
      calls.push("detailHydration")
      return null
    },
  }
})

import { getLendMarketDetailFromConvex } from "@/app/lib/lend-detail/convex-detail"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/market-ids"

describe("lend detail SSR", () => {
  it("uses one product-scoped Convex detail batch", async () => {
    await getLendMarketDetailFromConvex(LEND_MARKET_CATALOG[0].marketId)
    expect(calls).toEqual(["detailHydration"])
  })
})
