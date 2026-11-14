import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { createDataSourceAdapter } from "@/app/lib/data/core/source-runtime"
import { fetchBorrowPage } from "@/app/lib/data/providers/borrow"
import type { BorrowPageData, BorrowPageSource } from "@/app/lib/data/providers/borrow"
import { fetchLendPage } from "@/app/lib/data/providers/lend"
import type { LendPageData, LendPageSource } from "@/app/lib/data/providers/lend"
import { fetchMultiplyPage } from "@/app/lib/data/providers/multiply"
import type { MultiplyPageData, MultiplyPageSource } from "@/app/lib/data/providers/multiply"
import { fetchPortfolioPage, resolvePortfolioWalletProfileId } from "@/app/lib/data/providers/portfolio"
import type { PortfolioPageSource } from "@/app/lib/data/providers/portfolio"
import { fetchRewardsPage } from "@/app/lib/data/providers/rewards"
import type { RewardsPageData, RewardsPageSource } from "@/app/lib/data/providers/rewards"
import { mockPortfolioPageSource } from "@/app/lib/data/mock/wallet/portfolio/source"

describe("page providers", () => {
  beforeEach(() => {
    vi.stubEnv("AVANA_DATA_SOURCE", "mock")
  })

  afterEach(() => {
    vi.unstubAllEnvs()
  })

  it("fetches borrow page data from the default source", async () => {
    const data = await fetchBorrowPage()

    expect(data.poolCatalog.length).toBeGreaterThan(0)
    expect(data.heroMetrics.totalTvlUsd).toBeGreaterThan(0)
    expect(data.heroMetrics.totalCollateralUsd).toBeGreaterThan(0)
    expect(data.heroMetrics.availableCreditUsd).toBeGreaterThan(0)
    expect(data.heroMetrics.outstandingLoansUsd).toBeGreaterThan(0)
  })

  it("accepts a borrow source override", async () => {
    const source: BorrowPageSource = {
      adapter: createDataSourceAdapter({ id: "borrow-test", label: "Borrow test source", mode: "mock" }),
      async getBorrowPageData() {
        return {
          data: {
            walletId: "wallet-override",
            borrowSessionSeed: '{"stub":true}',
            poolCatalog: [
              {
                id: "custom-eth-usdc",
                name: "ETH / USDC",
                tvlUsd: 1000,
                availableUsd: 250,
                totalBorrowedUsd: 750,
                aprMin: 4.5,
                aprMax: 5.5,
                change24hPct: 1.2,
                visuals: [
                  { symbol: "ETH", iconUrl: "https://example.com/eth.png" },
                  { symbol: "USDC", iconUrl: "https://example.com/usdc.png" },
                ],
              },
            ] as unknown as BorrowPageData["poolCatalog"],
            borrowableAssets: [
              {
                id: "usdc",
                symbol: "USDC",
                name: "USD Coin",
              },
            ] as unknown as BorrowPageData["borrowableAssets"],
            pendingRows: [{ id: "pending-1" }] as unknown as BorrowPageData["pendingRows"],
            dexes: [{ id: "custom", label: "Custom" }] as unknown as BorrowPageData["dexes"],
            collateralPools: [{ id: "pool-1", name: "ETH / USDC" }] as unknown as BorrowPageData["collateralPools"],
            initialDebts: { "pool-1": 0 },
            borrowSnapshot: {
              totalBorrowedUsd: 0,
              availableCreditUsd: 1000,
              totalCollateralUsd: 1500,
              liquidationValueUsd: 1200,
              healthFactor: null,
            },
            heroMetrics: {
              totalTvlUsd: 1000,
              totalCollateralUsd: 1500,
              availableCreditUsd: 250,
              outstandingLoansUsd: 750,
              totalTvlChangePct: 1.2,
            },
          },
        }
      },
    }

    const data = await fetchBorrowPage(source)
    expect(data.poolCatalog[0]?.id).toBe("custom-eth-usdc")
    expect(data.heroMetrics.totalTvlUsd).toBe(1000)
  })

  it("fetches lend page data from the default source", async () => {
    const data = await fetchLendPage()

    expect(data.markets.length).toBeGreaterThan(0)
    expect(data.assetGroups.length).toBeGreaterThan(0)
    expect(data.featuredSequence.length).toBeGreaterThan(0)
    expect(data.featuredSnapshots.length).toBe(3)
    expect(data.assetGroups.flatMap((group) => group.rows).length).toBeGreaterThan(10)
  })

  it("accepts a lend source override", async () => {
    const source: LendPageSource = {
      adapter: createDataSourceAdapter({ id: "lend-test", label: "Lend test source", mode: "mock" }),
      async getLendPageData() {
        return {
          data: {
            tokens: [
              {
                symbol: "USDC",
                name: "USD Coin",
                balance: 1,
                price: 1,
                color: "blue",
                bg: "bg",
                apy: 5,
                earned: 1,
                daily: 1,
                utilization: 10,
              },
            ] as unknown as LendPageData["tokens"],
            markets: [
              {
                symbol: "DAI",
                name: "Dai",
                apy: 4,
                apyChange24h: 0.2,
                tvl: "$1.0M",
                utilization: 50,
                type: "Liquid",
                protocol: "Maker",
                color: "orange",
                bg: "bg",
                soon: false,
                event: null,
              },
            ] as unknown as LendPageData["markets"],
            activity: [
              { type: "deposit", asset: "USDC", amount: "+10", date: "Today" },
            ] as unknown as LendPageData["activity"],
            chartSeries: [{ time: "00:00", value: 1 }],
            featuredAssets: {
              usdc: {
                id: "usdc",
                symbol: "USDC",
                displayName: "USD Coin",
                eyebrow: "Prime",
                apy: 3.2,
                tone: "blue",
                iconUrl: "https://example.com/usdc.png",
                path: "M0,0L10,10",
              },
            } as unknown as LendPageData["featuredAssets"],
            featuredSequence: ["usdc"] as unknown as LendPageData["featuredSequence"],
            featuredSnapshots: [{ marketId: "usdc", symbol: "USDC", href: "/lend/markets/usdc", apyLabel: "3.20%" }],
            assetGroups: [
              { title: "Stablecoins", rows: [{ symbol: "USDC", name: "USD Coin", apy: "3.2%" }] },
            ] as unknown as LendPageData["assetGroups"],
          },
        }
      },
    }

    const data = await fetchLendPage(source)
    expect(data.featuredSequence).toEqual(["usdc"])
  })

  it("fetches multiply page data from the default source", async () => {
    const data = await fetchMultiplyPage()

    expect(data.markets.length).toBeGreaterThan(0)
    expect(data.lendRows.length).toBeGreaterThan(0)
    expect(data.trendingSnapshots.length).toBe(3)
    expect(data.pageSize).toBeGreaterThan(0)
  })

  it("accepts a multiply source override", async () => {
    const source: MultiplyPageSource = {
      adapter: createDataSourceAdapter({ id: "multiply-test", label: "Multiply test source", mode: "mock" }),
      async getMultiplyPageData() {
        return {
          data: {
            markets: [
              {
                symbol: "ETH",
                name: "Ethereum",
                price: 3000,
                funding: 0.01,
                change: 1,
                volume: 1000,
                maxLeverage: 10,
                longOi: 60,
                shortOi: 40,
              },
            ] as unknown as MultiplyPageData["markets"],
            heroMetrics: { totalLiquidityUsd: 1000, marketCount: 1, averageMaxApy: 0.075, averageMaxLeverage: 10 },
            lendRows: [
              {
                href: "/multiply/markets/eth-usdc",
                protocol: "ETH",
                protocolLogo: "https://example.com/eth.png",
                asset: "USDC",
                kind: "Loop",
                apy: "7.50%",
                apyLabel: "Custom",
                collateralFactor: 0.8,
                liquidationThreshold: 0.85,
              },
            ] as unknown as MultiplyPageData["lendRows"],
            trendingSnapshots: [],
            pageSize: 24,
            tokenLogos: { ETH: "https://example.com/eth.png" } as unknown as MultiplyPageData["tokenLogos"],
          },
        }
      },
    }

    const data = await fetchMultiplyPage(source)
    expect(data.pageSize).toBe(24)
  })

  // The default rewards source (liveRewardsPageSource) requires an authenticated
  // Convex client — that path is exercised by real-app integration tests, not
  // here. This test only covers the override path.
  it("accepts a rewards source override", async () => {
    const source: RewardsPageSource = {
      adapter: createDataSourceAdapter({ id: "rewards-test", label: "Rewards test source", mode: "mock" }),
      async getRewardsPageData(input) {
        return {
          data: {
            walletProfileId: input.walletProfileId,
            promoTabs: [{ id: "new-users", label: "New users" }] as unknown as RewardsPageData["promoTabs"],
            questsByTab: {
              "new-users": [
                {
                  id: "quest-1",
                  title: "Connect wallet",
                  description: "Start profile",
                  reward: "25 AVA",
                  cta: "Connect",
                  category: "Setup",
                  iconId: "wallet",
                },
              ],
            } as unknown as RewardsPageData["questsByTab"],
          },
        }
      },
    }

    const data = await fetchRewardsPage({ walletProfileId: "wallet-1" }, source)
    expect(data.walletProfileId).toBe("wallet-1")
    expect(data.questsByTab["new-users"]!.length).toBe(1)
  })

  it("fetches portfolio page data from the default source", async () => {
    const data = await fetchPortfolioPage({ walletProfileId: await resolvePortfolioWalletProfileId() })

    expect(data.walletProfile.id).toBeTruthy()
    expect(data.activity.rows.length).toBeGreaterThan(0)
    expect(data.borrow.collateralPositions.length).toBeGreaterThan(0)
  })

  it("accepts a portfolio source override", async () => {
    const source: PortfolioPageSource = {
      adapter: createDataSourceAdapter({ id: "portfolio-test", label: "Portfolio test source", mode: "mock" }),
      getDefaultWalletProfileId() {
        return "wallet-override"
      },
      async getPortfolioPageRecords(walletProfileId) {
        const records = await mockPortfolioPageSource.getPortfolioPageRecords(await resolvePortfolioWalletProfileId())
        return {
          ...records,
          data: {
            ...records.data,
            walletProfile: {
              ...records.data.walletProfile,
              id: walletProfileId,
              displayName: "Override wallet",
            },
          },
        }
      },
    }

    const data = await fetchPortfolioPage({ walletProfileId: "wallet-override" }, { source })
    expect(data.walletProfile.id).toBe("wallet-override")
    expect(data.walletProfile.displayName).toBe("Override wallet")
  })
})
