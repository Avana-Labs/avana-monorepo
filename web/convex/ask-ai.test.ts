// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { describe, expect, test } from "vitest"
import { api, internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

describe("Ask AI thread ownership", () => {
  test("renames an owned thread and rejects invalid titles", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})

    await expect(
      owner.mutation(api.askAI.rename, { threadId: thread.threadId, title: "  ETH   risk\nreview  " }),
    ).resolves.toEqual({
      threadId: thread.threadId,
      title: "ETH risk review",
    })
    await expect(owner.mutation(api.askAI.rename, { threadId: thread.threadId, title: "   " })).rejects.toThrow(
      "Thread title must contain 1 to 80 characters",
    )
  })

  test("does not allow another subject to rename a thread", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const other = t.withIdentity({ subject: "ask-guest:other" })
    const thread = await owner.mutation(api.askAI.create, {})

    await expect(other.mutation(api.askAI.rename, { threadId: thread.threadId, title: "Stolen" })).rejects.toThrow(
      "Thread not found",
    )
  })

  test("archives and restores only owned threads", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const other = t.withIdentity({ subject: "ask-guest:other" })
    const thread = await owner.mutation(api.askAI.create, {})

    await expect(other.mutation(api.askAI.archive, { threadId: thread.threadId })).rejects.toThrow("Thread not found")
    await owner.mutation(api.askAI.archive, { threadId: thread.threadId })
    await expect(owner.query(api.askAI.list, {})).resolves.toEqual([])
    await expect(owner.query(api.askAI.list, { includeArchived: true })).resolves.toEqual([
      expect.objectContaining({ threadId: thread.threadId, status: "archived" }),
    ])
    await expect(other.mutation(api.askAI.unarchive, { threadId: thread.threadId })).rejects.toThrow("Thread not found")
    await owner.mutation(api.askAI.unarchive, { threadId: thread.threadId })
    await expect(owner.query(api.askAI.list, {})).resolves.toEqual([
      expect.objectContaining({ threadId: thread.threadId, status: "active" }),
    ])
  })
})

describe("Ask AI turn lifecycle", () => {
  test("a cancelled turn is not resurrected by a late completeGeneratedTurn", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})

    // A turn that the user already cancelled (cancelRunningTurn set this state
    // and aborted the stream). Inserted directly to avoid the rate-limiter
    // component, which the convex-test harness does not register.
    const promptMessageId = "cancelled-prompt-message"
    const turnId = await t.run(async (ctx) => {
      const now = Date.now()
      return await ctx.db.insert("askAITurns", {
        threadId: thread.threadId,
        ownerSubject: "ask-guest:owner",
        promptMessageId,
        prompt: "What is Avana?",
        status: "cancelled",
        createdAt: now,
        updatedAt: now,
      })
    })

    // The in-flight action's stream finished just after the cancel landed and
    // still calls completeGeneratedTurn. It must be a no-op, not a completion.
    await t.mutation(internal.askAI.completeGeneratedTurn, {
      turnId,
      assistantMessageId: "late-assistant-message",
      model: "gpt-5.6-luna",
      usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30 },
      richParts: { sources: [], usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30 } },
    })

    const { turn, parts } = await t.run(async (ctx) => {
      const turnRow = await ctx.db
        .query("askAITurns")
        .withIndex("by_prompt_message", (q) => q.eq("promptMessageId", promptMessageId))
        .unique()
      const partRows = await ctx.db
        .query("askAIMessageParts")
        .withIndex("by_thread", (q) => q.eq("threadId", thread.threadId))
        .collect()
      return { turn: turnRow, parts: partRows }
    })

    expect(turn?.status).toBe("cancelled")
    expect(parts).toHaveLength(0)
  })

  test("turnQueue returns only this thread's non-terminal turns", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const threadA = await owner.mutation(api.askAI.create, {})
    const threadB = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      const now = Date.now()
      const insert = (threadId: string, status: "queued" | "running" | "complete" | "cancelled", key: string) =>
        ctx.db.insert("askAITurns", {
          threadId,
          ownerSubject: "ask-guest:owner",
          promptMessageId: key,
          prompt: key,
          status,
          createdAt: now,
          updatedAt: now,
        })
      await insert(threadA.threadId, "queued", "a-queued")
      await insert(threadA.threadId, "complete", "a-complete")
      await insert(threadB.threadId, "running", "b-running")
    })

    const queue = await owner.query(api.askAI.turnQueue, { threadId: threadA.threadId })
    expect(queue.map((row) => row.promptMessageId)).toEqual(["a-queued"])
  })

  test("turnQueue bounds retained failures instead of collecting the thread forever", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      for (let index = 0; index < 75; index += 1) {
        await ctx.db.insert("askAITurns", {
          threadId: thread.threadId,
          ownerSubject: "ask-guest:owner",
          promptMessageId: `failed-${index}`,
          prompt: `failed-${index}`,
          status: "failed",
          createdAt: index,
          updatedAt: index,
        })
      }
    })

    const queue = await owner.query(api.askAI.turnQueue, { threadId: thread.threadId })
    expect(queue).toHaveLength(50)
    expect(queue[0]?.promptMessageId).toBe("failed-25")
    expect(queue.at(-1)?.promptMessageId).toBe("failed-74")
  })

  test("enqueueTurn closes a full thread before writing another prompt", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      for (let index = 0; index < 500; index += 1) {
        await ctx.db.insert("askAITurns", {
          threadId: thread.threadId,
          ownerSubject: "ask-guest:owner",
          promptMessageId: `complete-${index}`,
          prompt: `complete-${index}`,
          status: "complete",
          createdAt: index,
          updatedAt: index,
        })
      }
    })

    await expect(
      owner.mutation(api.askAI.enqueueTurn, {
        threadId: thread.threadId,
        prompt: "one turn too many",
        clientRequestId: "full-thread-request",
      }),
    ).rejects.toThrow(/This chat is full/)
    const turns = await t.run(async (ctx) =>
      ctx.db
        .query("askAITurns")
        .withIndex("by_thread_status_created", (q) => q.eq("threadId", thread.threadId))
        .collect(),
    )
    expect(turns).toHaveLength(500)
  })

  test("messageParts returns persisted rich parts for an owned thread", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const other = t.withIdentity({ subject: "ask-guest:other" })
    const thread = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      await ctx.db.insert("askAIMessageParts", {
        threadId: thread.threadId,
        messageId: "m1",
        parts: { sources: [], usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 } },
        createdAt: Date.now(),
      })
    })

    await expect(owner.query(api.askAI.messageParts, { threadId: thread.threadId })).resolves.toEqual([
      { messageId: "m1", parts: { sources: [], usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 } } },
    ])
    await expect(other.query(api.askAI.messageParts, { threadId: thread.threadId })).rejects.toThrow("Thread not found")
  })

  test("messageParts bounds a long-lived thread to its latest 500 results", async () => {
    const t = askAITest()
    const owner = t.withIdentity({ subject: "ask-guest:owner" })
    const thread = await owner.mutation(api.askAI.create, {})
    await t.run(async (ctx) => {
      for (let index = 0; index < 525; index += 1) {
        await ctx.db.insert("askAIMessageParts", {
          threadId: thread.threadId,
          messageId: `m${index}`,
          parts: { index },
          createdAt: index,
        })
      }
    })

    const parts = await owner.query(api.askAI.messageParts, { threadId: thread.threadId })
    expect(parts).toHaveLength(500)
    expect(parts[0]?.messageId).toBe("m524")
    expect(parts.at(-1)?.messageId).toBe("m25")
  })
})
