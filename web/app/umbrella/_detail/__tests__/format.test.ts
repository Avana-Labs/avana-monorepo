import { describe, expect, it } from "vitest"
import { formatCompactUsd as canonicalCompact, formatUsdExact } from "@/app/lib/borrow-sim"
import { formatCompactUsd, formatPct, formatUsd } from "@/app/umbrella/_detail/format"

// Regression: Umbrella surfaces must render money through the same currency-aware
// canonical formatters as the rest of Avana. Previously these hardcoded "$" and
// ignored the active currency, so picking EUR left the Umbrella block in USD while
// the surrounding page converted — mixed €/$ on one screen (dashboard + /umbrella).
describe("umbrella formatters delegate to the currency-aware canonical helpers", () => {
  it("formatUsd is exactly formatUsdExact (currency-aware, shared cents policy)", () => {
    expect(formatUsd(25_000)).toBe(formatUsdExact(25_000))
    expect(formatUsd(44.32)).toBe(formatUsdExact(44.32))
    expect(formatUsd(0)).toBe(formatUsdExact(0))
  })

  it("formatCompactUsd is the canonical compact — real K/M/B, no $2000.00M overflow", () => {
    expect(formatCompactUsd(1_500_000)).toBe(canonicalCompact(1_500_000))
    expect(formatCompactUsd(2_000_000_000)).toBe(canonicalCompact(2_000_000_000))
    expect(formatCompactUsd(2_000_000_000)).toContain("B")
  })

  it("formatPct is a bare percent body (callers append %), variable precision", () => {
    expect(formatPct(6.4)).toBe("6.4")
    expect(formatPct(5)).toBe("5")
    expect(formatPct(4.84)).toBe("4.84")
  })
})
