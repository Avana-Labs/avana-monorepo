/**
 * Shared market-identity module for the product-siloed tables (`borrowMarkets`,
 * `lendMarkets`, `multiplyMarkets`). Legacy `markets` remains the FK hub for walletEvents.
 * The three product files were copies that differed only in the table name, borrow's extra
 * `kind`, and the identity fields `getMarket` returns (borrow: `kind` + `scope: kind`;
 * lend/multiply: a literal `scope`), which each product passes in as `identity`.
 */

import { v } from "convex/values"
import type { WithoutSystemFields } from "convex/server"
import type { Doc } from "../_generated/dataModel"
import type { QueryCtx } from "../_generated/server"
import { internalMutation, query } from "../_generated/server"
import { kindField } from "./kindField"

const marketFields = {
  chainId: v.number(),
  name: v.string(),
  symbol: v.string(),
  venueLabel: v.optional(v.string()),
  category: v.optional(v.union(v.literal("stable"), v.literal("crypto"), v.literal("stock"))),
  explorerUrl: v.optional(v.string()),
  reserveFactorPct: v.optional(v.number()),
  rewardsApyPct: v.optional(v.number()),
  description: v.optional(v.string()),
  iconUrl: v.optional(v.string()),
  spokeId: v.optional(v.string()),
  feeTier: v.optional(v.string()),
  maxLtvPct: v.optional(v.number()),
  priceUsd: v.optional(v.number()),
  visuals: v.optional(
    v.array(
      v.object({
        symbol: v.string(),
        shortLabel: v.string(),
        bgClassName: v.string(),
        textClassName: v.string(),
        iconUrl: v.optional(v.string()),
      }),
    ),
  ),
  resources: v.optional(v.array(v.object({ label: v.string(), href: v.string() }))),
  createdAt: v.number(),
}

type MarketTable = "borrowMarkets" | "lendMarkets" | "multiplyMarkets"

export function defineMarketsModule<T extends MarketTable, Identity extends object, WithKind extends boolean = false>(
  table: T,
  options: { withKind?: WithKind; identity: (row: Doc<T>) => Identity },
) {
  // The tables share one document shape (borrow adds `kind`), so type the reads and writes
  // against one of them. The args validator and the schema still validate every row;
  // `identity` sees the row as its real table type.
  const tableName = table as MarketTable as "lendMarkets"
  /** Shared reader for `getMarket`, so batched detail queries compose it instead of copying it. */
  async function readMarket(ctx: QueryCtx, slug: string) {
    const row = await ctx.db
      .query(tableName)
      .withIndex("by_slug", (q) => q.eq("slug", slug))
      .unique()
    if (!row) return null
    return {
      slug: row.slug,
      ...options.identity(row as unknown as Doc<T>),
      chainId: row.chainId,
      name: row.name,
      symbol: row.symbol,
      venueLabel: row.venueLabel,
      category: row.category,
      explorerUrl: row.explorerUrl,
      reserveFactorPct: row.reserveFactorPct,
      rewardsApyPct: row.rewardsApyPct,
      description: row.description,
      iconUrl: row.iconUrl,
      spokeId: row.spokeId,
      feeTier: row.feeTier,
      maxLtvPct: row.maxLtvPct,
      priceUsd: row.priceUsd,
      visuals: row.visuals,
      resources: row.resources,
      createdAt: row.createdAt,
    }
  }

  return {
    readMarket,
    getMarket: query({
      args: { slug: v.string() },
      handler: async (ctx, { slug }) => readMarket(ctx, slug),
    }),
    upsertMarkets: internalMutation({
      args: {
        rows: v.array(
          v.object({
            slug: v.string(),
            ...kindField(options.withKind ?? (false as WithKind)),
            ...marketFields,
          }),
        ),
      },
      handler: async (ctx, { rows }) => {
        // `kindField` is generic here, so pin the row type to the table it is written to.
        for (const row of rows as unknown as Array<WithoutSystemFields<Doc<typeof tableName>>>) {
          const existing = await ctx.db
            .query(tableName)
            .withIndex("by_slug", (q) => q.eq("slug", row.slug))
            .unique()
          if (existing) await ctx.db.patch(existing._id, row)
          else await ctx.db.insert(tableName, row)
        }
        return { written: rows.length }
      },
    }),
  }
}
