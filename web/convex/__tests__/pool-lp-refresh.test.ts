// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

async function seedTokenPrices(t: ReturnType<typeof convexTest>, prices: Record<string, number>) {
  await t.run(async (ctx) => {
    for (const [symbol, priceUsd] of Object.entries(prices)) {
      await ctx.db.insert("tokenPrices", {
        symbol,
        llamaId: `test:${symbol}`,
        priceUsd,
        source: "test",
        status: "fresh",
        updatedAt: 0,
      })
    }
  })
}

async function seedPoolMarket(
  t: ReturnType<typeof convexTest>,
  slug: string,
  constituents: Array<{ symbol: string; weight: number }>,
  priceUsd = 1,
) {
  await t.run(async (ctx) => {
    await ctx.db.insert("markets", {
      scope: "pool",
      slug,
      chainId: 1,
      name: slug,
      symbol: slug,
      priceUsd,
      constituents,
      createdAt: 0,
    })
  })
}

async function readPoolPrice(t: ReturnType<typeof convexTest>, slug: string) {
  return await t.run(async (ctx) => {
    const m = await ctx.db
      .query("markets")
      .withIndex("by_scope_slug", (q) => q.eq("scope", "pool").eq("slug", slug))
      .unique()
    return m?.priceUsd
  })
}

describe("refreshPoolLpPrices — server LP price = Σ(weightᵢ × priceᵢ) (C9)", () => {
  test("recomputes a pool's priceUsd from live token prices × weights", async () => {
    const t = convexTest(schema, modules)
    await seedTokenPrices(t, { weth: 1900, usdc: 1 })
    await seedPoolMarket(t, "weth-usdc", [
      { symbol: "weth", weight: 0.5 },
      { symbol: "usdc", weight: 0.5 },
    ])
    const res = await t.mutation(internal.prices.refreshPoolLpPrices, {})
    expect(res.updated).toBe(1)
    expect(await readPoolPrice(t, "weth-usdc")).toBeCloseTo(0.5 * 1900 + 0.5 * 1, 6)
  })

  test("stablecoin depeg flows into the server LP price", async () => {
    const t = convexTest(schema, modules)
    await seedTokenPrices(t, { usdc: 1, usdt: 0.999 })
    await seedPoolMarket(t, "usdc-usdt", [
      { symbol: "usdc", weight: 0.5 },
      { symbol: "usdt", weight: 0.5 },
    ])
    await t.mutation(internal.prices.refreshPoolLpPrices, {})
    expect(await readPoolPrice(t, "usdc-usdt")).toBeCloseTo(0.9995, 6)
  })

  test("does not patch a pool whose calculated price is unchanged", async () => {
    const t = convexTest(schema, modules)
    await seedTokenPrices(t, { usdc: 1, usdt: 0.999 })
    await seedPoolMarket(
      t,
      "usdc-usdt",
      [
        { symbol: "usdc", weight: 0.5 },
        { symbol: "usdt", weight: 0.5 },
      ],
      0.9995,
    )
    await expect(t.mutation(internal.prices.refreshPoolLpPrices, {})).resolves.toEqual({
      updated: 0,
      unchanged: 1,
      skipped: 0,
    })
  })

  test("SKIPS a pool with an unpriced leg — leaves its price unchanged (unavailable over wrong)", async () => {
    const t = convexTest(schema, modules)
    await seedTokenPrices(t, { weth: 1900 }) // no price for the exotic leg
    await seedPoolMarket(
      t,
      "weth-exotic",
      [
        { symbol: "weth", weight: 0.5 },
        { symbol: "exotic", weight: 0.5 },
      ],
      777,
    )
    const res = await t.mutation(internal.prices.refreshPoolLpPrices, {})
    expect(res.skipped).toBe(1)
    expect(await readPoolPrice(t, "weth-exotic")).toBe(777)
  })

  test("SKIPS a pool whose leg price is invalid-status", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "weth",
        llamaId: "test:weth",
        priceUsd: 1900,
        source: "test",
        status: "invalid",
        updatedAt: 0,
      })
    })
    await seedPoolMarket(t, "weth-only", [{ symbol: "weth", weight: 1 }], 42)
    const res = await t.mutation(internal.prices.refreshPoolLpPrices, {})
    expect(res.skipped).toBe(1)
    expect(await readPoolPrice(t, "weth-only")).toBe(42)
  })

  test("3-token equal-weight pool prices as the average", async () => {
    const t = convexTest(schema, modules)
    await seedTokenPrices(t, { dai: 1.001, usdc: 1, usdt: 0.999 })
    await seedPoolMarket(t, "tri", [
      { symbol: "dai", weight: 1 / 3 },
      { symbol: "usdc", weight: 1 / 3 },
      { symbol: "usdt", weight: 1 / 3 },
    ])
    await t.mutation(internal.prices.refreshPoolLpPrices, {})
    expect(await readPoolPrice(t, "tri")).toBeCloseTo((1.001 + 1 + 0.999) / 3, 6)
  })
})
