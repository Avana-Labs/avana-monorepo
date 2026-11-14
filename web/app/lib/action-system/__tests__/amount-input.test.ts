import { describe, expect, it } from "vitest"
import {
  parseActionPercentBps,
  parsePositiveActionAmount,
  sanitizeDecimalInput,
} from "@/app/lib/action-system/amount-input"
import { parseFixed } from "@/app/lib/borrow-system/model"

describe("action amount parsing", () => {
  it.each(["1abc", "1.2.3", "1,000", "Infinity", "NaN", "-1", "0", ""])("rejects malformed amount %s", (value) => {
    expect(parsePositiveActionAmount(value)).toBeNull()
  })

  it("accepts complete positive decimal input", () => {
    expect(parsePositiveActionAmount("12.34")).toBe(12.34)
    expect(parsePositiveActionAmount(".5")).toBe(0.5)
    expect(parsePositiveActionAmount("1.")).toBe(1)
  })

  it("validates decimal input non-destructively while typing", () => {
    expect(sanitizeDecimalInput("qqqqqq")).toBe("")
    // Comma is the decimal separator in de/fr/es/…: "1,5" is 1.5, never 15.
    expect(sanitizeDecimalInput("1,5")).toBe("1.5")
    // An invalid character stops parsing instead of concatenating the digits around it.
    expect(sanitizeDecimalInput("12a3.4b5")).toBe("12")
    expect(sanitizeDecimalInput("1e9")).toBe("1")
    expect(sanitizeDecimalInput("-5")).toBe("")
    // A stray second separator is dropped rather than merging the fraction groups.
    expect(sanitizeDecimalInput("1.2.3")).toBe("1.2")
    expect(sanitizeDecimalInput("12.34.56")).toBe("12.34")
    // Stays incremental-typing friendly: a trailing/leading separator is preserved.
    expect(sanitizeDecimalInput("1.")).toBe("1.")
    expect(sanitizeDecimalInput(".5")).toBe(".5")
    expect(sanitizeDecimalInput("12.34")).toBe("12.34")
  })

  it("converts percentages to integer basis points within 0-100%", () => {
    expect(parseActionPercentBps("25")).toBe(2500)
    expect(parseActionPercentBps("12.345")).toBe(1235)
    expect(parseActionPercentBps("100.1")).toBeNull()
    expect(parseActionPercentBps("50abc")).toBeNull()
  })

  it("rejects amounts at or beyond the exponential-notation threshold (>=1e21)", () => {
    // Regression: 1e30 was accepted, then Number#toFixed(6) returned "1e+30"
    // which parseFixed rejected by throwing, crashing the borrow preview.
    expect(parsePositiveActionAmount("1000000000000000000000000000000")).toBeNull()
    expect(parsePositiveActionAmount("1e30")).toBeNull()
    expect(parsePositiveActionAmount(String(1e21))).toBeNull()
  })

  it("keeps accepted amounts safe to feed parseFixed via toFixed(6)", () => {
    const value = parsePositiveActionAmount("12345.6789")
    expect(value).not.toBeNull()
    const fixed = value!.toFixed(6)
    expect(fixed).not.toMatch(/e/i)
    expect(() => parseFixed(fixed, 6)).not.toThrow()
  })
})
