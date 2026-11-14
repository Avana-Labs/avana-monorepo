// @vitest-environment edge-runtime
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { ASK_AI_CONFIG } from "../app/lib/ask-ai/config"
import { api } from "./_generated/api"
import * as askAIModule from "./askAI"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

// Seed durable token usage so the daily-token budget is already exhausted for
// this owner (the check reads askAIUsage summed over the trailing 24h window).
async function exhaustDailyTokenBudget(t: ReturnType<typeof askAITest>, ownerSubject: string) {
  await t.run(async (ctx) => {
    await ctx.db.insert("askAIUsage", {
      ownerSubject,
      threadId: "seed-thread",
      messageId: "seed-message",
      model: ASK_AI_CONFIG.defaultModel,
      provider: "openai",
      inputTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
      outputTokens: 0,
      totalTokens: ASK_AI_CONFIG.limits.dailyTokenBudget,
      createdAt: Date.now(),
    })
  })
}

// The client-facing error contract: the turn
// entry points throw a ConvexError carrying a user-safe `{ code, message }`
// payload — never a raw Error — so Convex's production redaction preserves the
// friendly message and the UI can key copy off `code`. `error.data` is the
// ConvexError payload; a raw Error has no `data`.
describe("Ask AI turn error contract", () => {
  describe("enqueueTurn", () => {
    test("message too long -> ASK_AI_GENERATION_FAILED", async () => {
      const t = askAITest()
      const owner = t.withIdentity({ subject: "ask-guest:enqueue-toolong" })
      const thread = await owner.mutation(api.askAI.create, {})

      await expect(
        owner.mutation(api.askAI.enqueueTurn, {
          threadId: thread.threadId,
          prompt: "y".repeat(ASK_AI_CONFIG.maxInputCharacters + 1),
          clientRequestId: "too-long",
        }),
      ).rejects.toMatchObject({
        data: { code: "ASK_AI_GENERATION_FAILED", message: expect.stringContaining("2000 characters") },
      })
    })

    test("daily token budget reached -> ASK_AI_RATE_LIMITED", async () => {
      const t = askAITest()
      const ownerSubject = "ask-guest:enqueue-tokenlimit"
      await exhaustDailyTokenBudget(t, ownerSubject)
      const owner = t.withIdentity({ subject: ownerSubject })
      const thread = await owner.mutation(api.askAI.create, {})

      await expect(
        owner.mutation(api.askAI.enqueueTurn, {
          threadId: thread.threadId,
          prompt: "Any question",
          clientRequestId: "token-limit",
        }),
      ).rejects.toMatchObject({
        data: { code: "ASK_AI_RATE_LIMITED", message: expect.stringContaining("daily token limit") },
      })
    })

    test("per-subject daily request limiter tripped -> ASK_AI_RATE_LIMITED", async () => {
      const t = askAITest()
      const owner = t.withIdentity({ subject: "ask-guest:enqueue-ratelimit" })
      // perSubjectDaily allows 20 requests/day. Spread one enqueue across 20
      // separate threads so the per-thread queue-full guard (>= 10 queued) is
      // never the thing that trips — the 21st enqueue must fail on the limiter.
      for (let i = 0; i < 20; i += 1) {
        const thread = await owner.mutation(api.askAI.create, {})
        await owner.mutation(api.askAI.enqueueTurn, {
          threadId: thread.threadId,
          prompt: `Q${i}`,
          clientRequestId: `rate-${i}`,
        })
      }
      const overflowThread = await owner.mutation(api.askAI.create, {})

      await expect(
        owner.mutation(api.askAI.enqueueTurn, {
          threadId: overflowThread.threadId,
          prompt: "One too many",
          clientRequestId: "rate-overflow",
        }),
      ).rejects.toMatchObject({ data: { code: "ASK_AI_RATE_LIMITED", message: expect.any(String) } })
    })

    test("queue-full guard also throws the typed ASK_AI_RATE_LIMITED code", async () => {
      const t = askAITest()
      const owner = t.withIdentity({ subject: "ask-guest:enqueue-queuefull" })
      const thread = await owner.mutation(api.askAI.create, {})
      // The queue caps at 10 queued turns per thread; the 11th is rejected.
      for (let i = 0; i < 10; i += 1)
        await owner.mutation(api.askAI.enqueueTurn, {
          threadId: thread.threadId,
          prompt: `Q${i}`,
          clientRequestId: `queue-${i}`,
        })

      await expect(
        owner.mutation(api.askAI.enqueueTurn, {
          threadId: thread.threadId,
          prompt: "Eleventh",
          clientRequestId: "queue-eleventh",
        }),
      ).rejects.toMatchObject({ data: { code: "ASK_AI_RATE_LIMITED", message: expect.stringContaining("queue") } })
    })
  })

  // Mutation lockdown: completeGeneratedTurn / failTurn are internalMutation so no
  // client can settle or fail a turn. The generated `api`/`internal` objects are
  // proxies that fabricate a reference for ANY property access, so absence cannot
  // be probed there. Instead assert the registered function objects themselves are
  // internal-only (isInternal, not isPublic) — this is what determines whether they
  // land on `api` vs `internal`.
  describe("mutation lockdown", () => {
    const registered = askAIModule as unknown as Record<string, { isInternal?: boolean; isPublic?: boolean }>
    const lockedDown = ["completeGeneratedTurn", "failTurn"] as const

    test.each(lockedDown)("%s is registered internal-only (never public)", (name) => {
      expect(registered[name]).toBeDefined()
      expect(registered[name].isInternal).toBe(true)
      expect(registered[name].isPublic).toBeUndefined()
    })

    test("the public turn entry points remain public (control)", () => {
      expect(registered.enqueueTurn.isPublic).toBe(true)
    })
  })
})
