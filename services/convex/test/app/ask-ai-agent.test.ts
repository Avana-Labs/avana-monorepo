// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { describe, expect, test } from "vitest"
import { api, internal } from "../../convex/_generated/api"
import { convexTest } from "convex-test"
import schema from "../../convex/schema"
import { ASK_AI_CONFIG } from "../../convex/lib/askAI/config"

const modules = import.meta.glob("../../convex/**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

describe("Ask AI generated-turn lifecycle", () => {
  test("persists queued turns and allows the owner to cancel before execution", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:queue-owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    const first = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "First question",
      clientRequestId: "queue-first",
    })
    await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Second question",
      clientRequestId: "queue-second",
    })

    await expect(owner.query(api.askAI.turnQueue, { threadId: thread.threadId })).resolves.toMatchObject([
      { prompt: "First question", status: "queued" },
      { prompt: "Second question", status: "queued" },
    ])
    const row = await t.run(async (ctx) =>
      ctx.db
        .query("askAITurns")
        .withIndex("by_prompt_message", (q) => q.eq("promptMessageId", first.promptMessageId))
        .unique(),
    )
    await owner.mutation(api.askAI.cancelQueuedTurn, { turnId: row!._id })
    await expect(owner.query(api.askAI.turnQueue, { threadId: thread.threadId })).resolves.toMatchObject([
      { prompt: "Second question", status: "queued" },
    ])
  })

  test("only one of two simultaneous workers can claim a queued turn", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello",
      clientRequestId: "simultaneous-claim",
    })

    const claims = await Promise.all([
      t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId }),
      t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId }),
    ])
    expect(claims.filter(Boolean)).toHaveLength(1)
    expect(claims.filter((claim) => claim === null)).toHaveLength(1)
  })

  test("fails a stale running turn and ignores a late completion", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:timeout-owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "What is AAVE worth?",
      clientRequestId: "timeout-turn",
    })
    await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
    await t.run((ctx) => ctx.db.patch(turn.turnId, { updatedAt: Date.now() - 90_001 }))

    await expect(t.mutation(internal.askAI.timeoutRunningTurn, { turnId: turn.turnId })).resolves.toBe(true)
    await t.mutation(internal.askAI.completeGeneratedTurn, {
      turnId: turn.turnId,
      assistantMessageId: "message:late-timeout",
      model: "gpt-5.6-luna",
      usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 },
    })

    const stored = await t.run((ctx) => ctx.db.get(turn.turnId))
    expect(stored?.status).toBe("failed")
  })

  test("deduplicates repeated submits by client request ID", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:idempotent" })
    const thread = await owner.mutation(api.askAI.create, {})
    const args = { threadId: thread.threadId, prompt: "One question", clientRequestId: "same-request" }
    const first = await owner.mutation(api.askAI.enqueueTurn, args)
    const second = await owner.mutation(api.askAI.enqueueTurn, args)

    expect(second).toMatchObject({ turnId: first.turnId, promptMessageId: first.promptMessageId, duplicate: true })
    const rows = await t.run((ctx) => ctx.db.query("askAITurns").collect())
    expect(rows).toHaveLength(1)
  })

  test("claims only the first queued turn while another turn is running", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:serial-queue" })
    const thread = await owner.mutation(api.askAI.create, {})
    const first = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "First",
      clientRequestId: "serial-first",
    })
    const second = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Second",
      clientRequestId: "serial-second",
    })

    await expect(t.mutation(internal.askAI.claimQueuedTurn, { turnId: first.turnId })).resolves.toBeTruthy()
    await expect(t.mutation(internal.askAI.claimQueuedTurn, { turnId: second.turnId })).resolves.toBeNull()
  })

  test("message queries accept stream cursors before a stream exists", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:stream-owner" })
    const thread = await owner.mutation(api.askAI.create, {})

    await expect(
      owner.query(api.askAI.messages, {
        threadId: thread.threadId,
        paginationOpts: { cursor: null, numItems: 20 },
      }),
    ).resolves.toMatchObject({ page: [], isDone: true })
  })

  test("cancels a running turn without converting it to a retryable failure", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:cancel-owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Analyze risk",
      clientRequestId: "cancel-running",
    })
    await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })

    await expect(owner.mutation(api.askAI.cancelRunningTurn, { threadId: thread.threadId })).resolves.toBe(true)
    await t.mutation(internal.askAI.failTurn, { turnId: turn.turnId })
    await expect(owner.query(api.askAI.turnQueue, { threadId: thread.threadId })).resolves.toEqual([])
  })

  test("persists financial results and retrieval chunks as validated rich parts", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:rich" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "What is my risk?",
      clientRequestId: "rich-parts",
    })
    await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })

    await t.mutation(internal.askAI.completeGeneratedTurn, {
      turnId: turn.turnId,
      assistantMessageId: "message:rich",
      model: "gpt-5.6-luna",
      usage: { inputTokens: 5, outputTokens: 7, totalTokens: 12 },
      richParts: {
        sources: [{ domain: "avana", title: "Docs", locator: "L1" }],
        usage: { inputTokens: 5, outputTokens: 7, totalTokens: 12 },
        financialResults: [{ kind: "portfolio", dataProvenance: "connected_wallet", payload: { netValueUsd: 100 } }],
        retrievalChunks: [{ title: "Docs", locator: "L1", text: "How Avana values LP collateral", score: 0.91 }],
      },
    })

    const parts = await t.run((ctx) =>
      ctx.db
        .query("askAIMessageParts")
        .withIndex("by_message", (q) => q.eq("messageId", "message:rich"))
        .unique(),
    )
    expect(parts?.parts).toMatchObject({
      financialResults: [{ kind: "portfolio", dataProvenance: "connected_wallet", payload: { netValueUsd: 100 } }],
      retrievalChunks: [{ title: "Docs", locator: "L1", text: "How Avana values LP collateral", score: 0.91 }],
    })
  })

  test("reports provider token usage from durable records", async () => {
    const t = askAITest()
    const ownerSubject = "ask-guest:usage-owner"
    await t.run(async (ctx) => {
      await ctx.db.insert("askAIUsage", {
        ownerSubject,
        threadId: "thread-usage",
        messageId: "message-usage",
        model: "gpt-5.6-luna",
        provider: "openai",
        inputTokens: 120,
        outputTokens: 30,
        totalTokens: 150,
        createdAt: Date.now(),
      })
    })

    await expect(t.withIdentity({ subject: ownerSubject }).query(api.askAI.quota, {})).resolves.toMatchObject({
      tokensUsed: 150,
      tokenLimit: ASK_AI_CONFIG.limits.dailyTokenBudget,
      tokensRemaining: ASK_AI_CONFIG.limits.dailyTokenBudget - 150,
    })
  })
})
