/**
 * Support Center persistence. Every request submitted from the Support Center
 * form is written here so the team has a durable, queryable record. Submission
 * requires an authenticated wallet: the wallet is derived server-side from
 * ctx.auth (never trusted from the client, so it can't be spoofed), and a
 * per-wallet hourly cap bounds storage-abuse. Inputs are validated and clamped
 * server-side — never trust client-supplied lengths.
 */

import { codedError } from "./codedError"
import { v } from "convex/values"
import { internalQuery, mutation } from "./_generated/server"
import { getAuthedWallet } from "./sandbox/auth"

const MESSAGE_MIN = 10
const MESSAGE_MAX = 5000
const FIELD_MAX = 200

/** Hourly per-wallet support-request cap (anti-abuse). Exported for tests. */
export const MAX_REQUESTS_PER_HOUR = 20

function clamp(value: string, max: number) {
  return value.trim().slice(0, max)
}

export const submitSupportRequest = mutation({
  args: {
    category: v.string(),
    categoryLabel: v.optional(v.string()),
    topic: v.string(),
    topicLabel: v.optional(v.string()),
    message: v.string(),
    userEmail: v.optional(v.string()),
    userAgent: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const wallet = await getAuthedWallet(ctx)
    if (!wallet) {
      throw codedError("UNAUTHENTICATED: connect a wallet and sign in to contact support.")
    }

    const message = args.message.trim()
    if (message.length < MESSAGE_MIN) {
      throw new Error(`Please describe the issue in at least ${MESSAGE_MIN} characters.`)
    }
    const category = clamp(args.category, FIELD_MAX)
    const topic = clamp(args.topic, FIELD_MAX)
    if (!category || !topic) {
      throw new Error("Choose a category and topic before sending.")
    }

    // Hourly per-wallet rate limit. `take(MAX_REQUESTS_PER_HOUR)` bounds the read
    // instead of collecting the wallet's entire trailing-hour history to count it.
    const now = Date.now()
    const windowStart = now - 60 * 60 * 1000
    const recent = await ctx.db
      .query("supportRequests")
      .withIndex("by_wallet_created", (q) => q.eq("wallet", wallet).gte("createdAt", windowStart))
      .take(MAX_REQUESTS_PER_HOUR)
    if (recent.length >= MAX_REQUESTS_PER_HOUR) {
      throw codedError(`RATE_LIMITED: more than ${MAX_REQUESTS_PER_HOUR} support requests in the last hour.`)
    }

    const id = await ctx.db.insert("supportRequests", {
      wallet,
      userEmail: args.userEmail ? clamp(args.userEmail, FIELD_MAX) : undefined,
      category,
      categoryLabel: args.categoryLabel ? clamp(args.categoryLabel, FIELD_MAX) : undefined,
      topic,
      topicLabel: args.topicLabel ? clamp(args.topicLabel, FIELD_MAX) : undefined,
      message: message.slice(0, MESSAGE_MAX),
      status: "new",
      userAgent: args.userAgent ? clamp(args.userAgent, FIELD_MAX) : undefined,
      createdAt: now,
    })

    return { id: String(id) }
  },
})

/**
 * Most-recent support requests (newest first). For an internal triage view only —
 * these rows contain other users' PII (wallet, email, message), so this is an
 * `internalQuery` and is never exposed on the public `api`.
 */
export const listRecentSupportRequests = internalQuery({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const take = Math.min(Math.max(limit ?? 50, 1), 200)
    return await ctx.db.query("supportRequests").withIndex("by_created_at").order("desc").take(take)
  },
})
