import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { LendMarketDetailClient } from "@/app/lend/markets/[marketId]/market-detail-client"
import { getLendMarketDetail } from "@/app/lib/lend-detail"

// Force French so the breadcrumb label must come from the translator, not a
// hardcoded English string — this is exactly the nav/breadcrumb mismatch (#129).
vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => (key === "Lend" ? "Prêter" : key), language: "FR" }),
}))

vi.mock("@/app/lend/_detail", () => ({
  LendHero: () => <div data-testid="lend-hero" />,
  LendHeroIdentity: () => <div data-testid="lend-hero-identity" />,
  LendSidebar: () => <div data-testid="lend-sidebar" />,
}))
vi.mock("@/app/borrow/_detail/ui", () => ({
  AboutNewsSection: () => <div data-testid="about" />,
  DetailFaqSection: () => <div data-testid="faqs" />,
}))
vi.mock("@/app/borrow/_detail/pool-sections", () => ({
  CashflowCard: () => <div data-testid="cashflow" />,
  QuickStatsGrid: () => <div data-testid="quickstats" />,
  RiskSection: () => <div data-testid="risk" />,
}))
vi.mock("@/app/components/detail-transaction-table/detail-market-transactions", () => ({
  DetailMarketTransactions: () => <div data-testid="transactions" />,
  LEND_KIND_CONFIG: {},
}))
vi.mock("@/app/lib/lend-system/lend-session-context", () => ({
  useLendSessionContext: () => ({ walletId: "demo-wallet", transactionHistory: [] }),
}))
vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useAvanaIdentity: () => ({ walletAddress: "0x0000000000000000000000000000000000000001" }),
}))

describe("LendMarketDetailClient breadcrumb", () => {
  afterEach(cleanup)

  it("localizes the breadcrumb root label so it matches the translated nav", () => {
    const detail = getLendMarketDetail("usdc")!
    render(<LendMarketDetailClient detail={detail} />)

    // The breadcrumb link uses the translated label, not the English "Lend".
    const crumb = screen.getByRole("link", { name: "Prêter" })
    expect(crumb).toHaveAttribute("href", "/lend")
    expect(screen.queryByRole("link", { name: "Lend" })).toBeNull()
  })
})
