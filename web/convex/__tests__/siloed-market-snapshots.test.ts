// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test harness */
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")
const DAY = new Date().toISOString().slice(0, 10)

async function seed(t: any, scope: "pool" | "asset" | "lend" | "multiply", slug: string) {
  return t.run(async (ctx: any) => {
    const marketId = await ctx.db.insert("markets", {
      scope,
      slug,
      chainId: 1,
      name: slug,
      symbol: slug.toUpperCase(),
      createdAt: 0,
    })
    await ctx.db.insert("marketDailyStats", {
      marketId,
      day: DAY,
      suppliedUsd: 1_000_000,
      borrowedUsd: 400_000,
      utilizationPct: 40,
      supplyApyPct: 2,
      borrowAprPct: 5,
      tvlUsd: 1_000_000,
      volumeUsd: 0,
      feesUsd: 0,
    })
    return marketId
  })
}

describe("product-scoped market snapshot lists", () => {
  test("listBorrow/Lend/MultiplyMarketSnapshots isolate scopes", async () => {
    const t = convexTest(schema, modules)
    await seed(t, "pool", "uni-v2-weth-usdc")
    await seed(t, "asset", "uni-v2:usdc")
    await seed(t, "lend", "usdc")
    await seed(t, "multiply", "eth-usdt")
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})

    const borrow = await t.query(api.markets.listBorrowMarketSnapshots, {})
    const lend = await t.query(api.markets.listLendMarketSnapshots, {})
    const multiply = await t.query(api.markets.listMultiplyMarketSnapshots, {})
    const all = await t.query(api.markets.listMarketSnapshots, {})

    expect(borrow.map((r) => r.scope).sort()).toEqual(["asset", "pool"])
    expect(lend.every((r) => r.scope === "lend")).toBe(true)
    expect(multiply.every((r) => r.scope === "multiply")).toBe(true)
    expect(lend.map((r) => r.slug)).toEqual(["usdc"])
    expect(multiply.map((r) => r.slug)).toEqual(["eth-usdt"])
    expect(all).toHaveLength(4)
    expect(borrow).toHaveLength(2)
    expect(lend).toHaveLength(1)
    expect(multiply).toHaveLength(1)
  })

  test("siloed borrow list never includes lend or multiply rows", async () => {
    const t = convexTest(schema, modules)
    await seed(t, "lend", "usdc")
    await seed(t, "multiply", "aave-gho")
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})

    const borrow = await t.query(api.markets.listBorrowMarketSnapshots, {})
    expect(borrow).toEqual([])
  })
})
