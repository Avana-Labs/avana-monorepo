import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { BorrowWorkspace } from "@/app/borrow/components/borrow-workspace"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import type { BorrowPoolRow, BorrowableAsset } from "@/app/lib/borrow-market-rows"
import type { BorrowWorkspaceData } from "@/app/lib/data/providers/borrow"

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/borrow",
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useBorrowSessionContext: () => ({ state: {} }),
}))

vi.mock("@/app/lib/borrow-system/dashboard-selectors", () => ({
  selectPortfolioSupplyRows: () => [],
}))

const SPOKE = "0xAbCdEf0000000000000000000000000000000001"

const pool = {
  id: "weth-usdc-uniswap-v3-ethereum",
  name: "WETH / USDC",
  venue: "Uniswap v3",
  feeTier: "0.30%",
  tvlUsd: 100_000_000,
  spoke: SPOKE.toLowerCase(),
  spokeLabel: "Uniswap v3 Bluechip",
  dexId: "uniswap",
  dexLabel: "Uniswap",
  ltv: 78,
  dexes: [{ id: "uniswap", label: "Uniswap" }],
  borrowableTokens: [],
  aprMin: 4.7,
  aprMax: 5.9,
  availableUsd: 25_000_000,
  riskPremiumBps: 70,
  visuals: [
    { symbol: "WETH", shortLabel: "W", bgClass: "bg-indigo-100", textClass: "text-indigo-700" },
    { symbol: "USDC", shortLabel: "U", bgClass: "bg-sky-100", textClass: "text-sky-700" },
  ],
  constituents: [],
  collateralExampleUsd: 1000,
  trendUp: true,
} as unknown as BorrowPoolRow

// A live Convex slug id (no "<spoke>:" prefix); the Spoke comes from `spokeId`, checksummed here.
const gho: BorrowableAsset = {
  id: "gho-uniswap-v3-stable-ethereum",
  spokeId: SPOKE,
  symbol: "GHO",
  name: "Gho Token",
  subtitle: "Stablecoin",
  borrowApr: 4.2,
  totalBorrowedUsd: 1_000_000,
  utilization: 40,
  availableUsd: 1_500_000,
  hasWalletBalance: false,
  visual: { symbol: "GHO", shortLabel: "G", bgClass: "bg-emerald-100", textClass: "text-emerald-700" },
  trendUp: true,
  category: "stable",
}

const pageData = {
  walletId: "wallet-1",
  poolCatalog: [pool],
  borrowableAssets: [gho],
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
} as BorrowWorkspaceData

describe("BorrowWorkspace Borrowable tab", () => {
  it("lists a borrowable asset under the pool whose Spoke matches its spokeId", () => {
    render(
      <DisplayPreferencesProvider>
        <BorrowWorkspace pageData={pageData} />
      </DisplayPreferencesProvider>,
    )

    const section = screen.getByRole("heading", { name: "Uniswap v3 Bluechip" }).closest("section") as HTMLElement
    fireEvent.click(within(section).getByRole("button", { name: "Borrowable" }))

    expect(within(section).getAllByText("GHO").length).toBeGreaterThan(0)
  })
})
