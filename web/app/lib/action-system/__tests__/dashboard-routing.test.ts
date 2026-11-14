import { describe, expect, it } from "vitest"
import { successDashboardCtaLabel } from "@/app/lib/action-system/dashboard-routing"

describe("dashboard-routing", () => {
  it("labels success CTAs to return to the dashboard", () => {
    expect(successDashboardCtaLabel("lend")).toBe("View dashboard")
    expect(successDashboardCtaLabel("borrow")).toBe("View dashboard")
    expect(successDashboardCtaLabel("multiply")).toBe("View dashboard")
    expect(successDashboardCtaLabel("rewards")).toBe("View dashboard")
  })
})
