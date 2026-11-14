import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { ActionRiskBanner } from "@/app/components/action-page/action-banners"

afterEach(() => cleanup())

describe("ActionRiskBanner", () => {
  it("renders warning copy with readable light-mode text classes", () => {
    render(
      <ActionRiskBanner
        level="warning"
        title="Review leverage carefully"
        message="This leverage reduces your safety buffer."
      />,
    )

    const banner = screen.getByTestId("action-risk-banner")
    // Banners use theme-aware semantic status tokens (not hardcoded amber/rose/emerald).
    expect(banner).toHaveClass("text-warning")
    expect(screen.getByText("Review leverage carefully")).toBeInTheDocument()
    expect(screen.getByText("This leverage reduces your safety buffer.")).toBeInTheDocument()
  })

  it("renders danger variant with theme-aware text classes", () => {
    render(<ActionRiskBanner level="danger" title="Risk of liquidation" message="Health factor is too low." />)

    const banner = screen.getByTestId("action-risk-banner")
    expect(banner).toHaveClass("text-danger")
  })

  it("renders safe variant with theme-aware text classes", () => {
    render(<ActionRiskBanner level="safe" title="Healthy position" message="Your buffer looks comfortable." />)

    const banner = screen.getByTestId("action-risk-banner")
    expect(banner).toHaveClass("text-success")
  })
})
