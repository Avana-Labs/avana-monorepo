import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { AskAIFinancialResultCard } from "../components/ask-ai-financial-result-card"

afterEach(cleanup)

describe("Ask AI financial result card", () => {
  it("renders structured current and projected values without recalculating them", () => {
    render(
      <AskAIFinancialResultCard
        result={{
          kind: "borrow_capacity",
          title: "Borrow simulation",
          freshness: "fresh",
          metrics: [
            { label: "LTV", value: "35.00%", after: "45.00%" },
            { label: "Health factor", value: "1.86", after: "1.44" },
          ],
        }}
      />,
    )

    expect(screen.getByRole("region", { name: "Borrow simulation" })).toBeInTheDocument()
    expect(screen.getByText("35.00%")).toBeInTheDocument()
    expect(screen.getByText(/45.00%/)).toBeInTheDocument()
    expect(screen.getByText("fresh")).toBeInTheDocument()
  })

  it("surfaces stale structured data", () => {
    render(
      <AskAIFinancialResultCard
        result={{
          kind: "market",
          title: "ETH market",
          freshness: "stale",
          metrics: [{ label: "Price", value: "$4,000" }],
        }}
      />,
    )
    expect(screen.getByText("stale")).toBeInTheDocument()
  })

  it("renders structured rows as a semantic table", () => {
    render(
      <AskAIFinancialResultCard
        result={{
          kind: "pool",
          title: "Pool metrics",
          metrics: [],
          columns: ["Pool", "TVL", "APY"],
          rows: [{ id: "eth-usdc", cells: ["ETH/USDC", "$4,000,000", "4.20%"] }],
        }}
      />,
    )
    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "TVL" })).toBeInTheDocument()
    expect(screen.getByText("ETH/USDC")).toBeInTheDocument()
  })
})
