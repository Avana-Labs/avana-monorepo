// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, it } from "vitest"
import schema from "../../convex/schema"
import { api, internal } from "../../convex/_generated/api"
import { aaveApyVisual } from "../../convex/lib/askAI/aaveMcp"

const modules = import.meta.glob("../../convex/**/*.*s")
function setup() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

describe("Aave Convex integration", () => {
  it("binds personal reads to the queued identity and rejects a non-running turn", async () => {
    const t = setup()
    const wallet = "0x1111111111111111111111111111111111111111"
    const owner = t.withIdentity({ subject: wallet, wallet })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "My Aave positions for 0x2222222222222222222222222222222222222222",
      clientRequestId: "aave-wallet",
    })
    // enqueueTurn stamps the wallet from the authenticated identity, never from
    // the address in the prompt. Read the row rather than querying through the
    // status gate, which the scheduled generateTurn is concurrently advancing.
    expect(await t.run((ctx) => ctx.db.get(turn.turnId))).toMatchObject({ wallet })

    // Assert the status gate on rows this test owns, so no scheduled work can
    // move a turn between the patch and the read.
    const gateTurn = (status: "queued" | "running") =>
      t.run((ctx) =>
        ctx.db.insert("askAITurns", {
          threadId: thread.threadId,
          ownerSubject: wallet,
          clientRequestId: `gate-${status}`,
          promptMessageId: `gate-message-${status}`,
          prompt: "My Aave positions",
          wallet,
          status,
          createdAt: Date.now(),
          updatedAt: Date.now(),
        }),
      )
    await expect(t.query(internal.askAITools.aaveWalletForTurn, { turnId: await gateTurn("queued") })).rejects.toThrow(
      "not running",
    )
    expect(await t.query(internal.askAITools.aaveWalletForTurn, { turnId: await gateTurn("running") })).toBe(wallet)

    // Every turn-scoped read shares the same gate, including the engine snapshot, which answers
    // that wallet positions are not available yet.
    await expect(
      t.query(internal.askAITools.engineSnapshotForTurn, { turnId: await gateTurn("queued") }),
    ).rejects.toThrow("not running")
    expect(
      await t.query(internal.askAITools.engineSnapshotForTurn, { turnId: await gateTurn("running") }),
    ).toMatchObject({ unavailable: true })
  })

  it("derives price moves instead of shipping raw history", async () => {
    const t = setup()
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "weth",
        llamaId: "coingecko:ethereum",
        priceUsd: 110,
        status: "fresh",
        source: "defillama",
        updatedAt: now,
        sourceUpdatedAt: now,
      })
      // Ascending days; index from the end is what the change window uses.
      const series = [
        ["2026-08-10", 50], // 30 days back
        ...Array.from({ length: 22 }, (_, i) => [`2026-08-${String(11 + i).padStart(2, "0")}`, 80] as const),
        ["2026-09-02", 100], // 7 days back
        ...Array.from({ length: 6 }, (_, i) => [`2026-09-0${3 + i}`, 100] as const),
        ["2026-09-09", 100], // yesterday
        ["2026-09-10", 110], // latest
      ] as ReadonlyArray<readonly [string, number]>
      for (const [day, priceUsd] of series)
        await ctx.db.insert("tokenPricesHistory", { symbol: "weth", day, priceUsd, updatedAt: now })
    })
    const result = await t.query(api.askAITools.searchMarkets, { query: "what's the WETH price?" })
    const price = result.providerData.find((row) => row.kind === "token_price")
    // 110 vs 100 a day back = +10%; the raw 90-point series never has to reach
    // the model for "is it up today?" to be answerable.
    expect(price?.data).toMatchObject({ symbol: "weth", priceUsd: 110, change24hPct: 10 })
    expect(typeof (price?.data as Record<string, unknown>).change7dPct).toBe("number")
  })

  it("persists APY timestamps and the new Aave financial kinds, then reloads them", async () => {
    const t = setup()
    const owner = t.withIdentity({ subject: "ask-guest:aave-chart" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Aave USDC APY chart",
      clientRequestId: "aave-chart",
    })
    await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
    const visual = aaveApyVisual(
      [
        { date: "2026-09-09", apyPct: "3" },
        { date: "2026-09-10", apyPct: "4" },
      ],
      "Aave USDC",
      "supply",
      "week",
    )!
    await t.mutation(internal.askAI.completeGeneratedTurn, {
      turnId: turn.turnId,
      assistantMessageId: "aave-chart-result",
      model: "test",
      usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 },
      richParts: { visual, financialResults: [{ kind: "aave_governance", payload: { data: { proposalId: "516" } } }] },
    })
    const parts = await t.run((ctx) =>
      ctx.db
        .query("askAIMessageParts")
        .withIndex("by_message", (q) => q.eq("messageId", "aave-chart-result"))
        .unique(),
    )
    expect(parts?.parts).toMatchObject({
      visual: { kind: "aave_apy", points: [3, 4], timestamps: visual.timestamps },
      financialResults: [{ kind: "aave_governance" }],
    })
  })

  it("records HTTP 429 cooldown and preserves the last successful snapshots", async () => {
    const t = setup()
    const now = Date.now()
    await t.mutation(internal.askAIIngestion.upsertRecordsMutation, {
      records: [
        {
          source: "aave",
          kind: "lending_market",
          key: "v3:1:USDC",
          fetchedAt: now,
          payload: { symbol: "USDC", supplyApyPct: 3 },
        },
      ],
    })
    await t.mutation(internal.askAIIngestion.recordProviderRun, {
      source: "aave",
      status: "failed",
      records: 0,
      inserted: 0,
      updated: 0,
      unchanged: 0,
      error: "Aave MCP rate limited (429)",
      httpStatus: 429,
      retryAt: now + 120000,
      startedAt: now,
      completedAt: now,
    })
    expect(await t.query(internal.askAIIngestion.providerCooldown, { source: "aave" })).toBe(now + 120000)
    const rows = await t.run((ctx) => ctx.db.query("askAIMarketSnapshots").collect())
    expect(rows).toHaveLength(1)
    expect(rows[0]!.payload.supplyApyPct).toBe(3)
  })

  it("keeps explicit Avana catalog queries separate from cached Aave v4 markets", async () => {
    const t = setup()
    await t.mutation(internal.askAIIngestion.upsertRecordsMutation, {
      records: [
        {
          source: "aave",
          kind: "lending_market",
          key: "v4:1:USDC",
          fetchedAt: Date.now(),
          payload: { symbol: "USDC", market: "Aave v4 Ethereum", supplyApyPct: 3 },
        },
      ],
    })
    const avana = await t.query(api.askAITools.searchMarkets, { query: "Avana USDC markets" })
    expect(avana.providerData).toEqual([])
    const aave = await t.query(api.askAITools.searchMarkets, { query: "Aave v4 USDC markets" })
    expect(aave.markets).toEqual([])
    expect(aave.providerData[0]).toMatchObject({ source: "aave", data: { supplyApyPct: 3 } })
  })
})
