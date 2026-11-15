// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Daily liquidation and revenue rollups (lib/rollups.ts). Shortly after each UTC midnight a cron writes one row per
// market (liquidations, collateral seized, debt repaid, bad debt, valued at each event's hour) and one per Hub asset
// (interest paid, the Hub's reserve share, the suppliers' share) for the day that ended. Logs are kept 30 days, so
// these rows are what the pages' longer histories read (`rollups.history`). Rerunning a day replaces its rows.

import { v } from "convex/values";
import { internalMutation, type MutationCtx, query, type QueryCtx } from "./_generated/server";
import { type Values, combineSources } from "./lib/charts.ts";
import { hubAssetKey } from "./lib/pages.ts";
import { type LiquidationPricing, hourValue, liquidationTotals, previousUtcDay, revenueDay } from "./lib/rollups.ts";
import { type HubAssetDoc, type MarketDoc, type World, bySlug, loadWorld, scopePoints } from "./model.ts";

async function hours(ctx: QueryCtx, kind: string, key: string, fromMs: number): Promise<Map<number, Values>> {
  return combineSources(kind as never, await scopePoints(ctx, kind, key, "hour", Math.floor(fromMs / 1000 / 3_600) * 3_600));
}

/** Prices at each event's hour from the market and Hub asset hourly buckets, else the current sample. */
export async function liquidationPricing(ctx: QueryCtx, w: World, m: MarketDoc, fromMs: number): Promise<LiquidationPricing> {
  const marketHours = await hours(ctx, "market", `${m.chainId}:${m.marketId}`, fromMs);
  const assetHours = new Map<string, Map<number, Values>>();
  const assetOf = (spoke: string, reserveId: string) => {
    const r = w.reserves.find((x) => x.chainId === m.chainId && x.spoke === spoke && x.reserveId === reserveId);
    return r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
  };
  for (const r of w.reserves.filter((x) => x.chainId === m.chainId && x.spoke === m.spoke)) {
    const a = w.assetsByKey.get(hubAssetKey(r));
    if (a && !assetHours.has(hubAssetKey(a))) assetHours.set(hubAssetKey(a), await hours(ctx, "hubAsset", hubAssetKey(a), fromMs));
  }
  const assetPrice = (a: HubAssetDoc, at: number) => {
    const h = assetHours.get(hubAssetKey(a));
    return { priceUsd8: BigInt((h && hourValue(h, at, "priceUsd8")) ?? a.priceUsd8), decimals: a.decimals, drawnIndexRay: BigInt((h && hourValue(h, at, "drawnIndexRay")) ?? a.drawnIndexRay) };
  };
  return {
    collateral: (at) => ({ priceUsd8: BigInt(hourValue(marketHours, at, "acceptedPrice") ?? m.acceptedPrice), decimals: m.vaultDecimals }),
    debt: (reserveId, at) => {
      const a = assetOf(m.spoke, reserveId);
      return a ? assetPrice(a, at) : null;
    },
    deficit: (key, at) => {
      const r = w.reserves.find((x) => `${x.chainId}:${x.spoke}:${x.reserveId}` === key);
      const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
      return a ? assetPrice(a, at) : null;
    },
  };
}

async function upsert(ctx: MutationCtx, row: { chainId: number; scopeKind: "market" | "hubAsset"; scopeKey: string; day: string; values: Record<string, number> }) {
  const existing = await ctx.db.query("dailyRollups").withIndex("by_scope", (q) => q.eq("scopeKind", row.scopeKind).eq("scopeKey", row.scopeKey).eq("day", row.day)).unique();
  const doc = { ...row, updatedAt: Date.now() };
  if (existing) await ctx.db.replace(existing._id, doc);
  else await ctx.db.insert("dailyRollups", doc);
}

export const rollUp = internalMutation({
  args: { nowMs: v.optional(v.number()) },
  handler: async (ctx, { nowMs }) => {
    const { day, from, to } = previousUtcDay(nowMs ?? Date.now());
    const w = await loadWorld(ctx);
    for (const m of w.markets) {
      const logs = await ctx.db
        .query("ingestedLogs")
        .withIndex("by_market", (q) => q.eq("marketKey", `${m.chainId}:${m.marketId}`).gte("at", from).lt("at", to))
        .collect();
      const totals = liquidationTotals(logs as never, from, to, await liquidationPricing(ctx, w, m, from));
      await upsert(ctx, { chainId: m.chainId, scopeKind: "market", scopeKey: `${m.chainId}:${m.marketId}`, day, values: { ...totals } });
    }
    for (const a of w.hubAssets) {
      const days = combineSources("hubAsset", await scopePoints(ctx, "hubAsset", hubAssetKey(a), "day", from / 1000));
      const bucket = days.get(from / 1000);
      if (!bucket) continue;
      await upsert(ctx, { chainId: a.chainId, scopeKind: "hubAsset", scopeKey: hubAssetKey(a), day, values: { ...revenueDay(bucket, a.decimals, a.liquidityFeeBps) } });
    }
    return { day, markets: w.markets.length, hubAssets: w.hubAssets.length };
  },
});

/** A page's daily rollups, oldest first: liquidations for a pool page, revenue for a Lend or Borrow asset page. */
export const history = query({
  args: { scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool")), slug: v.string(), days: v.optional(v.number()) },
  handler: async (ctx, { scope, slug, days }) => {
    const w = await loadWorld(ctx);
    const row = bySlug(w, scope, slug);
    if (!row) return null;
    const n = Math.min(Math.max(Math.floor(days ?? 90), 1), 365);
    const since = new Date(Date.now() - n * 86_400_000).toISOString().slice(0, 10);
    // A Borrow asset page reads its Hub asset's revenue: a debt reserve and its Hub asset share chain, Hub and asset id.
    const key = scope === "pool" ? `${row.chainId}:${(row as MarketDoc).marketId}` : hubAssetKey(row as HubAssetDoc);
    const rows = await ctx.db
      .query("dailyRollups")
      .withIndex("by_scope", (q) => q.eq("scopeKind", scope === "pool" ? "market" : "hubAsset").eq("scopeKey", key).gte("day", since))
      .collect();
    return { slug, kind: scope === "pool" ? ("liquidations" as const) : ("revenue" as const), days: rows.map((r) => ({ day: r.day, ...r.values })) };
  },
});
