import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { buildBorrowPageData } from "@/app/lib/borrow-system/read-model"

/**
 * Hero ↔ list universe reconciliation. The borrow landing renders TWO tabs:
 *   - Collateral tab (pool markets) — Σ TVL / Available should equal hero
 *     totalTvlUsd / availableCreditUsd exactly.
 *   - Borrowable tab (asset markets) — Σ borrowed should equal hero
 *     outstandingLoansUsd exactly.
 *
 * If either invariant breaks, the hero and the visible table diverge and a user
 * can't reconcile the headline totals against what's on the page. Codifying this
 * so a future change that adds/removes a scope from either side trips the test.
 */
describe("borrow hero reconciles with visible list universe", () => {
  const walletId = "0x0000000000000000000000000000000000000a11"
  const state = buildMockBorrowSystemState(walletId)
  const data = buildBorrowPageData(state, walletId)

  const roundCents = (value: number) => Math.round(value * 100) / 100

  it("Collateral tab Σ TVL equals hero totalTvlUsd", () => {
    const listTvl = data.poolCatalog.reduce((sum, row) => sum + row.tvlUsd, 0)
    expect(roundCents(listTvl)).toBe(roundCents(data.heroMetrics.totalTvlUsd))
  })

  it("Collateral tab Σ available equals hero availableCreditUsd", () => {
    const listAvail = data.poolCatalog.reduce((sum, row) => sum + row.availableUsd, 0)
    expect(roundCents(listAvail)).toBe(roundCents(data.heroMetrics.availableCreditUsd))
  })

  it("Borrowable tab Σ borrowed equals hero outstandingLoansUsd", () => {
    const listBorrowed = data.borrowableAssets.reduce((sum, row) => sum + row.totalBorrowedUsd, 0)
    expect(roundCents(listBorrowed)).toBe(roundCents(data.heroMetrics.outstandingLoansUsd))
  })
})
