import { v } from "convex/values"
import { query, type QueryCtx } from "./_generated/server"

/**
 * Persistence for Ask AI mode-runs (Phase 2).
 *
 * A run is the typed unit the deterministic modes produce: mode + the single snapshot
 * it was computed on + typed widgets + typed actions. Storing it here (instead of
 * scattering financial results across askAIMessageParts.parts) makes an answer
 * reproducible, testable, and attributable for feedback. Read-only for now: the unused
 * public `record` writer was removed, so a future writer should be an internalMutation
 * that validates widget discriminants against ASK_AI_WIDGET_TYPES.
 */

async function requireOwnerSubject(ctx: Pick<QueryCtx, "auth">): Promise<string> {
  const identity = await ctx.auth.getUserIdentity()
  if (!identity?.subject) throw new Error("Ask AI session required")
  return identity.subject
}

export const get = query({
  args: { runId: v.id("askAiRuns") },
  handler: async (ctx, { runId }) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    const run = await ctx.db.get(runId)
    if (!run || run.ownerSubject !== ownerSubject) return null
    return run
  },
})

export const listByThread = query({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    const runs = await ctx.db
      .query("askAiRuns")
      .withIndex("by_thread", (q) => q.eq("threadId", threadId))
      .collect()
    return runs.filter((run) => run.ownerSubject === ownerSubject)
  },
})
