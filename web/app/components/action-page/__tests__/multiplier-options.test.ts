import { describe, expect, it } from "vitest"
import { buildMultiplierOptions, clampMultiplierToOptions } from "@/app/components/action-page/multiplier-options"

describe("buildMultiplierOptions", () => {
  it("never produces an option above the public maximum (floors, never rounds up)", () => {
    const options = buildMultiplierOptions(1.75)
    expect(Math.max(...options)).toBeLessThanOrEqual(1.75)
    expect(options).toEqual([1.5, 1.7])
  })

  it("includes standard presets within range plus the floored cap", () => {
    expect(buildMultiplierOptions(2.5)).toEqual([1.5, 2, 2.5])
    expect(buildMultiplierOptions(3)).toEqual([1.5, 2, 3])
    expect(buildMultiplierOptions(10)).toEqual([1.5, 2, 3, 5, 7, 10])
  })

  it("falls back to a usable option for degenerate maxima", () => {
    const options = buildMultiplierOptions(Number.NaN)
    expect(options.length).toBeGreaterThan(0)
    expect(Math.max(...options)).toBeLessThanOrEqual(5)
  })
})

describe("clampMultiplierToOptions", () => {
  const options = [1.5, 1.7]

  it("keeps a value that is already a valid option", () => {
    expect(clampMultiplierToOptions(1.7, options)).toBe(1.7)
  })

  it("snaps an out-of-range value down to the largest valid option", () => {
    // The classic bug: default 2 on a 1.7x-max market must not stay at 2.
    expect(clampMultiplierToOptions(2, options)).toBe(1.7)
  })

  it("snaps a below-range value up to the smallest option", () => {
    expect(clampMultiplierToOptions(1.1, options)).toBe(1.5)
  })

  it("keeps standard 2x when it is a valid option", () => {
    expect(clampMultiplierToOptions(2, [1.5, 2, 3, 5])).toBe(2)
  })
})
