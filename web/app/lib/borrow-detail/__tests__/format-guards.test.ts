import { describe, expect, it } from "vitest"
import { formatOraclePrice } from "@/app/lib/borrow-detail/formatters"
import { formatBpsAsPct } from "@/app/lib/borrow-detail/allocation"
import { aprRangeLabel, formatRiskPremium } from "@/app/lib/borrow-sim"
import type { BorrowPoolRow } from "@/app/lib/borrow-sim"

/**
 * Guard regression: presentational formatters must never surface "$NaN" / "NaN%"
 * when an upstream value is non-finite (missing oracle price, empty pool, etc.).
 * They fall back to the em-dash placeholder instead. (#22/#28)
 */
describe("formatter finite guards", () => {
  it("formatOraclePrice returns — for non-finite input", () => {
    expect(formatOraclePrice(Number.NaN)).toBe("—")
    expect(formatOraclePrice(Number.POSITIVE_INFINITY)).toBe("—")
    // Finite values still format normally.
    expect(formatOraclePrice(3102.55)).toBe("$3,102.55")
  })

  it("formatBpsAsPct returns — for non-finite input", () => {
    expect(formatBpsAsPct(Number.NaN)).toBe("—")
    expect(formatBpsAsPct(80)).toBe("+0.80%")
  })

  it("formatRiskPremium returns — for non-finite input", () => {
    expect(formatRiskPremium(Number.NaN)).toBe("—")
    expect(formatRiskPremium(120)).toBe("+1.20%")
  })

  it("aprRangeLabel returns — when either bound is non-finite", () => {
    const pool = { aprMin: Number.NaN, aprMax: 5 } as BorrowPoolRow
    expect(aprRangeLabel(pool)).toBe("—")
    expect(aprRangeLabel({ aprMin: 3, aprMax: 5 } as BorrowPoolRow)).toBe("3.0–5.0%")
  })
})
