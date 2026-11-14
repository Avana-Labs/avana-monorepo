import { describe, expect, it } from "vitest"
import { formatChartAxis, formatChartValue } from "@/app/components/charts/format"

/**
 * #42 — negative currency values must place the sign BEFORE the symbol
 * ("-$1.50K"), never after it ("$-1.50K"). Default active currency is USD.
 */
describe("chart currency sign placement", () => {
  it("formatChartValue puts the minus before the symbol", () => {
    expect(formatChartValue("usdCompact", -1_500)).toBe("-$1.50K")
    expect(formatChartValue("usdCompact", 1_500)).toBe("$1.50K")
    expect(formatChartValue("usd", -2_500.5)).toBe("-$2,500.50")
  })

  it("formatChartAxis puts the minus before the symbol", () => {
    expect(formatChartAxis("usdCompact", -1_500)).toBe("-$1.5K")
    expect(formatChartAxis("usd", -42)).toBe("-$42")
  })
})
