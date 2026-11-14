// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test harness */
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")
const POOL_SLUG = "uni-v3-bluechip-weth-usdc"
const LEND_SLUG = "gho"
const ASSET_SLUG = "uni-v2:usdc"
const MULTIPLY_SLUG = "eth-usdt"
const WALLET = "0xabc0000000000000000000000000000000000001"
const OTHER = "0xddd0000000000000000000000000000000000002"

async function insertMarket(ctx: any, scope: string, slug: string) {
  return ctx.db.insert("markets", {
    scope,
    slug,
    chainId: 1,
    name: slug,
    symbol: slug,
    createdAt: 0,
  })
}

async function insertSandboxTx(
  ctx: any,
  slug: string,
  kind: string,
  product: "borrow" | "lend" | "multiply" = "borrow",
  extra: Record<string, unknown> = {},
) {
  await ctx.db.insert("transactions", {
    wallet: WALLET,
    product,
    kind,
    status: "success",
    marketSlug: slug,
    requestedAmountUsd6: "1000000000",
    executedAmountUsd6: "1000000000",
    amountUsd: 1_000,
    syntheticTxHash: `0xlivehash${kind}${product}`.padEnd(42, "0"),
    simulated: true,
    at: Date.now(),
    ...extra,
  })
}

function asWallet(t: ReturnType<typeof convexTest>, wallet = WALLET) {
  return t.withIdentity({ subject: wallet })
}

describe("getRecentTransactions merges sandbox activity with seed history", () => {
  test("keeps seeded market history visible beside sandbox activity", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      const marketId = await insertMarket(ctx, "pool", POOL_SLUG)
      await ctx.db.insert("walletEvents", {
        marketId,
        wallet: "0xseed000000000000000000000000000000000001",
        kind: "supply",
        amountUsd: 99_000,
        at: Date.now() - 86_400_000 * 50,
        txHash: "0xseedhash00000000000000000000000000000001",
        blockNumber: 1,
      })
      await insertSandboxTx(ctx, POOL_SLUG, "deposit")
    })

    const rows = await t.query(api.markets.getRecentTransactions, {
      scope: "pool",
      slug: POOL_SLUG,
      limit: 12,
    })
    expect(rows).toHaveLength(2)
    expect(rows[0]?.source).toBe("sandbox")
    expect(rows[0]?.kind).toBe("supply")
    expect(rows[0]?.amountLabel).toContain("1")
    expect(rows[1]?.source).toBe("seed")
    expect(rows[1]?.kind).toBe("supply")
  })

  test("signed-out visitors see the sandbox activity too (community feed)", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      const marketId = await insertMarket(ctx, "pool", POOL_SLUG)
      await ctx.db.insert("walletEvents", {
        marketId,
        wallet: "0xseed000000000000000000000000000000000001",
        kind: "supply",
        amountUsd: 37_380,
        at: Date.now() - 86_400_000 * 53,
        txHash: "0xseedhash00000000000000000000000000000002",
        blockNumber: 2,
      })
      await insertSandboxTx(ctx, POOL_SLUG, "deposit")
    })

    const rows = await t.query(api.markets.getRecentTransactions, {
      scope: "pool",
      slug: POOL_SLUG,
    })
    expect(rows).toHaveLength(2)
    expect(rows[0]?.source).toBe("sandbox")
    expect(rows[0]?.kind).toBe("supply")
    expect(rows[1]?.source).toBe("seed")
  })

  test("falls back to seeded walletEvents when no sandbox activity exists", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      const marketId = await insertMarket(ctx, "pool", POOL_SLUG)
      await ctx.db.insert("walletEvents", {
        marketId,
        wallet: "0xseed000000000000000000000000000000000001",
        kind: "supply",
        amountUsd: 37_380,
        at: Date.now() - 86_400_000 * 53,
        txHash: "0xseedhash00000000000000000000000000000002",
        blockNumber: 2,
      })
    })

    const rows = await t.query(api.markets.getRecentTransactions, {
      scope: "pool",
      slug: POOL_SLUG,
    })
    expect(rows).toHaveLength(1)
    expect(rows[0]?.source).toBe("seed")
    expect(rows[0]?.kind).toBe("supply")
  })

  test("borrow splits by side: asset page shows debt, pool page shows collateral", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      // A GHO borrow (debt side) recorded against the bal-stable pool, plus an
      // LP pledge (collateral side) on the same pool.
      await insertSandboxTx(ctx, "bal-stable-sdai-usdc", "borrow", "borrow", { assetId: "gho" })
      await insertSandboxTx(ctx, "bal-stable-sdai-usdc", "deposit", "borrow")
    })

    const asset = await t.query(api.markets.getRecentTransactions, {
      scope: "asset",
      slug: "bal-stable:gho",
    })
    const pool = await t.query(api.markets.getRecentTransactions, {
      scope: "pool",
      slug: "bal-stable-sdai-usdc",
    })
    // Asset page = debt side only (unscoped `gho` matches scoped `bal-stable:gho`).
    expect(asset.some((row) => row.source === "sandbox" && row.kind === "borrow")).toBe(true)
    expect(asset.every((row) => row.kind !== "supply")).toBe(true)
    // Pool page = collateral side only; the borrow never leaks onto it.
    expect(pool.some((row) => row.source === "sandbox" && row.kind === "supply")).toBe(true)
    expect(pool.every((row) => row.kind !== "borrow")).toBe(true)
  })

  test("maps lend sandbox deposit/withdraw/claim kinds", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "lend", LEND_SLUG)
      await insertSandboxTx(ctx, LEND_SLUG, "deposit", "lend")
      await insertSandboxTx(ctx, LEND_SLUG, "withdraw", "lend")
      await insertSandboxTx(ctx, LEND_SLUG, "claim", "lend")
    })

    const rows = await asWallet(t).query(api.markets.getRecentTransactions, {
      scope: "lend",
      slug: LEND_SLUG,
      limit: 12,
    })
    const kinds = rows.map((row) => row.kind)
    expect(kinds).toContain("supply")
    expect(kinds).toContain("withdraw")
    expect(kinds).toContain("rewards")
  })

  test("maps asset sandbox borrow/repay kinds", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "asset", ASSET_SLUG)
      await insertSandboxTx(ctx, ASSET_SLUG, "borrow")
      await insertSandboxTx(ctx, ASSET_SLUG, "repay")
    })

    const rows = await asWallet(t).query(api.markets.getRecentTransactions, {
      scope: "asset",
      slug: ASSET_SLUG,
      limit: 12,
    })
    const kinds = rows.map((row) => row.kind)
    expect(kinds).toContain("borrow")
    expect(kinds).toContain("repay")
  })

  test("maps multiply sandbox kinds to multiply detail kinds", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "multiply", MULTIPLY_SLUG)
      await insertSandboxTx(ctx, MULTIPLY_SLUG, "multiply", "multiply")
      await insertSandboxTx(ctx, MULTIPLY_SLUG, "deleverage", "multiply")
      await insertSandboxTx(ctx, MULTIPLY_SLUG, "close", "multiply")
    })

    const rows = await asWallet(t).query(api.markets.getRecentTransactions, {
      scope: "multiply",
      slug: MULTIPLY_SLUG,
      limit: 12,
    })
    const kinds = rows.map((row) => row.kind)
    expect(kinds).toContain("open")
    expect(kinds).toContain("reduce")
    expect(kinds).toContain("close")
  })

  test("does not show a borrow-product row on a multiply market that shares the slug", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "multiply", MULTIPLY_SLUG)
      await insertSandboxTx(ctx, MULTIPLY_SLUG, "borrow", "borrow")
      await insertSandboxTx(ctx, MULTIPLY_SLUG, "multiply", "multiply")
    })

    const rows = await asWallet(t).query(api.markets.getRecentTransactions, {
      scope: "multiply",
      slug: MULTIPLY_SLUG,
      limit: 12,
    })
    expect(rows.every((row) => row.source === "sandbox")).toBe(true)
    expect(rows.map((row) => row.kind)).toEqual(["open"])
  })

  test("shows every wallet's sandbox activity (community feed)", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "lend", LEND_SLUG)
      await ctx.db.insert("transactions", {
        wallet: OTHER,
        product: "lend",
        kind: "deposit",
        status: "success",
        marketSlug: LEND_SLUG,
        requestedAmountUsd6: "1000000000",
        executedAmountUsd6: "1000000000",
        amountUsd: 1_000,
        syntheticTxHash: "0xotherwallet0000000000000000000000000001",
        simulated: true,
        at: Date.now(),
      })
    })

    const rows = await t.query(api.markets.getRecentTransactions, {
      scope: "lend",
      slug: LEND_SLUG,
    })
    expect(rows.some((row) => row.source === "sandbox" && row.kind === "supply")).toBe(true)
  })

  test("returns empty array when market slug is unknown", async () => {
    const t = convexTest(schema, modules)
    const rows = await t.query(api.markets.getRecentTransactions, {
      scope: "asset",
      slug: "unknown-market-slug",
    })
    expect(rows).toEqual([])
  })
})

describe("detail tables pick up the same recordTransaction rows as the dashboard", () => {
  test("lend, borrow asset, and multiply show the recorded tx; a borrow stays off the pool page", async () => {
    const t = convexTest(schema, modules)
    const w = WALLET.toLowerCase()
    await t.run(async (ctx: any) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "gho",
        symbol: "GHO",
        amount: 100,
        valueUsd: 100,
        state: "available",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLendBalances", {
        wallet: w,
        marketId: LEND_SLUG,
        assetId: "gho",
        symbol: "GHO",
        amount: 0,
        valueUsd: 0,
        state: "deposited",
        updatedAt: 1,
      })
      await ctx.db.insert("positions", {
        wallet: w,
        product: "lend",
        marketSlug: LEND_SLUG,
        status: "open",
        suppliedUsd6: "0",
        earnedUsd6: "0",
        openedAt: 1,
        lastUpdatedAt: 1,
        revision: 0,
      })
      await ctx.db.insert("walletBorrowBalances", {
        wallet: w,
        marketId: POOL_SLUG,
        poolId: POOL_SLUG,
        symbol: "WETH/USDC",
        amount: 2000,
        valueUsd: 2000,
        state: "collateral",
        updatedAt: 1,
      })
      await ctx.db.insert("walletLiquidBalances", {
        wallet: w,
        assetId: "eth",
        symbol: "ETH",
        amount: 2,
        valueUsd: 5000,
        state: "available",
        updatedAt: 1,
      })
    })

    const user = asWallet(t)

    await user.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "detail-lend",
      product: "lend",
      kind: "deposit",
      marketSlug: LEND_SLUG,
      assetId: "gho",
      requestedAmountUsd6: "10000000",
      executedAmountUsd6: "10000000",
      amountUsd: 10,
      simulated: true,
      expectedRevision: 0,
      position: { status: "open", marketSlug: LEND_SLUG, suppliedUsd6: "10000000", earnedUsd6: "0" },
    })

    await user.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "detail-borrow",
      product: "borrow",
      kind: "borrow",
      marketSlug: POOL_SLUG,
      assetId: ASSET_SLUG,
      requestedAmountUsd6: "1000000000",
      executedAmountUsd6: "1000000000",
      amountUsd: 1000,
      simulated: true,
      position: {
        status: "open",
        marketSlug: POOL_SLUG,
        debtValueUsd6: "1000000000",
        collateral: [
          {
            marketSlug: POOL_SLUG,
            collateralShares: "2000000000",
            principalTokenAmount: "2000000000",
            collateralEnabled: true,
            collateralValueUsd6: "2000000000",
          },
        ],
        debt: [
          {
            assetId: ASSET_SLUG,
            baseAssetId: "usdc",
            debtSharesUsd6: "1000000000",
            debtIndexRay: "1000000000000000000000000000",
            borrowRateWad: "50000000000000000",
            principalBorrowedUsd6: "1000000000",
          },
        ],
      },
    })

    await user.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "detail-multiply",
      product: "multiply",
      kind: "multiply",
      marketSlug: MULTIPLY_SLUG,
      assetId: "eth",
      requestedAmountUsd6: "1000000000",
      executedAmountUsd6: "1000000000",
      amountUsd: 1000,
      simulated: true,
      multiplierBefore: 1,
      multiplierAfter: 2,
      position: {
        status: "open",
        marketSlug: MULTIPLY_SLUG,
        assetId: "eth",
        collateralValueUsd: 2000,
        debtValueUsd: 1000,
        multiplier: 2,
        ltv: 0.5,
      },
    })

    const dashboard = await user.query(api.sandbox.transactions.getActivity, { wallet: WALLET })
    expect(dashboard.map((row) => row.product).sort()).toEqual(["borrow", "lend", "multiply"])

    const lend = await user.query(api.markets.getRecentTransactions, { scope: "lend", slug: LEND_SLUG })
    const asset = await user.query(api.markets.getRecentTransactions, { scope: "asset", slug: ASSET_SLUG })
    const pool = await user.query(api.markets.getRecentTransactions, { scope: "pool", slug: POOL_SLUG })
    const multiply = await user.query(api.markets.getRecentTransactions, {
      scope: "multiply",
      slug: MULTIPLY_SLUG,
    })

    expect(lend.some((row) => row.source === "sandbox" && row.kind === "supply")).toBe(true)
    expect(asset.some((row) => row.source === "sandbox" && row.kind === "borrow")).toBe(true)
    expect(multiply.some((row) => row.source === "sandbox" && row.kind === "open")).toBe(true)
    // The borrow is debt-side: it belongs on the asset page, never the pool page.
    expect(pool.every((row) => row.kind !== "borrow")).toBe(true)
  })
})

describe("getRecentTransactions reads market-scoped indexes", () => {
  test("a quiet market keeps its rows when newer activity elsewhere exceeds the scan window", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      await insertMarket(ctx, "lend", LEND_SLUG)
      await insertSandboxTx(ctx, LEND_SLUG, "deposit", "lend", { at: 1_000 })
      // 450 newer rows on another market: a global newest-400 scan never reached the GHO row.
      for (let i = 0; i < 450; i++) {
        await insertSandboxTx(ctx, "busy-market", "deposit", "lend", {
          at: 2_000 + i,
          syntheticTxHash: `0xbusy${i}`.padEnd(42, "0"),
        })
      }
    })
    const rows = await t.query(api.markets.getRecentTransactions, { scope: "lend", slug: LEND_SLUG })
    expect(rows.filter((row: any) => row.source === "sandbox")).toHaveLength(1)
  })

  test("a borrow asset page finds debt rows by assetId, including legacy unscoped ids", async () => {
    const t = convexTest(schema, modules)
    const SCOPED = "bal-boosted:gho"
    await t.run(async (ctx: any) => {
      await insertSandboxTx(ctx, "bal-boosted-sdai-usdc", "borrow", "borrow", {
        assetId: SCOPED,
        at: 2_000,
        syntheticTxHash: "0xscoped".padEnd(42, "0"),
      })
      await insertSandboxTx(ctx, "bal-boosted-sdai-usdc", "repay", "borrow", {
        assetId: "gho",
        at: 1_000,
        syntheticTxHash: "0xlegacy".padEnd(42, "0"),
      })
      // Another venue's GHO is a different asset and stays off this page.
      await insertSandboxTx(ctx, "uni-v2-wbtc-weth", "borrow", "borrow", {
        assetId: "uni-v2:gho",
        at: 3_000,
        syntheticTxHash: "0xother".padEnd(42, "0"),
      })
    })
    const rows = await t.query(api.markets.getRecentTransactions, { scope: "asset", slug: SCOPED })
    expect(rows.map((row: any) => row.kind)).toEqual(["borrow", "repay"])
  })
})
