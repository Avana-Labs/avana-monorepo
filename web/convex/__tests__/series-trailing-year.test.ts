// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")
const dayAgo = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10)

describe("daily series readers return the trailing year only", () => {
  test("getTokenPriceHistory drops points older than 365 days", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      for (const days of [500, 400, 30, 1])
        await ctx.db.insert("tokenPricesHistory", { symbol: "eth", day: dayAgo(days), priceUsd: days, updatedAt: 1 })
    })
    const history = await t.query(api.prices.getTokenPriceHistory, { symbol: "eth" })
    expect(history.map((point) => point.priceUsd)).toEqual([30, 1])
  })

  test("multiply getSupplyBorrow and getHistoricalUtilization drop days older than 365", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      for (const days of [405, 366, 364, 0])
        await ctx.db.insert("multiplyDailyStats", {
          slug: "aave-gho",
          day: dayAgo(days),
          suppliedUsd: days,
          borrowedUsd: 0,
          utilizationPct: days,
          supplyApyPct: 0,
          borrowAprPct: 0,
          tvlUsd: 0,
          volumeUsd: 0,
          feesUsd: 0,
        })
    })
    const supplyBorrow = await t.query(api.multiply.dailyStats.getSupplyBorrow, { slug: "aave-gho" })
    expect(supplyBorrow?.supplied.points.map((point) => point.v)).toEqual([364, 0])
    const utilization = await t.query(api.multiply.dailyStats.getHistoricalUtilization, { slug: "aave-gho" })
    expect(utilization?.points.map((point) => point.v)).toEqual([364, 0])
  })
})
