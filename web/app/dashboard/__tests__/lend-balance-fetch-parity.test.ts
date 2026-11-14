import { describe, expect, it } from "vitest"
import { buildDemoLendSystemState } from "@/app/lib/lend-system/mock"
import { buildPortfolioLendData } from "@/app/lib/lend-system/read-model"
import { buildLendBalanceMetrics, projectLendPortfolioEarningsUsd } from "@/app/dashboard/dashboard-tab-metrics"

describe("Lend Balance fetching parity", () => {
  it("balance metrics agree with buildPortfolioLendData investments", () => {
    const state = buildDemoLendSystemState("lend-parity-wallet")
    const walletId = "lend-parity-wallet"
    // Ensure demo state has the wallet key the mock uses
    const wallets = Object.keys(state.positions).map((id) => state.positions[id]!.walletId)
    const wid = wallets[0] ?? walletId
    const tab = buildPortfolioLendData(wid, state)
    const balance = buildLendBalanceMetrics(tab)

    const supplied = tab.investments.reduce((s, i) => s + i.suppliedUsd, 0)
    const interest = tab.investments.reduce((s, i) => s + (i.interestUsd ?? 0), 0)
    expect(balance.totalSuppliedUsd).toBeCloseTo(supplied, 4)
    expect(balance.interestEarnedUsd).toBeCloseTo(interest, 4)
    expect(balance.projectedEarnings30dUsd).toBeCloseTo(projectLendPortfolioEarningsUsd(tab.investments, 30), 6)
    // Closed/inactive positions must not appear in investments used for Balance.
    expect(tab.investments.every((i) => i.status !== "closed")).toBe(true)
  })
})
