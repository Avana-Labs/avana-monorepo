import { describe, expect, it } from "vitest"
import { getMultiplyMarketDetail, withLiveMultiplyRates } from "@/app/lib/multiply-detail"

// Prod 2026-09-23: wstETH/ETH read 10.50% APY / CF 90% on the Multiply list but Net APY 9.70% and
// CF 91% on its detail page, which showed catalog estimates instead of the live snapshot.
describe("withLiveMultiplyRates", () => {
  it("uses the list's live Net APY and collateral factor", () => {
    const detail = getMultiplyMarketDetail("wsteth-eth")!
    const live = withLiveMultiplyRates(detail, { supplyApyPct: 5.3, borrowAprPct: 4, maxLtvPct: 90 })
    const rate = (id: string) => live.marketRates.find((stat) => stat.id === id)?.value
    expect(rate("netApy")).toBe("10.50%")
    expect(rate("collateralFactor")).toBe("90%")
    expect(live.quickStats.find((stat) => stat.id === "profitability")?.value).toBe("10.50%")
    expect(live.row.collateralFactor).toBe(0.9)
  })

  it("leaves the detail unchanged without a snapshot", () => {
    const detail = getMultiplyMarketDetail("wsteth-eth")!
    expect(withLiveMultiplyRates(detail, null)).toBe(detail)
  })
})
