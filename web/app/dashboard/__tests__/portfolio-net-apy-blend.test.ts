import { describe, expect, it } from "vitest"
import { blendEquityWeightedNetApyPct } from "@/app/dashboard/portfolio-headline-metrics"
import { estimateBorrowNetApyPctFromRows } from "@/app/dashboard/dashboard-tab-metrics"
import type { DebtRowContext, SupplyRowContext } from "@/app/lib/data/borrow-position-types"

describe("multi-product portfolio Net APY blend (fetch → formula)", () => {
  it("blends Lend + Borrow + Multiply equities the way the dashboard hook does", () => {
    const lend = { equityUsd: 10_000, netApyPct: 5 }
    const borrow = { equityUsd: 6_000, netApyPct: -2 }
    const multiply = { equityUsd: 4_000, netApyPct: 12 }
    // (5*10k + -2*6k + 12*4k) / 20k = (50k - 12k + 48k) / 20k = 4.3
    expect(blendEquityWeightedNetApyPct([lend, borrow, multiply])).toBeCloseTo(4.3, 6)
  })
})

describe("estimateBorrowNetApyPctFromRows edge cases", () => {
  it("returns 0 when equity is zero or negative", () => {
    expect(estimateBorrowNetApyPctFromRows(1_000, 1_000, [], [])).toBe(0)
    expect(estimateBorrowNetApyPctFromRows(500, 800, [], [])).toBe(0)
  })

  it("ignores empty position lists without throwing", () => {
    expect(estimateBorrowNetApyPctFromRows(2_000, 500, [] as SupplyRowContext[], [] as DebtRowContext[])).toBe(0)
  })
})
