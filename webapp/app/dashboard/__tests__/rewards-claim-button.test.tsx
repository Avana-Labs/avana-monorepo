import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { PortfolioRewardsCards } from "@/app/dashboard/_rewards-components/rewards-balance-hero"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value, language: "EN" }),
}))

afterEach(cleanup)

const cards = (claimHref?: string) =>
  render(
    <DisplayPreferencesProvider>
      <PortfolioRewardsCards earnedAmount={3000} claimableAmount={2000} claimHref={claimHref} />
    </DisplayPreferencesProvider>,
  )

describe("Claim Rewards button", () => {
  it("is disabled when nothing can be redeemed", () => {
    cards()
    expect((screen.getByText("Claim Rewards").closest("button") as HTMLButtonElement).disabled).toBe(true)
  })

  it("links to the redeem page when points can be redeemed", () => {
    cards("/actions/rewards/claim?return=%2Fdashboard%3Ftab%3Dwallet")
    expect(screen.getByText("Claim Rewards").closest("a")?.getAttribute("href")).toBe(
      "/actions/rewards/claim?return=%2Fdashboard%3Ftab%3Dwallet",
    )
  })
})
