import type { ReactNode } from "react"
import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { DashboardWalletTab, resolvePoolRiskPremiumBps } from "@/app/dashboard/dashboard-wallet-tab"
import { BORROW_POOL_CATALOG, formatRiskPremium } from "@/app/lib/borrow-market-rows"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

vi.mock("@/app/lib/currency/use-currency", () => ({
  useCurrency: () => ({
    exact: (value: number) => `$${value.toFixed(2)}`,
    price: (value: number) => `$${value.toFixed(2)}`,
  }),
}))

// The wallet tab now consults Convex for balances when no explicit prop is passed.
// The isolated test render doesn't mount a ConvexProvider, so stub the hook to
// return undefined — the tab falls through to the DEMO_SWAP_BALANCES default.
vi.mock("@/app/lib/swap-system/use-convex-wallet-balances", () => ({
  useConvexProductWalletBalances: () => undefined,
  useConvexClaimBasis: () => undefined,
  useConvexWalletOnboardingSummary: () => undefined,
}))

function renderWalletTab(node: ReactNode) {
  return render(<DisplayPreferencesProvider>{node}</DisplayPreferencesProvider>)
}

describe("DashboardWalletTab", () => {
  it("renders wallet tokens and LPs separately", { timeout: 20_000 }, () => {
    renderWalletTab(<DashboardWalletTab walletId="demo-wallet" />)

    expect(screen.getByRole("heading", { name: "Wallet Overview" })).toBeInTheDocument()
    expect(screen.getByText("Wallet Value")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Tokens" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Pools" })).toBeInTheDocument()
    expect(screen.getAllByText("Ether").length).toBeGreaterThan(0)
    expect(screen.getAllByText("ETH / USDC LP").length).toBeGreaterThan(0)
    expect(screen.getAllByText("76.5%").length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link").some((link) => link.getAttribute("href") === "/borrow/markets/eth-usdc")).toBe(
      true,
    )
  })

  it("renders the pool risk premium from the canonical pool catalog", { timeout: 20_000 }, () => {
    renderWalletTab(
      <DashboardWalletTab
        walletId="wallet-live"
        balances={[
          {
            id: "pool-a",
            walletId: "wallet-live",
            assetId: "aura-weth-lp",
            amount: 1,
            valueUsd: 100,
            sourceType: "borrow_collateral_unpledged",
            symbol: "AURA / WETH LP",
            isLpToken: true,
            sourcePositionId: "bal-weighted-80-20-aura-weth",
          },
        ]}
      />,
    )

    const pool = BORROW_POOL_CATALOG.find((row) => row.id === "bal-weighted-80-20-aura-weth")
    expect(pool).toBeDefined()
    expect(screen.getAllByText(/^Risk Premium$/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(formatRiskPremium(pool!.riskPremiumBps)).length).toBeGreaterThan(0)
  })

  it("prefers the hydrated market premium for pools added after the catalog", () => {
    const row = {
      id: "future-pool-row",
      assetId: "future-pool-lp",
      symbol: "FUTURE / WETH",
      name: "FUTURE / WETH LP",
      amount: 1,
      valueUsd: 100,
      sourceType: "borrow_collateral_unpledged" as const,
      sourceLabel: "Borrow collateral",
      isLpToken: true,
      isWalletHeld: false,
      swappable: false,
      restrictionReason: null,
    }

    expect(resolvePoolRiskPremiumBps(row, { "future-pool": { listPremiumBps: 137 } })).toBe(137)
  })

  it("renders the authoritative LTV for every pool row", { timeout: 20_000 }, () => {
    renderWalletTab(
      <DashboardWalletTab
        walletId="wallet-live"
        balances={[
          {
            id: "pool-a",
            walletId: "wallet-live",
            assetId: "aura-weth-lp",
            amount: 1,
            valueUsd: 100,
            sourceType: "borrow_collateral_unpledged",
            symbol: "AURA / WETH LP",
            isLpToken: true,
            sourcePositionId: "bal-weighted-80-20-aura-weth",
          },
          {
            id: "pool-b",
            walletId: "wallet-live",
            assetId: "wbtc-eth-lp",
            amount: 2,
            valueUsd: 200,
            sourceType: "borrow_collateral_unpledged",
            symbol: "WBTC / ETH LP",
            isLpToken: true,
            sourcePositionId: "curve-crypto-wbtc-eth",
          },
        ]}
      />,
    )

    expect(screen.getByText("2 pools")).toBeInTheDocument()
    expect(screen.getAllByText("58.5%").length).toBeGreaterThan(0)
    expect(screen.getAllByText("70%").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Balancer Weighted LPs").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Curve Crypto LPs").length).toBeGreaterThan(0)
  })

  it("renders a per-row Swap action that deep-links to the swap flow", { timeout: 20_000 }, () => {
    renderWalletTab(<DashboardWalletTab walletId="demo-wallet" />)

    const swapLinks = screen.getAllByRole("link", { name: "Swap" })
    expect(swapLinks.length).toBeGreaterThan(0)
    expect(swapLinks.some((link) => link.getAttribute("href")?.startsWith("/swap?from="))).toBe(true)
  })

  it("does not show a pool status column or row-level pool action buttons", { timeout: 20_000 }, () => {
    renderWalletTab(<DashboardWalletTab walletId="demo-wallet" />)

    expect(screen.queryByText("Status")).toBeNull()
    expect(screen.queryByText("Fees")).toBeNull()
    expect(screen.queryByText("Unclaimed fees")).toBeNull()
    expect(screen.queryByRole("button", { name: "View" })).toBeNull()
  })

  it("can render live session balances passed by the dashboard", { timeout: 20_000 }, () => {
    renderWalletTab(
      <DashboardWalletTab
        walletId="wallet-live"
        balances={[{ id: "live-usdc", walletId: "wallet-live", assetId: "usdc", amount: 123, sourceType: "wallet" }]}
      />,
    )

    expect(screen.getAllByText("USD Coin").length).toBeGreaterThan(0)
    expect(screen.getAllByText("123 USDC").length).toBeGreaterThan(0)
  })

  it(
    "shows returned Lend assets and unpledged Borrow LPs without showing pledged collateral",
    { timeout: 20_000 },
    () => {
      renderWalletTab(
        <DashboardWalletTab
          walletId="wallet-live"
          balances={[
            { id: "free-usdc", walletId: "wallet-live", assetId: "usdc", amount: 300, sourceType: "wallet" },
            {
              id: "available-lp",
              walletId: "wallet-live",
              assetId: "eth-usdc-lp",
              amount: 5.6,
              valueUsd: 700,
              sourceType: "borrow_collateral_unpledged",
              symbol: "ETH / USDC LP",
              isLpToken: true,
            },
            {
              id: "pledged-lp",
              walletId: "wallet-live",
              assetId: "eth-usdc-lp",
              amount: 0.8,
              valueUsd: 100,
              sourceType: "borrow_collateral_pledged",
            },
          ]}
        />,
      )

      // Returned/available product balances are visible; pledged collateral remains on Borrow.
      expect(screen.getAllByText("USD Coin").length).toBeGreaterThan(0)
      expect(screen.getAllByText("ETH / USDC LP").length).toBeGreaterThan(0)
      expect(screen.getAllByText("Borrow collateral").length).toBeGreaterThan(0)
      expect(screen.queryByText("Pledged collateral")).toBeNull()
    },
  )

  it("shows a Lend available balance when no liquid mirror exists", { timeout: 20_000 }, () => {
    renderWalletTab(
      <DashboardWalletTab
        walletId="wallet-live"
        balances={[
          {
            id: "lend-eth",
            walletId: "wallet-live",
            assetId: "eth",
            amount: 2,
            valueUsd: 4_000,
            sourceType: "lend_available",
          },
        ]}
      />,
    )

    expect(screen.getAllByText("Ether").length).toBeGreaterThan(0)
    expect(screen.getAllByText("2 ETH").length).toBeGreaterThan(0)
  })
})
