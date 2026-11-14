// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test harness */
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

const SLUG = "uni-v2-wbtc-usdc"
const DAY = new Date().toISOString().slice(0, 10)

async function seedPoolWithTip(t: any, suppliedUsd = 10_000_000, borrowedUsd = 7_000_000) {
  return t.run(async (ctx: any) => {
    const marketId = await ctx.db.insert("markets", {
      scope: "pool" as const,
      slug: SLUG,
      chainId: 1,
      name: "WBTC / USDC",
      symbol: "WBTC / USDC",
      createdAt: 0,
    })
    await ctx.db.insert("marketDailyStats", {
      marketId,
      day: DAY,
      suppliedUsd,
      borrowedUsd,
      utilizationPct: (borrowedUsd / suppliedUsd) * 100,
      supplyApyPct: 2,
      borrowAprPct: 5,
      tvlUsd: suppliedUsd,
      volumeUsd: 0,
      feesUsd: 0,
    })
    return marketId
  })
}

describe("live tip+delta on market reference reads (no EOD rollup required)", () => {
  test("listMarketSnapshots shows tip + supply delta before rollupDailyStats", async () => {
    const t = convexTest(schema, modules)
    await seedPoolWithTip(t, 10_000_000, 7_000_000)
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})

    const before = await t.query(api.markets.listMarketSnapshots, {})
    const rowBefore = before.find((r) => r.slug === SLUG)
    expect(rowBefore?.suppliedUsd).toBe(10_000_000)
    expect(rowBefore?.availableUsd).toBe(3_000_000)

    // User supplies +$20M — ledger append only; do NOT run rollupDailyStats.
    await t.mutation(internal.liquidity.recordDelta, { marketSlug: SLUG, suppliedDeltaUsd: 20_000_000 })

    const after = await t.query(api.markets.listMarketSnapshots, {})
    const row = after.find((r) => r.slug === SLUG)
    expect(row?.suppliedUsd).toBe(30_000_000)
    expect(row?.borrowedUsd).toBe(7_000_000)
    expect(row?.availableUsd).toBe(23_000_000)
    expect(row?.tvlUsd).toBe(30_000_000)
  })

  test("getQuickStats reflects the same live tip+delta without EOD rollup", async () => {
    const t = convexTest(schema, modules)
    await seedPoolWithTip(t, 10_000_000, 7_000_000)

    await t.mutation(internal.liquidity.recordDelta, { marketSlug: SLUG, suppliedDeltaUsd: 20_000_000 })

    const stats = await t.query(api.markets.getQuickStats, { scope: "pool", slug: SLUG })
    const supplied = stats?.find((s) => s.id === "supplied")
    const borrowed = stats?.find((s) => s.id === "borrowed")
    expect(supplied?.value).toBe("$30.00M")
    expect(borrowed?.value).toBe("$7.00M")
  })
})
