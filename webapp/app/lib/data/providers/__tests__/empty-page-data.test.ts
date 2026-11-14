import { describe, expect, it, vi } from "vitest"

// No services/convex deployment: every snapshot read comes back empty.
vi.mock("@/app/lib/borrow-system/market-hydration-server", () => ({ fetchConvexMarketSnapshots: async () => [] }))
vi.mock("@/app/lib/lend-system/market-hydration-server", () => ({ fetchLendMarketSnapshots: async () => [] }))

import { fetchBorrowPage } from "@/app/lib/data/providers/borrow/fetch-borrow-page"
import { fetchLendPage } from "@/app/lib/data/providers/lend/fetch-lend-page"

describe("page data without market snapshots", () => {
  it("serves an empty Borrow page that passes its schema", async () => {
    const page = await fetchBorrowPage()
    expect(page.poolCatalog).toEqual([])
    expect(page.borrowableAssets).toEqual([])
    expect(page.heroMetrics.totalTvlUsd).toBe(0)
  })

  it("serves an empty Lend page that passes its schema", async () => {
    const page = await fetchLendPage()
    expect(page.markets).toEqual([])
    expect(page.featuredSnapshots).toEqual([])
  })
})
