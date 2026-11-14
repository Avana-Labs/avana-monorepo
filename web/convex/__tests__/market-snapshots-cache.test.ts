// @vitest-environment edge-runtime
/* eslint-disable @typescript-eslint/no-explicit-any -- convex-test's t.run(ctx) is loosely typed; the ctx casts in this harness test are intentional. */
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"
import type { Id } from "../_generated/dataModel"

// Rooted at the convex directory so convex-test can resolve module imports.
const modules = import.meta.glob("../**/*.*s")

const DAY = "2026-06-30"

/** Seed one market + one latest daily-stats row; return the market id. */
async function seedMarket(
  t: any,
  slug: string,
  overrides: Partial<{ suppliedUsd: number; borrowedUsd: number }> = {},
): Promise<Id<"markets">> {
  return t.run(async (ctx: any) => {
    const marketId = await ctx.db.insert("markets", {
      scope: "asset" as const,
      slug,
      chainId: 1,
      name: slug.toUpperCase(),
      symbol: slug.toUpperCase(),
      createdAt: 0,
    })
    await ctx.db.insert("marketDailyStats", {
      marketId,
      day: DAY,
      suppliedUsd: overrides.suppliedUsd ?? 1000,
      borrowedUsd: overrides.borrowedUsd ?? 400,
      utilizationPct: 40,
      supplyApyPct: 2,
      borrowAprPct: 5,
      tvlUsd: 1000,
      volumeUsd: 0,
      feesUsd: 0,
    })
    return marketId
  })
}

describe("listMarketSnapshots reads a single precomputed cache doc", () => {
  test("rebuildMarketSnapshots is internal-only, not publicly callable", () => {
    // @ts-expect-error rebuildMarketSnapshots must not be publicly callable
    void api.markets.rebuildMarketSnapshots
    expect(internal.markets.rebuildMarketSnapshots).toBeDefined()
  })

  test("cold cache falls back to the recompute so the app still hydrates", async () => {
    const t = convexTest(schema, modules)
    await seedMarket(t, "usdc", { suppliedUsd: 1000, borrowedUsd: 400 })

    // No cache row written yet — the query must still return the computed snapshot.
    const cacheBefore = await t.run(async (ctx: any) => ctx.db.query("marketSnapshotsCache").collect())
    expect(cacheBefore).toHaveLength(0)

    const rows = await t.query(api.markets.listMarketSnapshots, {})
    expect(rows).toHaveLength(1)
    expect(rows[0].slug).toBe("usdc")
    expect(rows[0].availableUsd).toBe(600)
  })

  test("rebuild writes exactly one cache doc and the query serves it", async () => {
    const t = convexTest(schema, modules)
    await seedMarket(t, "usdc", { suppliedUsd: 1000, borrowedUsd: 400 })
    await seedMarket(t, "weth", { suppliedUsd: 5000, borrowedUsd: 1000 })

    const res = await t.mutation(internal.markets.rebuildMarketSnapshots, {})
    expect(res.markets).toBe(2)

    // Exactly ONE cache document holds the whole folded array (O(1) subscribed read).
    const cacheDocs = await t.run(async (ctx: any) => ctx.db.query("marketSnapshotsCache").collect())
    expect(cacheDocs).toHaveLength(1)
    expect(cacheDocs[0].rows).toHaveLength(2)

    const rows = await t.query(api.markets.listMarketSnapshots, {})
    expect(rows).toHaveLength(2)
    const bySlug = Object.fromEntries(rows.map((r) => [r.slug, r]))
    expect(bySlug.usdc.availableUsd).toBe(600)
    expect(bySlug.weth.availableUsd).toBe(4000)
  })

  test("cached query serves stored rows and does not re-scan markets", async () => {
    const t = convexTest(schema, modules)
    await seedMarket(t, "usdc", { suppliedUsd: 1000, borrowedUsd: 400 })
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})

    // Add a brand-new market AFTER the rebuild. Because the hot query reads the
    // cache doc (not the markets table), the new market must NOT appear until the
    // next rebuild — proving the query no longer collects the markets table.
    await seedMarket(t, "dai", { suppliedUsd: 2000, borrowedUsd: 0 })

    const stale = await t.query(api.markets.listMarketSnapshots, {})
    expect(stale.map((r) => r.slug)).toEqual(["usdc"])

    // A rebuild picks up the new market.
    await t.mutation(internal.markets.rebuildMarketSnapshots, {})
    const fresh = await t.query(api.markets.listMarketSnapshots, {})
    expect(fresh.map((r) => r.slug).sort()).toEqual(["dai", "usdc"])

    // Rebuild is idempotent — still exactly one cache row after a second run.
    const cacheDocs = await t.run(async (ctx: any) => ctx.db.query("marketSnapshotsCache").collect())
    expect(cacheDocs).toHaveLength(1)
  })
})
