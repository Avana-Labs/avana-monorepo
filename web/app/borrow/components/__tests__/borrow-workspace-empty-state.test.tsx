import { fireEvent, render, screen, cleanup } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { BorrowWorkspace } from "@/app/borrow/components/borrow-workspace"

const market = {
  id: "uni-v3-bluechip-weth-usdc",
  name: "WETH / USDC",
  venue: "Uniswap",
  feeTier: "0.05%",
  tvlUsd: 1000000,
  spoke: "uni-v3-bluechip",
  ltv: 70,
  dexes: [],
  borrowableTokens: [],
  aprMin: 2,
  aprMax: 4,
  availableUsd: 500000,
  riskPremiumBps: 25,
  visuals: [
    { symbol: "WETH", shortLabel: "WETH", bgClassName: "bg-black", textClassName: "text-white", iconUrl: "/weth.svg" },
    {
      symbol: "USDC",
      shortLabel: "USDC",
      bgClassName: "bg-blue-500",
      textClassName: "text-white",
      iconUrl: "/usdc.svg",
    },
  ],
  collateralExampleUsd: 12000,
  trendUp: true,
}

const asset = {
  id: "uni-v3-bluechip:usdc",
  name: "USD Coin",
  symbol: "USDC",
  subtitle: "Stablecoin",
  borrowApr: 4.2,
  visual: { symbol: "USDC", shortLabel: "USDC", bgClass: "bg-blue-500", textClass: "text-white" },
}

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
}))
vi.mock("@/app/lib/page-loading", () => ({ triggerPageLoading: vi.fn() }))
vi.mock("@/app/lib/use-media-query", () => ({ useMediaQuery: () => true }))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useBorrowSessionContext: () => ({
    state: buildMockBorrowSystemState("wallet-1"),
    marketSummaries: [market],
    collateralPools: [],
    initialDebts: {},
    getBorrowableAssetsForMarket: () => [asset],
    createIntent: vi.fn(),
    previewTransaction: vi.fn(),
    executeTransaction: vi.fn(),
  }),
}))

// Expose the real search callback so the test can drive the page-local search.
vi.mock("@/app/borrow/components/tabs-bar", () => ({
  TabsBar: ({ search, onSearchChange }: { search: string; onSearchChange: (v: string) => void }) => (
    <input aria-label="market-search" value={search} onChange={(event) => onSearchChange(event.target.value)} />
  ),
  isPoolTab: () => true,
}))

vi.mock("@/app/borrow/components/collateral-pools-table", () => ({
  CollateralPoolsTable: () => <div data-testid="pools-table" />,
}))

const pageData = {
  walletId: "wallet-1",
  borrowSessionSeed: "{}",
  poolCatalog: [market],
  borrowableAssets: [asset],
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
} as const

describe("BorrowWorkspace zero-result search", () => {
  afterEach(cleanup)

  it("shows a no-results empty state and restores the list when cleared", () => {
    render(<BorrowWorkspace pageData={pageData} />)

    // Baseline: the market list renders.
    expect(screen.getByTestId("pools-table")).toBeInTheDocument()

    // Search for something no market matches → empty state, not a blank area.
    fireEvent.change(screen.getByLabelText("market-search"), { target: { value: "zzz-no-match" } })
    expect(screen.queryByTestId("pools-table")).toBeNull()
    expect(screen.getByText(/No markets match/)).toBeInTheDocument()
    expect(screen.getByText(/zzz-no-match/)).toBeInTheDocument()

    // Clearing the filters (search included) restores the list.
    fireEvent.click(screen.getByRole("button", { name: /clear filters/i }))
    expect(screen.getByTestId("pools-table")).toBeInTheDocument()
    expect(screen.queryByText(/No markets match/)).toBeNull()
  })
})
