// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import { marketFreshness } from "./askAITools"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")
const WALLET_A = "0x00000000000000000000000000000000000000aa"
const WALLET_B = "0x00000000000000000000000000000000000000bb"

async function seedPosition(t: ReturnType<typeof convexTest>, wallet: string, marketSlug: string) {
  return await t.run(async (ctx) =>
    ctx.db.insert("positions", {
      wallet,
      product: "multiply",
      marketSlug,
      assetId: "ETH",
      status: "open",
      collateralValueUsd: 10_000,
      debtValueUsd: 3_500,
      ltv: 0.35,
      healthFactor: 1.857,
      openedAt: 1,
      lastUpdatedAt: 2,
    }),
  )
}

describe("Ask AI authenticated portfolio tools", () => {
  test("returns a wallet-required result for a guest", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.withIdentity({ subject: "ask-guest:test" }).query(api.askAITools.borrowCapacity, {}),
    ).resolves.toMatchObject({
      walletRequired: true,
    })
  })

  test("does not expose another wallet's position", async () => {
    const t = convexTest(schema, modules)
    const ownId = await seedPosition(t, WALLET_A, "eth-usdc")
    const otherId = await seedPosition(t, WALLET_B, "wbtc-usdc")
    const asA = t.withIdentity({ subject: WALLET_A })

    await expect(asA.query(api.askAITools.positionRisk, { positionId: ownId })).resolves.toMatchObject({
      wallet: WALLET_A,
      dataProvenance: "sandbox",
      positions: [expect.objectContaining({ marketSlug: "eth-usdc" })],
    })
    await expect(asA.query(api.askAITools.positionRisk, { positionId: otherId })).rejects.toThrow("Position not found")
  })

  test("simulates the requested borrow amount without mutating the position", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seedPosition(t, WALLET_A, "eth-usdc")
    await t.run(async (ctx) =>
      ctx.db.insert("borrowMarkets", {
        slug: "eth-usdc",
        kind: "pool",
        chainId: 1,
        name: "ETH / USDC",
        symbol: "ETH/USDC",
        maxLtvPct: 55,
        createdAt: 1,
      }),
    )
    await t.run(async (ctx) =>
      ctx.db.insert("pools", {
        slug: "eth-usdc",
        name: "ETH / USDC",
        venue: "Uniswap v3",
        category: "v3",
        visuals: [
          { symbol: "ETH", shortLabel: "ETH", bgClassName: "", textClassName: "" },
          { symbol: "USDC", shortLabel: "USDC", bgClassName: "", textClassName: "" },
        ],
        maxLtvPct: 55,
        pairAprPct: 5,
        createdAt: 1,
      }),
    )
    const asA = t.withIdentity({ subject: WALLET_A })

    await expect(
      asA.query(api.askAITools.simulateBorrow, {
        positionId,
        additionalBorrowAmount: 1_000,
        borrowAsset: "USDC",
      }),
    ).resolves.toMatchObject({
      dataProvenance: "sandbox",
      additionalBorrowAmount: 1_000,
      simulation: {
        current: { debtValueUsd: 3_500, ltv: 0.35 },
        projected: { debtValueUsd: 4_500, ltv: 0.45 },
        remainingBorrowCapacityUsd: 1_000,
      },
      interestProjection: {
        borrowAprPct: 5,
        days: 365,
        incrementalInterestUsd: 50,
        totalProjectedInterestUsd: 225,
        onAdditionalBorrowUsd: 1_000,
        onDebtUsd: 4_500,
      },
    })
    await expect(t.run(async (ctx) => ctx.db.get(positionId))).resolves.toMatchObject({ debtValueUsd: 3_500 })
  })

  test("stress-tests the owned position with the requested shock", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seedPosition(t, WALLET_A, "eth-usdc")
    await t.run(async (ctx) =>
      ctx.db.insert("multiplyTokenParameters", {
        symbol: "ETH",
        supplyApyPct: 3,
        borrowAprPct: 5,
        availableUsd: 1_000_000,
        collateralFactorPct: 55,
        liquidationThresholdPct: 65,
        iconUrl: "/eth.svg",
        updatedAt: 1,
      }),
    )

    await expect(
      t.withIdentity({ subject: WALLET_A }).query(api.askAITools.stressPosition, {
        positionId,
        assetPriceChanges: [{ symbol: "ETH", change: -0.2 }],
      }),
    ).resolves.toMatchObject({
      dataProvenance: "sandbox",
      simulation: {
        weightedCollateralChange: -0.2,
        projected: { collateralValueUsd: 8_000, debtValueUsd: 3_500 },
      },
    })
  })

  test("stamps sandbox provenance on portfolio and borrow-capacity reads", async () => {
    const t = convexTest(schema, modules)
    await seedPosition(t, WALLET_A, "eth-usdc")
    const asA = t.withIdentity({ subject: WALLET_A })

    await expect(asA.query(api.askAITools.portfolio, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(asA.query(api.askAITools.borrowCapacity, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(asA.query(api.askAITools.engineSnapshot, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
  })

  test("reports multiply Net APY in percent, recomputed from the market, not the stored 0", async () => {
    const t = convexTest(schema, modules)
    // Prod shape: the sandbox persists netApyPct 0 at open (20 of 21 open loops on 2026-09-22).
    const positionId = await t.run(async (ctx) =>
      ctx.db.insert("positions", {
        wallet: WALLET_A,
        product: "multiply",
        marketSlug: "aave-gho",
        status: "open",
        collateralValueUsd: 20_000,
        debtValueUsd: 10_000,
        netApyPct: 0,
        openedAt: 1,
        lastUpdatedAt: 2,
      }),
    )
    const asA = t.withIdentity({ subject: WALLET_A })
    // aave-gho: supply 7.6%, borrow 3.9% → (0.076×20k − 0.039×10k) / 10k equity = 11.3%.
    const snapshot = (await asA.query(api.askAITools.engineSnapshot, {})) as {
      multiply: Array<{ netApyPct: number | null }>
    }
    expect(snapshot.multiply[0].netApyPct).toBeCloseTo(11.3, 6)
    const risk = await asA.query(api.askAITools.positionRisk, { positionId })
    expect(risk.positions?.[0]?.netApyPct).toBeCloseTo(11.3, 6)
    const portfolio = (await asA.query(api.askAITools.portfolio, {})) as { totals: { netApyPct: number } }
    expect(portfolio.totals.netApyPct).toBeCloseTo(11.3, 6)
  })

  test("Net Value does not count a lend withdrawal twice (liquid row + lend available mirror)", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      // Prod shape (2026-09-22): a withdrawal credited both the liquid AAVE row and lend `available`.
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET_A,
        assetId: "aave",
        symbol: "AAVE",
        amount: 1,
        valueUsd: 120,
        state: "available",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: WALLET_A,
        marketId: "aave",
        assetId: "aave",
        symbol: "AAVE",
        amount: 1,
        valueUsd: 120,
        state: "available",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: WALLET_A,
        marketId: "usdc",
        assetId: "usdc",
        symbol: "USDC",
        amount: 1_000,
        valueUsd: 1_000,
        state: "deposited",
        updatedAt: 1,
      })
    })
    const portfolio = (await t.withIdentity({ subject: WALLET_A }).query(api.askAITools.portfolio, {})) as {
      totals: { netValueUsd: number }
    }
    expect(portfolio.totals.netValueUsd).toBe(1_120)
  })

  test("returns authoritative per-tranche Umbrella cooldown timing", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      const positionId = await ctx.db.insert("positions", {
        wallet: WALLET_A,
        product: "umbrella",
        marketSlug: "gho",
        assetId: "GHO",
        status: "open",
        suppliedUsd6: "5000000000",
        cooldownAmountUsd6: "2500000000",
        cooldownStartedAt: now - 86_400_000,
        cooldownEndsAt: now + 6 * 86_400_000,
        withdrawalWindowEndsAt: now + 8 * 86_400_000,
        openedAt: now - 10 * 86_400_000,
        lastUpdatedAt: now,
      })
      await ctx.db.insert("umbrellaCooldownTranches", {
        positionId,
        wallet: WALLET_A,
        marketId: "gho",
        amountUsd6: "2500000000",
        startedAt: now - 86_400_000,
        endsAt: now + 6 * 86_400_000,
        windowEndsAt: now + 8 * 86_400_000,
        status: "cooling",
        createdAt: now,
        updatedAt: now,
      })
    })

    const result = await t.withIdentity({ subject: WALLET_A }).query(api.askAITools.portfolio, {})
    if (result.walletRequired) throw new Error("Expected an authenticated portfolio result")
    expect(result.umbrellaCooldownSummary).toMatchObject({
      coolingCount: 1,
      coolingUsd: 2_500,
      readyCount: 0,
    })
    expect(result.umbrellaCooldowns).toEqual([
      expect.objectContaining({
        marketId: "gho",
        amountUsd: 2_500,
        status: "cooling",
        canWithdraw: false,
      }),
    ])
    expect(result.umbrellaCooldowns[0]?.remainingCooldownMs).toBeGreaterThan(5 * 86_400_000)
    expect(result.umbrella[0]).toMatchObject({
      marketSlug: "gho",
      cooldownUsd: 2_500,
      lifecycleStatus: "partiallyCooling",
    })
  })

  test("falls back to portfolio capacity using Borrow-product debt only", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("portfolioCurrent", {
        wallet: WALLET_A,
        at: now,
        totalValueUsd: 50_000,
        totalSuppliedUsd: 20_000,
        totalBorrowedUsd: 3_000,
        availableToBorrowUsd: 7_500,
        totalMultiplyExposureUsd: 0,
        totalEarnedUsd: 0,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet: WALLET_A,
        marketId: "eth-usdc",
        assetId: "usdc",
        poolId: "eth-usdc",
        symbol: "USDC",
        amount: 3_000,
        valueUsd: 3_000,
        state: "debt",
        updatedAt: now,
      })
    })

    await expect(t.withIdentity({ subject: WALLET_A }).query(api.askAITools.borrowCapacity, {})).resolves.toMatchObject(
      {
        walletRequired: false,
        capacity: {
          borrowCapacityUsd: 10_500,
          availableBorrowCapacityUsd: 7_500,
          totalBorrowedUsd: 3_000,
          source: "portfolio_current",
        },
        asOf: now,
      },
    )
  })

  test("does not treat starter Multiply debt as Borrow debt", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("portfolioCurrent", {
        wallet: WALLET_A,
        at: now,
        totalValueUsd: 750_000,
        totalSuppliedUsd: 1_250_000,
        totalBorrowedUsd: 250_000,
        availableToBorrowUsd: 245_000,
        totalMultiplyExposureUsd: 500_000,
        totalEarnedUsd: 0,
      })
      await ctx.db.insert("walletMultiplyBalances", {
        wallet: WALLET_A,
        marketId: "aave-gho",
        assetId: "gho",
        symbol: "GHO",
        amount: 250_000,
        valueUsd: 250_000,
        state: "debt",
        updatedAt: now,
      })
    })

    await expect(t.withIdentity({ subject: WALLET_A }).query(api.askAITools.borrowCapacity, {})).resolves.toMatchObject(
      {
        capacity: {
          borrowCapacityUsd: 245_000,
          availableBorrowCapacityUsd: 245_000,
          totalBorrowedUsd: 0,
          noDebt: true,
          healthFactor: null,
          source: "portfolio_current",
        },
      },
    )
  })
})

describe("Ask AI normalized market tools", () => {
  test("rejects provider values after their data-kind freshness window", () => {
    const now = 2_000_000
    expect(marketFreshness("token_price", now - 19 * 60_000, now)).toBe("fresh")
    expect(marketFreshness("token_price", now - 21 * 60_000, now)).toBe("stale")
    expect(marketFreshness("dex_pool", now - 31 * 60_000, now)).toBe("stale")
  })

  test("searches canonical markets and labels provider freshness", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: "eth-usdc",
        chainId: 1,
        name: "ETH / USDC",
        symbol: "ETH/USDC",
        venueLabel: "Uniswap v3",
        createdAt: 1,
      })
      await ctx.db.insert("askAIMarketSnapshots", {
        source: "defillama",
        kind: "dex_pool",
        key: "eth-usdc",
        payload: { liquidityUsd: 4_000_000, volume24h: 500_000 },
        sourceUpdatedAt: now,
        fetchedAt: now,
      })
      await ctx.db.insert("tokenPrices", {
        symbol: "weth",
        llamaId: "coingecko:ethereum",
        priceUsd: 4_321,
        confidence: 0.99,
        sourceUpdatedAt: now,
        fetchedAt: now,
        snapshotAt: now,
        status: "fresh",
        source: "defillama",
        updatedAt: now,
      })
    })

    await expect(t.query(api.askAITools.searchMarkets, { query: "ETH" })).resolves.toMatchObject({
      markets: [expect.objectContaining({ slug: "eth-usdc" })],
      providerData: expect.arrayContaining([
        expect.objectContaining({
          source: "defillama",
          kind: "token_price",
          key: "weth",
          data: expect.objectContaining({ priceUsd: 4_321 }),
        }),
      ]),
    })
    await expect(t.query(api.askAITools.poolMetrics, { marketId: "eth-usdc" })).resolves.toMatchObject({
      market: expect.objectContaining({ name: "ETH / USDC" }),
      providerData: [expect.objectContaining({ source: "defillama", freshness: "fresh" })],
    })
  })

  test("ranks the exact cached token quote first for a natural price question", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "aave",
        llamaId: "coingecko:aave",
        priceUsd: 123.98,
        confidence: 0.99,
        sourceUpdatedAt: now,
        fetchedAt: now,
        snapshotAt: now,
        status: "fresh",
        source: "defillama",
        updatedAt: now,
      })
      await ctx.db.insert("askAIMarketSnapshots", {
        source: "aave",
        kind: "lending_market",
        key: "aave-v3-usdc",
        payload: {
          market: "AaveV3Ethereum",
          name: "Aave token lending market",
          symbol: "USDC",
          sizeUsd: 2_000_000_000,
        },
        sourceUpdatedAt: now,
        fetchedAt: now,
      })
    })

    const result = await t.query(api.askAITools.searchMarkets, { query: "What's Aave token price now?" })
    expect(result.providerData[0]).toMatchObject({
      kind: "token_price",
      key: "aave",
      data: { priceUsd: 123.98 },
    })
  })

  test("maps natural asset names to canonical cached price symbols", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "btc",
        llamaId: "coingecko:bitcoin",
        priceUsd: 77_856.08,
        confidence: 0.99,
        sourceUpdatedAt: now,
        fetchedAt: now,
        snapshotAt: now,
        status: "fresh",
        source: "defillama",
        updatedAt: now,
      })
      for (const [symbol, priceUsd] of [
        ["wbtc", 77_810],
        ["cbbtc", 77_805],
      ] as const)
        await ctx.db.insert("tokenPrices", {
          symbol,
          llamaId: `coingecko:${symbol}`,
          priceUsd,
          confidence: 0.99,
          sourceUpdatedAt: now,
          fetchedAt: now,
          snapshotAt: now,
          status: "fresh",
          source: "defillama",
          updatedAt: now,
        })
    })

    const result = await t.query(api.askAITools.searchMarkets, { query: "What is Bitcoin's price now?" })
    expect(result.providerData[0]).toMatchObject({
      kind: "token_price",
      key: "btc",
      data: { priceUsd: 77_856.08 },
    })
  })

  test("reads only the indexed requested token and its bounded history", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      for (const [symbol, priceUsd] of [
        ["uni", 7.25],
        ["eth", 2_500],
      ] as const) {
        await ctx.db.insert("tokenPrices", {
          symbol,
          llamaId: `coingecko:${symbol}`,
          priceUsd,
          sourceUpdatedAt: now,
          fetchedAt: now,
          snapshotAt: now,
          status: "fresh",
          source: "defillama",
          updatedAt: now,
        })
        await ctx.db.insert("tokenPricesHistory", {
          symbol,
          day: "2026-08-21",
          priceUsd,
          updatedAt: now,
        })
      }
    })

    const result = await t.query(api.askAITools.searchMarkets, { query: "What's the Uniswap token price?" })
    expect(result.markets).toEqual([])
    expect(result.providerData).toEqual([
      expect.objectContaining({
        key: "uni",
        kind: "token_price",
        history: [{ day: "2026-08-21", priceUsd: 7.25 }],
      }),
    ])
  })

  test("returns DEX pool metrics instead of lending rows for a pool lookup", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("askAIMarketSnapshots", {
        source: "defillama",
        kind: "dex_pool",
        key: "defillama:usdc-pool",
        payload: { project: "uniswap-v3", symbol: "USDC-WETH", tvlUsd: 42_000_000, apy: 6.2 },
        sourceUpdatedAt: now,
        fetchedAt: now,
      })
      await ctx.db.insert("askAIMarketSnapshots", {
        source: "aave",
        kind: "lending_market",
        key: "aave:usdc",
        payload: { market: "AaveV3Ethereum", symbol: "USDC", sizeUsd: 2_000_000_000 },
        sourceUpdatedAt: now,
        fetchedAt: now,
      })
    })

    const result = await t.query(api.askAITools.searchMarkets, { query: "What are the best USDC pools?" })
    expect(result.providerData).toEqual([
      expect.objectContaining({
        kind: "dex_pool",
        data: expect.objectContaining({ symbol: "USDC-WETH", tvlUsd: 42_000_000, apyPct: 6.2 }),
      }),
    ])
  })

  test("uses only Aave lending rows and ranks an APY threshold from the same result set", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      for (const [source, key, payload] of [
        [
          "aave",
          "aave:usdc",
          { market: "AaveV3Ethereum", name: "USD Coin", symbol: "USDC", supplyApyPct: 3.35, sizeUsd: 2e9 },
        ],
        ["aave", "aave:gho", { market: "AaveV3Ethereum", name: "GHO", symbol: "GHO", supplyApyPct: 4.2, sizeUsd: 1e8 }],
        ["defillama", "sky:susds", { project: "sky-lending", symbol: "sUSDS", apy: 8.4, tvlUsd: 4e9 }],
      ] as const)
        await ctx.db.insert("askAIMarketSnapshots", {
          source,
          kind: source === "aave" ? "lending_market" : "dex_pool",
          key,
          payload,
          sourceUpdatedAt: now,
          fetchedAt: now,
        })
    })

    const result = await t.query(api.askAITools.searchMarkets, {
      query: "Any Aave lending markets offering at least 4% APY?",
    })

    expect(result.markets).toEqual([])
    expect(result.providerData).toEqual([
      expect.objectContaining({
        source: "aave",
        kind: "lending_market",
        key: "aave:gho",
        data: expect.objectContaining({ symbol: "GHO", supplyApyPct: 4.2 }),
      }),
      expect.objectContaining({ source: "aave", key: "aave:usdc" }),
    ])
  })
})
