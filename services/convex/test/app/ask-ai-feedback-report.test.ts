// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { internal } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")

describe("Ask AI feedback reporting", () => {
  test("groups feedback and joins model usage for auditing", async () => {
    const t = convexTest(schema, modules)
    const now = Date.now()
    await t.run(async (ctx) => {
      await ctx.db.insert("askAIThreads", {
        ownerSubject: "owner",
        threadId: "thread-feedback",
        title: "ETH liquidation risk",
        status: "active",
        createdAt: now,
        updatedAt: now,
      })
      await ctx.db.insert("askAIFeedback", {
        ownerSubject: "owner",
        threadId: "thread-feedback",
        messageId: "message-feedback",
        categories: ["Incorrect", "Outdated data"],
        note: "Wrong price",
        createdAt: now,
        updatedAt: now,
      })
      await ctx.db.insert("askAIUsage", {
        ownerSubject: "owner",
        threadId: "thread-feedback",
        messageId: "message-feedback",
        model: "gpt-5.6-luna",
        provider: "openai",
        inputTokens: 100,
        outputTokens: 20,
        totalTokens: 120,
        createdAt: now,
      })
    })

    await expect(t.query(internal.askAI.feedbackReport, {})).resolves.toMatchObject({
      total: 1,
      categories: { Incorrect: 1, "Outdated data": 1 },
      rows: [
        expect.objectContaining({
          threadTitle: "ETH liquidation risk",
          model: "gpt-5.6-luna",
          totalTokens: 120,
        }),
      ],
    })
  })
})
