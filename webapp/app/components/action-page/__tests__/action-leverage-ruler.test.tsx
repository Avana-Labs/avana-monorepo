import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ActionLeverageRuler } from "@/app/components/action-page/action-leverage-ruler"

afterEach(() => cleanup())

describe("ActionLeverageRuler", () => {
  it("shows Multiplier header, value pill, and five evenly spaced scale ticks", () => {
    render(<ActionLeverageRuler value="1" onChange={() => {}} />)

    expect(screen.getByTestId("action-leverage-ruler")).toHaveTextContent("Multiplier")
    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("1x")

    const ticks = screen.getByTestId("action-leverage-ticks")
    expect(ticks).toHaveTextContent("1x")
    expect(ticks).toHaveTextContent("3.25x")
    expect(ticks).toHaveTextContent("5.5x")
    expect(ticks).toHaveTextContent("7.74x")
    expect(ticks).toHaveTextContent("9.99x")
  })

  it("updates the pill when the slider moves through 0.01 steps", () => {
    const onChange = vi.fn()
    render(<ActionLeverageRuler value="2" onChange={onChange} label="Multiplier" />)

    const slider = screen.getByRole("slider", { name: "Multiplier" })
    fireEvent.change(slider, { target: { value: "6.7" } })

    expect(onChange).toHaveBeenCalledWith("6.7")
  })

  it("exposes the slider with an accessible label", () => {
    render(<ActionLeverageRuler value="2" onChange={() => {}} label="Multiplier" />)

    expect(screen.getByRole("slider", { name: "Multiplier" })).toBeInTheDocument()
  })

  it("supports percentage formatting for bounded action controls", () => {
    render(
      <ActionLeverageRuler
        value="25"
        onChange={() => {}}
        label="Percentage to remove"
        valueSuffix="%"
        subvalue="Estimated removal · $10,903.25"
        min={0}
        max={100}
        step={1}
      />,
    )

    expect(screen.getByTestId("action-leverage-pill")).toHaveTextContent("25%")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("0%")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("25%")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("50%")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("75%")
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("100%")
    expect(screen.getByText("Estimated removal · $10,903.25")).toBeInTheDocument()
  })

  it("does not duplicate the only tick when the range has one value", () => {
    render(<ActionLeverageRuler value="1" onChange={() => {}} min={1} max={1} step={1} />)

    expect(screen.getByTestId("action-leverage-ticks").children).toHaveLength(1)
    expect(screen.getByTestId("action-leverage-ticks")).toHaveTextContent("1x")
  })

  it("does not render number input, recommended copy, or USD endpoints", () => {
    render(<ActionLeverageRuler value="2" onChange={() => {}} />)

    expect(screen.queryByRole("spinbutton")).toBeNull()
    expect(screen.queryByText(/Recommended up to/i)).toBeNull()
    expect(screen.queryByText(/USD/)).toBeNull()
  })
})
