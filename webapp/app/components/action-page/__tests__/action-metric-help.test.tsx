import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ActionMetricHelp } from "@/app/components/action-page/action-metric-help"

describe("ActionMetricHelp", () => {
  it("P1-17 opens help on hover, focus, and tap without a native title", () => {
    render(<ActionMetricHelp topic="Rate" text="The current exchange rate." />)

    const trigger = screen.getByRole("button", { name: "More information about Rate" })
    expect(trigger).not.toHaveAttribute("title")
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()

    fireEvent.mouseEnter(trigger)
    expect(screen.getByRole("tooltip")).toHaveTextContent("The current exchange rate.")
    fireEvent.mouseLeave(trigger)
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()

    fireEvent.focus(trigger)
    expect(screen.getByRole("tooltip")).toBeInTheDocument()
    fireEvent.blur(trigger)
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()

    fireEvent.click(trigger)
    expect(screen.getByRole("tooltip")).toBeInTheDocument()
  })

  it("uses a concise aria-label instead of the full tooltip body", () => {
    render(
      <ActionMetricHelp
        topic="health factor"
        text="Health factor estimates how far your position is from liquidation. Above 1.0 is solvent; below 1.0 can be liquidated."
      />,
    )

    expect(screen.getByRole("button", { name: "More information about health factor" })).toBeInTheDocument()
    expect(
      screen.queryByRole("button", {
        name: "Health factor estimates how far your position is from liquidation. Above 1.0 is solvent; below 1.0 can be liquidated.",
      }),
    ).not.toBeInTheDocument()
  })
})
