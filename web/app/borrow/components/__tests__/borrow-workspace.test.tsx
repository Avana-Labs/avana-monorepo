import { fireEvent, render, screen, cleanup } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { borrowAssetDetailPath } from "@/app/lib/borrow-routes"
import { BorrowWorkspace } from "@/app/borrow/components/borrow-workspace"

const push = vi.fn()
const createIntent = vi.fn()
const previewTransaction = vi.fn()
const executeTransaction = vi.fn()

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
  visual: {
    symbol: "USDC",
    shortLabel: "USDC",
    bgClass: "bg-blue-500",
    textClass: "text-white",
  },
}

let borrowSessionState = buildMockBorrowSystemState("wallet-1")
let borrowAssetToLaunch = asset

const unsupportedAsset = {
  id: "uni-v3-stable:usdt",
  name: "Tether USD",
  symbol: "USDT",
  subtitle: "Stablecoin",
  borrowApr: 4.2,
  visual: {
    symbol: "USDT",
    shortLabel: "USDT",
    bgClass: "bg-emerald-500",
    textClass: "text-white",
  },
}

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  useSearchParams: () => new URLSearchParams(),
}))

vi.mock("@/app/lib/page-loading", () => ({
  triggerPageLoading: vi.fn(),
}))

let isDesktopViewport = false
vi.mock("@/app/lib/use-media-query", () => ({
  useMediaQuery: () => isDesktopViewport,
}))

vi.mock("@/app/lib/avana-session/avana-sessions-provider", () => ({
  useBorrowSessionContext: () => ({
    state: borrowSessionState,
    marketSummaries: [market],
    collateralPools: [
      {
        id: market.id,
        name: market.name,
        venue: market.venue,
        category: market.feeTier,
        collateralUsd: 12000,
        maxLtv: 70,
        borrowPowerUsd: 8400,
        liquidationUsd: 9000,
        pairApr: 3.1,
        visuals: [
          { symbol: "WETH", shortLabel: "WETH", bgClassName: "bg-black", textClassName: "text-white" },
          { symbol: "USDC", shortLabel: "USDC", bgClassName: "bg-blue-500", textClassName: "text-white" },
        ],
      },
    ],
    initialDebts: { [market.id]: 0 },
    getBorrowableAssetsForMarket: () => [asset],
    createIntent,
    previewTransaction,
    executeTransaction,
  }),
}))

vi.mock("@/app/borrow/components/tabs-bar", () => ({
  TabsBar: () => <div data-testid="tabs-bar" />,
  isPoolTab: () => true,
}))

vi.mock("@/app/borrow/components/collateral-pools-table", () => ({
  CollateralPoolsTable: ({
    groups,
    onUseAsCollateral,
    onBorrowAsset,
  }: {
    groups: Array<{ spokes: Array<{ rows: Array<typeof market> }> }>
    onUseAsCollateral: (pool: typeof market) => void
    onBorrowAsset: (asset: typeof asset) => void
  }) => (
    <div>
      <span data-testid="rendered-market">
        {groups.flatMap((group) => group.spokes).flatMap((spoke) => spoke.rows)[0]?.name}
      </span>
      <button type="button" onClick={() => onUseAsCollateral(market)}>
        open-supply
      </button>
      <button type="button" onClick={() => onBorrowAsset(borrowAssetToLaunch)}>
        open-borrow
      </button>
    </div>
  ),
}))

describe("BorrowWorkspace", () => {
  beforeEach(() => {
    push.mockClear()
    borrowAssetToLaunch = asset
    // Phone viewport by default: the Borrow row action goes straight into the borrow flow.
    isDesktopViewport = false
  })

  afterEach(() => {
    cleanup()
  })

  it("routes supply and borrow actions to the shared action pages", () => {
    render(
      <BorrowWorkspace
        pageData={{
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
        }}
      />,
    )

    fireEvent.click(screen.getByText("open-supply"))
    expect(push).toHaveBeenCalledWith("/actions/borrow/supply?market=uni-v3-bluechip-weth-usdc")

    fireEvent.click(screen.getByText("open-borrow"))
    expect(push).toHaveBeenCalledWith(
      "/actions/borrow/borrow?market=uni-v3-bluechip-weth-usdc&asset=uni-v3-bluechip%3Ausdc",
    )
  })

  it("sends the desktop Borrow row action to the asset detail page", () => {
    isDesktopViewport = true
    render(
      <BorrowWorkspace
        pageData={{
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
        }}
      />,
    )

    fireEvent.click(screen.getByText("open-supply"))
    expect(push).toHaveBeenCalledWith("/actions/borrow/supply?market=uni-v3-bluechip-weth-usdc")

    fireEvent.click(screen.getByText("open-borrow"))
    expect(push).toHaveBeenLastCalledWith(borrowAssetDetailPath(asset.id))
  })

  it("keeps rendering the server market snapshot when the wallet session differs", () => {
    render(
      <BorrowWorkspace
        pageData={{
          walletId: "wallet-1",
          borrowSessionSeed: "{}",
          poolCatalog: [{ ...market, name: "Server WBTC / USDC" }],
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
        }}
      />,
    )

    expect(screen.getByTestId("rendered-market")).toHaveTextContent("Server WBTC / USDC")
  })

  it("falls back to the asset detail page when the mobile borrow asset has no matching collateral spoke", () => {
    borrowSessionState = buildMockBorrowSystemState("wallet-1")
    borrowSessionState.accounts["wallet-1"]!.collateralPositions = []
    borrowAssetToLaunch = unsupportedAsset

    render(
      <BorrowWorkspace
        pageData={{
          walletId: "wallet-1",
          borrowSessionSeed: "{}",
          poolCatalog: [market],
          borrowableAssets: [unsupportedAsset],
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
        }}
      />,
    )

    fireEvent.click(screen.getByText("open-borrow"))
    expect(push).toHaveBeenCalledWith(borrowAssetDetailPath(unsupportedAsset.id))
  })
})
