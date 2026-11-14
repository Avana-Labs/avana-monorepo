import { describe, expect, it } from "vitest"
import { buildRiskParameterSet, withEngineLiquidationThreshold } from "@/app/lib/borrow-detail/risk-parameters"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"

// Prod 2026-09-23: WBTC/USDC v2 read "LT: 75%" on the Borrow list and "Liquidation threshold 70%"
// on its detail page; the engine liquidates at 75%.
describe("withEngineLiquidationThreshold", () => {
  it("shows the engine threshold, not the seeded collateral factor + 5", () => {
    const parameters = buildRiskParameterSet({
      collateralFactorPct: 65,
      liquidationThresholdPct: 70,
      depositCapacityLabel: "$174.0M",
      borrowCapacityLabel: "$140.0M",
      liquidationPenaltyPct: 7,
    })
    const about = withEngineLiquidationThreshold({
      history: [],
      governanceParameters: { parameters, changelog: [] },
    } as never)
    const lt = about.governanceParameters?.parameters.find((parameter) => parameter.id === "liquidationThreshold")
    expect(lt?.value).toBe("75.00%")
    expect(liquidationThresholdPctFromMaxLtvPct(65)).toBe(75)
  })
})
