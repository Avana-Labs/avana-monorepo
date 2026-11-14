// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")
const wallet = "0xabc0000000000000000000000000000000000001"

test("a lend withdrawal cannot claim 50 percent interest on a 5 percent position", async () => {
  const t = convexTest(schema, modules)
  const yearAgo = Date.now() - 365 * 24 * 3600 * 1000
  await t.run(async (ctx) => {
    await ctx.db.insert("tokenPrices", {
      symbol: "usdc",
      llamaId: "test:usdc",
      priceUsd: 1,
      source: "baseline",
      confidence: 0.99,
      status: "fresh",
      updatedAt: Date.now(),
    })
    await ctx.db.insert("walletLendBalances", {
      wallet,
      marketId: "usdc",
      assetId: "usdc",
      symbol: "USDC",
      amount: 100,
      valueUsd: 100,
      state: "deposited",
      updatedAt: yearAgo,
    })
    await ctx.db.insert("positions", {
      wallet,
      product: "lend",
      marketSlug: "usdc",
      status: "open",
      suppliedUsd6: "100000000",
      earnedUsd6: "0",
      supplyApyPct: 5,
      openedAt: yearAgo,
      lastUpdatedAt: yearAgo,
      revision: 0,
    })
  })
  await expect(
    t.withIdentity({ subject: wallet }).mutation(api.sandbox.transactions.recordTransaction, {
      wallet,
      intentId: "review-excess-interest",
      product: "lend",
      kind: "withdraw",
      marketSlug: "usdc",
      assetId: "usdc",
      amountUsd: 150,
      tokenAmount: 150,
      expectedRevision: 0,
      requestedAmountUsd6: "150000000",
      executedAmountUsd6: "150000000",
      simulated: true,
      position: { status: "closed", marketSlug: "usdc", suppliedUsd6: "0", earnedUsd6: "0" },
    }),
  ).rejects.toThrow(/INSUFFICIENT_BALANCE|INVALID_TRANSITION/)
})

test("a lend deposit cannot move more tokens than the wallet owns after a price drop", async () => {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("tokenPrices", {
      symbol: "aave",
      llamaId: "test:aave",
      priceUsd: 50,
      source: "baseline",
      confidence: 0.99,
      status: "fresh",
      updatedAt: Date.now(),
    })
    await ctx.db.insert("walletLiquidBalances", {
      wallet,
      assetId: "aave",
      symbol: "AAVE",
      amount: 10,
      valueUsd: 1000,
      state: "available",
      updatedAt: Date.now(),
    })
  })
  await expect(
    t.withIdentity({ subject: wallet }).mutation(api.sandbox.transactions.recordTransaction, {
      wallet,
      intentId: "review-overdraft",
      product: "lend",
      kind: "deposit",
      marketSlug: "aave",
      assetId: "aave",
      amountUsd: 750,
      tokenAmount: 15,
      requestedAmountUsd6: "750000000",
      executedAmountUsd6: "750000000",
      simulated: true,
      position: { status: "open", marketSlug: "aave", suppliedUsd6: "750000000", earnedUsd6: "0" },
    }),
  ).rejects.toThrow(/INSUFFICIENT_BALANCE/)
})

test("a lend deposit can use owned tokens after a price rise", async () => {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("tokenPrices", {
      symbol: "aave",
      llamaId: "test:aave",
      priceUsd: 200,
      source: "baseline",
      confidence: 0.99,
      status: "fresh",
      updatedAt: Date.now(),
    })
    await ctx.db.insert("walletLiquidBalances", {
      wallet,
      assetId: "aave",
      symbol: "AAVE",
      amount: 10,
      valueUsd: 1000,
      state: "available",
      updatedAt: Date.now(),
    })
  })
  await expect(
    t.withIdentity({ subject: wallet }).mutation(api.sandbox.transactions.recordTransaction, {
      wallet,
      intentId: "review-owned",
      product: "lend",
      kind: "deposit",
      marketSlug: "aave",
      assetId: "aave",
      amountUsd: 2000,
      tokenAmount: 10,
      requestedAmountUsd6: "2000000000",
      executedAmountUsd6: "2000000000",
      simulated: true,
      position: { status: "open", marketSlug: "aave", suppliedUsd6: "2000000000", earnedUsd6: "0" },
    }),
  ).resolves.toMatchObject({ receipt: { status: "success" } })
})
