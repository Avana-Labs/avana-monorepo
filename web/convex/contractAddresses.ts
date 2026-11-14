/**
 * Contract-address lookups for pool / asset / lend / multiply detail pages. Seeded
 * with FNV-hashed synthetic 0x… strings (`contractAddressFor`) for the About
 * salts vault / token / riskManager / oracleRouter (`isSynthetic: true` today);
 * an Etherscan sync flips them to real addresses later with `isSynthetic: false`
 * and no UI change.
 *
 * Split by scope but co-located here so the seed writer can populate all tables
 * from a single import path.
 */

import { v } from "convex/values"
import type { QueryCtx } from "./_generated/server"
import { internalMutation, query } from "./_generated/server"

const baseFields = {
  salt: v.string(),
  address: v.string(),
  label: v.string(),
  href: v.string(),
  chain: v.string(),
  isSynthetic: v.boolean(),
}

const poolAddressRow = v.object({ poolSlug: v.string(), ...baseFields })
const assetAddressRow = v.object({ assetSlug: v.string(), ...baseFields })
const marketAddressRow = v.object({ marketSlug: v.string(), ...baseFields })

const stripMeta = <T extends { _id: unknown; _creationTime: unknown; updatedAt: unknown }>(row: T) => {
  const { _id: _mid, _creationTime: _mct, updatedAt: _mua, ...rest } = row
  return rest
}

// -----------------------------------------------------------------------------
// Pool
// -----------------------------------------------------------------------------

export async function readPoolAddresses(ctx: QueryCtx, poolSlug: string) {
  const rows = await ctx.db
    .query("poolContractAddresses")
    .withIndex("by_pool", (q) => q.eq("poolSlug", poolSlug))
    .collect()
  return rows.map(stripMeta)
}

export const listPoolAddresses = query({
  args: { poolSlug: v.string() },
  handler: async (ctx, { poolSlug }) => readPoolAddresses(ctx, poolSlug),
})

export const upsertPoolAddresses = internalMutation({
  args: { rows: v.array(poolAddressRow) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("poolContractAddresses")
        .withIndex("by_pool_salt", (q) => q.eq("poolSlug", row.poolSlug).eq("salt", row.salt))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("poolContractAddresses", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})

// -----------------------------------------------------------------------------
// Asset
// -----------------------------------------------------------------------------

export async function readAssetAddresses(ctx: QueryCtx, assetSlug: string) {
  const rows = await ctx.db
    .query("assetContractAddresses")
    .withIndex("by_asset", (q) => q.eq("assetSlug", assetSlug))
    .collect()
  return rows.map(stripMeta)
}

export const listAssetAddresses = query({
  args: { assetSlug: v.string() },
  handler: async (ctx, { assetSlug }) => readAssetAddresses(ctx, assetSlug),
})

export const upsertAssetAddresses = internalMutation({
  args: { rows: v.array(assetAddressRow) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("assetContractAddresses")
        .withIndex("by_asset_salt", (q) => q.eq("assetSlug", row.assetSlug).eq("salt", row.salt))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("assetContractAddresses", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})

// -----------------------------------------------------------------------------
// Multiply market
// -----------------------------------------------------------------------------

export async function readMultiplyAddresses(ctx: QueryCtx, marketSlug: string) {
  const rows = await ctx.db
    .query("multiplyContractAddresses")
    .withIndex("by_market", (q) => q.eq("marketSlug", marketSlug))
    .collect()
  return rows.map(stripMeta)
}

export const listMultiplyAddresses = query({
  args: { marketSlug: v.string() },
  handler: async (ctx, { marketSlug }) => readMultiplyAddresses(ctx, marketSlug),
})

export const upsertMultiplyAddresses = internalMutation({
  args: { rows: v.array(marketAddressRow) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("multiplyContractAddresses")
        .withIndex("by_market_salt", (q) => q.eq("marketSlug", row.marketSlug).eq("salt", row.salt))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("multiplyContractAddresses", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})

// -----------------------------------------------------------------------------
// Lend market
// -----------------------------------------------------------------------------

export async function readLendAddresses(ctx: QueryCtx, marketSlug: string) {
  const rows = await ctx.db
    .query("lendContractAddresses")
    .withIndex("by_market", (q) => q.eq("marketSlug", marketSlug))
    .collect()
  return rows.map(stripMeta)
}

export const listLendAddresses = query({
  args: { marketSlug: v.string() },
  handler: async (ctx, { marketSlug }) => readLendAddresses(ctx, marketSlug),
})

export const upsertLendAddresses = internalMutation({
  args: { rows: v.array(marketAddressRow) },
  handler: async (ctx, { rows }) => {
    const now = Date.now()
    for (const row of rows) {
      const existing = await ctx.db
        .query("lendContractAddresses")
        .withIndex("by_market_salt", (q) => q.eq("marketSlug", row.marketSlug).eq("salt", row.salt))
        .unique()
      if (existing) await ctx.db.patch(existing._id, { ...row, updatedAt: now })
      else await ctx.db.insert("lendContractAddresses", { ...row, updatedAt: now })
    }
    return { written: rows.length }
  },
})
