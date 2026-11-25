// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api, internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"
import { ASK_AI_CONFIG } from "../../convex/lib/askAI/config"

const modules = import.meta.glob("../../convex/**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

describe("Ask AI atomic cost gate", () => {
  test("rejected turn creates no prompt message or turn row", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:reject-persist" })
    const thread = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      await ctx.db.insert("askAIUsage", {
        ownerSubject: "ask-guest:reject-persist",
        threadId: thread.threadId,
        messageId: "seed",
        model: "gpt-5.6-luna",
        provider: "openai",
        inputTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
        outputTokens: 0,
        totalTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
        createdAt: Date.now(),
      })
    })

    await expect(
      owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: "Should not persist",
        clientRequestId: "reject-persist",
      }),
    ).rejects.toMatchObject({ data: { code: "ASK_AI_RATE_LIMITED" } })

    const turns = await t.run(async (ctx) =>
      ctx.db
        .query("askAITurns")
        .withIndex("by_owner_request", (q) =>
          q.eq("ownerSubject", "ask-guest:reject-persist").eq("clientRequestId", "reject-persist"),
        )
        .collect(),
    )
    expect(turns).toHaveLength(0)
  })

  test("duplicate clientRequestId generates once", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:idempotent-gate" })
    const thread = await owner.mutation(api.askAI.create, {})
    const args = {
      threadId: thread.threadId,
      prompt: "Same question",
      clientRequestId: "idempotent-once",
    }
    const first = await owner.mutation(api.askAI.enqueueTurn, args)
    const second = await owner.mutation(api.askAI.enqueueTurn, args)
    expect(first.duplicate).toBe(false)
    expect(second.duplicate).toBe(true)
    expect(second.turnId).toBe(first.turnId)

    const turns = await t.run(async (ctx) =>
      ctx.db
        .query("askAITurns")
        .withIndex("by_owner_request", (q) =>
          q.eq("ownerSubject", "ask-guest:idempotent-gate").eq("clientRequestId", "idempotent-once"),
        )
        .collect(),
    )
    expect(turns).toHaveLength(1)
  })

  test("cancelled queued turn cannot be claimed for generation", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:cancel-gate" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Cancel me",
      clientRequestId: "cancel-before-claim",
    })
    await owner.mutation(api.askAI.cancelQueuedTurn, { turnId: turn.turnId })
    const claimed = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
    expect(claimed).toBeNull()
    const row = await t.run(async (ctx) => ctx.db.get(turn.turnId))
    expect(row?.status).toBe("cancelled")
  })

  test("retryFailedTurn is blocked by the same cost gate", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:retry-gate" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Will fail then retry",
      clientRequestId: "retry-gate",
    })
    await t.run(async (ctx) => {
      const now = Date.now()
      await ctx.db.patch(turn.turnId, { status: "failed", updatedAt: Date.now() })
      await ctx.db.insert("askAIUsage", {
        ownerSubject: "ask-guest:retry-gate",
        threadId: thread.threadId,
        messageId: "seed-retry",
        model: "gpt-5.6-luna",
        provider: "openai",
        inputTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
        outputTokens: 0,
        totalTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
        createdAt: now,
      })
      const bucket = await ctx.db
        .query("askAICostBuckets")
        .withIndex("by_owner_bucket", (q) =>
          q
            .eq("ownerSubject", "ask-guest:retry-gate")
            .eq("bucketStart", Math.floor(now / (60 * 60 * 1_000)) * (60 * 60 * 1_000)),
        )
        .unique()
      await ctx.db.patch(bucket!._id, { usedTokens: bucket!.usedTokens + ASK_AI_CONFIG.limits.dailyTokenBudget })
    })
    await expect(owner.mutation(api.askAI.retryFailedTurn, { turnId: turn.turnId })).rejects.toMatchObject({
      data: { code: "ASK_AI_RATE_LIMITED" },
    })
    const row = await t.run(async (ctx) => ctx.db.get(turn.turnId))
    expect(row?.status).toBe("failed")
  })

  test("enqueueTurn enforces the daily subject cap", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:shared-gate" })
    const thread = await owner.mutation(api.askAI.create, {})
    for (let index = 0; index < ASK_AI_CONFIG.limits.messagesPerDay; index += 1) {
      const turn = await owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: `Question ${index}`,
        clientRequestId: `shared-gate-${index}`,
      })
      // Drain queue capacity so daily quota can be exhausted without hitting the
      // per-thread queue depth of 10.
      await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
      await t.run(async (ctx) => {
        await ctx.db.patch(turn.turnId, { status: "complete", updatedAt: Date.now() })
      })
    }
    await expect(
      owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: "One more should fail",
        clientRequestId: "shared-gate-begin",
      }),
    ).rejects.toMatchObject({ data: { code: "ASK_AI_RATE_LIMITED" } })
  })
})

describe("token reservations", () => {
  test("reserves before generation and releases only an unstarted cancellation", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:reservation" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello",
      clientRequestId: "reserve",
    })
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(ASK_AI_CONFIG.limits.reservedTokensPerTurn)
    await owner.mutation(api.askAI.cancelQueuedTurn, { turnId: turn.turnId })
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(0)
  })
  test("settles each attempt once and retains unknown failed-stream costs", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:settlement" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello",
      clientRequestId: "settle",
    })
    const claimed = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
    const args = {
      reservationId: claimed!.budgetReservationId!,
      threadId: thread.threadId,
      model: "test",
      complete: false,
      usage: { inputTokens: 80, outputTokens: 20, totalTokens: 100 },
    }
    await t.mutation(internal.askAI.settleBudgetReservation, args)
    await t.mutation(internal.askAI.settleBudgetReservation, args)
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(ASK_AI_CONFIG.limits.reservedTokensPerTurn)
    expect(await t.run((ctx) => ctx.db.query("askAIUsage").collect())).toHaveLength(1)
  })
  test("settles a cancelled running attempt to observed complete usage", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:cancel-settle" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello",
      clientRequestId: "cancel-settle",
    })
    const claimed = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
    await owner.mutation(api.askAI.cancelRunningTurn, { threadId: thread.threadId })
    await t.mutation(internal.askAI.settleBudgetReservation, {
      reservationId: claimed!.budgetReservationId!,
      threadId: thread.threadId,
      model: "test",
      complete: true,
      usage: { inputTokens: 80, outputTokens: 20, totalTokens: 100 },
    })
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(100)
    expect((await t.run((ctx) => ctx.db.get(turn.turnId)))?.status).toBe("cancelled")
  })
})

test("capacity retries coalesce duplicate wakeups without losing queued work", async () => {
  const t = askAITest()
  const owner = t.withIdentity({ subject: "ask-guest:backoff" })
  const turns: Array<{ turnId: import("../../convex/_generated/dataModel").Id<"askAITurns"> }> = []
  for (let index = 0; index < 3; index++) {
    const thread = await owner.mutation(api.askAI.create, {})
    turns.push(
      await owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: "Hello",
        clientRequestId: `backoff-${index}`,
      }),
    )
  }
  for (const turn of turns.slice(0, 2)) await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
  const args = { turnId: turns[2]!.turnId }
  expect(await t.mutation(internal.askAI.claimQueuedTurn, args)).toBeNull()
  expect(await t.mutation(internal.askAI.claimQueuedTurn, args)).toBeNull()
  expect(await t.run((ctx) => ctx.db.get(args.turnId))).toMatchObject({ status: "queued", capacityAttempts: 1 })
  await t.run(async (ctx) => {
    await ctx.db.patch(turns[0]!.turnId, { status: "complete" })
    await ctx.db.patch(args.turnId, { nextCapacityRetryAt: 0 })
  })
  expect(await t.mutation(internal.askAI.claimQueuedTurn, args)).not.toBeNull()
})

describe("quota bucket migration", () => {
  test.each([false, true])(
    "settles a legacy reservation before enqueue (partial bucket: %s)",
    async (partialBucket) => {
      const t = askAITest()
      const subject = "ask-guest:legacy-settlement"
      const owner = t.withIdentity({ subject })
      const thread = await owner.mutation(api.askAI.create, {})
      const reservationId = await t.run(async (ctx) => {
        const now = Date.now()
        if (partialBucket)
          await ctx.db.insert("askAICostBuckets", {
            ownerSubject: subject,
            bucketStart: Math.floor(now / 3_600_000) * 3_600_000,
            usedTokens: 999,
            reservedTokens: 999,
            updatedAt: now,
          })
        return ctx.db.insert("askAIBudgetReservations", {
          ownerSubject: subject,
          tokens: 25_000,
          settled: false,
          createdAt: now,
        })
      })
      const settlement = {
        reservationId,
        threadId: thread.threadId,
        model: "test",
        complete: true,
        usage: { inputTokens: 80, outputTokens: 20, totalTokens: 100 },
      }
      await t.mutation(internal.askAI.settleBudgetReservation, settlement)
      await t.mutation(internal.askAI.settleBudgetReservation, settlement)
      expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(100)
      await owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: "Hello",
        clientRequestId: "after-migration",
      })
      expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(25_100)
      expect(await t.run((ctx) => ctx.db.query("askAICostBuckets").collect())).toHaveLength(1)
    },
  )

  test("archiving a queued chat releases both reservation and bucket exactly once", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:archive-refund" })
    const thread = await owner.mutation(api.askAI.create, {})
    const turn = await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello",
      clientRequestId: "archive",
    })
    await owner.mutation(api.askAI.archive, { threadId: thread.threadId })
    expect(await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })).toBeNull()
    expect(await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })).toBeNull()
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(0)
    const reservations = await t.run((ctx) => ctx.db.query("askAIBudgetReservations").collect())
    expect(reservations).toMatchObject([{ tokens: 0, settled: true }])
  })

  test("legacy unreserved completion initializes before adding its usage", async () => {
    const t = askAITest()
    const subject = "ask-guest:legacy-complete"
    const owner = t.withIdentity({ subject })
    const thread = await owner.mutation(api.askAI.create, {})
    const turnId = await t.run((ctx) =>
      ctx.db.insert("askAITurns", {
        ownerSubject: subject,
        threadId: thread.threadId,
        promptMessageId: "legacy-prompt",
        prompt: "Hello",
        status: "running",
        createdAt: Date.now(),
        updatedAt: Date.now(),
      }),
    )
    await t.mutation(internal.askAI.completeGeneratedTurn, {
      turnId,
      assistantMessageId: "legacy-reply",
      model: "test",
      usage: { inputTokens: 80, outputTokens: 20, totalTokens: 100 },
    })
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(100)
    await owner.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "Hello again",
      clientRequestId: "after-completion",
    })
    expect((await owner.query(api.askAI.quota, {})).tokensUsed).toBe(25_100)
  })
})
