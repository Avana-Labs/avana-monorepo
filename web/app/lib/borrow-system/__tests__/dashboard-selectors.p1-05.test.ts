import { describe, expect, it } from "vitest"
import { accrueBorrowSystemState } from "@/app/lib/borrow-system/model"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { selectPortfolioSupplyRows } from "@/app/lib/borrow-system/dashboard-selectors"

const DAY_MS = 24 * 60 * 60 * 1000

describe("portfolio supply fee totals", () => {
  it("p1-05: supply rows surface accrued LP interest instead of hardcoded feesUsd: 0", () => {
    const seeded = buildMockBorrowSystemState("demo-wallet")
    const state = accrueBorrowSystemState(seeded, seeded.now + 30 * DAY_MS)
    const supplies = selectPortfolioSupplyRows(state, "demo-wallet")
    const pledged = supplies.filter((row) => row.pool.collateralUsd > 0)

    expect(pledged.length).toBeGreaterThan(0)
    expect(pledged.some((row) => row.feesUsd > 0)).toBe(true)
    expect(pledged.every((row) => row.feesLabel !== "$0.00" || row.feesUsd === 0)).toBe(true)
  })
})
