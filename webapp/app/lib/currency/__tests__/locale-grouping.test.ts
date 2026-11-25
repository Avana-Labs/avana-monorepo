import { afterEach, describe, expect, it } from "vitest"
import { currencyContext, formatExactCurrency, formatTokenQuantity } from "@/app/lib/currency/format"
import { getActiveLocale, setActiveLocale } from "@/app/lib/currency/active-rate"

// The formatters read the module-level active locale; reset to the en-US default after each test
// so ordering never leaks (mirrors setActiveCurrency usage in the chart tests).
afterEach(() => {
  // "EN" maps to "en" → en-US-equivalent grouping; the default the rest of the suite relies on.
  setActiveLocale("EN")
})

describe("locale-aware number grouping (C16 middle-path)", () => {
  it("defaults to en-US grouping so existing output is unchanged", () => {
    expect(getActiveLocale()).toBe("en-US")
    expect(formatExactCurrency(1_234_567.89, currencyContext("USD"))).toBe("$1,234,567.89")
  })

  it("German locale uses '.' grouping and ',' decimals — with the custom symbol preserved", () => {
    setActiveLocale("DE")
    // Symbol stays the app's custom prefix; only the number grouping/decimals localize.
    expect(formatExactCurrency(1_234_567.89, currencyContext("USD"))).toBe("$1.234.567,89")
  })

  it("Indian locale groups in lakhs/crores (12,34,567 not 1,234,567)", () => {
    setActiveLocale("HI")
    expect(formatExactCurrency(1_234_567, currencyContext("USD"))).toBe("$12,34,567.00")
  })

  it("token quantities localize their grouping too", () => {
    setActiveLocale("DE")
    expect(formatTokenQuantity(1_234.5, "GHO")).toBe("1,23K GHO")
  })

  it("switching back to English restores en-US grouping", () => {
    setActiveLocale("DE")
    setActiveLocale("EN")
    expect(formatExactCurrency(1_234.5, currencyContext("USD"))).toBe("$1,234.50")
  })
})
