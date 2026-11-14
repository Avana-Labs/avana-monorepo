import { describe, expect, it } from "vitest"
import { formatHealthFactor } from "@/app/lib/home-view-model"

describe("formatHealthFactor", () => {
  it("renders a normal leveraged health factor with two decimals", () => {
    expect(formatHealthFactor(1.8)).toBe("1.80")
    expect(formatHealthFactor(2.664567)).toBe("2.66")
  })

  it("renders ∞ for a non-finite health factor", () => {
    expect(formatHealthFactor(Number.POSITIVE_INFINITY)).toBe("∞")
  })

  it("caps a meaninglessly-large finite health factor as ∞ instead of a raw number", () => {
    // A dust-sized debt against real collateral yields a huge-but-finite HF
    // (the QA reported 18369.7). It must read "∞", never the raw figure.
    expect(formatHealthFactor(18_369.7)).toBe("∞")
    expect(formatHealthFactor(1_000)).toBe("∞")
    // Just below the threshold still prints the number.
    expect(formatHealthFactor(999.99)).toBe("999.99")
  })

  it("renders — only when the health factor is unknown", () => {
    expect(formatHealthFactor(null)).toBe("—")
    expect(formatHealthFactor(Number.NaN)).toBe("—")
  })
})
