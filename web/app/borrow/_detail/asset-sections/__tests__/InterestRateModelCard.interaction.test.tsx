import { describe, expect, it } from "vitest"
import { fireEvent, render, screen } from "@testing-library/react"
import { InterestRateModelCard } from "@/app/borrow/_detail/asset-sections/InterestRateModelCard"
import { buildInterestRateModelParameterRows } from "@/app/lib/borrow-detail/protocol-parameters"

describe("InterestRateModelCard interaction", () => {
  it("keeps sidebar current util at 2dp and probes hover APR from the anchored curve", () => {
    render(
      <InterestRateModelCard
        utilizationPct={62.93}
        borrowAprPct={5.4}
        borrowedUsd={6_293_000}
        suppliedUsd={10_000_000}
        protocolParameters={buildInterestRateModelParameterRows("test:usdc", 5.4)}
      />,
    )

    expect(screen.getByText("62.93%")).toBeTruthy()
    expect(screen.getByText(/Current 62\.93%/)).toBeTruthy()

    const chart = screen.getByTestId("interest-rate-model-chart")
    const plot = chart.firstElementChild as HTMLElement
    // Fake a mid-plot hover; jsdom has no layout so we stub geometry.
    Object.defineProperty(plot, "getBoundingClientRect", {
      value: () => ({
        left: 0,
        width: 640,
        top: 0,
        height: 300,
        right: 640,
        bottom: 300,
        x: 0,
        y: 0,
        toJSON: () => ({}),
      }),
    })
    fireEvent.pointerMove(plot, { clientX: 320, clientY: 150 })

    const tooltip = screen.getByTestId("interest-rate-model-tooltip")
    expect(tooltip.textContent).toMatch(/Utilization Rate/)
    expect(tooltip.textContent).toMatch(/Borrow APY/)
    expect(tooltip.textContent).toMatch(/Borrow amount to reach/)

    fireEvent.pointerLeave(plot)
    expect(screen.queryByTestId("interest-rate-model-tooltip")).toBeNull()
  })
})
