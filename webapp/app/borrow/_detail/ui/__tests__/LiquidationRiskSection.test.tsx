import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { LiquidationRiskSection } from "@/app/borrow/_detail/ui/LiquidationRiskSection"
import type { LiquidationRiskStat } from "@/app/lib/detail-page/liquidation-risk"

describe("LiquidationRiskSection", () => {
  const stats: LiquidationRiskStat[] = [
    {
      id: "liquidations",
      label: "Liquidations (24h)",
      value: "12",
      deltaValue: 2,
      deltaLabel: "2",
      goodDirection: "down",
      format: "number",
    },
    {
      id: "collateralAtRisk",
      label: "Collateral at risk",
      value: "$8.00M",
      deltaValue: -1_000_000,
      deltaLabel: "$1.00M",
      goodDirection: "down",
      format: "usd",
    },
  ]

  it("renders KPI labels, values, and daily delta arrows", () => {
    render(<LiquidationRiskSection stats={stats} />)
    expect(screen.getByRole("heading", { name: "Liquidation Risk" })).toBeInTheDocument()
    expect(screen.getByText("Liquidations (24h)")).toBeInTheDocument()
    expect(screen.getByText("12")).toBeInTheDocument()
    expect(screen.getByText("Collateral at risk")).toBeInTheDocument()
    expect(screen.getByText("$8.00M")).toBeInTheDocument()
    expect(screen.getByText("▲")).toBeInTheDocument()
    expect(screen.getByText("▼")).toBeInTheDocument()
  })

  it("renders nothing when stats are empty", () => {
    const { container } = render(<LiquidationRiskSection stats={[]} />)
    expect(container).toBeEmptyDOMElement()
  })
})
