// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

const risk = {
  assessedAt: 1,
  premiumBps: 20,
  level: "low" as const,
  score: 90,
  headline: "Low risk",
  summary: "Covered",
  breakdown: [],
  metrics: [],
}
const content = { description: "Market", stats: [], history: [], faqs: [] }
const revenue = {
  day: "2026-08-24",
  interestFromBorrowersUsd: 10,
  interestToSuppliersUsd: 8,
  reserveTakeUsd: 2,
  rewardsDistributedUsd: 0,
  swapFeesUsd: 0,
}

describe("legacy shared market coverage", () => {
  test("reports product rows by canonical market slug", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      const marketId = await ctx.db.insert("markets", {
        scope: "asset",
        slug: "usdc",
        chainId: 1,
        name: "USD Coin",
        symbol: "USDC",
        createdAt: 1,
      })
      await ctx.db.insert("marketRevenueDaily", { marketId, ...revenue })
      await ctx.db.insert("riskAssessments", { marketId, ...risk })
      await ctx.db.insert("marketContent", { marketId, ...content })
      await ctx.db.insert("borrowRevenueDaily", { slug: "usdc", kind: "asset", ...revenue })
      await ctx.db.insert("borrowRiskAssessments", { slug: "usdc", kind: "asset", ...risk })
      await ctx.db.insert("borrowMarketContent", { slug: "usdc", kind: "asset", ...content })
    })

    for (const kind of ["revenue", "risk", "content"] as const) {
      await expect(
        t.query(internal.legacyMarketCoverage.checkLegacyMarketCoverage, { kind, batchSize: 10 }),
      ).resolves.toMatchObject({ kind, scanned: 1, covered: 1, missing: [], isDone: true })
    }
  })
})
