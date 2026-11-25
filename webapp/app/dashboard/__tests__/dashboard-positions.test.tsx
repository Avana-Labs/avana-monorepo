import { fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { DashboardBorrowTab } from "@/app/dashboard/dashboard-borrow-tab"

const push = vi.fn()
const ltvCardProps = vi.fn()

const poolVisual = { symbol: "WETH", shortLabel: "WETH", bgClassName: "bg-black", textClassName: "text-white" }
const stableVisual = { symbol: "USDC", shortLabel: "USDC", bgClassName: "bg-blue-500", textClassName: "text-white" }

const pool = {
  id: "uni-v3-bluechip-weth-usdc",
  name: "WETH / USDC",
  venue: "Uniswap",
  category: "0.05%",
  collateralUsd: 12000,
  maxLtv: 70,
  borrowPowerUsd: 8400,
  liquidationUsd: 9000,
  pairApr: 3.1,
  visuals: [poolVisual, stableVisual] as [typeof poolVisual, typeof stableVisual],
}

const debtRow = {
  id: "debt-1",
  pool,
  borrowedUsd: 500,
  liquidationThresholdUsd: 9000,
  healthFactor: 18,
  borrowApr: 4.2,
  accruedInterestUsd: 5,
  dailyInterestUsd: 0.4,
}

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
}))

vi.mock("@/app/components/display-preferences", () => ({
  useAmountDisplayPreferences: () => ({ showDollarAmounts: true }),
  useOptionalLocaleDisplayPreferences: () => ({ currency: "USD", language: "EN" }),
}))

vi.mock("@/app/dashboard/borrow-tab/supplies-table", () => ({
  SuppliesHealthFactorCard: () => null,
  SuppliesPanel: () => <div />,
}))

vi.mock("@/app/dashboard/borrow-tab/debts-table", () => ({
  CurrentLtvCard: (props: unknown) => {
    ltvCardProps(props)
    return null
  },
  DebtsPanel: ({ rows, onRepay }: { rows: Array<typeof debtRow>; onRepay: (row: typeof debtRow) => void }) => (
    <div>
      <button type="button" onClick={() => onRepay(rows[0]!)}>
        open-repay
      </button>
    </div>
  ),
}))

describe("DashboardBorrowTab", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("routes dashboard debt actions to shared action pages", () => {
    render(<DashboardBorrowTab section="debts" debtPositions={[debtRow] as never} returnHref="/dashboard" />)

    fireEvent.click(screen.getByText("open-repay"))
    expect(push).toHaveBeenCalledWith("/actions/borrow/repay?market=uni-v3-bluechip-weth-usdc&return=%2Fdashboard")
  })
})

describe("DashboardBorrowTab borrowing power", () => {
  it("gives the borrowing power card the account's liquidation threshold", () => {
    render(<DashboardBorrowTab section="all" debtPositions={[debtRow] as never} collateralPositions={[]} />)

    // 9,000 liquidation value over 12,000 collateral.
    expect(ltvCardProps).toHaveBeenCalledWith(expect.objectContaining({ liquidationThresholdPct: 75 }))
  })
})
