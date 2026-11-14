// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

describe("unchanged oracle refreshes skip quote writes", () => {
  test("identical price refresh writes zero quote rows but advances provider health", async () => {
    const t = convexTest(schema, modules)
    const row = {
      symbol: "eth",
      llamaId: "coingecko:ethereum",
      priceUsd: 3200,
      source: "defillama",
      status: "fresh" as const,
      updatedAt: 1_000,
      fetchedAt: 1_000,
    }
    const first = await t.mutation(internal.prices.upsertPrices, { rows: [row] })
    expect(first).toEqual({ written: 1, unchanged: 0 })

    const second = await t.mutation(internal.prices.upsertPrices, {
      rows: [{ ...row, updatedAt: 2_000, fetchedAt: 2_000 }],
    })
    expect(second).toEqual({ written: 0, unchanged: 1 })

    const prices = await t.run(async (ctx) => ctx.db.query("tokenPrices").collect())
    expect(prices).toHaveLength(1)
    expect(prices[0]?.updatedAt).toBe(1_000)

    const status = await t.query(api.prices.getPriceStatus, {})
    expect(status.updatedAt).toBe(2_000)
  })

  test("changed quotes update only affected rows", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.prices.upsertPrices, {
      rows: [
        {
          symbol: "eth",
          llamaId: "coingecko:ethereum",
          priceUsd: 3200,
          source: "defillama",
          updatedAt: 1_000,
        },
        {
          symbol: "usdc",
          llamaId: "coingecko:usd-coin",
          priceUsd: 1,
          source: "defillama",
          updatedAt: 1_000,
        },
      ],
    })
    const result = await t.mutation(internal.prices.upsertPrices, {
      rows: [
        {
          symbol: "eth",
          llamaId: "coingecko:ethereum",
          priceUsd: 3300,
          source: "defillama",
          updatedAt: 2_000,
        },
        {
          symbol: "usdc",
          llamaId: "coingecko:usd-coin",
          priceUsd: 1,
          source: "defillama",
          updatedAt: 2_000,
        },
      ],
    })
    expect(result).toEqual({ written: 1, unchanged: 1 })
    const bySymbol = new Map(
      (await t.run(async (ctx) => ctx.db.query("tokenPrices").collect())).map((row) => [row.symbol, row]),
    )
    expect(bySymbol.get("eth")?.priceUsd).toBe(3300)
    expect(bySymbol.get("eth")?.updatedAt).toBe(2_000)
    expect(bySymbol.get("usdc")?.updatedAt).toBe(1_000)
  })

  test("identical FX refresh writes zero rate rows but advances provider health", async () => {
    const t = convexTest(schema, modules)
    const rows = [
      {
        currency: "USD",
        usdPerUnit: 1,
        source: "er-api",
        status: "fresh" as const,
        updatedAt: 1_000,
        fetchedAt: 1_000,
      },
      {
        currency: "EUR",
        usdPerUnit: 0.92,
        source: "er-api",
        status: "fresh" as const,
        updatedAt: 1_000,
        fetchedAt: 1_000,
      },
    ]
    expect(await t.mutation(internal.fx.upsertFxRates, { rows })).toEqual({ written: 2, unchanged: 0 })
    expect(
      await t.mutation(internal.fx.upsertFxRates, {
        rows: rows.map((row) => ({ ...row, updatedAt: 2_000, fetchedAt: 2_000 })),
      }),
    ).toEqual({ written: 0, unchanged: 2 })

    const stored = await t.run(async (ctx) => ctx.db.query("fxRates").collect())
    expect(stored.every((row) => row.updatedAt === 1_000)).toBe(true)
    const quotes = await t.query(api.fx.getFxRates, {})
    expect(quotes.status.updatedAt).toBe(1_000)
    const health = await t.query(api.fx.getFxStatus, {})
    expect(health.updatedAt).toBe(2_000)
  })

  test("unchanged price refresh does not change getPriceSnapshot quote status", async () => {
    const t = convexTest(schema, modules)
    const row = {
      symbol: "eth",
      llamaId: "coingecko:ethereum",
      priceUsd: 3200,
      source: "defillama",
      status: "fresh" as const,
      updatedAt: 1_000,
      fetchedAt: 1_000,
    }
    await t.mutation(internal.prices.upsertPrices, { rows: [row] })
    const before = await t.query(api.prices.getPriceSnapshot, {})
    await t.mutation(internal.prices.upsertPrices, {
      rows: [{ ...row, updatedAt: 2_000, fetchedAt: 2_000 }],
    })
    const after = await t.query(api.prices.getPriceSnapshot, {})
    expect(after.prices).toEqual(before.prices)
    expect(after.status.updatedAt).toBe(1_000)
    const health = await t.query(api.prices.getPriceStatus, {})
    expect(health.updatedAt).toBe(2_000)
  })
})
