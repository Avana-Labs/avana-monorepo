// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { codedError } from "./codedError"
import { v } from "convex/values"
import { mutation } from "./_generated/server"

/** Server-enforced ceilings on the client-supplied bucket parameters. The trusted callers
 *  (SIWE nonce/verify) pass small fixed values well inside these; the bounds exist so a direct
 *  caller cannot request an enormous window/limit or spray oversized keys to bloat the table. */
const MAX_KEY_LENGTH = 128
const MAX_LIMIT = 10_000
const MIN_WINDOW_MS = 1_000
const MAX_WINDOW_MS = 24 * 60 * 60 * 1000

/** Constant-time string compare (no early exit) for the optional shared secret. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

/**
 * Atomically consume one hit from the (key, windowMs) bucket. Convex mutations are
 * serializable — concurrent callers with the same key retry on write conflict — so
 * this is a correct shared counter across Next server instances. Returns whether the
 * hit was allowed and how many remain in the current window.
 *
 * This is a PUBLIC mutation because its only caller is a Next server route using an
 * external Convex client (which cannot call internal functions). It is therefore
 * hardened two ways:
 *  - the client-supplied key/limit/windowMs are bounded (below), and
 *  - a matching `CONVEX_RATE_LIMIT_SECRET` is always required. Failing closed keeps
 *    direct callers from poisoning another user's SIWE bucket.
 */
export const consume = mutation({
  args: {
    key: v.string(),
    limit: v.number(),
    windowMs: v.number(),
    secret: v.string(),
  },
  handler: async (ctx, { key, limit, windowMs, secret }) => {
    const requiredSecret = process.env.CONVEX_RATE_LIMIT_SECRET
    if (!requiredSecret || !safeEqual(secret, requiredSecret)) {
      throw codedError("UNAUTHORIZED: rate-limit secret required")
    }
    if (
      key.length === 0 ||
      key.length > MAX_KEY_LENGTH ||
      !Number.isFinite(limit) ||
      limit < 1 ||
      limit > MAX_LIMIT ||
      !Number.isFinite(windowMs) ||
      windowMs < MIN_WINDOW_MS ||
      windowMs > MAX_WINDOW_MS
    ) {
      throw codedError("INVALID_RATE_LIMIT: key/limit/windowMs out of bounds")
    }

    const now = Date.now()
    const existing = await ctx.db
      .query("rateLimitBuckets")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique()

    if (!existing || existing.resetAt <= now) {
      const resetAt = now + windowMs
      if (existing) {
        await ctx.db.patch(existing._id, { count: 1, resetAt })
      } else {
        await ctx.db.insert("rateLimitBuckets", { key, count: 1, resetAt })
      }
      return { allowed: true, remaining: Math.max(0, limit - 1), resetAt }
    }

    if (existing.count >= limit) {
      return { allowed: false, remaining: 0, resetAt: existing.resetAt }
    }

    const nextCount = existing.count + 1
    await ctx.db.patch(existing._id, { count: nextCount })
    return { allowed: true, remaining: Math.max(0, limit - nextCount), resetAt: existing.resetAt }
  },
})
