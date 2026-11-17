import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { PortfolioRewardsCards } from "@/app/dashboard/_rewards-components/rewards-balance-hero"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value, language: "EN" }),
}))

afterEach(cleanup)

const cards = (onClaim?: () => void) =>
  render(
    <DisplayPreferencesProvider>
      <PortfolioRewardsCards earnedAmount={3000} claimableAmount={2000} onClaim={onClaim} />
    </DisplayPreferencesProvider>,
  )

describe("Claim Rewards button", () => {
  it("is disabled when nothing can be redeemed", () => {
    cards()
    expect((screen.getByText("Claim Rewards").closest("button") as HTMLButtonElement).disabled).toBe(true)
  })

  it("opens the redemption when points can be redeemed", () => {
    const onClaim = vi.fn()
    cards(onClaim)
    fireEvent.click(screen.getByText("Claim Rewards"))
    expect(onClaim).toHaveBeenCalledTimes(1)
  })
})
