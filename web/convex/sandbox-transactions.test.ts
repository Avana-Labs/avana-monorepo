// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"
import { MAX_TX_PER_HOUR, upsertPortfolioCurrent } from "./sandbox/transactions"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xDdD0000000000000000000000000000000000002"

function borrowIntent(intentId: string, overrides: Record<string, unknown> = {}) {
  return {
    wallet: WALLET,
    intentId,
    product: "borrow" as const,
    kind: "borrow",
    marketSlug: "uni-v3-bluechip-weth-usdc",
    assetId: "uni-v2:usdc",
    requestedAmountUsd6: "1000000000",
    executedAmountUsd6: "1000000000",
    amountUsd: 1000,
    simulated: true,
    ...overrides,
  }
}

async function seedBorrowCollateral(t: ReturnType<typeof convexTest>, valueUsd = 2000) {
  await t.run(async (ctx) => {
    await ctx.db.insert("walletBorrowBalances", {
      wallet: WALLET.toLowerCase(),
      marketId: "uni-v3-bluechip-weth-usdc",
      poolId: "uni-v3-bluechip-weth-usdc",
      symbol: "WETH/USDC",
      amount: valueUsd,
      valueUsd,
      state: "collateral",
      updatedAt: 1,
    })
  })
}

async function seedMultiplyCollateral(t: ReturnType<typeof convexTest>, valueUsd = 1000) {
  await t.run(async (ctx) => {
    await ctx.db.insert("walletLiquidBalances", {
      wallet: WALLET.toLowerCase(),
      assetId: "eth",
      symbol: "ETH",
      amount: 1,
      valueUsd,
      state: "available",
      updatedAt: 1,
    })
  })
}

describe("recordTransaction — ownership, idempotency, rate limit, ledger", () => {
  test("rejects unauthenticated calls", async () => {
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("i1"))).rejects.toThrow(
      /UNAUTHENTICATED/,
    )
  })

  test("rejects a wallet that does not match the authed identity", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("i1", { wallet: OTHER })),
    ).rejects.toThrow(/WALLET_MISMATCH/)
  })

  test("writes exactly one transaction row + a position, and the ledger delta", async () => {
    const t = convexTest(schema, modules)
    await seedBorrowCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    const res = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("i1", {
        position: {
          status: "open",
          marketSlug: "uni-v3-bluechip-weth-usdc",
          debtValueUsd6: "1000000000",
          collateral: [
            {
              marketSlug: "uni-v3-bluechip-weth-usdc",
              collateralShares: "2000000000",
              principalTokenAmount: "2000000000",
              collateralEnabled: true,
              collateralValueUsd6: "2000000000",
            },
          ],
          debt: [
            {
              assetId: "uni-v2:usdc",
              baseAssetId: "usdc",
              debtSharesUsd6: "1000000000",
              debtIndexRay: "1000000000000000000000000000",
              borrowRateWad: "50000000000000000",
              principalBorrowedUsd6: "1000000000",
            },
          ],
        },
      }),
    )
    expect(res.idempotent).toBe(false)
    expect(res.receipt.status).toBe("success")
    expect(res.receipt.hash).toMatch(/^sim-borrow-borrow-/)

    const activity = await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })
    expect(activity).toHaveLength(1)
    expect(activity[0]?.kind).toBe("borrow")

    const positions = await asUser.query(api.sandbox.transactions.getPositions, { wallet: WALLET })
    expect(positions).toHaveLength(1)
    expect(positions[0]?.product).toBe("borrow")
    expect(positions[0]?.debtValueUsd6).toBe("1000000000")
    expect(positions[0]?.collateral).toHaveLength(1)
    expect(positions[0]?.debt).toHaveLength(1)

    // The aggregate ledger delta is recomputed server-side (there is no client ledger
    // arg), keyed by the borrowed asset, never anything the client could dictate.
    expect(await asUser.query(api.liquidity.listDeltas)).toEqual([])

    const portfolio = await asUser.query(api.sandbox.transactions.getPortfolio, { wallet: WALLET })
    expect(portfolio.latest?.totalBorrowedUsd).toBe(1000)
    // Borrow credits the liquid wallet, so net portfolio stays flat (cash +1000, debt +1000).
    expect(portfolio.latest?.totalValueUsd).toBe(0)
    const risk = await asUser.query(api.sandbox.transactions.getRiskSeries, { wallet: WALLET })
    expect(risk).toEqual([
      expect.objectContaining({
        healthFactorWad: "1700000000000000000",
        trigger: "borrow",
      }),
    ])
  })

  test("rejects malformed fixed-point position state before writing", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("invalid", {
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            debtValueUsd6: "-1",
          },
        }),
      ),
    ).rejects.toThrow(/INVALID_POSITION/)

    expect(await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })).toHaveLength(0)
  })

  test("rejects oversized fixed-point strings before BigInt parsing or writes", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("oversized-fixed-point", { requestedAmountUsd6: "9".repeat(100_000) }),
      ),
    ).rejects.toThrow(/INVALID_POSITION/)
    expect(await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })).toHaveLength(0)
  })

  test("rejects oversized idempotency keys before indexed reads or writes", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("x".repeat(100_000))),
    ).rejects.toThrow(/intentId must contain 1 to 200 characters/)
    expect(await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })).toHaveLength(0)
  })

  test("rejects client amounts that do not match the fixed-point execution", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })

    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("invalid-amount", { amountUsd: 50_000 }),
      ),
    ).rejects.toThrow(/INVALID_TRANSITION/)
    expect(await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })).toHaveLength(0)
  })

  test("lend deposit succeeds when the positions row lags the product-balance ledger", async () => {
    const t = convexTest(schema, modules)
    // Desync: the product-balance ledger has a live $50 USDC deposit, but the positions row for
    // the same market is stale/closed at $0. Before the fix this made the next deposit fail with
    // INVALID_TRANSITION because the transition check read the stale positions row (before=0).
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("positions", {
        wallet: w,
        product: "lend",
        marketSlug: "usdc",
        status: "closed",
        suppliedUsd6: "0",
        earnedUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: w,
        marketId: "usdc",
        assetId: "usdc",
        symbol: "USDC",
        amount: 50,
        valueUsd: 50,
        state: "deposited",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "usdc",
        symbol: "USDC",
        amount: 10,
        valueUsd: 10,
        state: "available",
        updatedAt: 1,
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })
    const res = await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "lend-desync",
      product: "lend" as const,
      kind: "deposit",
      marketSlug: "usdc",
      assetId: "usdc",
      requestedAmountUsd6: "10000000",
      executedAmountUsd6: "10000000",
      amountUsd: 10,
      simulated: true,
      expectedRevision: 0,
      position: { status: "open" as const, marketSlug: "usdc", suppliedUsd6: "60000000", earnedUsd6: "0" },
    })
    expect(res.receipt.status).toBe("success")
    // The write re-syncs both sources to the new $60 balance.
    const positions = await asUser.query(api.sandbox.transactions.getPositions, { wallet: WALLET })
    const lend = positions.find((p) => p.product === "lend")
    expect(lend?.suppliedUsd6).toBe("60000000")
    expect(lend?.status).toBe("open")
  })

  test("rejects a deposit that exceeds the wallet's liquid balance (affordability)", async () => {
    const t = convexTest(schema, modules)
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("positions", {
        wallet: w,
        product: "lend",
        marketSlug: "usdc",
        status: "open",
        suppliedUsd6: "0",
        earnedUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: w,
        marketId: "usdc",
        assetId: "usdc",
        symbol: "USDC",
        amount: 0,
        valueUsd: 0,
        state: "deposited",
        updatedAt: 1,
      })
      // Only $5 of liquid USDC on hand.
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "usdc",
        symbol: "USDC",
        amount: 5,
        valueUsd: 5,
        state: "available",
        updatedAt: 1,
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordTransaction, {
        wallet: WALLET,
        intentId: "afford-over",
        product: "lend" as const,
        kind: "deposit",
        marketSlug: "usdc",
        assetId: "usdc",
        requestedAmountUsd6: "10000000",
        executedAmountUsd6: "10000000",
        amountUsd: 10,
        simulated: true,
        expectedRevision: 0,
        position: { status: "open" as const, marketSlug: "usdc", suppliedUsd6: "10000000", earnedUsd6: "0" },
      }),
    ).rejects.toThrow(/INSUFFICIENT_BALANCE/)
  })

  test("rejects a deposit when the authenticated wallet has no liquid source row", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordTransaction, {
        wallet: WALLET,
        intentId: "afford-missing",
        product: "lend" as const,
        kind: "deposit",
        marketSlug: "usdc",
        assetId: "usdc",
        requestedAmountUsd6: "10000000",
        executedAmountUsd6: "10000000",
        amountUsd: 10,
        simulated: true,
        position: { status: "open" as const, marketSlug: "usdc", suppliedUsd6: "10000000", earnedUsd6: "0" },
      }),
    ).rejects.toThrow(/INSUFFICIENT_BALANCE/)

    expect(await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })).toHaveLength(0)
  })

  test("allows a deposit within the wallet's liquid balance", async () => {
    const t = convexTest(schema, modules)
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("positions", {
        wallet: w,
        product: "lend",
        marketSlug: "usdc",
        status: "open",
        suppliedUsd6: "0",
        earnedUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: w,
        marketId: "usdc",
        assetId: "usdc",
        symbol: "USDC",
        amount: 0,
        valueUsd: 0,
        state: "deposited",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "usdc",
        symbol: "USDC",
        amount: 100,
        valueUsd: 100,
        state: "available",
        updatedAt: 1,
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })
    const res = await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "afford-ok",
      product: "lend" as const,
      kind: "deposit",
      marketSlug: "usdc",
      assetId: "usdc",
      requestedAmountUsd6: "10000000",
      executedAmountUsd6: "10000000",
      amountUsd: 10,
      simulated: true,
      expectedRevision: 0,
      position: { status: "open" as const, marketSlug: "usdc", suppliedUsd6: "10000000", earnedUsd6: "0" },
    })
    expect(res.receipt.status).toBe("success")
  })

  test("idempotent on intentId — a replay returns the existing row and does not double-apply", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    const first = await asUser.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("dup"))
    const second = await asUser.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("dup"))
    expect(second.idempotent).toBe(true)
    expect(second.transactionId).toBe(first.transactionId)

    const activity = await asUser.query(api.sandbox.transactions.getActivity, { wallet: WALLET })
    expect(activity).toHaveLength(1)
  })

  test("deduplicates cross-store Umbrella copies by hash, action, and market", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    const wallet = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("transactions", {
        wallet,
        intentId: "umbrella-stake-weth",
        product: "umbrella",
        kind: "stake",
        status: "success",
        marketSlug: "weth",
        requestedAmountUsd6: "1000000000",
        executedAmountUsd6: "1000000000",
        amountUsd: 1000,
        syntheticTxHash: "sim-shared",
        simulated: true,
        at: now,
      })
      for (const [kind, marketSlug] of [
        ["umbrella_stake", "weth"],
        ["umbrella_startCooldown", "weth"],
        ["umbrella_stake", "usdc"],
      ] as const) {
        await ctx.db.insert("sandboxActivity", {
          wallet,
          kind,
          amountUsd: 1000,
          marketSlug,
          syntheticTxHash: "sim-shared",
          at: now,
        })
      }
    })

    const activity = await t
      .withIdentity({ subject: WALLET })
      .query(api.sandbox.transactions.getActivity, { wallet: WALLET })
    expect(activity).toHaveLength(3)
    expect(
      activity.filter((row) => row.product === "umbrella" && row.kind === "stake" && row.marketSlug === "weth"),
    ).toHaveLength(1)
    expect(activity.map((row) => [row.kind, row.marketSlug])).toEqual(
      expect.arrayContaining([
        ["stake", "weth"],
        ["startCooldown", "weth"],
        ["stake", "usdc"],
      ]),
    )
  })

  test("enforces the hourly per-wallet rate limit", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      for (let i = 0; i < MAX_TX_PER_HOUR; i++) {
        await ctx.db.insert("transactions", {
          wallet: WALLET.toLowerCase(),
          intentId: `seed-${i}`,
          product: "borrow",
          kind: "borrow",
          status: "success",
          requestedAmountUsd6: "1",
          executedAmountUsd6: "1",
          amountUsd: 1,
          syntheticTxHash: `seed-${i}`,
          simulated: true,
          at: now - 1000,
        })
      }
    })
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(asUser.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("over"))).rejects.toThrow(
      /RATE_LIMITED/,
    )
  })

  test("updates the current portfolio without appending per-action history", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET.toLowerCase(),
        assetId: "usdc",
        symbol: "USDC",
        amount: 1000,
        valueUsd: 1000,
        state: "available",
        updatedAt: 1,
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      ...borrowIntent("portfolio-current-create"),
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      assetId: undefined,
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "500000000" },
    })
    await asUser.mutation(api.sandbox.transactions.recordTransaction, {
      ...borrowIntent("portfolio-current-update"),
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      assetId: undefined,
      requestedAmountUsd6: "250000000",
      executedAmountUsd6: "250000000",
      amountUsd: 250,
      expectedRevision: 0,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "750000000" },
    })

    const portfolio = await asUser.query(api.sandbox.transactions.getPortfolio, { wallet: WALLET })
    expect(portfolio.latest?.totalSuppliedUsd).toBe(750)
    expect(portfolio.snapshots).toHaveLength(2)
    const stored = await t.run(async (ctx) => ({
      current: await ctx.db.query("portfolioCurrent").collect(),
      history: await ctx.db.query("portfolioSnapshots").collect(),
    }))
    expect(stored.current).toHaveLength(1)
    expect(stored.history).toHaveLength(1)
  })

  test("excludes umbrella staked principal + rewards from the portfolio snapshot value", async () => {
    const t = convexTest(schema, modules)
    const wallet = WALLET.toLowerCase()
    // A wallet holding both a plain liquid balance ($1,000) and an umbrella position
    // ($400 staked + $10 rewards). Umbrella lives on its own page and is excluded from
    // the dashboard headline / Net APY / onboarding snapshot — the running snapshot writer
    // must agree, or stored history drifts from the live number by the umbrella amount.
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet,
        assetId: "usdc",
        symbol: "USDC",
        amount: 1000,
        valueUsd: 1000,
        state: "available",
        updatedAt: 1,
      })
      await ctx.db.insert("positions", {
        wallet,
        product: "umbrella",
        marketSlug: "usdc",
        assetId: "usdc",
        status: "open",
        suppliedUsd6: "400000000",
        earnedUsd6: "10000000",
        openedAt: 1,
        lastUpdatedAt: 1,
      })
    })

    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.transactions.ensurePortfolioSnapshot, { wallet: WALLET })

    const portfolio = await asUser.query(api.sandbox.transactions.getPortfolio, { wallet: WALLET })
    // Only the $1,000 liquid balance counts — umbrella's $400 + $10 are excluded.
    expect(portfolio.latest?.totalValueUsd).toBe(1000)
    expect(portfolio.latest?.totalSuppliedUsd).toBe(0)
  })
})

describe("liquidation recording", () => {
  test("rejects an audit-only liquidation with no victim position", async () => {
    const t = convexTest(schema, modules)
    const asLiquidator = t.withIdentity({ subject: OTHER })
    await expect(
      asLiquidator.mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: WALLET,
        liquidatorWallet: OTHER,
        intentId: "missing-position",
        repaidUsd6: "500000000",
        seizedCollateralUsd6: "550000000",
        healthFactorWadBefore: "900000000000000000",
        healthFactorWadAfter: "1100000000000000000",
      }),
    ).rejects.toThrow(/victim position is required/)
  })

  test("rejects a liquidation whose liquidatorWallet is not the caller", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: OTHER,
        liquidatorWallet: OTHER, // caller is WALLET, not OTHER
        intentId: "wrong-liquidator",
        repaidUsd6: "1",
        seizedCollateralUsd6: "1",
        healthFactorWadBefore: null,
        healthFactorWadAfter: null,
      }),
    ).rejects.toThrow(/LIQUIDATOR_MISMATCH/)
  })

  test("atomically reduces victim debt and collateral and records the transaction", async () => {
    const t = convexTest(schema, modules)
    const ids = await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "usdc",
        llamaId: "coingecko:usd-coin",
        priceUsd: 1,
        source: "test",
        confidence: 1,
        fetchedAt: Date.now(),
        updatedAt: Date.now(),
      })
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: "uni-v3-bluechip-weth-usdc",
        chainId: 1,
        name: "Test LP",
        symbol: "TEST-LP",
        priceUsd: 1,
        createdAt: Date.now(),
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: OTHER.toLowerCase(),
        assetId: "usdc",
        symbol: "USDC",
        amount: 10_000,
        valueUsd: 10_000,
        state: "available",
        updatedAt: Date.now(),
      })
      const positionId = await ctx.db.insert("positions", {
        wallet: WALLET.toLowerCase(),
        product: "borrow",
        marketSlug: "uni-v3-bluechip-weth-usdc",
        status: "open",
        collateralValueUsd6: "2000000000",
        // Underwater: $2000 collateral @ 85% fallback LT = $1700 < $2000 debt.
        debtValueUsd6: "2000000000",
        openedAt: 1,
        lastUpdatedAt: 1,
      })
      await ctx.db.insert("positionCollateral", {
        wallet: WALLET.toLowerCase(),
        positionId,
        marketSlug: "uni-v3-bluechip-weth-usdc",
        collateralShares: "2000000000",
        principalTokenAmount: "2000000000",
        collateralEnabled: true,
        collateralValueUsd6: "2000000000",
        updatedAt: 1,
      })
      const debtPositionId = await ctx.db.insert("positionDebt", {
        wallet: WALLET.toLowerCase(),
        positionId,
        assetId: "uni-v2:usdc",
        baseAssetId: "usdc",
        debtSharesUsd6: "2000000000",
        debtIndexRay: "1000000000000000000000000000",
        borrowRateWad: "50000000000000000",
        principalBorrowedUsd6: "2000000000",
        updatedAt: 1,
      })
      return { positionId, debtPositionId }
    })
    const asLiquidator = t.withIdentity({ subject: OTHER })
    await asLiquidator.mutation(api.sandbox.liquidation.recordLiquidation, {
      wallet: WALLET,
      liquidatorWallet: OTHER,
      intentId: "atomic-liquidation",
      positionId: ids.positionId,
      debtPositionId: ids.debtPositionId,
      marketSlug: "uni-v3-bluechip-weth-usdc",
      repaidUsd6: "500000000",
      seizedCollateralUsd6: "550000000",
      healthFactorWadBefore: "900000000000000000",
      healthFactorWadAfter: "1100000000000000000",
    })

    const state = await t.run(async (ctx) => ({
      position: await ctx.db.get(ids.positionId),
      debt: await ctx.db.get(ids.debtPositionId),
      collateral: await ctx.db
        .query("positionCollateral")
        .withIndex("by_position", (q) => q.eq("positionId", ids.positionId))
        .first(),
      transactions: await ctx.db
        .query("transactions")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", WALLET.toLowerCase()))
        .collect(),
      snapshots: await ctx.db
        .query("portfolioSnapshots")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", WALLET.toLowerCase()))
        .collect(),
      risk: await ctx.db
        .query("riskSnapshots")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", WALLET.toLowerCase()))
        .unique(),
    }))
    expect(state.position?.debtValueUsd6).toBe("1500000000")
    expect(state.position?.collateralValueUsd6).toBe("1450000000")
    expect(state.debt?.principalBorrowedUsd6).toBe("1500000000")
    expect(state.collateral?.collateralValueUsd6).toBe("1450000000")
    expect(state.transactions).toHaveLength(1)
    expect(state.transactions[0]?.kind).toBe("liquidation")
    expect(state.snapshots).toHaveLength(1)
    expect(state.risk).toMatchObject({
      collateralValueUsd6: "1450000000",
      totalBorrowedUsd6: "1500000000",
      healthFactorWad: "821666667000000000",
      trigger: "liquidation",
    })
  })

  test("bumps position revision so a victim's stale-read write is rejected (regression: C-2)", async () => {
    const t = convexTest(schema, modules)
    const ids = await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "usdc",
        llamaId: "coingecko:usd-coin",
        priceUsd: 1,
        source: "test",
        confidence: 1,
        fetchedAt: Date.now(),
        updatedAt: Date.now(),
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: OTHER.toLowerCase(),
        assetId: "usdc",
        symbol: "USDC",
        amount: 10_000,
        valueUsd: 10_000,
        state: "available",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: "uni-v3-bluechip-weth-usdc",
        chainId: 1,
        name: "Test LP",
        symbol: "TEST-LP",
        priceUsd: 1,
        createdAt: Date.now(),
      })
      const positionId = await ctx.db.insert("positions", {
        wallet: WALLET.toLowerCase(),
        product: "borrow",
        marketSlug: "uni-v3-bluechip-weth-usdc",
        status: "open",
        collateralValueUsd6: "2000000000",
        // Underwater: $2000 collateral @ 85% fallback LT = $1700 < $2000 debt.
        debtValueUsd6: "2000000000",
        revision: 0,
        openedAt: 1,
        lastUpdatedAt: 1,
      })
      await ctx.db.insert("positionCollateral", {
        wallet: WALLET.toLowerCase(),
        positionId,
        marketSlug: "uni-v3-bluechip-weth-usdc",
        collateralShares: "2000000000",
        principalTokenAmount: "2000000000",
        collateralEnabled: true,
        collateralValueUsd6: "2000000000",
        updatedAt: 1,
      })
      const debtPositionId = await ctx.db.insert("positionDebt", {
        wallet: WALLET.toLowerCase(),
        positionId,
        assetId: "uni-v2:usdc",
        baseAssetId: "usdc",
        debtSharesUsd6: "2000000000",
        debtIndexRay: "1000000000000000000000000000",
        borrowRateWad: "50000000000000000",
        principalBorrowedUsd6: "2000000000",
        updatedAt: 1,
      })
      return { positionId, debtPositionId }
    })

    const asLiquidator = t.withIdentity({ subject: OTHER })
    await asLiquidator.mutation(api.sandbox.liquidation.recordLiquidation, {
      wallet: WALLET,
      liquidatorWallet: OTHER,
      intentId: "revision-liquidation",
      positionId: ids.positionId,
      debtPositionId: ids.debtPositionId,
      marketSlug: "uni-v3-bluechip-weth-usdc",
      repaidUsd6: "500000000",
      seizedCollateralUsd6: "550000000",
      healthFactorWadBefore: "900000000000000000",
      healthFactorWadAfter: "1100000000000000000",
    })

    // The liquidation advanced the optimistic-concurrency token.
    const after = await t.run(async (ctx) => ctx.db.get(ids.positionId))
    expect(after?.revision).toBe(1)

    // A victim tab that cached the pre-liquidation revision (0) must NOT be able to write —
    // its payload was computed from the pre-liquidation numbers and would reverse the seizure.
    const asVictim = t.withIdentity({ subject: WALLET })
    await expect(
      asVictim.mutation(api.sandbox.transactions.recordTransaction, {
        wallet: WALLET,
        intentId: "victim-stale-repay",
        product: "borrow",
        kind: "repay",
        marketSlug: "uni-v3-bluechip-weth-usdc",
        assetId: "uni-v2:usdc",
        requestedAmountUsd6: "0",
        executedAmountUsd6: "0",
        amountUsd: 0,
        expectedRevision: 0,
        position: {
          status: "open",
          marketSlug: "uni-v3-bluechip-weth-usdc",
          debtValueUsd6: "1200000000",
        },
      }),
    ).rejects.toThrow(/STALE_WRITE/)
  })
})

describe("recordTransaction — server-side solvency re-derivation", () => {
  test("rejects forged Borrow collateral that the authenticated wallet does not own", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("forged-collateral", {
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            debtValueUsd6: "1000000000",
            collateral: [
              {
                marketSlug: "uni-v3-bluechip-weth-usdc",
                collateralShares: "2000000000",
                principalTokenAmount: "2000000000",
                collateralEnabled: true,
              },
            ],
          },
        }),
      ),
    ).rejects.toThrow(/INSUFFICIENT_COLLATERAL_BALANCE/)
  })

  // Prod 2026-09-23: both wallets holding LP collateral could not borrow or repay once the pool's
  // live LP price rose above the price at claim (cbBTC/USDC $43,750 claimed, pledge valued $48,668).
  describe("LP collateral conservation is measured in LP tokens, not frozen USD", () => {
    const LP_SLUG = "uni-v3-bluechip-weth-usdc"
    const ONE_LP = 10n ** 18n

    async function seedOwnedLp(t: ReturnType<typeof convexTest>, liveLpPriceUsd: number) {
      await t.run(async (ctx) => {
        await ctx.db.insert("markets", {
          scope: "pool",
          slug: LP_SLUG,
          chainId: 1,
          name: "WETH / USDC",
          symbol: "WETH/USDC",
          priceUsd: liveLpPriceUsd,
          createdAt: 0,
        })
        // 1 LP token claimed at $40,000.
        await ctx.db.insert("walletBorrowBalances", {
          wallet: WALLET.toLowerCase(),
          marketId: LP_SLUG,
          poolId: LP_SLUG,
          symbol: "WETH/USDC",
          amount: 1,
          valueUsd: 40_000,
          state: "collateral",
          updatedAt: 1,
        })
      })
    }

    function pledge(intentId: string, lpTokens: bigint, kind = "borrow") {
      return borrowIntent(intentId, {
        kind,
        marketSlug: LP_SLUG,
        position: {
          status: "open",
          marketSlug: LP_SLUG,
          debtValueUsd6: "1000000000",
          collateral: [
            {
              marketSlug: LP_SLUG,
              collateralShares: lpTokens.toString(),
              principalTokenAmount: lpTokens.toString(),
              collateralEnabled: true,
            },
          ],
        },
      })
    }

    test("borrowing against the LP tokens a wallet owns succeeds after the LP price rises", async () => {
      const t = convexTest(schema, modules)
      await seedOwnedLp(t, 44_000)
      await expect(
        t
          .withIdentity({ subject: WALLET })
          .mutation(api.sandbox.transactions.recordTransaction, pledge("lp-up", ONE_LP)),
      ).resolves.toBeDefined()
    })

    test("a write keeps the stored LP token count exact", async () => {
      const t = convexTest(schema, modules)
      await seedOwnedLp(t, 44_000)
      await t
        .withIdentity({ subject: WALLET })
        .mutation(api.sandbox.transactions.recordTransaction, pledge("lp-keep", (ONE_LP * 3n) / 4n, "withdraw"))
      const rows = await t.run((ctx) => ctx.db.query("walletBorrowBalances").collect())
      const byState = Object.fromEntries(rows.filter((r) => r.marketId === LP_SLUG).map((r) => [r.state, r]))
      expect(byState.collateral?.amount).toBeCloseTo(0.75, 9)
      expect(byState.poolAvailable?.amount).toBeCloseTo(0.25, 9)
      expect(byState.collateral?.valueUsd).toBeCloseTo(30_000, 6)
    })

    test("pledging more LP tokens than the wallet owns is still rejected", async () => {
      const t = convexTest(schema, modules)
      await seedOwnedLp(t, 40_000)
      await expect(
        t
          .withIdentity({ subject: WALLET })
          .mutation(api.sandbox.transactions.recordTransaction, pledge("lp-over", (ONE_LP * 12n) / 10n)),
      ).rejects.toThrow(/INSUFFICIENT_COLLATERAL_BALANCE/)
    })
  })

  test("rejects a Multiply position without authenticated-wallet collateral", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("forged-multiply", {
          product: "multiply",
          kind: "multiply",
          marketSlug: "eth-usdc-loop",
          position: {
            status: "open",
            marketSlug: "eth-usdc-loop",
            assetId: "eth",
            collateralValueUsd: 2000,
            debtValueUsd: 1000,
            multiplier: 2,
            ltv: 0.5,
          },
        }),
      ),
    ).rejects.toThrow(/INSUFFICIENT_BALANCE/)
  })

  test("debits the wallet collateral that funds a new Multiply position", async () => {
    const t = convexTest(schema, modules)
    await seedMultiplyCollateral(t)
    await t.withIdentity({ subject: WALLET }).mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("funded-multiply", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )
    const liquid = await t.run(async (ctx) => ctx.db.query("walletLiquidBalances").unique())
    expect(liquid?.amount).toBe(0)
    expect(liquid?.valueUsd).toBe(0)
  })

  test("rejects an undercollateralized borrow (debt > liquidation value)", async () => {
    const t = convexTest(schema, modules)
    await seedBorrowCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("insolvent", {
          amountUsd: 2000,
          requestedAmountUsd6: "2000000000",
          executedAmountUsd6: "2000000000",
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            debtValueUsd6: "2000000000", // $2000 debt vs $2000 collateral @ 85% = $1700 max
            collateral: [
              {
                marketSlug: "uni-v3-bluechip-weth-usdc",
                collateralShares: "2000000000",
                principalTokenAmount: "2000000000",
                collateralEnabled: true,
                collateralValueUsd6: "2000000000",
              },
            ],
          },
        }),
      ),
    ).rejects.toThrow(/undercollateralized|health factor/i)
  })

  test("rejects borrow debt with no backing collateral", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("unbacked", {
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            debtValueUsd6: "1000000000",
            collateral: [],
          },
        }),
      ),
    ).rejects.toThrow(/no backing collateral/i)
  })

  test("rejects borrow debt when shares and principal are zero (no server-verifiable value)", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("unpriced-collateral", {
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            debtValueUsd6: "1000000000",
            collateral: [
              {
                marketSlug: "uni-v3-bluechip-weth-usdc",
                collateralShares: "0",
                principalTokenAmount: "0",
                collateralEnabled: true,
                // Spoofed client USD must not count as verifiable collateral.
                collateralValueUsd6: "999999999000000",
              },
            ],
          },
        }),
      ),
    ).rejects.toThrow(/no server-verifiable value/i)
  })

  test("p0-02: rejects inflated client collateralValueUsd6 when shares revalue underwater", async () => {
    const t = convexTest(schema, modules)
    await seedBorrowCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("inflated-collateral", {
          amountUsd: 5000,
          requestedAmountUsd6: "5000000000",
          executedAmountUsd6: "5000000000",
          position: {
            status: "open",
            marketSlug: "uni-v3-bluechip-weth-usdc",
            // $5k debt. Real shares = $2k → LT 85% = $1.7k max. Client lies with $1M USD.
            debtValueUsd6: "5000000000",
            collateral: [
              {
                marketSlug: "uni-v3-bluechip-weth-usdc",
                collateralShares: "2000000000",
                principalTokenAmount: "2000000000",
                collateralEnabled: true,
                collateralValueUsd6: "1000000000000000",
              },
            ],
          },
        }),
      ),
    ).rejects.toThrow(/undercollateralized|health factor/i)
  })

  test("rejects a multiply position above the protocol leverage ceiling", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("overlev", {
          product: "multiply",
          kind: "multiply",
          marketSlug: "eth-usdt",
          position: {
            status: "open",
            marketSlug: "eth-usdt",
            collateralValueUsd: 15000,
            debtValueUsd: 14000, // equity 1000 → multiplier 15x (> 10 ceiling)
            multiplier: 15,
            ltv: 14000 / 15000,
          },
        }),
      ),
    ).rejects.toThrow(/multiplier exceeds the protocol maximum/i)
  })

  test("marks a multiply position closed when close records a zeroed payload (regression: C-1)", async () => {
    const t = convexTest(schema, modules)
    await seedMultiplyCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    // Open a 2x loop.
    const open = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("m-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        multiplierBefore: 1,
        multiplierAfter: 2,
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )
    expect(open.positionId).toBeTruthy()

    // Per-transaction leverage round-trips through the schema (M-7): getSessionState exposes it.
    const session = await asUser.query(api.sandbox.transactions.getSessionState, { wallet: WALLET })
    const openTx = session.transactions.find((row) => row.intentId === "m-open")
    expect(openTx?.multiplierBefore).toBe(1)
    expect(openTx?.multiplierAfter).toBe(2)

    // Close it — the client now sends an explicit zeroed closed payload with kind "close".
    await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("m-close", {
        product: "multiply",
        kind: "close",
        marketSlug: "eth-usdc-loop",
        requestedAmountUsd6: "0",
        executedAmountUsd6: "0",
        amountUsd: 0,
        expectedRevision: 0,
        position: {
          status: "closed",
          marketSlug: "eth-usdc-loop",
          collateralValueUsd: 0,
          debtValueUsd: 0,
          multiplier: 1,
          ltv: 0,
        },
      }),
    )

    const positions = await t.run(async (ctx) => ctx.db.query("positions").collect())
    expect(positions).toHaveLength(1)
    expect(positions[0]?.status).toBe("closed")
    expect(positions[0]?.closedAt).toBeTruthy()
  })

  test("accepts a persisted Multiply deleverage against the current position revision", async () => {
    const t = convexTest(schema, modules)
    await seedMultiplyCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("deleverage-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )

    const result = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("deleverage-write", {
        product: "multiply",
        kind: "deleverage",
        marketSlug: "eth-usdc-loop",
        requestedAmountUsd6: "250000000",
        executedAmountUsd6: "250000000",
        amountUsd: 250,
        expectedRevision: 0,
        multiplierBefore: 2,
        multiplierAfter: 1.75,
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 1750,
          debtValueUsd: 750,
          multiplier: 1.75,
          ltv: 750 / 1750,
        },
      }),
    )

    expect(result.receipt.status).toBe("success")
    expect(result.revision).toBe(1)

    const positions = await asUser.query(api.sandbox.transactions.getPositions, { wallet: WALLET })
    expect(positions).toHaveLength(1)
    expect(positions[0]).toMatchObject({
      status: "open",
      collateralValueUsd: 1750,
      debtValueUsd: 750,
      multiplier: 1.75,
      ltv: 750 / 1750,
      revision: 1,
    })
  })

  test("accepts a full 1x deleverage without requiring a second wallet deposit", async () => {
    const t = convexTest(schema, modules)
    await seedMultiplyCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("full-deleverage-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )

    const result = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("full-deleverage-write", {
        product: "multiply",
        kind: "deleverage",
        marketSlug: "eth-usdc-loop",
        requestedAmountUsd6: "1000000000",
        executedAmountUsd6: "1000000000",
        amountUsd: 1000,
        expectedRevision: 0,
        multiplierBefore: 2,
        multiplierAfter: 1,
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralAmount: 996.990972918756,
          collateralValueUsd: 996.990972918756,
          debtValueUsd: 0,
          multiplier: 1,
          ltv: 0,
        },
      }),
    )

    expect(result.receipt.status).toBe("success")
    expect(result.revision).toBe(1)
  })

  test("returns the position revision on create and on idempotent replay (regression: M-12)", async () => {
    const t = convexTest(schema, modules)
    await seedMultiplyCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    const create = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("rev-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )
    expect(create.idempotent).toBe(false)
    expect(create.revision).toBe(0)

    // Replaying the same intent (lost original response) must still surface the revision so the
    // client can seed its map — otherwise its next write is rejected REVISION_REQUIRED.
    const replay = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("rev-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "eth-usdc-loop",
        position: {
          status: "open",
          marketSlug: "eth-usdc-loop",
          assetId: "eth",
          collateralValueUsd: 2000,
          debtValueUsd: 1000,
          multiplier: 2,
          ltv: 0.5,
        },
      }),
    )
    expect(replay.idempotent).toBe(true)
    expect(replay.revision).toBe(0)
  })

  test("still accepts a healthy borrow (debt within liquidation value)", async () => {
    const t = convexTest(schema, modules)
    await seedBorrowCollateral(t)
    const asUser = t.withIdentity({ subject: WALLET })
    const res = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("healthy", {
        position: {
          status: "open",
          marketSlug: "uni-v3-bluechip-weth-usdc",
          debtValueUsd6: "1000000000", // $1000 debt vs $2000 collateral @ 85% = $1700 max
          collateral: [
            {
              marketSlug: "uni-v3-bluechip-weth-usdc",
              collateralShares: "2000000000",
              principalTokenAmount: "2000000000",
              collateralEnabled: true,
              collateralValueUsd6: "2000000000",
            },
          ],
        },
      }),
    )
    expect(res.receipt.status).toBe("success")
  })
})

describe("portfolioCurrent duplicate tolerance (regression: .unique() bricked the wallet)", () => {
  // A race between the onboarding claim's insert and the dashboard's first snapshot write left
  // TWO portfolioCurrent rows. Every read used `.unique()`, which then threw on the wallet —
  // breaking getPortfolio (dashboard "Something went wrong") AND the claim's own snapshot step,
  // which rolled the whole claim back so the $1M portfolio never seeded.
  const wallet = WALLET.toLowerCase()
  const snap = (at: number, totalValueUsd: number) => ({
    wallet,
    at,
    totalValueUsd,
    totalSuppliedUsd: 0,
    totalBorrowedUsd: 0,
    availableToBorrowUsd: 0,
    totalMultiplyExposureUsd: 0,
    totalEarnedUsd: 0,
  })

  test("getPortfolio returns the newest row instead of throwing when duplicates exist", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("portfolioCurrent", snap(1000, 111))
      await ctx.db.insert("portfolioCurrent", snap(2000, 222)) // duplicate from a concurrent writer
    })
    const asUser = t.withIdentity({ subject: WALLET })
    const portfolio = await asUser.query(api.sandbox.transactions.getPortfolio, { wallet: WALLET })
    expect(portfolio.latest?.at).toBe(2000)
    expect(portfolio.latest?.totalValueUsd).toBe(222)
  })

  test("upsertPortfolioCurrent self-heals duplicates down to one row", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("portfolioCurrent", snap(1000, 111))
      await ctx.db.insert("portfolioCurrent", snap(2000, 222))
      await upsertPortfolioCurrent(ctx, wallet, snap(3000, 333))
      const rows = await ctx.db
        .query("portfolioCurrent")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect()
      expect(rows).toHaveLength(1)
      expect(rows[0]!.at).toBe(3000)
      expect(rows[0]!.totalValueUsd).toBe(333)
    })
  })

  test("upsertPortfolioCurrent inserts exactly one row when none exist", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await upsertPortfolioCurrent(ctx, wallet, snap(500, 55))
      const rows = await ctx.db
        .query("portfolioCurrent")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .collect()
      expect(rows).toHaveLength(1)
      expect(rows[0]!.at).toBe(500)
    })
  })
})

describe("split session subscriptions", () => {
  test("preserves the combined session contract and rejects foreign wallets", async () => {
    const t = convexTest(schema, modules)
    const user = t.withIdentity({ subject: WALLET })
    await seedBorrowCollateral(t)
    await user.mutation(api.sandbox.transactions.recordTransaction, borrowIntent("split-session"))
    const args = { wallet: WALLET }
    const balances = await user.query(api.sandbox.transactions.getSessionBalances, args)
    const transactions = await user.query(api.sandbox.transactions.getSessionTransactions, args)
    expect({ ...balances, transactions }).toEqual(await user.query(api.sandbox.transactions.getSessionState, args))
    expect(transactions).toHaveLength(1)
    expect(balances).not.toHaveProperty("transactions")
    for (const query of [
      api.sandbox.transactions.getSessionBalances,
      api.sandbox.transactions.getSessionTransactions,
    ]) {
      await expect(user.query(query, { wallet: OTHER })).rejects.toThrow()
    }
  })
})

describe("Multiply settles against the live collateral price, not the stored equity", () => {
  // Mirrors the onboarding-seeded loops in production: stored at the claim-time $83,333 /
  // $41,667 with no assetId on the row, while the collateral price has moved since.
  async function seedLoop(t: ReturnType<typeof convexTest>, livePriceUsd: number | null) {
    await t.run(async (ctx) => {
      await ctx.db.insert("positions", {
        wallet: WALLET.toLowerCase(),
        product: "multiply",
        marketSlug: "eth-usdt",
        status: "open",
        collateralAmount: 30,
        collateralValueUsd: 83_333,
        debtValueUsd: 41_667,
        multiplier: 2,
        ltv: 0.5,
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
      // The canonical market row: its symbol is the collateral the loop is repriced with.
      await ctx.db.insert("markets", {
        scope: "multiply",
        slug: "eth-usdt",
        name: "ETH / USDT",
        symbol: "ETH",
        chainId: 1,
        createdAt: 0,
      })
      if (livePriceUsd != null) {
        await ctx.db.insert("tokenPrices", {
          symbol: "eth",
          llamaId: "test:eth",
          priceUsd: livePriceUsd,
          source: "baseline",
          confidence: 0.99,
          status: "fresh",
          updatedAt: Date.now(),
        })
      }
    })
  }

  async function multiplyAvailableUsd(t: ReturnType<typeof convexTest>) {
    const rows = await t.run((ctx) => ctx.db.query("walletMultiplyBalances").collect())
    return rows.filter((row) => row.state === "available").reduce((sum, row) => sum + row.valueUsd, 0)
  }

  function closeIntent(intentId: string, amountUsd: number, assetId = "eth") {
    const usd6 = String(Math.round(amountUsd * 1_000_000))
    return borrowIntent(intentId, {
      product: "multiply",
      kind: "close",
      marketSlug: "eth-usdt",
      requestedAmountUsd6: usd6,
      executedAmountUsd6: usd6,
      amountUsd,
      expectedRevision: 0,
      position: {
        status: "closed",
        marketSlug: "eth-usdt",
        assetId,
        collateralAmount: 0,
        collateralValueUsd: 0,
        debtValueUsd: 0,
        multiplier: 1,
        ltv: 0,
      },
    })
  }

  test("a close naming a different, higher-priced collateral asset is rejected", async () => {
    const t = convexTest(schema, modules)
    await seedLoop(t, 3000)
    await t.run((ctx) =>
      ctx.db.insert("tokenPrices", {
        symbol: "wbtc",
        llamaId: "test:wbtc",
        priceUsd: 100_000,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      }),
    )
    // Repricing 30 "WBTC" would have credited ~$3M of equity for a $48k loop.
    await expect(
      t
        .withIdentity({ subject: WALLET })
        .mutation(api.sandbox.transactions.recordTransaction, closeIntent("c-sub", 48_333, "wbtc")),
    ).rejects.toThrow(/INVALID_TRANSITION/)
    expect(await multiplyAvailableUsd(t)).toBe(0)
  })

  test("a close credits the live equity, not the equity from the last write", async () => {
    const t = convexTest(schema, modules)
    await seedLoop(t, 3000) // 30 ETH now worth $90,000 → live equity $48,333
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, closeIntent("c1", 48_333))
    // The stale diff credited $41,666 (83,333 − 41,667) and dropped the $6,667 price gain.
    expect(await multiplyAvailableUsd(t)).toBeCloseTo(48_333, 0)
  })

  test("a deleverage after a price gain does not demand a top-up", async () => {
    const t = convexTest(schema, modules)
    await seedLoop(t, 3000)
    // Sell 5 ETH ($15,000) to repay debt: equity stays $48,333 at the live price. The stale diff
    // read the $6,667 gain as new equity and, with no liquid ETH, threw INSUFFICIENT_BALANCE.
    const res = await t.withIdentity({ subject: WALLET }).mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("d1", {
        product: "multiply",
        kind: "deleverage",
        marketSlug: "eth-usdt",
        requestedAmountUsd6: "15000000000",
        executedAmountUsd6: "15000000000",
        amountUsd: 15_000,
        expectedRevision: 0,
        position: {
          status: "open",
          marketSlug: "eth-usdt",
          assetId: "eth",
          collateralAmount: 25,
          collateralValueUsd: 75_000,
          debtValueUsd: 26_667,
          multiplier: 75_000 / 48_333,
          ltv: 26_667 / 75_000,
        },
      }),
    )
    expect(res.receipt.status).toBe("success")
  })

  test("keeps the stored equity when the collateral has no current oracle price", async () => {
    const t = convexTest(schema, modules)
    await seedLoop(t, null)
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, closeIntent("c2", 41_666))
    expect(await multiplyAvailableUsd(t)).toBeCloseTo(41_666, 0)
  })
})

describe("liquid credits convert USD to tokens at a real price, not $1/token", () => {
  // Mirrors production lend legs: token-denominated ledger rows ($37,500 each) in assets the wallet
  // holds no liquid row for, so the old $1 fallback credited the USD figure as a token count.
  async function seedLendLeg(t: ReturnType<typeof convexTest>, asset: string, amount: number) {
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLendBalances", {
        wallet: WALLET.toLowerCase(),
        marketId: asset,
        assetId: asset,
        symbol: asset.toUpperCase(),
        amount,
        valueUsd: 37_500,
        state: "deposited",
        updatedAt: 1,
      })
    })
  }

  async function seedOraclePrice(t: ReturnType<typeof convexTest>, symbol: string, priceUsd: number) {
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol,
        llamaId: `test:${symbol}`,
        priceUsd,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      })
    })
  }

  async function liquidRow(t: ReturnType<typeof convexTest>, assetId: string) {
    const rows = await t.run((ctx) => ctx.db.query("walletLiquidBalances").collect())
    return rows.find((row) => row.wallet === WALLET.toLowerCase() && row.assetId === assetId)
  }

  function fullLendWithdraw(marketSlug: string) {
    return borrowIntent(`withdraw-${marketSlug}`, {
      product: "lend",
      kind: "withdraw",
      marketSlug,
      assetId: undefined,
      requestedAmountUsd6: "37500000000",
      executedAmountUsd6: "37500000000",
      amountUsd: 37_500,
      position: { status: "closed", marketSlug, suppliedUsd6: "0", earnedUsd6: "0", supplyApyPct: 3 },
    })
  }

  test("a lend withdraw into an asset with no liquid row credits tokens at the oracle price", async () => {
    const t = convexTest(schema, modules)
    await seedLendLeg(t, "reth", 11.711816288454887)
    await seedOraclePrice(t, "reth", 3208.75)
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, fullLendWithdraw("reth"))
    const row = await liquidRow(t, "reth")
    // $37,500 / $3,208.75 ≈ 11.687 rETH. The $1 fallback credited 37,500 rETH (~$120M live).
    expect(row?.amount).toBeCloseTo(37_500 / 3208.75, 6)
    expect(row?.valueUsd).toBeCloseTo(37_500, 2)
  })

  test("falls back to the lend ledger's price for an asset the oracle does not cover", async () => {
    const t = convexTest(schema, modules)
    await seedLendLeg(t, "tsla", 102.70877269863877) // stocks are priced outside tokenPrices
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, fullLendWithdraw("tsla"))
    expect((await liquidRow(t, "tsla"))?.amount).toBeCloseTo(102.70877269863877, 6)
  })

  test("a borrow into an asset the wallet never held credits tokens at the oracle price", async () => {
    const t = convexTest(schema, modules)
    await seedBorrowCollateral(t)
    await seedOraclePrice(t, "weth", 2749.05)
    await t.withIdentity({ subject: WALLET }).mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("borrow-weth", {
        assetId: "uni-v2:weth",
        position: {
          status: "open",
          marketSlug: "uni-v3-bluechip-weth-usdc",
          debtValueUsd6: "1000000000",
          collateral: [
            {
              marketSlug: "uni-v3-bluechip-weth-usdc",
              collateralShares: "2000000000",
              principalTokenAmount: "2000000000",
              collateralEnabled: true,
            },
          ],
          debt: [
            {
              assetId: "uni-v2:weth",
              baseAssetId: "weth",
              debtSharesUsd6: "1000000000",
              debtIndexRay: "1000000000000000000000000000",
              borrowRateWad: "50000000000000000",
              principalBorrowedUsd6: "1000000000",
            },
          ],
        },
      }),
    )
    // $1,000 of WETH ≈ 0.3638 WETH, not 1,000 WETH.
    expect((await liquidRow(t, "weth"))?.amount).toBeCloseTo(1000 / 2749.05, 6)
  })
})

describe("backfillBorrowLpTokenAmounts", () => {
  test("converts USD-in-amount LP rows to token counts at the live LP price and is idempotent", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: "lp-btc",
        chainId: 1,
        name: "BTC LP",
        symbol: "BTC-LP",
        priceUsd: 42_000,
        createdAt: 0,
      })
      await ctx.db.insert("markets", {
        scope: "pool",
        slug: "lp-stable",
        chainId: 1,
        name: "Stable LP",
        symbol: "S-LP",
        priceUsd: 1.0006,
        createdAt: 0,
      })
      for (const marketId of ["lp-btc", "lp-stable"]) {
        await ctx.db.insert("walletBorrowBalances", {
          wallet: WALLET.toLowerCase(),
          marketId,
          poolId: marketId,
          symbol: marketId,
          amount: 42_000,
          valueUsd: 42_000,
          state: "collateral",
          updatedAt: 1,
        })
      }
    })
    const { internal } = await import("./_generated/api")
    const dry = await t.mutation(internal.sandbox.migrations.backfillBorrowLpTokenAmounts, { dryRun: true })
    expect(dry.planned).toEqual([expect.objectContaining({ marketId: "lp-btc", toAmount: 1 })])
    const unchanged = await t.run((ctx) => ctx.db.query("walletBorrowBalances").collect())
    expect(unchanged.every((row) => row.amount === 42_000)).toBe(true)

    await t.mutation(internal.sandbox.migrations.backfillBorrowLpTokenAmounts, { dryRun: false })
    const rows = await t.run((ctx) => ctx.db.query("walletBorrowBalances").collect())
    expect(rows.find((row) => row.marketId === "lp-btc")).toMatchObject({ amount: 1, valueUsd: 42_000 })
    expect(rows.find((row) => row.marketId === "lp-stable")?.amount).toBe(42_000)
    const rerun = await t.mutation(internal.sandbox.migrations.backfillBorrowLpTokenAmounts, { dryRun: false })
    expect(rerun.planned).toEqual([])
  })
})

describe("alignBorrowLpTokensToPledgedLegs", () => {
  test("sets the owned LP tokens to the open position's pledged leg tokens", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      const wallet = WALLET.toLowerCase()
      const positionId = await ctx.db.insert("positions", {
        wallet,
        product: "borrow",
        marketSlug: "lp-btc",
        status: "open",
        collateralValueUsd6: "43750000000",
        debtValueUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
      })
      await ctx.db.insert("positionCollateral", {
        wallet,
        positionId,
        marketSlug: "lp-btc",
        collateralShares: "1152636000000000000",
        principalTokenAmount: "1152636000000000000",
        collateralEnabled: true,
        collateralValueUsd6: "44055875486",
        updatedAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: "lp-btc",
        poolId: "lp-btc",
        symbol: "LP",
        amount: 1.036829,
        valueUsd: 43_750,
        state: "collateral",
        updatedAt: 1,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet,
        marketId: "lp-btc",
        poolId: "lp-btc",
        symbol: "LP",
        amount: 0.5,
        valueUsd: 21_875,
        state: "poolAvailable",
        updatedAt: 1,
      })
    })
    const { internal } = await import("./_generated/api")
    await t.mutation(internal.sandbox.migrations.alignBorrowLpTokensToPledgedLegs, { dryRun: false })
    const rows = await t.run((ctx) => ctx.db.query("walletBorrowBalances").collect())
    expect(rows.find((row) => row.state === "collateral")?.amount).toBeCloseTo(1.152636, 9)
    expect(rows.find((row) => row.state === "poolAvailable")?.amount).toBeCloseTo(0.576318, 9)
    const rerun = await t.mutation(internal.sandbox.migrations.alignBorrowLpTokensToPledgedLegs, { dryRun: true })
    expect(rerun.planned).toEqual([])
  })
})

// Prod 2026-09-23: the dev wallet's 25,685 OP deposit (USD at deposit $37,500, OP now $0.1237)
// showed "305,012 OP supplied" on Withdraw and the review accepted a 300,000 OP withdraw.
describe("lend withdraw is bounded by the deposited tokens", () => {
  const OP_PRICE = 0.1237
  const DEPOSITED_OP = 25_684.93

  async function seedOpDeposit(t: ReturnType<typeof convexTest>) {
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "op",
        llamaId: "test:op",
        priceUsd: OP_PRICE,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("positions", {
        wallet: w,
        product: "lend",
        marketSlug: "op",
        status: "open",
        suppliedUsd6: "37500000000",
        earnedUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: Date.now(),
        revision: 0,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: w,
        marketId: "op",
        assetId: "op",
        symbol: "OP",
        amount: DEPOSITED_OP,
        valueUsd: 37_500,
        state: "deposited",
        updatedAt: Date.now(),
      })
    })
  }

  function withdrawIntent(intentId: string, amountUsd: number, afterUsd: number) {
    return {
      wallet: WALLET,
      intentId,
      product: "lend" as const,
      kind: "withdraw",
      marketSlug: "op",
      assetId: "op",
      requestedAmountUsd6: String(Math.round(amountUsd * 1e6)),
      executedAmountUsd6: String(Math.round(amountUsd * 1e6)),
      amountUsd: Math.round(amountUsd * 1e6) / 1e6,
      simulated: true,
      expectedRevision: 0,
      position: {
        status: afterUsd > 0 ? ("open" as const) : ("closed" as const),
        marketSlug: "op",
        suppliedUsd6: String(Math.round(afterUsd * 1e6)),
        earnedUsd6: "0",
      },
    }
  }

  test("rejects withdrawing more OP than was deposited", async () => {
    const t = convexTest(schema, modules)
    await seedOpDeposit(t)
    await expect(
      t
        .withIdentity({ subject: WALLET })
        .mutation(api.sandbox.transactions.recordTransaction, withdrawIntent("op-over", 300_000 * OP_PRICE, 0)),
    ).rejects.toThrow(/INSUFFICIENT_BALANCE/)
    const liquid = await t.run((ctx) => ctx.db.query("walletLiquidBalances").collect())
    expect(liquid).toHaveLength(0)
  })

  test("a full withdraw pays out exactly the deposited OP", async () => {
    const t = convexTest(schema, modules)
    await seedOpDeposit(t)
    const res = await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, withdrawIntent("op-full", DEPOSITED_OP * OP_PRICE, 0))
    expect(res.receipt.status).toBe("success")
    const liquid = await t.run((ctx) => ctx.db.query("walletLiquidBalances").unique())
    expect(liquid?.amount).toBeCloseTo(DEPOSITED_OP, 3)
    const deposited = await t.run(async (ctx) =>
      (await ctx.db.query("walletLendBalances").collect()).find((row) => row.state === "deposited"),
    )
    expect(deposited?.amount).toBeCloseTo(0, 6)
  })

  test("a partial withdraw leaves the remaining tokens and a proportional cost basis", async () => {
    const t = convexTest(schema, modules)
    await seedOpDeposit(t)
    const half = DEPOSITED_OP / 2
    await t
      .withIdentity({ subject: WALLET })
      .mutation(api.sandbox.transactions.recordTransaction, withdrawIntent("op-half", half * OP_PRICE, half * OP_PRICE))
    const deposited = await t.run(async (ctx) =>
      (await ctx.db.query("walletLendBalances").collect()).find((row) => row.state === "deposited"),
    )
    expect(deposited?.amount).toBeCloseTo(half, 3)
    expect(deposited?.valueUsd).toBeCloseTo(18_750, 1)
  })
})

describe("multiply open/add never shrinks an existing loop", () => {
  test("rejects a multiply write that would replace a larger open loop", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("positions", {
        wallet: WALLET.toLowerCase(),
        product: "multiply",
        marketSlug: "aave-gho",
        status: "open",
        assetId: "aave",
        collateralAmount: 793,
        collateralValueUsd: 83_333,
        debtValueUsd: 41_667,
        multiplier: 2,
        ltv: 0.5,
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
    })
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(
        api.sandbox.transactions.recordTransaction,
        borrowIntent("mult-replace", {
          product: "multiply",
          kind: "multiply",
          marketSlug: "aave-gho",
          requestedAmountUsd6: "207450000",
          executedAmountUsd6: "207450000",
          amountUsd: 207.45,
          expectedRevision: 0,
          position: {
            status: "open",
            marketSlug: "aave-gho",
            assetId: "aave",
            collateralAmount: 1.5,
            collateralValueUsd: 207.45,
            debtValueUsd: 69.15,
            multiplier: 207.45 / (207.45 - 69.15),
            ltv: 69.15 / 207.45,
          },
        }),
      ),
    ).rejects.toThrow(/STALE_WRITE/)
  })
})

describe("wallet-funded Multiply debits tokens at today's price", () => {
  test("a $138 top-up debits 1 AAVE, not the cost-basis 1.31 AAVE", async () => {
    const t = convexTest(schema, modules)
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "aave",
        llamaId: "test:aave",
        priceUsd: 138,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("markets", {
        scope: "multiply",
        slug: "aave-gho",
        name: "AAVE / GHO",
        symbol: "AAVE",
        chainId: 1,
        createdAt: 0,
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "aave",
        symbol: "AAVE",
        amount: 119.05,
        valueUsd: 12_499.88,
        state: "available",
        updatedAt: 1,
      })
    })
    await t.withIdentity({ subject: WALLET }).mutation(
      api.sandbox.transactions.recordTransaction,
      borrowIntent("aave-open", {
        product: "multiply",
        kind: "multiply",
        marketSlug: "aave-gho",
        requestedAmountUsd6: "138000000",
        executedAmountUsd6: "138000000",
        amountUsd: 138,
        position: {
          status: "open",
          marketSlug: "aave-gho",
          assetId: "aave",
          collateralAmount: 1,
          collateralValueUsd: 138,
          debtValueUsd: 0,
          multiplier: 1,
          ltv: 0,
        },
      }),
    )
    const liquid = await t.run((ctx) => ctx.db.query("walletLiquidBalances").unique())
    expect(liquid?.amount).toBeCloseTo(118.05, 6)
  })
})

describe("lend books the typed token quantity", () => {
  test("a 0.5 AAVE deposit priced 0.4% off the oracle moves exactly 0.5 AAVE", async () => {
    const t = convexTest(schema, modules)
    const w = WALLET.toLowerCase()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "aave",
        llamaId: "test:aave",
        priceUsd: 137.3,
        source: "baseline",
        confidence: 0.99,
        status: "fresh",
        updatedAt: Date.now(),
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "aave",
        symbol: "AAVE",
        amount: 10,
        valueUsd: 1_373,
        state: "available",
        updatedAt: 1,
      })
    })
    const amountUsd = 0.5 * 137.85
    await t.withIdentity({ subject: WALLET }).mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "aave-typed",
      product: "lend" as const,
      kind: "deposit",
      marketSlug: "aave",
      assetId: "aave",
      requestedAmountUsd6: String(Math.round(amountUsd * 1e6)),
      executedAmountUsd6: String(Math.round(amountUsd * 1e6)),
      amountUsd: Math.round(amountUsd * 1e6) / 1e6,
      tokenAmount: 0.5,
      simulated: true,
      position: {
        status: "open" as const,
        marketSlug: "aave",
        suppliedUsd6: String(Math.round(amountUsd * 1e6)),
        earnedUsd6: "0",
      },
    })
    const liquid = await t.run((ctx) => ctx.db.query("walletLiquidBalances").unique())
    expect(liquid?.amount).toBeCloseTo(9.5, 9)
    const tx = await t.run((ctx) => ctx.db.query("transactions").unique())
    expect(tx?.tokenAmount).toBe(0.5)
  })
})

// Prod 2026-09-23: 100 unauthenticated wallet-balance polls each returned a bare
// "[Request ID: …] Server Error"; the client could not tell sign-in from any other failure.
describe("blocked states carry stable ConvexError codes", () => {
  test("an unauthenticated wallet read fails with code UNAUTHENTICATED", async () => {
    const t = convexTest(schema, modules)
    const error = await t.query(api.wallet.productBalances.listForWallet, { wallet: WALLET }).then(
      () => null,
      (caught: unknown) => caught,
    )
    expect((error as { data?: { code?: string } } | null)?.data?.code).toBe("UNAUTHENTICATED")
  })

  test("a read of another wallet fails with code WALLET_MISMATCH", async () => {
    const t = convexTest(schema, modules)
    const error = await t
      .withIdentity({ subject: WALLET })
      .query(api.wallet.productBalances.listForWallet, { wallet: OTHER })
      .then(
        () => null,
        (caught: unknown) => caught,
      )
    expect((error as { data?: { code?: string } } | null)?.data?.code).toBe("WALLET_MISMATCH")
  })
})
