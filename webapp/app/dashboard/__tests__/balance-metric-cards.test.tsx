import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  DashboardCreditOverviewSection,
  DashboardLendPerformanceSection,
} from "@/app/dashboard/dashboard-metric-section"

vi.mock("@/app/components/display-preferences", () => ({
  useAmountDisplayPreferences: () => ({ showDollarAmounts: true }),
  useOptionalLocaleDisplayPreferences: () => ({ language: "EN", currency: "USD" }),
}))

afterEach(() => cleanup())

describe("Borrow Balance metric cards", () => {
  it("renders all eight wallet-level Borrow Balance metrics", () => {
    render(
      <DashboardCreditOverviewSection
        title="Borrow Balance"
        metrics={{
          netValueUsd: 12_000,
          collateralValueUsd: 20_000,
          totalBorrowedUsd: 8_000,
          availableToBorrowUsd: 4_500,
          healthFactor: 2.05,
          liquidationBufferUsd: 6_400,
          netApyPct: 3.25,
          interestOwedUsd: 42,
        }}
      />,
    )

    for (const label of [
      "Net Value",
      "Collateral Value",
      "Total Borrowed",
      "Available to Borrow",
      "Health Factor",
      "Liquidation Buffer",
      "Net APY",
      "Interest Owed",
    ]) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    expect(screen.getByText("2.05")).toBeTruthy()
    expect(screen.getByText("3.25%")).toBeTruthy()
    expect(screen.queryByText("Total Collateral")).toBeNull()
  })

  it("renders no liquidation buffer for a debt-free wallet", () => {
    render(
      <DashboardCreditOverviewSection
        title="Borrow Balance"
        metrics={{
          netValueUsd: 351_809,
          collateralValueUsd: 351_809,
          totalBorrowedUsd: 0,
          availableToBorrowUsd: 249_754,
          healthFactor: null,
          liquidationBufferUsd: null,
          netApyPct: 2,
          interestOwedUsd: 0,
        }}
      />,
    )

    expect(screen.getAllByText("—")).toHaveLength(2)
    expect(screen.queryByText("$284,276")).toBeNull()
  })
})

describe("Lend Balance metric cards", () => {
  it("renders eight growth metrics and omits Rewards Earned", () => {
    render(
      <DashboardLendPerformanceSection
        title="Lend Balance"
        metrics={{
          totalSuppliedUsd: 100_000,
          netApyPct: 6.5,
          interestEarnedUsd: 2_500,
          yieldGeneratedPct: 2.56,
          projectedEarnings1dUsd: 17.81,
          projectedEarnings30dUsd: 534.25,
          projectedEarnings90dUsd: 1_602.74,
          projectedEarnings6mUsd: 3_250,
          // null anchor → the live counters render their settled base (no elapsed accrual),
          // so the assertions below are deterministic.
          accrualSinceMs: null,
        }}
      />,
    )

    for (const label of [
      "Total Supplied",
      "Net APY",
      "Interest Earned",
      "Yield Generated",
      "1 Day",
      "30 Days",
      "90 Days",
      "6 Months",
    ]) {
      expect(screen.getByText(label)).toBeTruthy()
    }
    expect(screen.getByText("6.50%")).toBeTruthy()
    // Interest Earned + Yield Generated now accrue live from the recorded base interest
    // ($2,500 of $100,000 = 2.50%); the extra decimals mark them as live counters.
    expect(screen.getByText("$2,500.00")).toBeTruthy()
    expect(screen.getByText("2.50%")).toBeTruthy()
    expect(screen.queryByText("Rewards Earned")).toBeNull()
  })
})
