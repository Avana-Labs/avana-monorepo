import { describe, expect, it } from "vitest"
import { multiplyNetApyFraction } from "@/app/lib/multiply-system/read-model"

describe("multiplyNetApyFraction — canonical equity-weighted blend", () => {
  it("weights each position's netApy by net equity (collateral − debt), not by collateral", () => {
    // A: equity 100 (col 300, debt 200), netApy 10%. B: equity 900 (col 1000, debt 100), netApy 2%.
    const positions = [
      { collateralValueUsd: 300, debtValueUsd: 200, netApy: 0.1 },
      { collateralValueUsd: 1000, debtValueUsd: 100, netApy: 0.02 },
    ]
    // Equity-weighted: (100*0.1 + 900*0.02) / 1000 = 0.028
    expect(multiplyNetApyFraction(positions)).toBeCloseTo(0.028, 10)
    // Collateral-weighted (the OLD dashboard blend) would be (300*0.1 + 1000*0.02)/1300 ≈ 0.0385 — different.
    expect(multiplyNetApyFraction(positions)).not.toBeCloseTo(0.0385, 4)
  })

  it("returns 0 with no positions or zero total equity", () => {
    expect(multiplyNetApyFraction([])).toBe(0)
    expect(multiplyNetApyFraction([{ collateralValueUsd: 100, debtValueUsd: 100, netApy: 0.5 }])).toBe(0)
  })
})
