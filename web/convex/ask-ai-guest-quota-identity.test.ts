// @vitest-environment edge-runtime
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { ASK_AI_CONFIG } from "../app/lib/ask-ai/config"
import { api } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

function askAITest() {
  const t = convexTest(schema, modules)
  registerRateLimiter(t)
  return t
}

async function seedUsage(t: ReturnType<typeof askAITest>, ownerSubject: string, totalTokens: number) {
  await t.run((ctx) =>
    ctx.db.insert("askAIUsage", {
      ownerSubject,
      threadId: `thread-${ownerSubject}`,
      messageId: `message-${ownerSubject}`,
      model: ASK_AI_CONFIG.defaultModel,
      provider: "openai",
      inputTokens: totalTokens,
      outputTokens: 0,
      totalTokens,
      createdAt: Date.now(),
    }),
  )
}

// REGRESSION MARKER — guest quota identity / rotation risk.
//
// Ask AI quota (request count AND daily token budget) is keyed entirely on
// `ownerSubject` (convex/askAI.ts::quota, enqueueTurn). For an
// authenticated wallet the subject is stable, but a *guest* subject is minted
// per session ("ask-guest:*"). Nothing ties one guest subject to the next, so a
// guest who rotates to a fresh subject is handed a fresh daily budget — the
// per-subject limit does not survive subject rotation.
//
// This test documents that behavior on purpose: it is the intended contract for
// authed wallets and the known limitation for guests. If a future change makes
// guest quota survive rotation (e.g. a device/IP key), this test should be
// updated deliberately rather than silently regressed.
describe("Ask AI guest quota is keyed on ownerSubject", () => {
  test("a fresh guest subject starts with a fresh daily budget", async () => {
    const t = askAITest()
    const usedGuest = "ask-guest:rotation-before"
    const freshGuest = "ask-guest:rotation-after"

    // The first guest subject has burned most of its token budget.
    await seedUsage(t, usedGuest, ASK_AI_CONFIG.limits.dailyTokenBudget - 500)

    await expect(t.withIdentity({ subject: usedGuest }).query(api.askAI.quota, {})).resolves.toMatchObject({
      tokensUsed: ASK_AI_CONFIG.limits.dailyTokenBudget - 500,
      tokensRemaining: 500,
    })

    // A brand-new guest subject — the rotation case — sees an untouched budget,
    // because usage is filtered by ownerSubject and nothing links the two.
    await expect(t.withIdentity({ subject: freshGuest }).query(api.askAI.quota, {})).resolves.toMatchObject({
      tokensUsed: 0,
      tokenLimit: ASK_AI_CONFIG.limits.dailyTokenBudget,
      tokensRemaining: ASK_AI_CONFIG.limits.dailyTokenBudget,
    })
  })

  test("token usage from one subject never counts against another subject", async () => {
    const t = askAITest()
    await seedUsage(t, "ask-guest:subject-x", 12_345)

    await expect(t.withIdentity({ subject: "ask-guest:subject-y" }).query(api.askAI.quota, {})).resolves.toMatchObject({
      tokensUsed: 0,
    })
  })
})
