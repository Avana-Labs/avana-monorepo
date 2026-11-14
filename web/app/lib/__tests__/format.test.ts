import { describe, expect, it } from "vitest"
import { formatApy, formatPercent } from "@/app/lib/format"

describe("formatPercent", () => {
  it("defaults to two decimals", () => {
    expect(formatPercent(5.3)).toBe("5.30%")
    expect(formatPercent(30.1)).toBe("30.10%")
    expect(formatPercent(0.49)).toBe("0.49%")
  })

  it("honors a custom decimal count", () => {
    expect(formatPercent(37.104, { dp: 1 })).toBe("37.1%")
    expect(formatPercent(62.1, { dp: 0 })).toBe("62%")
  })

  it("prefixes a plus sign for positive values when asked", () => {
    expect(formatPercent(2.5, { sign: true })).toBe("+2.50%")
    expect(formatPercent(-2.5, { sign: true })).toBe("-2.50%")
    expect(formatPercent(0, { sign: true })).toBe("0.00%")
  })

  it("renders an em dash for non-finite input", () => {
    expect(formatPercent(Number.NaN)).toBe("—")
    expect(formatPercent(Number.POSITIVE_INFINITY)).toBe("—")
  })
})

describe("formatApy", () => {
  it("uses the 2dp asset convention", () => {
    expect(formatApy(5.3)).toBe("5.30%")
  })
})
