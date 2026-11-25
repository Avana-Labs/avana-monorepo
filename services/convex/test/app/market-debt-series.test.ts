// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The hourly sampler writes a market's debt reserves only while they carry debt. Once a market's debt is repaid or
// liquidated, the next market point has no debt point beside it, and the market's current debt rows must go.

import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../../convex/schema"
import { internal } from "../../convex/_generated/api"

const modules = import.meta.glob("../../convex/**/*.*s")

const CHAIN = 31337
const SPOKE = "0x00000000000000000000000000000000000000a1"
const HOUR = 3600

// Market scope keys are `chainId:integrationId:marketId`; these markets are integration 1's unless named otherwise.
function marketPoint(marketId: string, block: number, hour: number, integrationId = 1) {
  return { chainId: CHAIN, scopeKind: "market", scopeKey: `${CHAIN}:${integrationId}:${marketId}`, resolution: "hour", bucketStart: hour * HOUR, blockNumber: String(block), values: { debtUsd8: "0", borrowers: "0" } }
}

function debtPoint(marketId: string, reserveId: string, block: number, hour: number, debt: string, integrationId = 1) {
  return { chainId: CHAIN, scopeKind: "marketReserve", scopeKey: `${CHAIN}:${integrationId}:${marketId}:${SPOKE}:${reserveId}`, resolution: "hour", bucketStart: hour * HOUR, blockNumber: String(block), values: { debt, borrowers: "1" } }
}

async function setup() {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("ingestCheckpoints", { chainId: CHAIN, throughBlock: "0", throughBlockHash: "0x", schemaVersion: 1, lastPageHash: "0x", seriesThroughTime: -1, updatedAt: 0 })
  })
  let through = -1
  const apply = async (records: unknown[]) => {
    const next = through + HOUR
    const res = await t.mutation(internal.ingest.apply.applySeriesPage, { chainId: CHAIN, page: { schemaVersion: 1, chainId: CHAIN, after: through < 0 ? null : { throughTime: through }, next: { throughTime: next }, records, finalizedBlock: "0", pageHash: "0x" } })
    expect(res).toEqual({ applied: true })
    through = next
  }
  const debts = () =>
    t.run(async (ctx) => (await ctx.db.query("marketReserveDebt").collect()).map((d) => `${d.integrationId === 1 ? "" : `${d.integrationId}/`}${d.marketId}:${d.reserveId}:${d.debt}@${d.blockNumber}`).sort())
  return { apply, debts }
}

describe("market debt rows follow the hourly sampler", () => {
  test("a debt reserve missing from a later sample of its market is removed", async () => {
    const { apply, debts } = await setup()
    await apply([debtPoint("1", "0", 300, 1, "500"), debtPoint("1", "1", 300, 1, "70"), marketPoint("1", 300, 1), debtPoint("2", "0", 300, 1, "9"), marketPoint("2", 300, 1)])
    expect(await debts()).toEqual(["1:0:500@300", "1:1:70@300", "2:0:9@300"])

    // Market 1's reserve 1 was repaid and market 2 was liquidated to zero before block 600.
    await apply([debtPoint("1", "0", 600, 2, "450"), marketPoint("1", 600, 2), marketPoint("2", 600, 2)])
    expect(await debts()).toEqual(["1:0:450@600"])
  })

  test("the market point may come before its debt points in a page", async () => {
    const { apply, debts } = await setup()
    await apply([debtPoint("1", "0", 300, 1, "500"), marketPoint("1", 300, 1)])
    await apply([marketPoint("1", 600, 2), debtPoint("1", "0", 600, 2, "480")])
    expect(await debts()).toEqual(["1:0:480@600"])
  })

  test("two integrations' markets of the same ID keep their own debt rows", async () => {
    const { apply, debts } = await setup()
    await apply([debtPoint("1", "0", 300, 1, "500"), marketPoint("1", 300, 1), debtPoint("1", "0", 300, 1, "40", 3), marketPoint("1", 300, 1, 3)])
    expect(await debts()).toEqual(["1:0:500@300", "3/1:0:40@300"])
    // Integration 3's market 1 was repaid; integration 1's market 1 still owes.
    await apply([debtPoint("1", "0", 600, 2, "450"), marketPoint("1", 600, 2), marketPoint("1", 600, 2, 3)])
    expect(await debts()).toEqual(["1:0:450@600"])
  })

  test("a market without a later point keeps its debt rows", async () => {
    const { apply, debts } = await setup()
    await apply([debtPoint("1", "0", 300, 1, "500"), marketPoint("1", 300, 1)])
    await apply([marketPoint("2", 600, 2)])
    expect(await debts()).toEqual(["1:0:500@300"])
  })
})
