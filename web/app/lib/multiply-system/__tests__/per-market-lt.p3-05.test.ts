import { describe, expect, it } from "vitest"
import { buildMockMultiplySystemStateWithSeedPosition } from "@/app/lib/multiply-system/mock"
import { buildPortfolioMultiplyData } from "@/app/lib/multiply-system/read-model"

describe("multiply liquidation threshold", () => {
  it("P3-05: derives liquidation threshold from per-market LT instead of flat 0.85", () => {
    const state = buildMockMultiplySystemStateWithSeedPosition("demo-wallet")
    const data = buildPortfolioMultiplyData("demo-wallet", state)
    const positions = Object.values(state.positions).filter((position) => position.walletId === "demo-wallet")
    const weightedLt =
      positions.reduce((sum, position) => {
        const market = state.markets[position.marketId]!
        return sum + position.collateralValueUsd * market.risk.liquidationThreshold
      }, 0) / positions.reduce((sum, position) => sum + position.collateralValueUsd, 0)

    expect(data.creditLines.liquidationThresholdUsd).toBeCloseTo(data.creditLines.totalCollateralUsd * weightedLt, 2)
  })
})
