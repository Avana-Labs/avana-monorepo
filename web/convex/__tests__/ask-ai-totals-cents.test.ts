import { describe, expect, it } from "vitest"
import { toCentsTotals } from "../askAITools"

describe("Ask AI portfolio totals are handed to the model in cents", () => {
  it("rounds every *Usd total and rebuilds Net Value from the rounded components", () => {
    const totals = toCentsTotals({
      lendNetValueUsd: 300152.8922330352,
      borrowNetValueUsd: 346584.49686099996,
      multiplyNetValueUsd: 209040.26404174074,
      liquidNetValueUsd: 106950.47898141458,
      netValueUsd: 962728.1321171904,
      openPositionCount: 7,
      largestPositionLabel: "Borrow WETH",
      netApyPct: 4.123456,
    })
    expect(totals).toEqual({
      lendNetValueUsd: 300152.89,
      borrowNetValueUsd: 346584.5,
      multiplyNetValueUsd: 209040.26,
      liquidNetValueUsd: 106950.48,
      netValueUsd: 962728.13,
      openPositionCount: 7,
      largestPositionLabel: "Borrow WETH",
      netApyPct: 4.123456,
    })
    const parts =
      totals.lendNetValueUsd + totals.borrowNetValueUsd + totals.multiplyNetValueUsd + totals.liquidNetValueUsd
    expect(Math.round(parts * 100) / 100).toBe(totals.netValueUsd)
  })
})
