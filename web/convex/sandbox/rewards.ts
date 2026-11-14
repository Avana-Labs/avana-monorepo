import { codedError } from "../codedError"
import { v } from "convex/values"
import { mutation, query } from "../_generated/server"
import { requireSandboxWallet } from "./auth"
import { requireSandboxWalletForWrite } from "../writeRateLimit"
import { deriveClaimAmountUsd } from "./rewards_catalog"

const MAX_REWARD_EVENTS = 10_000
const MAX_REWARD_CLAIMS = 64
const MAX_REWARD_TEXT = 200

type JsonRecord = Record<string, unknown>

function isRecord(value: unknown): value is JsonRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function boundedText(value: unknown) {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_REWARD_TEXT
}

function parseRewardsState(stateJson: string, wallet: string) {
  let parsed: unknown
  try {
    parsed = JSON.parse(stateJson)
  } catch {
    throw codedError("INVALID_REWARDS_STATE")
  }
  if (!isRecord(parsed) || !Array.isArray(parsed.events) || !Array.isArray(parsed.claims)) {
    throw codedError("INVALID_REWARDS_STATE")
  }
  if (parsed.events.length > MAX_REWARD_EVENTS || parsed.claims.length > MAX_REWARD_CLAIMS) {
    throw codedError("REWARDS_STATE_TOO_LARGE")
  }
  for (const event of parsed.events) {
    if (
      !isRecord(event) ||
      !boundedText(event.id) ||
      !boundedText(event.type) ||
      !boundedText(event.product) ||
      typeof event.wallet !== "string" ||
      event.wallet.toLowerCase() !== wallet ||
      typeof event.timestamp !== "number" ||
      !Number.isFinite(event.timestamp)
    ) {
      throw codedError("INVALID_REWARDS_STATE")
    }
    if (event.amountUsd !== undefined && (typeof event.amountUsd !== "number" || !Number.isFinite(event.amountUsd))) {
      throw codedError("INVALID_REWARDS_STATE")
    }
    for (const field of [event.marketId, event.referredWallet]) {
      if (field !== undefined && !boundedText(field)) throw codedError("INVALID_REWARDS_STATE")
    }
  }
  for (const claim of parsed.claims) {
    if (
      !isRecord(claim) ||
      !boundedText(claim.claimId) ||
      !boundedText(claim.taskId) ||
      !boundedText(claim.syntheticTxHash) ||
      typeof claim.wallet !== "string" ||
      claim.wallet.toLowerCase() !== wallet ||
      claim.rewardSymbol !== "AVA" ||
      claim.status !== "confirmed" ||
      typeof claim.amount !== "number" ||
      !Number.isFinite(claim.amount) ||
      claim.amount !== deriveClaimAmountUsd([claim.taskId as string]) ||
      typeof claim.claimedAt !== "number" ||
      !Number.isFinite(claim.claimedAt)
    ) {
      throw codedError("INVALID_REWARDS_STATE")
    }
  }
  return parsed as JsonRecord & { events: JsonRecord[]; claims: JsonRecord[] }
}

export const getState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWallet(ctx, args.wallet)
    return ctx.db
      .query("sandboxRewards")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .unique()
  },
})

export const saveState = mutation({
  args: {
    wallet: v.string(),
    stateJson: v.string(),
    expectedRevision: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const wallet = await requireSandboxWalletForWrite(ctx, args.wallet)
    if (args.stateJson.length > 1_000_000) throw codedError("REWARDS_STATE_TOO_LARGE")
    const parsed = parseRewardsState(args.stateJson, wallet)
    const existing = await ctx.db
      .query("sandboxRewards")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .unique()
    // Claims already in the stored row were checked against a successful rewards
    // transaction by the write that first persisted them, so re-checking them re-reads up
    // to 500 transaction rows on EVERY save. That scan is the dominant database-I/O cost
    // of this mutation (~458 MB across ~38k calls, ~12 KB each) and it re-proves something
    // already proven, so only the delta is verified. A stored row we cannot parse proves
    // nothing, so it falls back to verifying every incoming claim.
    let alreadyPersisted = new Set<string>()
    if (existing) {
      try {
        alreadyPersisted = new Set(
          parseRewardsState(existing.stateJson, wallet).claims.map((claim) => claim.taskId as string),
        )
      } catch {
        // Leave the set empty — every incoming claim is verified below.
      }
    }
    const unverifiedClaims = parsed.claims.filter((claim) => !alreadyPersisted.has(claim.taskId as string))
    if (unverifiedClaims.length > 0) {
      const authorizedClaims = new Set<string>()
      const rewardTransactions = await ctx.db
        .query("transactions")
        .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet))
        .order("desc")
        .take(500)
      for (const transaction of rewardTransactions) {
        if (transaction.product !== "rewards" || transaction.status !== "success") continue
        for (const taskId of transaction.claimedTaskIds ?? []) authorizedClaims.add(taskId)
      }
      for (const claim of unverifiedClaims) {
        if (!authorizedClaims.has(claim.taskId as string)) throw codedError("UNAUTHORIZED_REWARD_CLAIM")
      }
    }
    const updatedAt = Date.now()
    if (existing) {
      const currentRevision = existing.revision ?? 0
      if (args.expectedRevision == null) {
        throw codedError("REVISION_REQUIRED: rewards state already exists; reload it and submit its expectedRevision.")
      }
      if (args.expectedRevision !== currentRevision) {
        return { id: existing._id, revision: currentRevision, stale: true }
      }
      const revision = currentRevision + 1
      await ctx.db.patch(existing._id, { stateJson: args.stateJson, updatedAt, revision })
      return { id: existing._id, revision, stale: false }
    }
    const id = await ctx.db.insert("sandboxRewards", {
      wallet,
      stateJson: args.stateJson,
      updatedAt,
      revision: 0,
    })
    return { id, revision: 0, stale: false }
  },
})
