import { describe, expect, it } from "vitest"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"

/**
 * The single client basis for a liquidation threshold. In Aave V4 the liquidation threshold equals
 * the collateral factor (REQ-LENS-045), capped at 95%.
 */
describe("liquidationThresholdPctFromMaxLtvPct", () => {
  it("equals the collateral factor", () => {
    expect(liquidationThresholdPctFromMaxLtvPct(76.5)).toBeCloseTo(76.5, 6)
    expect(liquidationThresholdPctFromMaxLtvPct(64)).toBeCloseTo(64, 6)
  })

  it("caps at 95%", () => {
    expect(liquidationThresholdPctFromMaxLtvPct(90)).toBe(90)
    expect(liquidationThresholdPctFromMaxLtvPct(97)).toBe(95)
  })

  it("is always at least the collateral factor (LT ≥ CF)", () => {
    for (const cf of [10, 50, 70, 80, 88]) {
      expect(liquidationThresholdPctFromMaxLtvPct(cf)).toBeGreaterThanOrEqual(cf)
    }
  })
})
