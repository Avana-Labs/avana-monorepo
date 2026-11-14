import { describe, expect, it } from "vitest"
import { deriveLendPositionAmounts } from "@/app/lib/lend-system/use-lend-session"

describe("deriveLendPositionAmounts — token vs USD units (C14)", () => {
  it("stablecoin ($1) position is unchanged (token == USD)", () => {
    const a = deriveLendPositionAmounts(10_000, 125, 1)
    expect(a.suppliedAmount).toBeCloseTo(10_000, 6)
    expect(a.interestEarnedAmount).toBeCloseTo(125, 6)
    expect(a.principalAmount).toBeCloseTo(9_875, 6)
  })

  it("ETH (~$1,934) position converts USD figures into TOKEN amounts, not 1934× inflated", () => {
    // 5 ETH supplied ($9,670), 0.08 ETH earned ($154.72).
    const price = 1934
    const a = deriveLendPositionAmounts(5 * price, 0.08 * price, price)
    expect(a.suppliedAmount).toBeCloseTo(5, 6)
    expect(a.interestEarnedAmount).toBeCloseTo(0.08, 6)
    expect(a.principalAmount).toBeCloseTo(4.92, 6)
    // Guard against the old bug: interest must be ~0.08 tokens, NOT ~154 (USD stuffed into a token field).
    expect(a.interestEarnedAmount).toBeLessThan(1)
  })

  it("interest × price reconstructs the earned USD (the invariant consumers rely on)", () => {
    const price = 64_000
    const earnedUsd = 128
    const a = deriveLendPositionAmounts(0.25 * price, earnedUsd, price)
    expect(a.interestEarnedAmount * price).toBeCloseTo(earnedUsd, 4)
  })

  it("falls back to a $1 price when the asset price is missing or non-positive", () => {
    expect(deriveLendPositionAmounts(100, 5, undefined).interestEarnedAmount).toBe(5)
    expect(deriveLendPositionAmounts(100, 5, 0).interestEarnedAmount).toBe(5)
  })
})
