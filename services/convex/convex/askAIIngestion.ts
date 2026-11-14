// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { AaveMcpError } from "./lib/askAI/aaveMcp"
import { makeFunctionReference } from "convex/server"
import { v } from "convex/values"
import { createAskAIProviders } from "./lib/askAI/providers/registry"
import type { ActiveAskAIMarketSource, AskAIMarketRecord } from "./lib/askAI/providers/contracts"
import { internal } from "./_generated/api"
import { internalAction, internalMutation, internalQuery } from "./_generated/server"

type UpsertResult = { inserted: number; updated: number; unchanged: number }

// Explicit shape so `ingest`'s handler carries an annotated return type. Its body
// calls sibling functions through `internal.askAIIngestion.*`, which includes
// `ingest` itself — without this annotation TypeScript infers the type through
// that cycle, falls back to `any`, and the `any` cascades across every module
// that reads the generated `internal`/`api` types.
type IngestProviderResult =
  | { source: ActiveAskAIMarketSource; status: "deferred"; records: number; retryAt: number }
  | ({ source: ActiveAskAIMarketSource; status: "success"; records: number } & UpsertResult)
  | { source: ActiveAskAIMarketSource; status: "failed"; records: number; error: string }

const upsertRecords = makeFunctionReference<"mutation", { records: AskAIMarketRecord[] }, UpsertResult>(
  "askAIIngestion:upsertRecordsMutation",
)

const sourceValidator = v.union(v.literal("coingecko"), v.literal("defillama"), v.literal("aave"))
const activeSourceValidator = v.union(v.literal("defillama"), v.literal("aave"))

// Keep each upsert transaction bounded so a large provider batch (DefiLlama can
// return hundreds of pools) does not push one mutation toward Convex's per-txn
// limits or hold a long OCC window.
const UPSERT_CHUNK_SIZE = 100

export const ingest = internalAction({
  args: { source: v.optional(activeSourceValidator) },
  handler: async (ctx, { source }): Promise<{ providers: IngestProviderResult[] }> => {
    const providers = createAskAIProviders().filter((provider) => !source || provider.source === source)
    const results = []
    for (const provider of providers) {
      const retryAt: number | null = await ctx.runQuery(internal.askAIIngestion.providerCooldown, {
        source: provider.source,
      })
      if (retryAt && retryAt > Date.now()) {
        results.push({ source: provider.source, status: "deferred" as const, records: 0, retryAt })
        continue
      }
      const startedAt = Date.now()
      try {
        const records = await provider.fetch()
        const written: UpsertResult = { inserted: 0, updated: 0, unchanged: 0 }
        for (let i = 0; i < records.length; i += UPSERT_CHUNK_SIZE) {
          const batch = records.slice(i, i + UPSERT_CHUNK_SIZE)
          const result = await ctx.runMutation(upsertRecords, { records: batch })
          written.inserted += result.inserted
          written.updated += result.updated
          written.unchanged += result.unchanged
        }
        await ctx.runMutation(internal.askAIIngestion.recordProviderRun, {
          source: provider.source,
          status: "success",
          records: records.length,
          ...written,
          startedAt,
          completedAt: Date.now(),
        })
        results.push({ source: provider.source, status: "success" as const, records: records.length, ...written })
      } catch (error) {
        const message = error instanceof Error ? error.message.slice(0, 500) : "Unknown provider failure"
        await ctx.runMutation(internal.askAIIngestion.recordProviderRun, {
          source: provider.source,
          status: "failed",
          records: 0,
          inserted: 0,
          updated: 0,
          unchanged: 0,
          error: message,
          ...(error instanceof AaveMcpError
            ? { httpStatus: error.status, retryAt: Date.now() + error.retryAfterMs }
            : {}),
          startedAt,
          completedAt: Date.now(),
        })
        results.push({ source: provider.source, status: "failed" as const, records: 0, error: message })
      }
    }
    return { providers: results }
  },
})

export const providerCooldown = internalQuery({
  args: { source: activeSourceValidator },
  handler: async (ctx, { source }) => {
    const state = await ctx.db
      .query("askAIMarketProviderState")
      .withIndex("by_source", (q) => q.eq("source", source))
      .unique()
    return state?.retryAt ?? null
  },
})

// Production still contains legacy provider snapshots. Keep cleanup deployable
// while the schema accepts those rows; only narrow the schema after an operator
// has run this action and independently verified that every legacy count is zero.
const LEGACY_MARKET_SOURCES = ["uniswap", "curve", "balancer"] as const

export const deleteLegacyMarketSnapshotBatch = internalMutation({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const budget = Math.min(Math.max(Math.trunc(limit ?? 500), 1), 1_000)
    let deleted = 0
    for (const source of LEGACY_MARKET_SOURCES) {
      if (deleted >= budget) break
      const rows = await ctx.db
        .query("askAIMarketSnapshots")
        .withIndex("by_source_kind_key", (q) => q.eq("source", source))
        .take(budget - deleted)
      for (const row of rows) {
        await ctx.db.delete(row._id)
        deleted += 1
      }
    }
    return { deleted }
  },
})

export const purgeLegacyMarketSnapshots = internalAction({
  args: {},
  handler: async (ctx) => {
    let deleted = 0
    for (;;) {
      const batch = await ctx.runMutation(internal.askAIIngestion.deleteLegacyMarketSnapshotBatch, {})
      deleted += batch.deleted
      if (batch.deleted === 0) return { deleted }
    }
  },
})

/** Operator-triggered, bounded cleanup for the legacy append-only provider run log. */
export const deleteProviderRunBatch = internalMutation({
  args: { limit: v.optional(v.number()) },
  handler: async (ctx, { limit }) => {
    const budget = Math.min(Math.max(Math.trunc(limit ?? 500), 1), 1_000)
    const rows = await ctx.db.query("askAIMarketProviderRuns").order("asc").take(budget)
    for (const row of rows) await ctx.db.delete(row._id)
    return { deleted: rows.length, hasMore: rows.length === budget }
  },
})

// Per-source ingestion health from one bounded state row per active provider.
export const providerHealth = internalQuery({
  args: {},
  handler: async (ctx) => {
    const sources = ["defillama", "aave"] as const
    const now = Date.now()
    const providers = await Promise.all(
      sources.map(async (source) => {
        const latest = await ctx.db
          .query("askAIMarketProviderState")
          .withIndex("by_source", (q) => q.eq("source", source))
          .unique()
        return {
          source,
          lastStatus: latest?.status ?? null,
          lastRecords: latest?.records ?? 0,
          lastCompletedAt: latest?.completedAt ?? null,
          ageMs: latest ? now - latest.completedAt : null,
          lastError: latest?.error ?? null,
          httpStatus: latest?.httpStatus ?? null,
          retryAt: latest?.retryAt ?? null,
          inserted: latest?.inserted ?? 0,
          updated: latest?.updated ?? 0,
          unchanged: latest?.unchanged ?? 0,
          lastChangedAt: latest?.lastChangedAt ?? null,
        }
      }),
    )
    return { providers }
  },
})

export const recordProviderRun = internalMutation({
  args: {
    source: activeSourceValidator,
    status: v.union(v.literal("success"), v.literal("failed")),
    records: v.number(),
    inserted: v.number(),
    updated: v.number(),
    unchanged: v.number(),
    error: v.optional(v.string()),
    httpStatus: v.optional(v.number()),
    retryAt: v.optional(v.number()),
    startedAt: v.number(),
    completedAt: v.number(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("askAIMarketProviderState")
      .withIndex("by_source", (q) => q.eq("source", args.source))
      .unique()
    const changed = args.inserted + args.updated > 0
    const state = {
      ...args,
      lastCheckedAt: args.completedAt,
      lastChangedAt: changed ? args.completedAt : existing?.lastChangedAt,
      lastSuccessAt: args.status === "success" ? args.completedAt : existing?.lastSuccessAt,
      lastFailureAt: args.status === "failed" ? args.completedAt : existing?.lastFailureAt,
    }
    if (existing) {
      await ctx.db.replace(existing._id, state)
      return existing._id
    }
    return ctx.db.insert("askAIMarketProviderState", state)
  },
})

function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "undefined"
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`

  const record = value as Record<string, unknown>
  return `{${Object.keys(record)
    .filter((key) => record[key] !== undefined)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`)
    .join(",")}}`
}

/** Deterministic non-cryptographic fingerprint used only to avoid no-op database patches. */
function contentHash(record: AskAIMarketRecord): string {
  const input = stableStringify({
    source: record.source,
    kind: record.kind,
    key: record.key,
    payload: record.payload,
    sourceUpdatedAt: record.sourceUpdatedAt,
  })
  let left = 0x811c9dc5
  let right = 0x9e3779b9
  for (let index = 0; index < input.length; index += 1) {
    const code = input.charCodeAt(index)
    left = Math.imul(left ^ code, 0x01000193)
    right = Math.imul(right ^ code, 0x85ebca6b)
  }
  return `${(left >>> 0).toString(16).padStart(8, "0")}${(right >>> 0).toString(16).padStart(8, "0")}`
}

export const upsertRecordsMutation = internalMutation({
  args: {
    records: v.array(
      v.object({
        source: sourceValidator,
        kind: v.union(v.literal("token_price"), v.literal("dex_pool"), v.literal("lending_market")),
        key: v.string(),
        payload: v.any(),
        sourceUpdatedAt: v.optional(v.number()),
        fetchedAt: v.number(),
      }),
    ),
  },
  handler: async (ctx, { records }) => {
    const result: UpsertResult = { inserted: 0, updated: 0, unchanged: 0 }
    for (const record of records) {
      const hash = contentHash(record)
      const existing = await ctx.db
        .query("askAIMarketSnapshots")
        .withIndex("by_source_kind_key", (q) =>
          q.eq("source", record.source).eq("kind", record.kind).eq("key", record.key),
        )
        .unique()
      if (!existing) {
        await ctx.db.insert("askAIMarketSnapshots", { ...record, contentHash: hash })
        result.inserted += 1
      } else if (existing.contentHash !== hash) {
        await ctx.db.patch(existing._id, { ...record, contentHash: hash })
        result.updated += 1
      } else {
        result.unchanged += 1
      }
    }
    return result
  },
})
