import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { buildPortfolioBorrowData } from "@/app/lib/borrow-system/read-model"

describe("borrow account section single source", () => {
  it("p1-02: hero and panels share buildPortfolioBorrowData creditLines totals", () => {
    const state = buildMockBorrowSystemState("demo-wallet")
    const tab = buildPortfolioBorrowData(state, "demo-wallet")
    const rowDebtTotal = tab.debtPositions.reduce((sum, row) => sum + row.borrowedUsd, 0)

    expect(tab.creditLines.totalBorrowedUsd).toBeCloseTo(rowDebtTotal, 6)

    const source = readFileSync(resolve(__dirname, "../borrow-account-section.tsx"), "utf8")
    expect(source).not.toContain("selectBorrowSnapshot")
    expect(source).toContain("buildPortfolioBorrowData")
    expect(source).toMatch(/creditLines\.totalBorrowedUsd/)
    expect(source).not.toMatch(/borrowDashboardMetrics\.overview\.totalBorrowedUsd/)
    expect(source).not.toMatch(/borrowDashboardMetrics\.performance\.poolCollateralUsd/)
  })
})
