import { describe, expect, it } from "vitest"
import { formatActionUsd } from "@/app/lib/action-system/formatters"
import { formatCompactUsd, formatUsdExact } from "@/app/lib/borrow-market-rows"

// Currency layer is untouched here, so the active currency stays USD ("$"),
// which is what these assertions assume.
describe("USD formatter negative handling (#130)", () => {
  it("places the minus sign OUTSIDE the currency symbol, not inside", () => {
    expect(formatActionUsd(-500)).toBe("-$500")
    expect(formatUsdExact(-500)).toBe("-$500")
    expect(formatCompactUsd(-500)).toBe("-$500")
  })

  it("compacts negative magnitudes the same way as positives", () => {
    expect(formatActionUsd(-5000, { compact: true })).toBe("-$5.0K")
    expect(formatCompactUsd(-5000)).toBe("-$5.0K")
    expect(formatCompactUsd(-2_500_000)).toBe("-$2.5M")
  })

  it("never renders a negative sign for a value that rounds to zero (no $-0.00)", () => {
    expect(formatActionUsd(-0.001)).toBe("$0.00")
    expect(formatUsdExact(-0.004)).toBe("$0")
    expect(formatCompactUsd(-0.004)).toBe("$0")
    expect(formatCompactUsd(0)).toBe("$0")
  })

  it("leaves positive formatting unchanged", () => {
    expect(formatActionUsd(500)).toBe("$500")
    expect(formatActionUsd(1)).toBe("$1.00")
    expect(formatActionUsd(6_885_000_000, { compact: true })).toBe("$6.9B")
    expect(formatUsdExact(1234)).toBe("$1,234")
    expect(formatCompactUsd(5000)).toBe("$5.0K")
  })
})
