import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { PortfolioRewardsCards } from "@/app/dashboard/_rewards-components/rewards-balance-hero"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value, language: "EN" }),
}))

describe("rewards cards", () => {
  it("show the earned and claimable totals as points with the rewards coin illustration, not AVA", () => {
    const { container } = render(
      <DisplayPreferencesProvider>
        <PortfolioRewardsCards earnedAmount={1250} claimableAmount={300} />
      </DisplayPreferencesProvider>,
    )
    expect(screen.getByText("1,250 pts")).toBeTruthy()
    expect(screen.getByText("300 pts")).toBeTruthy()
    expect(container.textContent).not.toMatch(/AVA/)
    const sources = [...container.querySelectorAll("img")].map((img) => img.getAttribute("src") ?? "")
    expect(sources.length).toBe(2)
    for (const src of sources) expect(decodeURIComponent(src)).toContain("/asset-rewards/7.png")
  })
})
