// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A local chain whose time was advanced runs ahead of the wall clock. Its series are bucketed by block time, so the
// charts must end at the chain's own clock, or everything it recorded since would be cut off.

import { convexTest } from "convex-test"
import { fixtureHubAsset } from "@avana/services-common/fixtures"
import { describe, expect, test } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"
import { chainOfScopeKey, seriesNow } from "../../convex/model"

const modules = import.meta.glob("../../convex/**/*.*s")

const CHAIN = 31337
const DAY = 86_400
const KEY = `${CHAIN}:0x00000000000000000000000000000000000000b1:0`

async function chainAhead(daysAhead: number) {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("ingestCheckpoints", { chainId: CHAIN, throughBlock: "0", throughBlockHash: "0x", schemaVersion: 1, lastPageHash: "0x", seriesThroughTime: -1, updatedAt: 0 })
  })
  const wall = Math.floor(Date.now() / 1000)
  const chainDay = Math.floor((wall + daysAhead * DAY) / DAY) * DAY
  const point = { chainId: CHAIN, scopeKind: "hubAsset", scopeKey: KEY, resolution: "day", bucketStart: chainDay - DAY, blockNumber: "10", values: { supplyRateRay: "1000" } }
  const res = await t.mutation(internal.ingest.apply.applySeriesPage, {
    chainId: CHAIN,
    page: { schemaVersion: 1, chainId: CHAIN, after: null, next: { throughTime: chainDay }, records: [point], finalizedBlock: "10", pageHash: "0x" },
  })
  expect(res).toEqual({ applied: true })
  return { t, wall, chainDay }
}

describe("charts follow a chain clock that runs ahead", () => {
  test("seriesNow is the chain's series clock when ahead, else the wall clock", async () => {
    const { t, wall, chainDay } = await chainAhead(20)
    await t.run(async (ctx) => {
      expect(await seriesNow(ctx, CHAIN)).toBe(chainDay)
      const other = await seriesNow(ctx, 8453)
      expect(other).toBeGreaterThanOrEqual(wall)
      expect(other).toBeLessThan(wall + 60)
      expect(await seriesNow(ctx, undefined)).toBeLessThan(wall + 60)
    })
  })

  test("a point recorded at the chain's time is in its chart", async () => {
    const { t, chainDay } = await chainAhead(20)
    const { points } = await t.query(api.series.get, { scopeKind: "hubAsset", scopeKey: KEY, metric: "supplyRateRay", resolution: "day", days: 30 })
    expect(points.some((p) => p.t === (chainDay - DAY) * 1000 && p.v === "1000")).toBe(true)
  })

  test("the chain of a scope key is its first part", () => {
    expect(chainOfScopeKey(KEY)).toBe(CHAIN)
    expect(chainOfScopeKey("x:y")).toBeUndefined()
  })
})

describe("Lend featured sparklines", () => {
  test("a Hub asset's last 24 hourly supply APYs, ending at its chain's clock", async () => {
    const t = convexTest(schema, modules)
    const a = { ...fixtureHubAsset, slug: "ethereum-usdc", updatedAt: 0, lendReserves: [...fixtureHubAsset.lendReserves] }
    const key = `${a.chainId}:${a.hub.toLowerCase()}:${a.assetId}`
    const HOUR = 3_600
    const wall = Math.floor(Date.now() / 1000)
    const head = Math.floor((wall + 20 * DAY) / HOUR) * HOUR
    // A 5% annual rate in RAY.
    const rate = "50000000000000000000000000"
    await t.run(async (ctx) => {
      await ctx.db.insert("hubAssets", a)
      await ctx.db.insert("ingestCheckpoints", { chainId: a.chainId, throughBlock: "0", throughBlockHash: "0x", schemaVersion: 1, lastPageHash: "0x", seriesThroughTime: -1, updatedAt: 0 })
    })
    const records = [2, 1].map((back) => ({ chainId: a.chainId, scopeKind: "hubAsset", scopeKey: key, resolution: "hour", bucketStart: head - back * HOUR, blockNumber: String(10 - back), values: { supplyRateRay: back === 2 ? "0" : rate } }))
    await t.mutation(internal.ingest.apply.applySeriesPage, {
      chainId: a.chainId,
      page: { schemaVersion: 1, chainId: a.chainId, after: null, next: { throughTime: head }, records, finalizedBlock: "10", pageHash: "0x" },
    })
    const [row, ...rest] = await t.query(api.markets.getLendSparklines, { slugs: ["ethereum-usdc", "nope"] })
    expect(rest).toEqual([])
    expect(row!.slug).toBe("ethereum-usdc")
    // The hour at the head has no point of its own yet and carries the last one forward.
    expect(row!.points.at(-3)).toBe(0)
    for (const value of row!.points.slice(-2)) {
      expect(value).toBeGreaterThanOrEqual(5)
      expect(value).toBeLessThan(5.2)
    }
  })
})
