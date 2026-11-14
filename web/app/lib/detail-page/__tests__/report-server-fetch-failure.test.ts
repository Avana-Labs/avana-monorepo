import { afterEach, describe, expect, it, vi } from "vitest"
import { reportServerFetchFailure } from "../report-server-fetch-failure"

describe("server fetch telemetry", () => {
  afterEach(() => vi.restoreAllMocks())

  it("includes product, route, slug, and Convex query labels", () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined)

    reportServerFetchFailure("fetchMultiplyDetailHydration", new Error("timeout"), {
      product: "multiply",
      route: "/multiply/markets/eth-usdt",
      slug: "eth-usdt",
      query: "detailHydration.getMultiplyDetail",
    })

    expect(warning).toHaveBeenCalledWith(
      expect.stringContaining(
        "fetchMultiplyDetailHydration product=multiply route=/multiply/markets/eth-usdt slug=eth-usdt query=detailHydration.getMultiplyDetail",
      ),
    )
  })
})
