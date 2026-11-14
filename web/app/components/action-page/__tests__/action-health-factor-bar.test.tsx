import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ActionHealthFactorBar } from "@/app/components/action-page/action-health-factor-bar"
import { ActionMetricsBlock } from "@/app/components/action-page/action-metrics"
import { ActionReviewStage } from "@/app/components/action-page/action-review-stage"

describe("ActionHealthFactorBar", () => {
  it("renders zone bar and status label", () => {
    render(<ActionHealthFactorBar value={1.2} />)
    expect(screen.getByTestId("action-health-factor-bar")).toBeInTheDocument()
    // 1.2 falls in the "Watch" band (conservative 4-band scale); it appears as the status
    // label and in the zone strip.
    expect(screen.getAllByText("Watch").length).toBeGreaterThan(0)
  })
})

describe("ActionMetricsBlock borrowable assets", () => {
  it("renders token icons for borrowable assets row", () => {
    render(
      <ActionMetricsBlock
        rows={[
          {
            id: "borrowable-assets",
            label: "Borrowable assets",
            value: "USDC, GHO",
            tokenSymbols: ["USDC", "GHO"],
          },
        ]}
      />,
    )

    expect(screen.getByTestId("borrowable-asset-icons")).toBeInTheDocument()
  })
})

describe("ActionReviewStage", () => {
  it("renders read-only review content", () => {
    render(
      <ActionReviewStage
        title="Liquidation preview"
        subtitle="Estimated outcome"
        preview={{
          allowed: true,
          amountLabel: "100 USDC",
          amountUsdLabel: "≈ $100",
          rateLabel: "Liquidation",
          rateValue: "$100",
          marketLabel: "Market",
          marketValue: "WETH / USDC",
          balanceLabel: "Repay",
          balanceValue: "$100",
          maxAmount: null,
          metrics: [],
          networkFeeLabel: "≈ $0.04",
          risk: null,
          blockedReason: null,
          validationErrors: [],
          warnings: [],
        }}
        primaryLabel="Close preview"
      />,
    )

    expect(screen.getByTestId("action-review-stage")).toBeInTheDocument()
    expect(screen.getByText("Liquidation preview")).toBeInTheDocument()
  })
})
