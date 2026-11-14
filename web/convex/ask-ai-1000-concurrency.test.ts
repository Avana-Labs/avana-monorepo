// @vitest-environment edge-runtime
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { internal } from "./_generated/api"
import type { Id } from "./_generated/dataModel"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")
const describeConcurrency = process.env.RUN_ASK_AI_1000_CONCURRENCY === "1" ? describe : describe.skip

/** Must match MAX_CONCURRENT_GENERATIONS_GLOBAL in askAI.ts. */
const MAX_CONCURRENT_GENERATIONS_GLOBAL = 100

describeConcurrency("Ask AI 1,000-user concurrency", () => {
  test("1,000 concurrent claims cannot exceed the global generation cap", async () => {
    const t = convexTest(schema, modules)
    registerAgent(t)
    registerRateLimiter(t)
    const now = Date.now()
    const turnIds = await t.run(async (ctx) => {
      const ids: Id<"askAITurns">[] = []
      for (let index = 0; index < 1_000; index += 1) {
        const threadId = `thread:load:${index}`
        const ownerSubject = `ask-guest:load:${index}`
        await ctx.db.insert("askAIThreads", {
          threadId,
          ownerSubject,
          title: "Load test",
          status: "active",
          createdAt: now,
          updatedAt: now,
        })
        ids.push(
          await ctx.db.insert("askAITurns", {
            threadId,
            ownerSubject,
            clientRequestId: `load:${index}`,
            promptMessageId: `message:load:${index}`,
            prompt: "What is Bitcoin's price?",
            status: "queued",
            createdAt: now,
            updatedAt: now,
          }),
        )
      }
      return ids
    })

    const startedAt = performance.now()
    const claims = await Promise.all(turnIds.map((turnId) => t.mutation(internal.askAI.claimQueuedTurn, { turnId })))
    const durationMs = performance.now() - startedAt
    const claimed = claims.filter(Boolean)
    expect(claimed.length).toBeLessThanOrEqual(MAX_CONCURRENT_GENERATIONS_GLOBAL)
    expect(claimed.length).toBe(MAX_CONCURRENT_GENERATIONS_GLOBAL)

    const stillQueued = await t.run(async (ctx) => {
      let count = 0
      for (const turnId of turnIds) {
        const turn = await ctx.db.get(turnId)
        if (turn?.status === "queued") count += 1
      }
      return count
    })
    expect(stillQueued).toBe(1_000 - MAX_CONCURRENT_GENERATIONS_GLOBAL)
    expect(durationMs).toBeLessThan(30_000)
  }, 60_000)
})
