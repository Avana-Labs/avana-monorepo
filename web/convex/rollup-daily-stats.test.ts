// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api, internal } from "./_generated/api"

// Rooted at the convex directory so convex-test can resolve sibling modules.
const modules = import.meta.glob("./**/*.*s")

const SLUG = "uni-v3-bluechip-weth-usdc"
const WALLET = "0xAbC0000000000000000000000000000000000001"

async function setup() {
  const t = convexTest(schema, modules)
  const marketId = await t.run(async (ctx) => {
    const id = await ctx.db.insert("markets", {
      scope: "pool",
      slug: SLUG,
      chainId: 1,
      name: "WETH / USDC",
      symbol: "WETH / USDC",
      createdAt: 0,
    })
    await ctx.db.insert("marketDailyStats", {
      marketId: id,
      day: "2026-01-01",
      suppliedUsd: 1_000_000,
      borrowedUsd: 400_000,
      utilizationPct: 40,
      supplyApyPct: 5,
      borrowAprPct: 6,
      tvlUsd: 1_000_000,
      volumeUsd: 0,
      feesUsd: 0,
    })
    return id
  })
  return { t, marketId }
}

describe("rollupDailyStats — flush the live delta into a persistent daily snapshot", () => {
  test("bakes the net delta into today's row and rebases the ledger to zero", async () => {
    const { t, marketId } = await setup()

    // Aggregate activity across wallets: +250k supplied. Rebuild the delta snapshot the
    // chart overlay reads so the live tip reflects it.
    await t.mutation(internal.liquidity.recordDelta, { marketSlug: SLUG, suppliedDeltaUsd: 250_000 })
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})

    // Read-path overlay: tip = seed 1.0M + 250k live delta.
    const before = await t.query(api.markets.getPoolHeroSeries, { slug: SLUG, metric: "tvl", range: "ALL" })
    expect(before?.points.at(-1)?.v).toBe(1_250_000)

    const res = await t.mutation(internal.markets.rollupDailyStats, {})
    expect(res.written).toBe(1)
    expect(res.rebased).toBe(1)
    await t.finishInProgressScheduledFunctions()

    // A fresh daily row persists the flushed absolute value.
    const latest = await t.run((ctx) =>
      ctx.db
        .query("marketDailyStats")
        .withIndex("by_market_day", (q) => q.eq("marketId", marketId))
        .order("desc")
        .first(),
    )
    expect(latest?.suppliedUsd).toBe(1_250_000)
    expect(latest?.tvlUsd).toBe(1_250_000)

    // The ledger is rebased to zero net for this market.
    const net = await t.withIdentity({ subject: WALLET }).query(api.liquidity.listDeltas, {})
    expect(net.find((r) => r.marketSlug === SLUG)?.suppliedDeltaUsd ?? 0).toBe(0)

    // Once the shared delta cache the overlay reads is refreshed (the rollup schedules
    // this; the 5-min cron is the backstop), the effective value is unchanged — the tip
    // now comes from the flushed row plus a zeroed delta, not a double count.
    await t.mutation(internal.liquidity.rebuildDeltaSnapshot, {})
    const after = await t.query(api.markets.getPoolHeroSeries, { slug: SLUG, metric: "tvl", range: "ALL" })
    expect(after?.points.at(-1)?.v).toBe(1_250_000)
  })

  test("is idempotent across repeated same-day runs", async () => {
    const { t, marketId } = await setup()
    await t.mutation(internal.liquidity.recordDelta, { marketSlug: SLUG, suppliedDeltaUsd: 100_000 })

    await t.mutation(internal.markets.rollupDailyStats, {})
    await t.finishInProgressScheduledFunctions()
    await t.mutation(internal.markets.rollupDailyStats, {})
    await t.finishInProgressScheduledFunctions()

    const rows = await t.run((ctx) =>
      ctx.db
        .query("marketDailyStats")
        .withIndex("by_market_day", (q) => q.eq("marketId", marketId))
        .collect(),
    )
    // Seed row + exactly one row for today (patched in place, never duplicated).
    expect(rows.length).toBe(2)
    expect(rows.at(-1)?.suppliedUsd).toBe(1_100_000)
  })
})
