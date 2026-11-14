import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DashboardQuickActions } from "@/app/dashboard/dashboard-quick-actions"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

describe("Dashboard primary quick actions", () => {
  it("shows the four primary entry actions with canonical routes", () => {
    render(<DashboardQuickActions activeTab="borrow" />)

    const quickActions = screen.getByRole("group", { name: "Quick actions" })
    expect(screen.getAllByRole("link")).toHaveLength(4)
    expect(screen.getByRole("link", { name: "Deposit" }).getAttribute("href")).toContain("/actions/lend/deposit")
    expect(screen.getByRole("link", { name: "Borrow" }).getAttribute("href")).toContain("/actions/borrow/borrow")
    expect(screen.getByRole("link", { name: "Multiply" }).getAttribute("href")).toContain("/actions/multiply/multiply")
    expect(screen.getByRole("link", { name: "Swap" }).getAttribute("href")).toContain("/swap")
    expect(quickActions).not.toHaveTextContent("Repay")
    expect(quickActions).not.toHaveTextContent("Withdraw")
    expect(quickActions).not.toHaveTextContent("Deleverage")
  })
})
