import { describe, expect, it } from "vitest"
import { getDeleverageMultiplierMax, isDeleverageCloseOnly } from "@/app/lib/multiply-system/leverage-limits"

describe("deleverage leverage limits", () => {
  it("p0-09: near-1x positions are close-only (no 1x→1x slider trap)", () => {
    expect(getDeleverageMultiplierMax(1)).toBe(1)
    expect(isDeleverageCloseOnly(1)).toBe(true)
    expect(isDeleverageCloseOnly(1.05)).toBe(true)
    expect(isDeleverageCloseOnly(2)).toBe(false)
    expect(getDeleverageMultiplierMax(2)).toBe(1.9)
  })
})
