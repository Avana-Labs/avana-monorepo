// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test harness */
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")
const DAY = new Date().toISOString().slice(0, 10)

describe("list ↔ detail live tip+delta parity (Convex)", () => {
  test("borrow list snapshot TVL/available match getQuickStats after supply delta", async () => {
    const slug = "uni-v2-wbtc-usdc"
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      const marketId = await ctx.db.insert("markets", {
        scope: "pool",
        slug,
        chainId: 1,
        name: "WBTC / USDC",
        symbol: "WBTC / USDC",
        createdAt: 0,
      })
      await ctx.db.insert("marketDailyStats", {
        marketId,
        day: DAY,
        suppliedUsd: 10_000_000,
        borrowedUsd: 7_000_000,
        utilizationPct: 70,
        supplyApyPct: 2.4,
        borrowAprPct: 5.1,
        tvlUsd: 10_000_000,
        volumeUsd: 0,
        feesUsd: 0,
      })
    })
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})
    await t.mutation(internal.liquidity.recordDelta, { marketSlug: slug, suppliedDeltaUsd: 20_000_000 })

    const list = await t.query(api.markets.listBorrowMarketSnapshots, {})
    const row = list.find((r) => r.slug === slug)
    expect(row?.suppliedUsd).toBe(30_000_000)
    expect(row?.tvlUsd).toBe(30_000_000)
    expect(row?.availableUsd).toBe(23_000_000)
    expect(row?.borrowedUsd).toBe(7_000_000)

    const bySlug = await t.query(api.markets.getMarketSnapshot, { scope: "pool", slug })
    expect(bySlug).toEqual(row)

    const stats = await t.query(api.markets.getQuickStats, { scope: "pool", slug })
    expect(stats?.find((s) => s.id === "supplied")?.value).toBe("$30.00M")
    expect(stats?.find((s) => s.id === "borrowed")?.value).toBe("$7.00M")
    // utilization from live tip+delta: 7/30
    expect(stats?.find((s) => s.id === "utilization")?.value).toBe(`${((7 / 30) * 100).toFixed(2)}%`)
    expect(stats?.find((s) => s.id === "supplyApy")?.value).toBe("2.40%")
  })

  test("lend list snapshot available matches getQuickStats after tip+delta", async () => {
    const slug = "usdc"
    const t = convexTest(schema, modules)
    await t.run(async (ctx: any) => {
      const marketId = await ctx.db.insert("markets", {
        scope: "lend",
        slug,
        chainId: 1,
        name: "USDC",
        symbol: "USDC",
        createdAt: 0,
      })
      await ctx.db.insert("marketDailyStats", {
        marketId,
        day: DAY,
        suppliedUsd: 8_000_000,
        borrowedUsd: 3_000_000,
        utilizationPct: 37.5,
        supplyApyPct: 4.5,
        borrowAprPct: 7.2,
        tvlUsd: 8_000_000,
        volumeUsd: 0,
        feesUsd: 0,
      })
    })
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})
    await t.mutation(internal.liquidity.recordDelta, { marketSlug: slug, suppliedDeltaUsd: 2_000_000 })

    const list = await t.query(api.markets.listLendMarketSnapshots, {})
    const row = list.find((r) => r.slug === slug)
    expect(row?.suppliedUsd).toBe(10_000_000)
    expect(row?.availableUsd).toBe(7_000_000)

    const bySlug = await t.query(api.markets.getMarketSnapshot, { scope: "lend", slug })
    expect(bySlug).toEqual(row)

    const stats = await t.query(api.markets.getQuickStats, { scope: "lend", slug })
    expect(stats?.find((s) => s.id === "supplied")?.value).toBe("$10.00M")
    expect(stats?.find((s) => s.id === "borrowed")?.value).toBe("$3.00M")
  })
})
