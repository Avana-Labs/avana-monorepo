import { describe, expect, it } from "vitest"
import { liquidationThresholdPctFromMaxLtvPct } from "@/app/lib/borrow-system/liquidation-threshold"

/**
 * #12 — the single client basis for an implied liquidation threshold. Must equal the Convex
 * persist gate's `liquidationThresholdFromMaxLtv` (maxLtv + 10pp, capped 95%) so a borrow the
 * preview shows as solvent is the same one the server accepts.
 */
describe("liquidationThresholdPctFromMaxLtvPct", () => {
  it("adds a 10pp spread above the collateral factor", () => {
    expect(liquidationThresholdPctFromMaxLtvPct(76.5)).toBeCloseTo(86.5, 6)
    expect(liquidationThresholdPctFromMaxLtvPct(64)).toBeCloseTo(74, 6)
  })

  it("caps at 95%", () => {
    expect(liquidationThresholdPctFromMaxLtvPct(90)).toBe(95)
    expect(liquidationThresholdPctFromMaxLtvPct(95)).toBe(95)
  })

  it("is always at least the collateral factor (LT ≥ CF)", () => {
    for (const cf of [10, 50, 70, 80, 88]) {
      expect(liquidationThresholdPctFromMaxLtvPct(cf)).toBeGreaterThanOrEqual(cf)
    }
  })
})
