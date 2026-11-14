import { describe, expect, it } from "vitest"
import {
  MULTIPLY_ACTION_MAX_LEVERAGE,
  MULTIPLY_ACTION_SLIDER_MAX,
  MULTIPLY_ACTION_SLIDER_STEP,
  getDeleverageMultiplierMax,
  getDefaultDeleverageMultiplier,
  resolveDefaultMultiplyLeverage,
  resolveMultiplyMarketMaxLeverage,
  snapMultiplierToStep,
} from "@/app/lib/multiply-system/leverage-limits"

describe("resolveMultiplyMarketMaxLeverage", () => {
  it("passes the (uninflated) catalog cap through as the public-cap helper", () => {
    expect(resolveMultiplyMarketMaxLeverage(1.8)).toBe(1.8)
  })

  it("never exceeds the global action ceiling", () => {
    expect(resolveMultiplyMarketMaxLeverage(60)).toBe(MULTIPLY_ACTION_MAX_LEVERAGE)
  })

  it("falls back to the global maximum for invalid market caps", () => {
    expect(resolveMultiplyMarketMaxLeverage(undefined)).toBe(MULTIPLY_ACTION_MAX_LEVERAGE)
    expect(resolveMultiplyMarketMaxLeverage(Number.NaN)).toBe(MULTIPLY_ACTION_MAX_LEVERAGE)
  })

  it("documents that the multiply slider ceiling is 9.99 with 0.01 steps, not per-market public max", () => {
    // Slider range is MULTIPLY_ACTION_SLIDER_*; publicMax is a validation hard-block.
    expect(MULTIPLY_ACTION_MAX_LEVERAGE).toBe(10)
    expect(MULTIPLY_ACTION_SLIDER_MAX).toBe(9.99)
    expect(MULTIPLY_ACTION_SLIDER_STEP).toBe(0.01)
    expect(resolveMultiplyMarketMaxLeverage(1.8)).toBeLessThan(MULTIPLY_ACTION_SLIDER_MAX)
  })

  it("defaults deleverage below the current multiplier", () => {
    expect(getDefaultDeleverageMultiplier(2)).toBe("1.5")
    expect(getDefaultDeleverageMultiplier(1.2)).toBe("1")
    expect(getDefaultDeleverageMultiplier(Number.NaN)).toBe("1")
  })

  it("defaults new positions to conservative leverage within market limits", () => {
    expect(resolveDefaultMultiplyLeverage(4, 3)).toBe(1.1)
    expect(resolveDefaultMultiplyLeverage(1.3, 1.2)).toBe(1.1)
  })

  it("caps deleverage at a valid target below the current multiplier", () => {
    expect(getDeleverageMultiplierMax(2)).toBe(1.9)
    expect(getDeleverageMultiplierMax(1.6)).toBe(1.5)
    expect(getDeleverageMultiplierMax(Number.NaN)).toBe(1)
  })
})

describe("snapMultiplierToStep", () => {
  it("snaps to the slider step grid (same rule the ruler thumb uses)", () => {
    // 1.75 sits on a half-step; the slider rounds it to 1.8, so the controlled
    // state must land there too (E6: slider/number/summary share ONE value).
    expect(snapMultiplierToStep(1.75, 1, 1.8, 0.1)).toBe(1.8)
    expect(snapMultiplierToStep(1.73, 1, 1.8, 0.1)).toBe(1.7)
    expect(snapMultiplierToStep(1.2, 1, 2, 0.1)).toBe(1.2)
  })

  it("preserves hundredths on the 0.01 multiply slider grid", () => {
    expect(snapMultiplierToStep(1.75, 1, 9.99, 0.01)).toBe(1.75)
    expect(snapMultiplierToStep(6.7, 1, 9.99, 0.01)).toBe(6.7)
    expect(snapMultiplierToStep(9.99, 1, 9.99, 0.01)).toBe(9.99)
  })

  it("clamps to the [min, max] range", () => {
    expect(snapMultiplierToStep(9, 1, 1.8, 0.1)).toBe(1.8)
    expect(snapMultiplierToStep(0.4, 1, 1.8, 0.1)).toBe(1)
  })
})
