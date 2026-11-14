// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"

const modules = import.meta.glob("../../convex/**/*.*s")

const row = (symbol: string, priceUsd: number, updatedAt: number) => ({
  symbol,
  llamaId: `test:${symbol}`,
  priceUsd,
  source: "test",
  updatedAt,
})

const DAY1_A = Date.parse("2026-08-17T01:00:00Z")
const DAY1_B = Date.parse("2026-08-17T22:00:00Z")
const DAY2 = Date.parse("2026-08-18T05:00:00Z")

describe("token price history — current vs historical separation (C12)", () => {
  test("writes one daily closing point instead of rewriting history on every current-price update", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 1900, DAY1_A)] })
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 1950, DAY1_B)] })
    await expect(t.mutation(internal.tokenPrices.snapshotDailyTokenPrices, { day: "2026-08-17" })).resolves.toEqual({
      inserted: 1,
      updated: 0,
      unchanged: 0,
    })
    const history = await t.query(api.tokenPrices.getTokenPriceHistory, { symbol: "eth" })
    expect(history).toEqual([{ day: "2026-08-17", priceUsd: 1950 }])
  })

  test("a new UTC day appends a new history row (series grows over time)", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 1900, DAY1_A)] })
    await t.mutation(internal.tokenPrices.snapshotDailyTokenPrices, { day: "2026-08-17" })
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 2100, DAY2)] })
    await t.mutation(internal.tokenPrices.snapshotDailyTokenPrices, { day: "2026-08-18" })
    const history = await t.query(api.tokenPrices.getTokenPriceHistory, { symbol: "eth" })
    expect(history).toEqual([
      { day: "2026-08-17", priceUsd: 1900 },
      { day: "2026-08-18", priceUsd: 2100 },
    ])
  })

  test("is idempotent when the closing price is unchanged", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 1900, DAY1_A)] })
    await t.mutation(internal.tokenPrices.snapshotDailyTokenPrices, { day: "2026-08-17" })
    await expect(t.mutation(internal.tokenPrices.snapshotDailyTokenPrices, { day: "2026-08-17" })).resolves.toEqual({
      inserted: 0,
      updated: 0,
      unchanged: 1,
    })
  })

  test("the CURRENT price query reflects only the latest value, never the history rows", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 1900, DAY1_A)] })
    await t.mutation(internal.tokenPrices.upsertPrices, { rows: [row("eth", 2100, DAY2)] })
    const current = await t.query(api.tokenPrices.getPrices, {})
    const eth = current.filter((p) => p.symbol === "eth")
    expect(eth).toHaveLength(1) // one current row, not one-per-day
    expect(eth[0]!.priceUsd).toBe(2100)
  })
})
