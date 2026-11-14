import { render, cleanup, within } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { SuppliesPanel } from "../supplies-table"
import type { SupplyRowContext } from "@/app/lib/data/borrow-position-types"

const visuals = [
  { symbol: "WETH", shortLabel: "E", bgClassName: "bg-sky-100", textClassName: "text-sky-700" },
  { symbol: "USDC", shortLabel: "U", bgClassName: "bg-emerald-100", textClassName: "text-emerald-700" },
] as [
  { symbol: string; shortLabel: string; bgClassName: string; textClassName: string },
  { symbol: string; shortLabel: string; bgClassName: string; textClassName: string },
]

// A dust-sized collateral position that nonetheless shares a spoke holding much
// larger collateral: its Borrow Power / Health Factor reflect the whole spoke, not
// the $2 in this row. The mobile card must label the health figure as scope-level
// rather than imply a per-row figure.
const tinyRow: SupplyRowContext = {
  pool: {
    id: "uni-v3-bluechip-weth-usdc",
    name: "WETH / USDC",
    venue: "Uniswap",
    category: "Uniswap 0.05%",
    collateralUsd: 2,
    maxLtv: 71,
    borrowPowerUsd: 3_700,
    liquidationUsd: 4_100,
    pairApr: 3.4,
    visuals,
  },
  borrowedUsd: 0,
  remainingBorrowPowerUsd: 3_700,
  liquidationThresholdUsd: 4_100,
  healthFactor: 4.57,
  pairApr: 3.4,
  feesUsd: 0,
  feesLabel: "$0.00",
}

describe("SuppliesPanel column scope", () => {
  it("shows No debt instead of a liquidation value when nothing in scope is borrowed", () => {
    const { container } = render(
      <SuppliesPanel
        rows={[{ ...tinyRow, healthFactor: Number.POSITIVE_INFINITY }]}
        totals={{ collateral: 2, borrowed: 0, available: 0, fees: 0, averageHf: null }}
        showSummary={false}
      />,
    )
    expect(container.textContent).toMatch(/No debt/)
    expect(container.textContent).not.toMatch(/Liq\./)
  })

  afterEach(() => {
    cleanup()
  })

  it("shows a lend-style empty state with heading and count", () => {
    const { container } = render(
      <SuppliesPanel
        rows={[]}
        totals={{ collateral: 0, borrowed: 0, available: 0, fees: 0, averageHf: null }}
        showSummary={false}
      />,
    )

    expect(container.textContent).toMatch(/My Collaterals/)
    expect(container.textContent).toMatch(/0 assets/)
    expect(container.textContent).toMatch(/No collateral deposited yet\. Supply an asset to start backing loans\./)
    expect(container.textContent).not.toMatch(/Nothing supplied yet/)
    expect(container.textContent).not.toMatch(/To borrow you need to supply any LPs/)
  })

  it("renders the spoke-scoped columns and labels the mobile health figure as scope-level", () => {
    const { container } = render(
      <SuppliesPanel
        rows={[tinyRow]}
        totals={{ collateral: 2, borrowed: 0, available: 3_700, fees: 0, averageHf: 4.57 }}
        showSummary={false}
        showHeading={false}
      />,
    )
    const view = within(container)

    // The desktop table exposes the spoke-scoped credit columns. "Borrow Power"
    // and the health factor here reflect the whole spoke, not the $2 in this row.
    expect(view.getAllByText(/^BORROW POWER$/).length).toBeGreaterThan(0)
    // The column is "Risk" — a combined health-factor + liquidation cell modelled on the
    // Multiply tab (the same table renders on phones).
    expect(view.getAllByText(/^RISK$/).length).toBeGreaterThan(0)
    // Liquidation value comes from the SAME field the My Debts table reads
    // (liquidationThresholdUsd), so the two tables never disagree. It is labelled
    // "Liq." with an (i) that explains it is a USD figure (vs Multiply's per-token price).
    expect(container.textContent).toMatch(/Liq\./)
    expect(container.textContent).toMatch(/4,100/)
    // No per-position "Max Borrow" label is shown that would imply the borrow
    // capacity belongs to this single dust-sized row.
    expect(view.queryByText(/Max Borrow/)).not.toBeInTheDocument()
  })
})
