import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { HealthRiskBanner } from "@/app/dashboard/health-risk-banner"

afterEach(() => cleanup())

describe("HealthRiskBanner", () => {
  it("renders a warning for a danger-band health factor and deep-links to Repay for borrow", () => {
    render(<HealthRiskBanner healthFactor={1.1} product="borrow" />)

    expect(screen.getByRole("alert")).toBeTruthy()
    expect(screen.getByText(/near liquidation/i)).toBeTruthy()
    const repay = screen.getByRole("link", { name: "Repay" })
    expect(repay.getAttribute("href")).toBe("/actions/borrow/repay")
  })

  it("renders nothing for a safe health factor", () => {
    const { container } = render(<HealthRiskBanner healthFactor={3.0} product="borrow" />)
    expect(container.firstChild).toBeNull()
    expect(screen.queryByRole("alert")).toBeNull()
  })

  it("renders nothing when the health factor is unknown (no position)", () => {
    const { container } = render(<HealthRiskBanner healthFactor={null} product="borrow" />)
    expect(container.firstChild).toBeNull()
  })

  it("can be dismissed", () => {
    render(<HealthRiskBanner healthFactor={1.1} product="borrow" />)
    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }))
    expect(screen.queryByRole("alert")).toBeNull()
  })
})
