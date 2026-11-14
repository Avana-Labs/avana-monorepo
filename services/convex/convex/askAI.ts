// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { queueRetryDelay } from "./lib/askAI/queueBackoff"
import {
  abortStream,
  createThread,
  listMessages,
  listStreams,
  listUIMessages,
  saveMessage,
  syncStreams,
  vStreamArgs,
} from "@convex-dev/agent"
import { RateLimiter, isRateLimitError } from "@convex-dev/rate-limiter"
import { paginationOptsValidator } from "convex/server"
import { ConvexError, v, type GenericId } from "convex/values"
import { components, internal } from "./_generated/api"
import type { Id } from "./_generated/dataModel"
import { internalMutation, internalQuery, mutation, query, type MutationCtx, type QueryCtx } from "./_generated/server"
import { ASK_AI_CONFIG } from "./lib/askAI/config"
import { getAuthedWallet } from "./walletAuth"
import { recordTurnOutcome } from "./askAITelemetry"

type AskAICtx = QueryCtx | MutationCtx

const askAIRateLimiter = new RateLimiter(components.rateLimiter, {
  perSubjectDaily: {
    kind: "fixed window",
    rate: ASK_AI_CONFIG.limits.messagesPerDay,
    period: 24 * 60 * 60 * 1_000,
  },
  perSubjectBurst: {
    kind: "token bucket",
    rate: 1,
    period: ASK_AI_CONFIG.limits.minimumMessageIntervalMs,
    capacity: 1,
  },
  globalDailyTokens: {
    kind: "fixed window",
    rate: ASK_AI_CONFIG.limits.globalReservedTokensPerDay,
    period: 24 * 60 * 60 * 1_000,
  },
  globalDaily: {
    kind: "fixed window",
    rate: ASK_AI_CONFIG.limits.globalMessagesPerDay,
    period: 24 * 60 * 60 * 1_000,
  },
  // Cross-instance cap on minting NEW guest identities per client IP, so clearing the guest
  // cookie cannot yield unlimited fresh quotas across serverless instances.
  guestMintPerIp: { kind: "fixed window", rate: 30, period: 60 * 60 * 1_000 },
  threadCreatePerSubject: { kind: "fixed window", rate: 30, period: 60 * 60 * 1_000 },
  threadCreateGlobal: { kind: "fixed window", rate: 5_000, period: 60 * 60 * 1_000 },
})

// User-facing throws MUST be ConvexError: the friendly message then survives Convex's
// production error redaction and the client renders error.data.message.
type AskAIErrorCode = "ASK_AI_GENERATION_FAILED" | "ASK_AI_RATE_LIMITED" | "ASK_AI_UNAVAILABLE"

const ASK_AI_RUNNING_TIMEOUT_MS = 90_000
const MAX_THREADS_PER_SUBJECT = 1_000
const MAX_TURNS_PER_THREAD = 500
const MAX_FAILED_TURNS_IN_QUEUE = 50
/** Global + per-subject caps on turns currently generating a model response. */
const MAX_CONCURRENT_GENERATIONS_GLOBAL = 100
const MAX_CONCURRENT_GENERATIONS_PER_SUBJECT = 2
const ASK_AI_COST_BUCKET_MS = 60 * 60 * 1_000

function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let index = 0; index < a.length; index += 1) diff |= a.charCodeAt(index) ^ b.charCodeAt(index)
  return diff === 0
}

function askAIError(code: AskAIErrorCode, message: string): ConvexError<{ code: AskAIErrorCode; message: string }> {
  return new ConvexError({ code, message })
}

// The rate limiter throws its own ConvexError ({ kind: "RateLimited", … }); re-map it to the
// shared Ask AI error shape so the client gets a friendly, redaction-safe message.
async function enforceAskAIRateLimit<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (error) {
    if (isRateLimitError(error))
      throw askAIError(
        "ASK_AI_RATE_LIMITED",
        "Ask AI is handling a lot of requests right now. Please wait a moment and try again.",
      )
    throw error
  }
}

/**
 * The single atomic cost gate for EVERY turn submission entry point: daily subject/global
 * message caps, burst spacing, optional concurrent-generation caps and the daily token budget,
 * all enforced before any message or turn row is persisted.
 */
async function enforceAskAICostGate(
  ctx: MutationCtx,
  ownerSubject: string,
  options: { enforceBurst: boolean; enforceConcurrent: boolean },
) {
  const now = Date.now()
  await ensureAskAIQuotaState(ctx, ownerSubject, now)
  const totals = await readAskAICostTotals(ctx, ownerSubject, now)
  if (
    totals.usedTokens + totals.reservedTokens + ASK_AI_CONFIG.limits.reservedTokensPerTurn >
    ASK_AI_CONFIG.limits.dailyTokenBudget
  ) {
    throw askAIError("ASK_AI_RATE_LIMITED", "Ask AI daily token limit reached. Need help? Contact Avana Support.")
  }

  if (options.enforceConcurrent) {
    await assertConcurrentGenerationCapacity(ctx, ownerSubject)
  }

  await enforceAskAIRateLimit(() => askAIRateLimiter.limit(ctx, "perSubjectDaily", { key: ownerSubject, throws: true }))
  if (options.enforceBurst) {
    await enforceAskAIRateLimit(() =>
      askAIRateLimiter.limit(ctx, "perSubjectBurst", { key: ownerSubject, throws: true }),
    )
  }
  await enforceAskAIRateLimit(() => askAIRateLimiter.limit(ctx, "globalDaily", { throws: true }))
  // Conservative: settled turns do NOT replenish this daily cap.
  await enforceAskAIRateLimit(() =>
    askAIRateLimiter.limit(ctx, "globalDailyTokens", {
      count: ASK_AI_CONFIG.limits.reservedTokensPerTurn,
      throws: true,
    }),
  )
  const reservationCreatedAt = Date.now()
  const reservationId = await ctx.db.insert("askAIBudgetReservations", {
    ownerSubject,
    tokens: ASK_AI_CONFIG.limits.reservedTokensPerTurn,
    settled: false,
    createdAt: reservationCreatedAt,
  })
  await adjustAskAICostBucket(ctx, ownerSubject, reservationCreatedAt, 0, ASK_AI_CONFIG.limits.reservedTokensPerTurn)
  return reservationId
}

function askAICostBucketStart(timestamp: number) {
  return Math.floor(timestamp / ASK_AI_COST_BUCKET_MS) * ASK_AI_COST_BUCKET_MS
}

async function ensureAskAIQuotaState(ctx: MutationCtx, ownerSubject: string, now: number) {
  const state = await ctx.db
    .query("askAIQuotaState")
    .withIndex("by_owner", (q) => q.eq("ownerSubject", ownerSubject))
    .unique()
  if (state) return

  const dayStart = now - 24 * 60 * 60 * 1_000
  const [usageRows, reservations, existingBuckets] = await Promise.all([
    ctx.db
      .query("askAIUsage")
      .withIndex("by_owner_created", (q) => q.eq("ownerSubject", ownerSubject).gte("createdAt", dayStart))
      .collect(),
    ctx.db
      .query("askAIBudgetReservations")
      .withIndex("by_owner_created", (q) => q.eq("ownerSubject", ownerSubject).gte("createdAt", dayStart))
      .collect(),
    ctx.db
      .query("askAICostBuckets")
      .withIndex("by_owner_bucket", (q) =>
        q.eq("ownerSubject", ownerSubject).gte("bucketStart", askAICostBucketStart(dayStart)),
      )
      .collect(),
  ])
  const buckets = new Map<number, { usedTokens: number; reservedTokens: number }>()
  const bucketFor = (timestamp: number) => {
    const bucketStart = askAICostBucketStart(timestamp)
    const existing = buckets.get(bucketStart) ?? { usedTokens: 0, reservedTokens: 0 }
    buckets.set(bucketStart, existing)
    return existing
  }
  for (const row of usageRows) bucketFor(row.createdAt).usedTokens += row.totalTokens
  for (const row of reservations) bucketFor(row.createdAt).reservedTokens += row.tokens
  // The ledger is authoritative. Replace any partial pre-initialization buckets
  // atomically rather than adding their totals again or creating duplicate keys.
  for (const row of existingBuckets) await ctx.db.delete(row._id)
  for (const [bucketStart, totals] of buckets) {
    await ctx.db.insert("askAICostBuckets", {
      ownerSubject,
      bucketStart,
      ...totals,
      updatedAt: now,
    })
  }
  await ctx.db.insert("askAIQuotaState", { ownerSubject, initializedAt: now })
}

async function readAskAICostTotals(ctx: AskAICtx, ownerSubject: string, now: number) {
  const state = await ctx.db
    .query("askAIQuotaState")
    .withIndex("by_owner", (q) => q.eq("ownerSubject", ownerSubject))
    .unique()
  if (!state) {
    const dayStart = now - 24 * 60 * 60 * 1_000
    const [usageRows, reservations] = await Promise.all([
      ctx.db
        .query("askAIUsage")
        .withIndex("by_owner_created", (q) => q.eq("ownerSubject", ownerSubject).gte("createdAt", dayStart))
        .collect(),
      ctx.db
        .query("askAIBudgetReservations")
        .withIndex("by_owner_created", (q) => q.eq("ownerSubject", ownerSubject).gte("createdAt", dayStart))
        .collect(),
    ])
    return {
      usedTokens: usageRows.reduce((sum, row) => sum + row.totalTokens, 0),
      reservedTokens: reservations.reduce((sum, row) => sum + row.tokens, 0),
    }
  }
  const buckets = await ctx.db
    .query("askAICostBuckets")
    .withIndex("by_owner_bucket", (q) =>
      q.eq("ownerSubject", ownerSubject).gte("bucketStart", askAICostBucketStart(now - 24 * 60 * 60 * 1_000)),
    )
    .collect()
  return {
    usedTokens: buckets.reduce((sum, row) => sum + row.usedTokens, 0),
    reservedTokens: buckets.reduce((sum, row) => sum + row.reservedTokens, 0),
  }
}

async function adjustAskAICostBucket(
  ctx: MutationCtx,
  ownerSubject: string,
  timestamp: number,
  usedDelta: number,
  reservedDelta: number,
) {
  const bucketStart = askAICostBucketStart(timestamp)
  const existing = await ctx.db
    .query("askAICostBuckets")
    .withIndex("by_owner_bucket", (q) => q.eq("ownerSubject", ownerSubject).eq("bucketStart", bucketStart))
    .unique()
  if (existing) {
    await ctx.db.patch(existing._id, {
      usedTokens: Math.max(0, existing.usedTokens + usedDelta),
      reservedTokens: Math.max(0, existing.reservedTokens + reservedDelta),
      updatedAt: Date.now(),
    })
    return
  }
  await ctx.db.insert("askAICostBuckets", {
    ownerSubject,
    bucketStart,
    usedTokens: Math.max(0, usedDelta),
    reservedTokens: Math.max(0, reservedDelta),
    updatedAt: Date.now(),
  })
}

async function releaseUnstartedReservation(ctx: MutationCtx, reservationId: Id<"askAIBudgetReservations">) {
  const reservation = await ctx.db.get(reservationId)
  if (!reservation || reservation.settled) return
  await ensureAskAIQuotaState(ctx, reservation.ownerSubject, Date.now())
  await ctx.db.patch(reservationId, { tokens: 0, settled: true })
  await adjustAskAICostBucket(ctx, reservation.ownerSubject, reservation.createdAt, 0, -reservation.tokens)
}

async function assertConcurrentGenerationCapacity(ctx: MutationCtx, ownerSubject: string): Promise<void> {
  const [subjectRunning, globalRunning] = await Promise.all([
    ctx.db
      .query("askAITurns")
      .withIndex("by_owner_status_created", (q) => q.eq("ownerSubject", ownerSubject).eq("status", "running"))
      .take(MAX_CONCURRENT_GENERATIONS_PER_SUBJECT + 1),
    ctx.db
      .query("askAITurns")
      .withIndex("by_status_created", (q) => q.eq("status", "running"))
      .take(MAX_CONCURRENT_GENERATIONS_GLOBAL + 1),
  ])
  if (subjectRunning.length >= MAX_CONCURRENT_GENERATIONS_PER_SUBJECT) {
    throw askAIError(
      "ASK_AI_RATE_LIMITED",
      "Ask AI is already generating a response. Wait for it to finish, or cancel it, then try again.",
    )
  }
  if (globalRunning.length >= MAX_CONCURRENT_GENERATIONS_GLOBAL) {
    throw askAIError(
      "ASK_AI_RATE_LIMITED",
      "Ask AI is handling a lot of requests right now. Please wait a moment and try again.",
    )
  }
}

function titleFromPrompt(prompt: string) {
  const compact = prompt
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[?.!]+$/, "")
  if (compact.length <= 44) return compact
  const shortened = compact
    .slice(0, 44)
    .replace(/\s+\S*$/, "")
    .trim()
  return `${shortened || compact.slice(0, 44)}…`
}

async function requireOwnerSubject(ctx: AskAICtx): Promise<string> {
  const identity = await ctx.auth.getUserIdentity()
  if (!identity?.subject) throw new Error("Ask AI session required")
  return identity.subject
}

async function requireOwnedThread(ctx: AskAICtx, threadId: string) {
  const ownerSubject = await requireOwnerSubject(ctx)
  const thread = await ctx.db
    .query("askAIThreads")
    .withIndex("by_thread", (q) => q.eq("threadId", threadId))
    .unique()
  if (!thread || thread.ownerSubject !== ownerSubject) throw new Error("Thread not found")
  return { ownerSubject, thread }
}

export const create = mutation({
  args: {},
  handler: async (ctx) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    const existing = await ctx.db
      .query("askAIThreads")
      .withIndex("by_owner_status_updated", (q) => q.eq("ownerSubject", ownerSubject))
      .take(MAX_THREADS_PER_SUBJECT)
    if (existing.length >= MAX_THREADS_PER_SUBJECT) {
      throw askAIError("ASK_AI_RATE_LIMITED", "Ask AI thread limit reached. Archive and reuse an existing chat.")
    }
    await enforceAskAIRateLimit(() =>
      askAIRateLimiter.limit(ctx, "threadCreatePerSubject", { key: ownerSubject, throws: true }),
    )
    await enforceAskAIRateLimit(() => askAIRateLimiter.limit(ctx, "threadCreateGlobal", { throws: true }))
    const title = "New Chat"
    const threadId = await createThread(ctx, components.agent, { userId: ownerSubject, title })
    const now = Date.now()
    await ctx.db.insert("askAIThreads", {
      threadId,
      ownerSubject,
      title,
      status: "active",
      createdAt: now,
      updatedAt: now,
    })
    return { threadId, title, createdAt: now, updatedAt: now }
  },
})

/** Legacy non-paginated reader retained for older clients, but hard-bounded. */
export const list = query({
  args: { includeArchived: v.optional(v.boolean()) },
  handler: async (ctx, { includeArchived }) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    if (includeArchived) {
      const rows = await ctx.db
        .query("askAIThreads")
        .withIndex("by_owner_status_updated", (q) => q.eq("ownerSubject", ownerSubject))
        .take(500)
      return rows.sort((a, b) => b.updatedAt - a.updatedAt)
    }
    return await ctx.db
      .query("askAIThreads")
      .withIndex("by_owner_status_updated", (q) => q.eq("ownerSubject", ownerSubject).eq("status", "active"))
      .order("desc")
      .take(500)
  },
})

export const listPage = query({
  args: {
    status: v.union(v.literal("active"), v.literal("archived")),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, { status, paginationOpts }) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    return await ctx.db
      .query("askAIThreads")
      .withIndex("by_owner_status_updated", (q) => q.eq("ownerSubject", ownerSubject).eq("status", status))
      .order("desc")
      .paginate(paginationOpts)
  },
})

export const messages = query({
  args: { threadId: v.string(), paginationOpts: paginationOptsValidator, streamArgs: vStreamArgs },
  handler: async (ctx, args) => {
    await requireOwnedThread(ctx, args.threadId)
    // Hot path: re-runs on every (throttled) stream delta, so it must return ONLY the
    // streamed text. Rich parts are written once at turn completion and fetched by the
    // separate `messageParts` query, never re-collected per token.
    const [result, streams] = await Promise.all([
      listUIMessages(ctx, components.agent, args),
      syncStreams(ctx, components.agent, args),
    ])
    return { ...result, streams }
  },
})

/**
 * Cold companion to `messages`: persisted rich assistant parts (cards, retrieval chunks,
 * sources) by messageId. Not stream-subscribed, so it re-runs only when a turn completes.
 */
export const messageParts = query({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    await requireOwnedThread(ctx, threadId)
    const rows = await ctx.db
      .query("askAIMessageParts")
      .withIndex("by_thread", (q) => q.eq("threadId", threadId))
      .order("desc")
      .take(MAX_TURNS_PER_THREAD)
    return rows.map((row) => ({ messageId: row.messageId, parts: row.parts }))
  },
})

export const quota = query({
  args: {},
  handler: async (ctx) => {
    const ownerSubject = await requireOwnerSubject(ctx)
    const current = await askAIRateLimiter.getValue(ctx, "perSubjectDaily", { key: ownerSubject })
    const limit = ASK_AI_CONFIG.limits.messagesPerDay
    const remaining = Math.max(0, Math.min(limit, Math.floor(current.value)))
    const { usedTokens, reservedTokens } = await readAskAICostTotals(ctx, ownerSubject, Date.now())
    const tokensUsed = usedTokens + reservedTokens
    return {
      used: limit - remaining,
      limit,
      resetsAt: current.ts + 24 * 60 * 60 * 1_000,
      tokensUsed,
      tokenLimit: ASK_AI_CONFIG.limits.dailyTokenBudget,
      tokensRemaining: Math.max(0, ASK_AI_CONFIG.limits.dailyTokenBudget - tokensUsed),
    }
  },
})

// Cross-instance guest-mint throttle for the pre-auth /api/ask-ai/session route, so no
// identity is required. `ip` is derived server-side; a forged ip only spends that key's own
// budget and cannot mint a JWT (minting stays in the route), so a public mutation is safe.
export const recordGuestMint = mutation({
  args: { ip: v.string(), secret: v.string() },
  handler: async (ctx, { ip, secret }) => {
    const requiredSecret = process.env.CONVEX_RATE_LIMIT_SECRET
    if (!requiredSecret || !safeEqual(secret, requiredSecret)) {
      throw new Error("UNAUTHORIZED: guest-mint secret required")
    }
    const key = (ip || "unknown").slice(0, 100)
    const result = await askAIRateLimiter.limit(ctx, "guestMintPerIp", { key })
    return { ok: result.ok, retryAfterMs: Math.max(0, Math.ceil(result.retryAfter ?? 0)) }
  },
})

export const enqueueTurn = mutation({
  args: {
    threadId: v.string(),
    prompt: v.string(),
    clientRequestId: v.string(),
  },
  handler: async (ctx, { threadId, prompt, clientRequestId }) => {
    const { ownerSubject, thread } = await requireOwnedThread(ctx, threadId)
    if (thread.status !== "active") throw new Error("Thread is archived")
    const text = prompt.trim()
    const requestId = clientRequestId.trim()
    if (!requestId || requestId.length > 100)
      throw askAIError("ASK_AI_GENERATION_FAILED", "Message request ID is invalid")
    const existing = await ctx.db
      .query("askAITurns")
      .withIndex("by_owner_request", (q) => q.eq("ownerSubject", ownerSubject).eq("clientRequestId", requestId))
      .unique()
    if (existing) {
      if (existing.threadId !== threadId || existing.prompt !== text)
        throw askAIError("ASK_AI_GENERATION_FAILED", "Message request ID was already used")
      return { turnId: existing._id, promptMessageId: existing.promptMessageId, duplicate: true }
    }
    if (!text || text.length > ASK_AI_CONFIG.maxInputCharacters)
      throw askAIError(
        "ASK_AI_GENERATION_FAILED",
        `Message must contain 1 to ${ASK_AI_CONFIG.maxInputCharacters} characters`,
      )
    const [queued, threadTurns] = await Promise.all([
      ctx.db
        .query("askAITurns")
        .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "queued"))
        .take(10),
      ctx.db
        .query("askAITurns")
        .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId))
        .take(MAX_TURNS_PER_THREAD),
    ])
    if (queued.length >= 10) throw askAIError("ASK_AI_RATE_LIMITED", "Ask AI queue is full")
    if (threadTurns.length >= MAX_TURNS_PER_THREAD) {
      throw askAIError("ASK_AI_RATE_LIMITED", "This chat is full. Start a new chat to continue.")
    }
    // Atomic cost gate before any message/turn persistence. Concurrency is enforced at claim
    // time so queued turns can stack safely; burst is enforced on retry only, and enqueue
    // relies on queue depth plus the daily/global/token caps.
    const budgetReservationId = await enforceAskAICostGate(ctx, ownerSubject, {
      enforceBurst: false,
      enforceConcurrent: false,
    })
    const saved = await saveMessage(ctx, components.agent, { threadId, userId: ownerSubject, prompt: text })
    const now = Date.now()
    const wallet = await getAuthedWallet(ctx)
    const turnId = await ctx.db.insert("askAITurns", {
      threadId,
      ownerSubject,
      clientRequestId: requestId,
      budgetReservationId,
      ...(wallet ? { wallet } : {}),
      promptMessageId: saved.messageId,
      prompt: text,
      status: "queued",
      timeoutOutcome: "pending",
      createdAt: now,
      updatedAt: now,
    })
    if (thread.title === "New Chat") await ctx.db.patch(thread._id, { title: titleFromPrompt(text), updatedAt: now })
    await ctx.scheduler.runAfter(0, internal.askAIAgent.generateTurn, { turnId })
    return { turnId, promptMessageId: saved.messageId, duplicate: false }
  },
})

export const claimQueuedTurn = internalMutation({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn || turn.status !== "queued") return null
    if (turn.nextCapacityRetryAt && turn.nextCapacityRetryAt > Date.now()) return null
    const running = await ctx.db
      .query("askAITurns")
      .withIndex("by_thread_status_created", (q) => q.eq("threadId", turn.threadId).eq("status", "running"))
      .first()
    if (running) return null
    const firstQueued = await ctx.db
      .query("askAITurns")
      .withIndex("by_thread_status_created", (q) => q.eq("threadId", turn.threadId).eq("status", "queued"))
      .first()
    if (!firstQueued || firstQueued._id !== turnId) return null
    const thread = await ctx.db
      .query("askAIThreads")
      .withIndex("by_thread", (q) => q.eq("threadId", turn.threadId))
      .unique()
    if (!thread || thread.ownerSubject !== turn.ownerSubject || thread.status !== "active") {
      if (turn.budgetReservationId) await releaseUnstartedReservation(ctx, turn.budgetReservationId)
      await recordTurnOutcome(ctx, turn, "cancelled")
      await ctx.db.patch(turnId, { status: "cancelled", timeoutOutcome: "cancelled", updatedAt: Date.now() })
      return null
    }
    try {
      await assertConcurrentGenerationCapacity(ctx, turn.ownerSubject)
    } catch {
      const attempt = turn.capacityAttempts ?? 0
      const delay = queueRetryDelay(attempt, String(turnId))
      await ctx.db.patch(turnId, { capacityAttempts: attempt + 1, nextCapacityRetryAt: Date.now() + delay })
      await ctx.scheduler.runAfter(delay, internal.askAIAgent.generateTurn, { turnId })
      return null
    }
    await ctx.db.patch(turnId, {
      status: "running",
      capacityAttempts: 0,
      nextCapacityRetryAt: undefined,
      updatedAt: Date.now(),
    })
    await ctx.scheduler.runAfter(ASK_AI_RUNNING_TIMEOUT_MS, internal.askAI.timeoutRunningTurn, { turnId })
    return {
      turnId: turn._id,
      threadId: turn.threadId,
      ownerSubject: turn.ownerSubject,
      promptMessageId: turn.promptMessageId,
      budgetReservationId: turn.budgetReservationId,
      prompt: turn.prompt,
      wallet: turn.wallet,
    }
  },
})

export const timeoutRunningTurn = internalMutation({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn || turn.status !== "running" || Date.now() - turn.updatedAt < ASK_AI_RUNNING_TIMEOUT_MS) return false
    await recordTurnOutcome(ctx, turn, "timed_out")
    await ctx.db.patch(turnId, { status: "failed", timeoutOutcome: "timed_out", updatedAt: Date.now() })
    await discardStrayAssistantMessage(ctx, turn.threadId)
    await scheduleNextQueuedTurn(ctx, turn.threadId)
    return true
  },
})

async function scheduleNextQueuedTurn(ctx: MutationCtx, threadId: string) {
  const next = await ctx.db
    .query("askAITurns")
    .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "queued"))
    .first()
  if (next) await ctx.scheduler.runAfter(0, internal.askAIAgent.generateTurn, { turnId: next._id })
}

export const turnQueue = query({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    await requireOwnedThread(ctx, threadId)
    // MUST scope to this thread via the threadId prefix index: an owner-wide scan on a live
    // subscription let any user's turn write invalidate every open queue.
    const rows = (
      await Promise.all([
        ctx.db
          .query("askAITurns")
          .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "queued"))
          .take(10),
        ctx.db
          .query("askAITurns")
          .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "running"))
          .take(1),
        ctx.db
          .query("askAITurns")
          .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "failed"))
          .order("desc")
          .take(MAX_FAILED_TURNS_IN_QUEUE),
      ])
    ).flat()
    return rows
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((row) => ({
        id: row._id,
        clientRequestId: row.clientRequestId,
        promptMessageId: row.promptMessageId,
        prompt: row.prompt,
        status: row.status,
      }))
  },
})

export const cancelQueuedTurn = mutation({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn) return
    const ownerSubject = await requireOwnerSubject(ctx)
    if (turn.ownerSubject !== ownerSubject) throw new Error("Ask AI turn not found")
    if (turn.status !== "queued") throw new Error("Only queued turns can be cancelled")
    if (turn.budgetReservationId) await releaseUnstartedReservation(ctx, turn.budgetReservationId)
    await recordTurnOutcome(ctx, turn, "cancelled")
    await ctx.db.patch(turnId, { status: "cancelled", timeoutOutcome: "cancelled", updatedAt: Date.now() })
    await scheduleNextQueuedTurn(ctx, turn.threadId)
  },
})

export const retryFailedTurn = mutation({
  args: { turnId: v.id("askAITurns") },
  handler: async (ctx, { turnId }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn) throw new Error("Ask AI turn not found")
    const ownerSubject = await requireOwnerSubject(ctx)
    if (turn.ownerSubject !== ownerSubject || turn.status !== "failed") throw new Error("Ask AI turn cannot be retried")
    // Same atomic cost gate as enqueue/begin — retries must not bypass daily/token/concurrent caps.
    const budgetReservationId = await enforceAskAICostGate(ctx, ownerSubject, {
      enforceBurst: true,
      enforceConcurrent: true,
    })
    await ctx.db.patch(turnId, {
      status: "queued",
      timeoutOutcome: "pending",
      budgetReservationId,
      updatedAt: Date.now(),
    })
    await ctx.scheduler.runAfter(0, internal.askAIAgent.generateTurn, { turnId })
  },
})

export const cancelRunningTurn = mutation({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    const { ownerSubject } = await requireOwnedThread(ctx, threadId)
    const running = await ctx.db
      .query("askAITurns")
      .withIndex("by_thread_status_created", (q) => q.eq("threadId", threadId).eq("status", "running"))
      .first()
    if (!running || running.ownerSubject !== ownerSubject) return false
    const streams = await listStreams(ctx, components.agent, { threadId, includeStatuses: ["streaming"] })
    await Promise.all(
      streams.map((stream) =>
        abortStream(ctx, components.agent, { streamId: stream.streamId, reason: "Cancelled by user" }),
      ),
    )
    await recordTurnOutcome(ctx, running, "cancelled")
    await ctx.db.patch(running._id, { status: "cancelled", timeoutOutcome: "cancelled", updatedAt: Date.now() })
    await scheduleNextQueuedTurn(ctx, threadId)
    return true
  },
})

export const completeGeneratedTurn = internalMutation({
  args: {
    turnId: v.id("askAITurns"),
    assistantMessageId: v.string(),
    budgetReservationId: v.optional(v.id("askAIBudgetReservations")),
    model: v.string(),
    usage: v.object({ inputTokens: v.number(), outputTokens: v.number(), totalTokens: v.number() }),
    // Explicit shape so the rich parts the UI renders are validated at the trust boundary.
    richParts: v.optional(
      v.object({
        sources: v.optional(
          v.array(
            v.object({
              domain: v.string(),
              title: v.string(),
              locator: v.string(),
              url: v.optional(v.string()),
              kind: v.optional(v.string()),
              version: v.optional(v.string()),
            }),
          ),
        ),
        usage: v.optional(v.object({ inputTokens: v.number(), outputTokens: v.number(), totalTokens: v.number() })),
        financialResults: v.optional(
          v.array(
            v.object({
              kind: v.union(
                v.literal("portfolio"),
                v.literal("market"),
                v.literal("pool"),
                v.literal("borrow_capacity"),
                v.literal("position_risk"),
                v.literal("engine_snapshot"),
                v.literal("simulate_borrow"),
                v.literal("stress_position"),
                v.literal("aave_reserve"),
                v.literal("aave_emode"),
                v.literal("aave_positions"),
                v.literal("aave_rewards"),
                v.literal("aave_preview"),
                v.literal("aave_governance"),
                v.literal("aave_hubs"),
              ),
              // Supplied by Lane D on the tool result; optional until it ships.
              dataProvenance: v.optional(
                v.union(v.literal("sandbox"), v.literal("connected_wallet"), v.literal("onchain")),
              ),
              // The tool's structured result verbatim; genuinely arbitrary shape.
              payload: v.any(),
            }),
          ),
        ),
        retrievalChunks: v.optional(
          v.array(
            v.object({
              title: v.string(),
              locator: v.string(),
              text: v.string(),
              score: v.optional(v.number()),
            }),
          ),
        ),
        visual: v.optional(
          v.object({
            label: v.string(),
            value: v.string(),
            delta: v.optional(v.string()),
            points: v.array(v.number()),
            kind: v.optional(v.literal("aave_apy")),
            timestamps: v.optional(v.array(v.number())),
            side: v.optional(v.union(v.literal("supply"), v.literal("borrow"))),
            window: v.optional(v.string()),
            asOf: v.optional(v.number()),
          }),
        ),
        // Deterministic mode-run (Risk / Stress / Returns), stored structurally like
        // financialResults.payload. Only written when the mode-runs flag is on.
        modeRun: v.optional(v.any()),
      }),
    ),
  },
  handler: async (ctx, { turnId, assistantMessageId, budgetReservationId, model, usage, richParts }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn) throw new Error("Ask AI turn not found")
    const thread = await ctx.db
      .query("askAIThreads")
      .withIndex("by_thread", (q) => q.eq("threadId", turn.threadId))
      .unique()
    if (!thread || thread.ownerSubject !== turn.ownerSubject) throw new Error("Ask AI turn not found")
    // Cancelled while the stream was finishing: cancelRunningTurn already set the terminal
    // status, so never resurrect it as a completed answer. Mirrors the guard in failTurn.
    if (turn.status !== "running" || (budgetReservationId && turn.budgetReservationId !== budgetReservationId)) return
    const existingParts = await ctx.db
      .query("askAIMessageParts")
      .withIndex("by_message", (q) => q.eq("messageId", assistantMessageId))
      .unique()
    if (richParts && !existingParts)
      await ctx.db.insert("askAIMessageParts", {
        threadId: turn.threadId,
        messageId: assistantMessageId,
        parts: richParts,
        createdAt: Date.now(),
      })
    const existingUsage = await ctx.db
      .query("askAIUsage")
      .withIndex("by_message", (q) => q.eq("messageId", assistantMessageId))
      .unique()
    if (!existingUsage && !turn.budgetReservationId) {
      await ensureAskAIQuotaState(ctx, turn.ownerSubject, Date.now())
      await ctx.db.insert("askAIUsage", {
        ownerSubject: turn.ownerSubject,
        threadId: turn.threadId,
        messageId: assistantMessageId,
        model,
        provider: "openai",
        ...usage,
        createdAt: Date.now(),
      })
      await adjustAskAICostBucket(ctx, turn.ownerSubject, Date.now(), usage.totalTokens, 0)
    }
    const now = Date.now()
    await recordTurnOutcome(ctx, turn, "completed")
    await ctx.db.patch(turn._id, { status: "complete", timeoutOutcome: "completed", updatedAt: now })
    await ctx.db.patch(thread._id, { updatedAt: now })
    await scheduleNextQueuedTurn(ctx, turn.threadId)
  },
})

// A failed turn can leave saveStreamDeltas' partial/empty assistant message persisted, which
// the list query would return as a normal answer (Copy / feedback controls beside an error
// card). Remove any assistant message that never settled or has no visible text.
async function discardStrayAssistantMessage(ctx: MutationCtx, threadId: string) {
  const { page } = await listMessages(ctx, components.agent, {
    threadId,
    excludeToolMessages: true,
    paginationOpts: { cursor: null, numItems: 20 },
  })
  const stale: GenericId<"messages">[] = []
  for (const message of page) {
    if (message.message?.role !== "assistant") continue
    const settled = message.status === "success" && (message.text ?? "").trim().length > 0
    if (!settled) stale.push(message._id as GenericId<"messages">)
  }
  if (stale.length > 0) await ctx.runMutation(components.agent.messages.deleteByIds, { messageIds: stale })
}

export const failTurn = internalMutation({
  args: { turnId: v.id("askAITurns"), budgetReservationId: v.optional(v.id("askAIBudgetReservations")) },
  handler: async (ctx, { turnId, budgetReservationId }) => {
    const turn = await ctx.db.get(turnId)
    if (!turn) return
    if (turn.status !== "running" || (budgetReservationId && turn.budgetReservationId !== budgetReservationId)) return
    await recordTurnOutcome(ctx, turn, "failed")
    await ctx.db.patch(turn._id, { status: "failed", timeoutOutcome: "failed", updatedAt: Date.now() })
    await discardStrayAssistantMessage(ctx, turn.threadId)
    await scheduleNextQueuedTurn(ctx, turn.threadId)
  },
})

const FEEDBACK_CATEGORIES = [
  "Helpful",
  "Incorrect",
  "Outdated data",
  "Not helpful",
  "Missing context",
  "Unsafe",
  "Other",
]

export const submitFeedback = mutation({
  args: { threadId: v.string(), messageId: v.string(), categories: v.array(v.string()), note: v.optional(v.string()) },
  handler: async (ctx, { threadId, messageId, categories, note }) => {
    const { ownerSubject } = await requireOwnedThread(ctx, threadId)
    const messageParts = await ctx.db
      .query("askAIMessageParts")
      .withIndex("by_message", (q) => q.eq("messageId", messageId))
      .unique()
    if (!messageParts || messageParts.threadId !== threadId) throw new Error("Assistant message not found")
    const cleanCategories = [...new Set(categories)].filter((category) => FEEDBACK_CATEGORIES.includes(category))
    const cleanNote = note?.trim().slice(0, 1_000) || undefined
    if (cleanCategories.length === 0 && !cleanNote) throw new Error("Choose a reason or add a note")
    const existing = await ctx.db
      .query("askAIFeedback")
      .withIndex("by_owner_message", (q) => q.eq("ownerSubject", ownerSubject).eq("messageId", messageId))
      .unique()
    const now = Date.now()
    if (existing) {
      await ctx.db.patch(existing._id, { categories: cleanCategories, note: cleanNote, updatedAt: now })
      return existing._id
    }
    return await ctx.db.insert("askAIFeedback", {
      ownerSubject,
      threadId,
      messageId,
      categories: cleanCategories,
      note: cleanNote,
      createdAt: now,
      updatedAt: now,
    })
  },
})

export const feedbackReport = internalQuery({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const rows = await ctx.db
      .query("askAIFeedback")
      .withIndex("by_created_at")
      .order("desc")
      .take(Math.min(limit ?? 100, 500))
    const categories = Object.fromEntries(FEEDBACK_CATEGORIES.map((category) => [category, 0]))
    const daily: Record<string, number> = {}
    for (const row of rows)
      for (const category of row.categories) categories[category] = (categories[category] ?? 0) + 1
    for (const row of rows) {
      const day = new Date(row.createdAt).toISOString().slice(0, 10)
      daily[day] = (daily[day] ?? 0) + 1
    }
    const enrichedRows = await Promise.all(
      rows.map(async (row) => {
        const [thread, usage] = await Promise.all([
          ctx.db
            .query("askAIThreads")
            .withIndex("by_thread", (q) => q.eq("threadId", row.threadId))
            .unique(),
          ctx.db
            .query("askAIUsage")
            .withIndex("by_message", (q) => q.eq("messageId", row.messageId))
            .unique(),
        ])
        return {
          ...row,
          threadTitle: thread?.title ?? "Deleted thread",
          model: usage?.model,
          provider: usage?.provider,
          totalTokens: usage?.totalTokens,
        }
      }),
    )
    return { total: rows.length, categories, daily, rows: enrichedRows }
  },
})

export const archive = mutation({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    const { thread } = await requireOwnedThread(ctx, threadId)
    await ctx.db.patch(thread._id, { status: "archived", updatedAt: Date.now() })
  },
})

function cleanThreadTitle(value: string) {
  const title = value
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  if (!title || title.length > 80) throw new Error("Thread title must contain 1 to 80 characters")
  return title
}

export const rename = mutation({
  args: { threadId: v.string(), title: v.string() },
  handler: async (ctx, { threadId, title }) => {
    const { thread } = await requireOwnedThread(ctx, threadId)
    const nextTitle = cleanThreadTitle(title)
    await ctx.db.patch(thread._id, { title: nextTitle, updatedAt: Date.now() })
    return { threadId, title: nextTitle }
  },
})

export const unarchive = mutation({
  args: { threadId: v.string() },
  handler: async (ctx, { threadId }) => {
    const { thread } = await requireOwnedThread(ctx, threadId)
    await ctx.db.patch(thread._id, { status: "active", updatedAt: Date.now() })
  },
})

/** Settle the specific attempt, even when its turn was cancelled or retried. */
export const settleBudgetReservation = internalMutation({
  args: {
    reservationId: v.id("askAIBudgetReservations"),
    threadId: v.string(),
    model: v.string(),
    complete: v.boolean(),
    usage: v.object({ inputTokens: v.number(), outputTokens: v.number(), totalTokens: v.number() }),
  },
  handler: async (ctx, { reservationId, threadId, model, complete, usage }) => {
    const reservation = await ctx.db.get(reservationId)
    if (!reservation || reservation.settled) return
    if (Object.values(usage).some((value) => !Number.isSafeInteger(value) || value < 0))
      throw Error("Invalid token usage")
    await ensureAskAIQuotaState(ctx, reservation.ownerSubject, Date.now())
    await ctx.db.insert("askAIUsage", {
      ownerSubject: reservation.ownerSubject,
      threadId,
      messageId: String(reservationId),
      model,
      provider: "openai",
      ...usage,
      createdAt: reservation.createdAt,
    })
    // A failed stream can omit the final provider usage; keep the allocation charged.
    const remainingReserved = complete ? 0 : Math.max(0, reservation.tokens - usage.totalTokens)
    await ctx.db.patch(reservationId, {
      tokens: remainingReserved,
      settled: true,
    })
    await adjustAskAICostBucket(
      ctx,
      reservation.ownerSubject,
      reservation.createdAt,
      usage.totalTokens,
      remainingReserved - reservation.tokens,
    )
  },
})
