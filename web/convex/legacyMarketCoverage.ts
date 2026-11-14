import { v } from "convex/values"
import type { Doc } from "./_generated/dataModel"
import { internalQuery, type QueryCtx } from "./_generated/server"

const kindValidator = v.union(v.literal("revenue"), v.literal("risk"), v.literal("content"))

async function productRowExists(
  ctx: QueryCtx,
  market: Doc<"markets">,
  kind: "revenue" | "risk" | "content",
  day?: string,
) {
  if (market.scope === "asset" || market.scope === "pool") {
    if (kind === "revenue")
      return Boolean(
        await ctx.db
          .query("borrowRevenueDaily")
          .withIndex("by_slug_day", (q) => q.eq("slug", market.slug).eq("day", day!))
          .unique(),
      )
    if (kind === "risk")
      return Boolean(
        await ctx.db
          .query("borrowRiskAssessments")
          .withIndex("by_slug", (q) => q.eq("slug", market.slug))
          .unique(),
      )
    return Boolean(
      await ctx.db
        .query("borrowMarketContent")
        .withIndex("by_slug", (q) => q.eq("slug", market.slug))
        .unique(),
    )
  }
  if (market.scope === "lend") {
    if (kind === "revenue")
      return Boolean(
        await ctx.db
          .query("lendRevenueDaily")
          .withIndex("by_slug_day", (q) => q.eq("slug", market.slug).eq("day", day!))
          .unique(),
      )
    if (kind === "risk")
      return Boolean(
        await ctx.db
          .query("lendRiskAssessments")
          .withIndex("by_slug", (q) => q.eq("slug", market.slug))
          .unique(),
      )
    return Boolean(
      await ctx.db
        .query("lendMarketContent")
        .withIndex("by_slug", (q) => q.eq("slug", market.slug))
        .unique(),
    )
  }
  if (kind === "revenue")
    return Boolean(
      await ctx.db
        .query("multiplyRevenueDaily")
        .withIndex("by_slug_day", (q) => q.eq("slug", market.slug).eq("day", day!))
        .unique(),
    )
  if (kind === "risk")
    return Boolean(
      await ctx.db
        .query("multiplyRiskAssessments")
        .withIndex("by_slug", (q) => q.eq("slug", market.slug))
        .unique(),
    )
  return Boolean(
    await ctx.db
      .query("multiplyMarketContent")
      .withIndex("by_slug", (q) => q.eq("slug", market.slug))
      .unique(),
  )
}

/** Read-only, paginated release gate for removing the three legacy shared tables. */
export const checkLegacyMarketCoverage = internalQuery({
  args: {
    kind: kindValidator,
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const pagination = {
      cursor: args.cursor ?? null,
      numItems: Math.min(Math.max(Math.trunc(args.batchSize ?? 100), 1), 250),
    }
    const page =
      args.kind === "revenue"
        ? await ctx.db.query("marketRevenueDaily").paginate(pagination)
        : args.kind === "risk"
          ? await ctx.db.query("riskAssessments").paginate(pagination)
          : await ctx.db.query("marketContent").paginate(pagination)
    const missing: Array<{ legacyId: string; marketId: string; slug: string | null; reason: string }> = []

    for (const row of page.page) {
      const market = await ctx.db.get(row.marketId)
      if (!market) {
        missing.push({ legacyId: row._id, marketId: row.marketId, slug: null, reason: "missing_market" })
        continue
      }
      const day = "day" in row ? row.day : undefined
      if (!(await productRowExists(ctx, market, args.kind, day))) {
        missing.push({ legacyId: row._id, marketId: row.marketId, slug: market.slug, reason: "missing_product_row" })
      }
    }

    return {
      kind: args.kind,
      scanned: page.page.length,
      covered: page.page.length - missing.length,
      missing,
      isDone: page.isDone,
      continueCursor: page.continueCursor,
    }
  },
})
