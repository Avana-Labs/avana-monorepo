import { codedError } from "../codedError"
import { v } from "convex/values"
import { internalMutation, mutation, query } from "../_generated/server"
import { getAuthedWallet, getAuthSubject } from "../sandbox/auth"

const preferencesValidator = v.object({
  theme: v.optional(v.union(v.literal("light"), v.literal("dark"), v.literal("system"))),
  language: v.optional(v.string()),
  currency: v.optional(v.string()),
  showDollarAmounts: v.optional(v.boolean()),
  name: v.optional(v.string()),
  dexSources: v.optional(v.array(v.string())),
})

type Preferences = {
  theme?: "light" | "dark" | "system"
  language?: string
  currency?: string
  showDollarAmounts?: boolean
  name?: string
  dexSources?: string[]
}

function sanitizePreferences(preferences: Preferences): Preferences {
  const sanitized = { ...preferences }

  if (typeof sanitized.name === "string") {
    const name = sanitized.name.trim().slice(0, 10)
    if (name) sanitized.name = name
    else delete sanitized.name
  }
  if (typeof sanitized.language === "string") {
    const language = sanitized.language.trim().slice(0, 12)
    if (language) sanitized.language = language
    else delete sanitized.language
  }
  if (typeof sanitized.currency === "string") {
    const currency = sanitized.currency.trim().slice(0, 12)
    if (currency) sanitized.currency = currency
    else delete sanitized.currency
  }
  if (sanitized.dexSources) {
    sanitized.dexSources = sanitized.dexSources
      .map((source) => source.trim().slice(0, 40))
      .filter(Boolean)
      .slice(0, 24)
  }

  return sanitized
}

export const getMine = query({
  args: {},
  handler: async (ctx) => {
    const wallet = await getAuthedWallet(ctx)
    if (!wallet) throw codedError("UNAUTHENTICATED: connect a wallet and sign in to read your profile.")
    return ctx.db
      .query("walletProfiles")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
      .unique()
  },
})

export const savePreferences = mutation({
  args: { preferences: preferencesValidator },
  handler: async (ctx, args) => {
    const wallet = await getAuthedWallet(ctx)
    if (!wallet) throw codedError("UNAUTHENTICATED: connect a wallet and sign in to update your profile.")

    const [existing, authSubject] = await Promise.all([
      ctx.db
        .query("walletProfiles")
        .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
        .unique(),
      getAuthSubject(ctx),
    ])
    const now = Date.now()
    const incoming = sanitizePreferences(args.preferences)

    if (existing) {
      await ctx.db.patch(existing._id, {
        authSubject: existing.authSubject ?? authSubject ?? undefined,
        preferences: { ...existing.preferences, ...incoming },
        updatedAt: now,
      })
      return "updated" as const
    }

    await ctx.db.insert("walletProfiles", {
      wallet,
      authSubject: authSubject ?? undefined,
      preferences: incoming,
      createdAt: now,
      updatedAt: now,
    })
    return "created" as const
  },
})

/**
 * Idempotent release migration from the temporary Sandbox profile.
 * Existing walletProfiles win, so a newer permanent profile is never overwritten.
 * This mutation is intentionally not scheduled or invoked by application code.
 */
export const migrateSandboxProfiles = internalMutation({
  args: {
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const page = await ctx.db
      .query("sandboxProfiles")
      .paginate({ cursor: args.cursor ?? null, numItems: Math.min(Math.max(args.batchSize ?? 200, 1), 500) })
    let migrated = 0
    let skippedEmpty = 0
    let skippedExisting = 0

    for (const source of page.page) {
      if (!source.preferences && !source.authSubject) {
        skippedEmpty++
        continue
      }
      const existing = await ctx.db
        .query("walletProfiles")
        .withIndex("by_wallet", (q) => q.eq("wallet", source.wallet))
        .unique()
      if (existing) {
        skippedExisting++
        continue
      }
      const now = Date.now()
      await ctx.db.insert("walletProfiles", {
        wallet: source.wallet,
        authSubject: source.authSubject,
        preferences: source.preferences,
        createdAt: source.createdAt,
        updatedAt: now,
      })
      migrated++
    }

    return {
      scanned: page.page.length,
      migrated,
      skippedEmpty,
      skippedExisting,
      isDone: page.isDone,
      continueCursor: page.continueCursor,
    }
  },
})
