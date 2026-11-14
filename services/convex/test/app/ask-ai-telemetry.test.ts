// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { register as registerAgent } from "@convex-dev/agent/test"
import { register as registerRateLimiter } from "@convex-dev/rate-limiter/test"
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api, internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")

describe("Ask AI operational telemetry", () => {
  test("reports latency, failures, tokens, and tool selection", async () => {
    const t = convexTest(schema, modules)
    const common = {
      ownerSubject: "ask-guest:telemetry",
      threadId: "thread-telemetry",
      model: "gpt-5.6-luna",
      provider: "openai",
    }
    await t.mutation(internal.askAITelemetry.record, {
      ...common,
      promptMessageId: "prompt-1",
      status: "complete",
      durationMs: 400,
      inputTokens: 100,
      outputTokens: 40,
      totalTokens: 140,
      tools: ["search_avana_knowledge"],
    })
    await t.mutation(internal.askAITelemetry.record, {
      ...common,
      promptMessageId: "prompt-2",
      status: "failed",
      durationMs: 100,
      tools: [],
      error: "Provider unavailable",
    })

    await expect(t.query(internal.askAITelemetry.report, {})).resolves.toMatchObject({
      total: 2,
      failures: 1,
      failureRate: 0.5,
      averageDurationMs: 400,
      totalTokens: 140,
      timeoutOutcomes: { unknown: 2 },
    })
  })
})

function setup(subject: string) {
  const t = convexTest(schema, modules)
  registerAgent(t)
  registerRateLimiter(t)
  return { t, owner: t.withIdentity({ subject }) }
}

test("watchdog outcomes survive retries and late worker metrics without duplicate rows", async () => {
  const subject = "ask-guest:telemetry-retry"
  const { t, owner } = setup(subject)
  const thread = await owner.mutation(api.askAI.create, {})
  const turn = await owner.mutation(api.askAI.enqueueTurn, {
    threadId: thread.threadId,
    prompt: "Hello",
    clientRequestId: "retry",
  })
  const first = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
  await t.run((ctx) => ctx.db.patch(turn.turnId, { updatedAt: Date.now() - 91_000 }))
  expect(await t.mutation(internal.askAI.timeoutRunningTurn, { turnId: turn.turnId })).toBe(true)
  // A worker that never returns still leaves a visible timeout, without invented model/usage.
  const timedOut = await t.query(internal.askAITelemetry.report, {})
  expect(timedOut).toMatchObject({ total: 1, failures: 1, timeoutOutcomes: { timed_out: 1 } })
  expect(timedOut.rows[0]!.model).toBeUndefined()
  expect(timedOut.rows[0]!.totalTokens).toBeUndefined()

  await owner.mutation(api.askAI.retryFailedTurn, { turnId: turn.turnId })
  const retry = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
  await t.mutation(internal.askAI.completeGeneratedTurn, {
    turnId: turn.turnId,
    assistantMessageId: "retry-reply",
    budgetReservationId: retry!.budgetReservationId,
    model: "test",
    usage: { inputTokens: 80, outputTokens: 20, totalTokens: 100 },
  })
  const metrics = {
    ownerSubject: subject,
    threadId: thread.threadId,
    promptMessageId: turn.promptMessageId,
    model: "test",
    provider: "openai",
    tools: [],
    durationMs: 100,
    status: "complete" as const,
    inputTokens: 80,
    outputTokens: 20,
    totalTokens: 100,
  }
  await t.mutation(internal.askAITelemetry.record, { ...metrics, attemptId: String(retry!.budgetReservationId) })
  // The original worker completes late, after the retry. It can fill usage, but cannot
  // rewrite its timeout, create another attempt, or change the user-visible duration.
  await t.mutation(internal.askAITelemetry.record, { ...metrics, attemptId: String(first!.budgetReservationId) })
  await t.mutation(internal.askAITelemetry.record, { ...metrics, attemptId: String(first!.budgetReservationId) })
  const report = await t.query(internal.askAITelemetry.report, {})
  expect(report).toMatchObject({
    total: 2,
    failures: 1,
    totalTokens: 200,
    timeoutOutcomes: { timed_out: 1, completed: 1 },
  })
  expect(report.rows.find((row) => row.attemptId === String(first!.budgetReservationId))).toMatchObject({
    status: "failed",
    timeoutOutcome: "timed_out",
    durationMs: timedOut.rows[0]!.durationMs,
    model: "test",
  })
})

test("cancellation is retained when the worker completes late and is not a provider failure", async () => {
  const subject = "ask-guest:telemetry-cancel"
  const { t, owner } = setup(subject)
  const thread = await owner.mutation(api.askAI.create, {})
  const turn = await owner.mutation(api.askAI.enqueueTurn, {
    threadId: thread.threadId,
    prompt: "Hello",
    clientRequestId: "cancel",
  })
  const claimed = await t.mutation(internal.askAI.claimQueuedTurn, { turnId: turn.turnId })
  await owner.mutation(api.askAI.cancelRunningTurn, { threadId: thread.threadId })
  await t.mutation(internal.askAITelemetry.record, {
    attemptId: String(claimed!.budgetReservationId),
    ownerSubject: subject,
    threadId: thread.threadId,
    promptMessageId: turn.promptMessageId,
    model: "test",
    provider: "openai",
    tools: [],
    durationMs: 100,
    status: "complete",
  })
  expect(await t.query(internal.askAITelemetry.report, {})).toMatchObject({
    total: 1,
    failures: 0,
    failureRate: 0,
    timeoutOutcomes: { cancelled: 1 },
  })
})
