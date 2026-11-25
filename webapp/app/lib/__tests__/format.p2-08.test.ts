import { describe, expect, it } from "vitest"
import { formatCompactUsd, formatUsd, formatUsdExact } from "@/app/lib/format"

describe("consolidated USD/APR formatters", () => {
  it("P2-08: re-exports borrow-sim USD helpers and keeps APR on format.ts", () => {
    expect(formatUsd(1234)).toBe(formatUsdExact(1234))
    expect(formatCompactUsd(5000)).toBe("$5.0K")
  })

  it("canonical USD formatters never emit $NaN for non-finite input (#40)", () => {
    expect(formatUsdExact(Number.NaN)).toBe("—")
    expect(formatUsd(Number.POSITIVE_INFINITY)).toBe("—")
    expect(formatCompactUsd(Number.NaN)).toBe("—")
  })
})
