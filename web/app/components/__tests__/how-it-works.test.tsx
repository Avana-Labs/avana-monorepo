import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { HowItWorks } from "@/app/components/how-it-works"

describe("Umbrella How it works", () => {
  it("explains Hub-reserve scope, first-loss coverage, and the exit path", () => {
    render(
      <DisplayPreferencesProvider>
        <HowItWorks topic="umbrella" />
      </DisplayPreferencesProvider>,
    )

    fireEvent.click(screen.getByRole("button", { name: "How it works" }))

    expect(screen.getByText("How Umbrella works")).toBeInTheDocument()
    expect(screen.getByText("Hub + reserve coverage")).toBeInTheDocument()
    expect(screen.getByText("First-loss protection")).toBeInTheDocument()
    expect(screen.getByText("Slashing stays live")).toBeInTheDocument()
    expect(screen.getByText(/a 2-day withdrawal window opens/)).toBeInTheDocument()
  })
})
