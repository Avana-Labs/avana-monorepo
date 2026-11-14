import { describe, expect, it } from "vitest"
import { makeExampleBorrowSystemState } from "@/app/lib/credit-engine/__tests__/fixtures"
import { buildPortfolioBorrowData } from "@/app/lib/borrow-system/read-model"
import { buildBorrowBalanceMetrics } from "@/app/dashboard/dashboard-tab-metrics"

const DAY_MS = 24 * 60 * 60 * 1000

// D3: the dashboard net-portfolio HEADLINE debt (buildBorrowBalanceMetrics ->
// totalBorrowedUsd) must equal the Borrow tab's "Total Borrowed" — the sum of
// the debt rows' borrowedUsd. Both must be read at the SAME (current) debt index.
describe("headline totalBorrowedUsd agrees with the Borrow-tab debt rows (D3)", () => {
  it("matches to the cent when both are read at the current index", () => {
    const state = makeExampleBorrowSystemState()
    // Read well after the last stored action so a non-trivial amount of interest has
    // accrued between state.now and the read — this is exactly the drift that used to
    // split the headline ($6.73) from the tab ($6.80).
    const now = state.now + 120 * DAY_MS

    const headlineTotal = buildBorrowBalanceMetrics(state, "wallet-1", now).totalBorrowedUsd
    const tab = buildPortfolioBorrowData(state, "wallet-1", now)
    const debtRowTotal = tab.debtPositions.reduce((sum, row) => sum + row.borrowedUsd, 0)

    expect(headlineTotal).toBeGreaterThan(0)
    expect(tab.debtPositions.length).toBeGreaterThan(0)
    // Single-sourced through the same current-index accrual: agree to the cent.
    expect(headlineTotal).toBeCloseTo(debtRowTotal, 2)
  })

  it("uses the current index, not the stored (stale) index", () => {
    const state = makeExampleBorrowSystemState()
    const now = state.now + 120 * DAY_MS

    // Reading at the stored index (no accrual) is strictly lower — the old headline.
    const staleTotal = buildBorrowBalanceMetrics(state, "wallet-1", state.now).totalBorrowedUsd
    const currentTotal = buildBorrowBalanceMetrics(state, "wallet-1", now).totalBorrowedUsd

    expect(currentTotal).toBeGreaterThan(staleTotal)
    // And the tab (already current-index) matches the current total, not the stale one.
    const debtRowTotal = buildPortfolioBorrowData(state, "wallet-1", now).debtPositions.reduce(
      (sum, row) => sum + row.borrowedUsd,
      0,
    )
    expect(debtRowTotal).toBeCloseTo(currentTotal, 2)
    expect(Math.abs(debtRowTotal - staleTotal)).toBeGreaterThan(0.005)
  })
})
