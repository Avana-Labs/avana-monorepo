import { v } from "convex/values"
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server"
import type { Doc } from "./_generated/dataModel"

type TurnOutcome = "completed" | "failed" | "timed_out" | "cancelled"

/** One terminal outcome per attempt, written atomically with the turn transition. */
export async function recordTurnOutcome(ctx: MutationCtx, turn: Doc<"askAITurns">, outcome: TurnOutcome) {
  const attemptId = String(turn.budgetReservationId ?? turn._id)
  const existing = await ctx.db
    .query("askAITelemetry")
    .withIndex("by_attempt", (q) => q.eq("attemptId", attemptId))
    .unique()
  if (existing?.timeoutOutcome) return
  const now = Date.now()
  const terminal = {
    timeoutOutcome: outcome,
    status:
      outcome === "completed"
        ? ("complete" as const)
        : outcome === "cancelled"
          ? ("cancelled" as const)
          : ("failed" as const),
    durationMs: Math.max(0, now - turn.updatedAt),
  }
  if (existing) {
    await ctx.db.patch(existing._id, terminal)
  } else {
    // Model/provider and usage remain absent until the worker supplies them.
    await ctx.db.insert("askAITelemetry", {
      attemptId,
      ownerSubject: turn.ownerSubject,
      threadId: turn.threadId,
      promptMessageId: turn.promptMessageId,
      ...terminal,
      tools: [],
      createdAt: now,
    })
  }
}

export const record = internalMutation({
  args: {
    attemptId: v.optional(v.string()),
    ownerSubject: v.string(),
    threadId: v.string(),
    promptMessageId: v.string(),
    status: v.union(v.literal("complete"), v.literal("failed")),
    model: v.string(),
    provider: v.string(),
    durationMs: v.number(),
    inputTokens: v.optional(v.number()),
    outputTokens: v.optional(v.number()),
    totalTokens: v.optional(v.number()),
    cacheReadTokens: v.optional(v.number()),
    cacheWriteTokens: v.optional(v.number()),
    serviceTier: v.optional(v.string()),
    tools: v.array(v.string()),
    routeIntent: v.optional(v.string()),
    toolBudget: v.optional(v.number()),
    error: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const existing = args.attemptId
      ? await ctx.db
          .query("askAITelemetry")
          .withIndex("by_attempt", (q) => q.eq("attemptId", args.attemptId))
          .unique()
      : null
    if (existing) {
      // Late worker completion must not overwrite a timeout/cancellation or move
      // a historical attempt onto the retry's outcome.
      await ctx.db.patch(existing._id, {
        ...args,
        ...(existing.timeoutOutcome ? { status: existing.status, durationMs: existing.durationMs } : {}),
      })
      return existing._id
    }
    return ctx.db.insert("askAITelemetry", { ...args, createdAt: Date.now() })
  },
})

export const report = internalQuery({
  args: { since: v.optional(v.number()), limit: v.optional(v.number()) },
  handler: async (ctx, { since, limit }) => {
    const rows = await ctx.db
      .query("askAITelemetry")
      .withIndex("by_created", (q) => (since ? q.gte("createdAt", since) : q))
      .order("desc")
      .take(Math.min(Math.max(limit ?? 200, 1), 1_000))
    const complete = rows.filter((row) => row.status === "complete")
    const generationsByPrompt = new Map<string, number>()
    for (const row of rows)
      generationsByPrompt.set(row.promptMessageId, (generationsByPrompt.get(row.promptMessageId) ?? 0) + 1)
    // Historical rows without an attempt outcome stay unknown; the mutable
    // turn row cannot tell us which retry produced a historical telemetry row.
    const rowsWithTimeoutOutcomes = rows.map((row) => ({ ...row, timeoutOutcome: row.timeoutOutcome ?? "unknown" }))
    const timeoutOutcomes = rowsWithTimeoutOutcomes.reduce<Record<string, number>>((counts, row) => {
      counts[row.timeoutOutcome] = (counts[row.timeoutOutcome] ?? 0) + 1
      return counts
    }, {})
    return {
      total: rows.length,
      failures: rows.filter((row) => row.status === "failed").length,
      failureRate: rows.length ? rows.filter((row) => row.status === "failed").length / rows.length : 0,
      averageDurationMs: complete.length ? complete.reduce((sum, row) => sum + row.durationMs, 0) / complete.length : 0,
      cacheReadTokens: rows.reduce((sum, row) => sum + (row.cacheReadTokens ?? 0), 0),
      cacheWriteTokens: rows.reduce((sum, row) => sum + (row.cacheWriteTokens ?? 0), 0),
      totalTokens: rows.reduce((sum, row) => sum + (row.totalTokens ?? 0), 0),
      duplicatePromptMessageIds: [...generationsByPrompt.entries()]
        .filter(([, count]) => count > 1)
        .map(([promptMessageId]) => promptMessageId),
      toolBudgetViolations: rows.filter((row) => row.toolBudget !== undefined && row.tools.length > row.toolBudget)
        .length,
      cachedPriceWebSearchViolations: rows.filter(
        (row) => row.routeIntent === "market" && row.tools.includes("web_search"),
      ).length,
      priceLookupTokenViolations: rows.filter((row) => row.routeIntent === "market" && (row.totalTokens ?? 0) > 2_000)
        .length,
      timeoutOutcomes,
      rows: rowsWithTimeoutOutcomes,
    }
  },
})
