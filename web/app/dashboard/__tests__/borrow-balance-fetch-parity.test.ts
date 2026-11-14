import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/borrow-system/model/__tests__/fixtures"
import { buildPortfolioBorrowData } from "@/app/lib/borrow-system/read-model"
import { buildBorrowBalanceMetrics } from "@/app/dashboard/dashboard-tab-metrics"

describe("Borrow Balance fetching parity", () => {
  it("creditLines.approvedUsd matches Available to Borrow from the balance builder", () => {
    const state = makeExampleBorrowSystemState()
    const tab = buildPortfolioBorrowData(state, "wallet-1", state.now)
    const balance = buildBorrowBalanceMetrics(state, "wallet-1", state.now)

    expect(tab.creditLines.approvedUsd).toBeCloseTo(balance.availableToBorrowUsd, 4)
    expect(tab.creditLines.totalCollateralUsd).toBeCloseTo(balance.collateralValueUsd, 4)
    expect(tab.creditLines.totalBorrowedUsd).toBeCloseTo(balance.totalBorrowedUsd, 4)
    expect(tab.creditLines.averageHealthFactor).toBeCloseTo(balance.healthFactor!, 4)
  })

  it("sums interest owed across every debt row for multi-debt wallets", () => {
    const state = makeExampleBorrowSystemState()
    const tab = buildPortfolioBorrowData(state, "wallet-1", state.now)
    const balance = buildBorrowBalanceMetrics(state, "wallet-1", state.now)
    const rowInterest = tab.debtPositions.reduce((sum, row) => sum + row.accruedInterestUsd, 0)
    expect(balance.interestOwedUsd).toBeCloseTo(rowInterest, 4)
  })
})
