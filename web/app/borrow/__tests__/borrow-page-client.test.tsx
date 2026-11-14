import type { ReactElement } from "react"
import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { BorrowPageHero } from "@/app/borrow/borrow-page-hero"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import type { BorrowPageData } from "@/app/lib/data/providers/borrow"

// The hero reads display preferences (currency / hide-amounts), so renders need the provider.
function renderWithPrefs(ui: ReactElement) {
  return render(<DisplayPreferencesProvider>{ui}</DisplayPreferencesProvider>)
}

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useAvanaIdentity: () => ({ walletId: "wallet-1" }),
  useBorrowSessionContext: () => ({
    state: {},
    readAdapter: { readBorrowPage: vi.fn() },
    transactionHistory: [],
  }),
}))

vi.mock("@/app/borrow/borrow-workspace-shell", () => ({
  BorrowWorkspaceShell: () => <div data-testid="borrow-workspace-shell" />,
}))

const basePageData = {
  walletId: "wallet-1",
  borrowSessionSeed: '{"stub":true}',
  poolCatalog: [
    {
      id: "market-1",
      name: "WETH / USDC",
      venue: "Uniswap v3",
      feeTier: "0.30%",
      tvlUsd: 100_000_000,
      availableUsd: 25_000_000,
      change24hPct: 1.1,
      spoke: "uni-v3-bluechip",
      ltv: 78,
      dexes: [{ id: "uniswap", label: "Uniswap" }],
      borrowableTokens: [],
      aprMin: 4.7,
      aprMax: 5.9,
      riskPremiumBps: 70,
      visuals: [
        {
          symbol: "WETH",
          shortLabel: "W",
          bgClass: "bg-indigo-100",
          textClass: "text-indigo-700",
          iconUrl: "/weth.png",
        },
        { symbol: "USDC", shortLabel: "U", bgClass: "bg-sky-100", textClass: "text-sky-700", iconUrl: "/usdc.png" },
      ],
      collateralExampleUsd: 1000,
      trendUp: true,
    },
  ],
  heroMetrics: {
    totalTvlUsd: 327_400_000,
    totalCollateralUsd: 315_700_000,
    availableCreditUsd: 92_700_000,
    outstandingLoansUsd: 159_800_000,
    totalTvlChangePct: 2.03,
  },
  borrowableAssets: [],
  pendingRows: [],
  dexes: [],
  collateralPools: [],
  initialDebts: {},
  borrowSnapshot: {
    totalBorrowedUsd: 0,
    availableCreditUsd: 0,
    totalCollateralUsd: 0,
    liquidationValueUsd: 0,
    healthFactor: null,
  },
} as unknown as BorrowPageData

describe("BorrowPageHero", () => {
  it("renders fetched hero metrics and market rows without recomputing them locally", () => {
    renderWithPrefs(<BorrowPageHero pageData={basePageData} />)

    expect(screen.getByText("Borrow TVL")).toBeInTheDocument()
    expect(screen.getByText("$327.4M")).toBeInTheDocument()
    // "Total Collateral" ($315.7M) was dropped in the one-stat-per-page hero refactor.
    // Available Credit / Outstanding Loans render twice (desktop inline + mobile condensed row).
    expect(screen.getAllByText("$92.7M").length).toBeGreaterThan(0)
    expect(screen.getAllByText("$159.8M").length).toBeGreaterThan(0)
    expect(screen.getByText("WETH / USDC")).toBeInTheDocument()
    expect(screen.getByText("5.30% LP APR")).toBeInTheDocument()
    expect(screen.getByText("78% LTV")).toBeInTheDocument()
  })

  it("formats billion-scale hero metrics with compact suffix", () => {
    const pageData = {
      ...basePageData,
      heroMetrics: {
        totalTvlUsd: 6_885_000_000,
        totalCollateralUsd: 315_700_000,
        availableCreditUsd: 92_700_000,
        outstandingLoansUsd: 159_800_000,
        totalTvlChangePct: 2.03,
      },
    } as unknown as BorrowPageData

    renderWithPrefs(<BorrowPageHero pageData={pageData} />)

    expect(screen.getByText("$6.9B")).toBeInTheDocument()
  })
})
