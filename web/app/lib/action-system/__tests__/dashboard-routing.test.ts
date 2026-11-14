import { describe, expect, it } from "vitest"
import { dashboardHrefForProduct, successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"

describe("dashboard-routing", () => {
  it("routes every product action back to the dashboard page", () => {
    expect(dashboardHrefForProduct("lend")).toBe("/dashboard?tab=lend")
    expect(dashboardHrefForProduct("borrow")).toBe("/dashboard?tab=borrow")
    expect(dashboardHrefForProduct("multiply")).toBe("/dashboard?tab=multiply")
    expect(dashboardHrefForProduct("rewards")).toBe("/dashboard?tab=wallet")
  })

  it("labels success CTAs to return to the dashboard", () => {
    expect(successDashboardCtaLabel("lend")).toBe("View dashboard")
    expect(successDashboardCtaLabel("borrow")).toBe("View dashboard")
    expect(successDashboardCtaLabel("multiply")).toBe("View dashboard")
    expect(successDashboardCtaLabel("rewards")).toBe("View dashboard")
  })
})
