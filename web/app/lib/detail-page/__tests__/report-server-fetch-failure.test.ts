import { afterEach, describe, expect, it, vi } from "vitest"
import { reportServerFetchFailure } from "../report-server-fetch-failure"

describe("server fetch telemetry", () => {
  afterEach(() => vi.restoreAllMocks())

  it("includes product, route, slug, and Convex query labels", () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined)

    reportServerFetchFailure("fetchBorrowPoolDetailHydration", new Error("timeout"), {
      product: "borrow",
      route: "/borrow/markets/eth-usdt",
      slug: "eth-usdt",
      query: "detailHydration.getBorrowPoolDetail",
    })

    expect(warning).toHaveBeenCalledWith(
      expect.stringContaining(
        "fetchBorrowPoolDetailHydration product=borrow route=/borrow/markets/eth-usdt slug=eth-usdt query=detailHydration.getBorrowPoolDetail",
      ),
    )
  })
})
