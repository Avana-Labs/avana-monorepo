import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { DashboardInvestments } from "@/app/dashboard/dashboard-investments"
import type { PortfolioSupplyPosition } from "@/app/lib/data/providers/portfolio"

vi.mock("@/app/components/display-preferences", () => ({
  useAmountDisplayPreferences: () => ({ showDollarAmounts: true }),
  // useTranslation() reads this; the component renders in English (t(key) === key).
  useOptionalLocaleDisplayPreferences: () => ({ language: "EN", currency: "USD" }),
}))

afterEach(() => cleanup())

describe("DashboardInvestments", () => {
  it("labels the per-day figure as a projected run-rate, not realized 'today' earnings", () => {
    const investment: PortfolioSupplyPosition = {
      id: "usdc",
      symbol: "USDC",
      name: "USD Coin",
      balance: 1_000,
      priceUsd: 1,
      suppliedUsd: 1_000,
      earnedUsd: 0,
      dailyEarnedUsd: 0.14,
      apyPct: 5.1,
      status: "active",
    }

    render(<DashboardInvestments investments={[investment]} showHeading={false} />)

    // A projected APY run-rate must not read as money already earned "today".
    expect(screen.queryByText(/today/i)).toBeNull()
  })

  it("shows claimable lend rewards and runs the claim action", () => {
    const onClaimRewards = vi.fn()

    render(
      <DashboardInvestments
        investments={[]}
        rewardsSummary={{ claimableUsd: 64, totalEarnedUsd: 64 }}
        onClaimRewards={onClaimRewards}
        isClaimingRewards={false}
      />,
    )

    expect(screen.getByRole("heading", { name: "Assets" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Claim $64.00" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Claim $64.00" }))
    expect(onClaimRewards).toHaveBeenCalledTimes(1)
  })
})
