// @vitest-environment edge-runtime
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return t
}

// Regression: message-read isolation. Ownership is enforced by
// `requireOwnedThread` in convex/askAI.ts. A different subject must never be
// able to read another owner's messages or turn queue by presenting the
// threadId — the read has to fail closed with "Thread not found", and must
// never leak the owner's rows.
describe("Ask AI cross-user message-read isolation", () => {
  test("user B cannot read user A's messages via api.askAI.messages", async () => {
    const t = askAITest()
    const userA = t.withIdentity({ subject: "ask-guest:owner-a" })
    const userB = t.withIdentity({ subject: "ask-guest:owner-b" })
    const thread = await userA.mutation(api.askAI.create, {})
    await userA.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "A's private question",
      clientRequestId: "authz-begin-a",
    })

    // Owner A can read; the query returns their own page.
    await expect(
      userA.query(api.askAI.messages, {
        threadId: thread.threadId,
        paginationOpts: { cursor: null, numItems: 20 },
      }),
    ).resolves.toMatchObject({ page: expect.any(Array) })

    // User B presenting A's threadId is rejected before any message is returned.
    await expect(
      userB.query(api.askAI.messages, {
        threadId: thread.threadId,
        paginationOpts: { cursor: null, numItems: 20 },
      }),
    ).rejects.toThrow("Thread not found")
  })

  test("user B cannot read user A's turn queue via api.askAI.turnQueue", async () => {
    const t = askAITest()
    const userA = t.withIdentity({ subject: "ask-guest:queue-a" })
    const userB = t.withIdentity({ subject: "ask-guest:queue-b" })
    const thread = await userA.mutation(api.askAI.create, {})
    await userA.mutation(api.askAI.enqueueTurn, {
      threadId: thread.threadId,
      prompt: "A's queued question",
      clientRequestId: "authz-queue-a",
    })

    await expect(userA.query(api.askAI.turnQueue, { threadId: thread.threadId })).resolves.toMatchObject([
      { prompt: "A's queued question", status: "queued" },
    ])
    await expect(userB.query(api.askAI.turnQueue, { threadId: thread.threadId })).rejects.toThrow("Thread not found")
  })

  test("an unauthenticated caller cannot read another owner's thread", async () => {
    const t = askAITest()
    const userA = t.withIdentity({ subject: "ask-guest:anon-owner" })
    const thread = await userA.mutation(api.askAI.create, {})

    await expect(
      t.query(api.askAI.messages, {
        threadId: thread.threadId,
        paginationOpts: { cursor: null, numItems: 20 },
      }),
    ).rejects.toThrow("Ask AI session required")
    await expect(t.query(api.askAI.turnQueue, { threadId: thread.threadId })).rejects.toThrow("Ask AI session required")
  })
})
