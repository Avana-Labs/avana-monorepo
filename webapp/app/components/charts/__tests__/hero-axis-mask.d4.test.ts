import { describe, expect, it } from "vitest"
import { heroAxisFormatter, HERO_AXIS_MASK } from "@/app/components/charts/market-hero-chart"
import { formatChartAxis } from "@/app/components/charts/format"

describe("hero chart Y-axis privacy mask (D4)", () => {
  it("masks the axis labels when amounts are hidden", () => {
    const fmt = heroAxisFormatter("usdCompact", true)
    expect(fmt(40700)).toBe(HERO_AXIS_MASK)
    expect(fmt(1_234_567)).toBe(HERO_AXIS_MASK)
  })

  it("shows real axis labels when amounts are visible", () => {
    const fmt = heroAxisFormatter("usdCompact", false)
    expect(fmt(40700)).toBe(formatChartAxis("usdCompact", 40700))
  })
})
