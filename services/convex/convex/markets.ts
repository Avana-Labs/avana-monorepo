// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The list, header, quick-stat, chart and activity queries of the Lend and Borrow screens, under the names and
// shapes the web app calls. A chain has several Hubs: list rows name their Hub, totals add every Hub. Scopes: "lend" =
// a Hub asset (Lend page), "asset" = one CDP Spoke's debt reserve
// (Borrow asset page), "pool" = one collateral market (Borrow pool page). Multiply is not part of v1, so its list is
// empty and no Multiply row exists.

import { v } from "convex/values";
import { bpsToPct, rayToAprPct, rayToApyPct, usd } from "@avana/services-common/views";
import { query, type QueryCtx } from "./_generated/server";
import { type RangeId, type Values, combineSources, daySeries, filledBuckets, quickStats, valueAt } from "./lib/charts.ts";
import { feedRow, type IngestedLog, type Pricing } from "./lib/activity.ts";
import { hubAssetKey, lendSnapshot, assetSnapshot, poolSnapshot } from "./lib/pages.ts";
import type { DaySeries, DetailTxRow, MarketSnapshotRow, PageScope } from "./lib/uiTypes.ts";
import { lendTotals } from "./lib/hubViews.ts";
import { type World, bySlug, hubLabelOf, loadWorld, priceAsset, reserveKey, scopePoints, sliceOf, snapshotRows, symbolOf } from "./model.ts";
import type { HubAssetDoc, MarketDoc, SpokeReserveDoc } from "./model.ts";

const scopeArg = v.union(v.literal("asset"), v.literal("pool"), v.literal("lend"), v.literal("multiply"));
const rangeArg = v.union(v.literal("1D"), v.literal("1W"), v.literal("1M"), v.literal("3M"), v.literal("1Y"), v.literal("ALL"));
const nowSeconds = () => Math.floor(Date.now() / 1000);

export const listMarketSnapshots = query({ args: {}, handler: async (ctx) => snapshotRows(ctx, await loadWorld(ctx), nowSeconds()) });

export const listBorrowMarketSnapshots = query({
  args: {},
  handler: async (ctx) => (await snapshotRows(ctx, await loadWorld(ctx), nowSeconds())).filter((r) => r.scope === "pool" || r.scope === "asset"),
});

export const listLendMarketSnapshots = query({ args: {}, handler: async (ctx) => snapshotRows(ctx, await loadWorld(ctx), nowSeconds(), "lend") });

/**
 * The Lend screen's totals: supplied, borrowed, available and utilization over every Hub asset of every Hub, split by
 * Hub and by token (each token's total over its Hubs, one row per Hub). A Hub listed later is included at once.
 */
export const getLendTotals = query({
  args: { chainId: v.optional(v.number()) },
  handler: async (ctx, { chainId }) => {
    const w = await loadWorld(ctx);
    const keep = <T extends { chainId: number }>(x: T) => chainId === undefined || x.chainId === chainId;
    return lendTotals(w.hubs.filter(keep), w.hubAssets.filter(keep), (h) => hubLabelOf(w, h.chainId, h.hub), (c, t) => symbolOf(w, c, t));
  },
});

/** Multiply is not in v1. */
export const listMultiplyMarketSnapshots = query({ args: {}, handler: async (): Promise<MarketSnapshotRow[]> => [] });

export async function readMarketSnapshot(ctx: QueryCtx, w: World, scope: PageScope, slug: string): Promise<MarketSnapshotRow | null> {
  return (await snapshotRows(ctx, w, nowSeconds(), scope)).find((r) => r.slug === slug) ?? null;
}

export const getMarketSnapshot = query({
  args: { scope: scopeArg, slug: v.string() },
  handler: async (ctx, { scope, slug }) => (scope === "multiply" ? null : readMarketSnapshot(ctx, await loadWorld(ctx), scope, slug)),
});

/** Day buckets of a scope, with gaps filled, keyed by bucket start. */
async function days(ctx: QueryCtx, kind: "hubAsset" | "hubAssetSpoke" | "market" | "pool", key: string): Promise<Map<number, Values>> {
  const filled = filledBuckets(kind, combineSources(kind, await scopePoints(ctx, kind, key, "day")), 0, nowSeconds(), "day");
  return new Map(filled.map((d) => [d.t, d.values]));
}

const list = (m: Map<number, Values>) => [...m.entries()].map(([t, values]) => ({ t, values }));

/** The previous day's snapshot row of a page, from the hourly bucket 24 hours ago, for the quick-stat deltas. */
async function snapshot24hAgo(ctx: QueryCtx, w: World, scope: PageScope, slug: string): Promise<MarketSnapshotRow | null> {
  const at = nowSeconds() - 86_400;
  const hour = async (kind: string, key: string) => valueAt(combineSources(kind as "hubAsset", await scopePoints(ctx, kind, key, "hour", at - 7_200)), at);
  const row = bySlug(w, scope, slug);
  if (!row) return null;
  if (scope === "lend") {
    const a = row as HubAssetDoc;
    const past = await hour("hubAsset", hubAssetKey(a));
    return past ? lendSnapshot({ ...a, ...past }, null, "") : null;
  }
  if (scope === "asset") {
    const r = row as SpokeReserveDoc;
    const a = w.assetsByKey.get(hubAssetKey(r));
    const s = sliceOf(w, r);
    if (!a || !s) return null;
    const [pa, ps] = [await hour("hubAsset", hubAssetKey(a)), await hour("hubAssetSpoke", `${hubAssetKey(a)}:${r.spoke}`)];
    return pa && ps ? assetSnapshot(r, { ...s, ...ps }, { ...a, ...pa }, null, "", "") : null;
  }
  const m = row as MarketDoc;
  const pm = await hour("market", `${m.chainId}:${m.marketId}`);
  if (!pm) return null;
  const debtUsd = Number(BigInt(pm.debtUsd8 ?? "0")) / 1e8;
  const current = poolSnapshot({ ...m, ...pm }, [], w.reserves, w.assetsByKey, { volumeUsd: 0, feesUsd: 0 }, null);
  const collateral = current.suppliedUsd;
  return { ...current, borrowedUsd: debtUsd, utilizationPct: collateral > 0 ? Math.min(100, (debtUsd / collateral) * 100) : 0 };
}

export const getQuickStats = query({
  args: { scope: scopeArg, slug: v.string() },
  handler: async (ctx, { scope, slug }) => {
    if (scope === "multiply") return null;
    const w = await loadWorld(ctx);
    const current = await readMarketSnapshot(ctx, w, scope, slug);
    if (!current) return null;
    return quickStats(current, await snapshot24hAgo(ctx, w, scope, slug));
  },
});

const usdOf = (units: string | undefined, decimals: number, price: string | undefined) => (units && price ? usd(units, decimals, price) : 0);

/** Hub asset chart metrics, in the units the charts show. */
function hubMetric(metric: string, decimals: number): (v: Values) => number {
  switch (metric) {
    case "supply":
      return (x) => usdOf(x.added, decimals, x.priceUsd8);
    case "borrow":
      return (x) => usdOf(x.owed, decimals, x.priceUsd8);
    case "utilization":
      return (x) => bpsToPct(Number(x.utilizationBps ?? "0"));
    case "price":
      return (x) => Number(BigInt(x.priceUsd8 ?? "0")) / 1e8;
    case "supplyApy":
      return (x) => rayToApyPct(x.supplyRateRay ?? "0");
    default:
      return (x) => rayToAprPct(x.drawnRateRay ?? "0");
  }
}

export async function lendSeries(ctx: QueryCtx, a: HubAssetDoc, metric: "supply" | "borrow" | "utilization" | "apy", range: RangeId, live: number): Promise<DaySeries> {
  const d = await days(ctx, "hubAsset", hubAssetKey(a));
  return daySeries(`${a.slug}:hero:${metric}:${range}`, metric, list(d), hubMetric(metric === "apy" ? "supplyApy" : metric, a.decimals), range, nowSeconds(), live);
}

export const getLendHeroSeries = query({
  args: { slug: v.string(), metric: v.union(v.literal("supply"), v.literal("utilization"), v.literal("apy")), range: rangeArg },
  handler: async (ctx, { slug, metric, range }) => {
    const w = await loadWorld(ctx);
    const a = w.hubAssets.find((x) => x.slug === slug);
    if (!a) return null;
    const live = lendSnapshot(a, null, "");
    return lendSeries(ctx, a, metric, range, metric === "supply" ? live.suppliedUsd : metric === "utilization" ? live.utilizationPct : live.supplyApyPct);
  },
});

/** Borrow asset page: Hub supply, utilization, price and base rate from the Hub series; "borrow" is this Spoke's draw. */
export const getAssetHeroSeries = query({
  args: { slug: v.string(), metric: v.union(v.literal("price"), v.literal("supply"), v.literal("borrow"), v.literal("utilization"), v.literal("apy")), range: rangeArg },
  handler: async (ctx, { slug, metric, range }) => {
    const w = await loadWorld(ctx);
    const r = w.reserves.find((x) => x.slug === slug);
    const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
    const s = r ? sliceOf(w, r) : undefined;
    if (!r || !a || !s) return null;
    const live = assetSnapshot(r, s, a, null, "", "");
    const hub = await days(ctx, "hubAsset", hubAssetKey(a));
    const id = `${slug}:hero:${metric}:${range}`;
    if (metric === "borrow") {
      const slice = await days(ctx, "hubAssetSpoke", `${hubAssetKey(a)}:${r.spoke}`);
      const joined = list(slice).map(({ t, values }) => ({ t, values: { ...values, priceUsd8: hub.get(t)?.priceUsd8 ?? a.priceUsd8 } }));
      return daySeries(id, metric, joined, hubMetric("borrow", a.decimals), range, nowSeconds(), live.borrowedUsd);
    }
    const tip = metric === "supply" ? live.suppliedUsd : metric === "utilization" ? live.utilizationPct : metric === "price" ? Number(BigInt(a.priceUsd8)) / 1e8 : live.borrowAprPct;
    return daySeries(id, metric, list(hub), hubMetric(metric === "apy" ? "borrowApr" : metric, a.decimals), range, nowSeconds(), tip);
  },
});

/** Pool page: collateral value, debt backed, LTV, and the pool's volume and fees. */
export const getPoolHeroSeries = query({
  args: {
    slug: v.string(),
    metric: v.union(v.literal("tvl"), v.literal("borrowed"), v.literal("volume"), v.literal("fees"), v.literal("utilization"), v.literal("apy")),
    range: rangeArg,
  },
  handler: async (ctx, { slug, metric, range }) => {
    const w = await loadWorld(ctx);
    const m = w.markets.find((x) => x.slug === slug);
    if (!m) return null;
    const live = (await readMarketSnapshot(ctx, w, "pool", slug))!;
    const id = `${slug}:hero:${metric}:${range}`;
    if (metric === "volume" || metric === "fees") {
      const pool = await days(ctx, "pool", `${m.chainId}:${m.pool}`);
      const idx = m.tokens.findIndex((t) => priceAsset(w, m.chainId, t, m.hub) !== undefined);
      const asset = idx >= 0 ? priceAsset(w, m.chainId, m.tokens[idx]!, m.hub) : undefined;
      const fn = (x: Values) => (asset ? usdOf(x[`${metric === "volume" ? "volume" : "fees"}${idx}`], asset.decimals, asset.priceUsd8) : 0);
      return daySeries(id, metric, list(pool), fn, range, nowSeconds(), null);
    }
    const market = await days(ctx, "market", `${m.chainId}:${m.marketId}`);
    const usd8 = (x: string | undefined) => Number(BigInt(x ?? "0")) / 1e8;
    const fn =
      metric === "tvl"
        ? (x: Values) => usd8(x.suppliedUsd8)
        : metric === "borrowed"
          ? (x: Values) => usd8(x.debtUsd8)
          : metric === "utilization"
            ? (x: Values) => (usd8(x.suppliedUsd8) > 0 ? Math.min(100, (usd8(x.debtUsd8) / usd8(x.suppliedUsd8)) * 100) : 0)
            : () => 0;
    const tip = metric === "tvl" ? live.suppliedUsd : metric === "borrowed" ? live.borrowedUsd : metric === "utilization" ? live.utilizationPct : 0;
    return daySeries(id, metric, list(market), fn, range, nowSeconds(), tip);
  },
});

async function supplyBorrow(ctx: QueryCtx, w: World, scope: "lend" | "asset", slug: string) {
  const make = (s: DaySeries, label: string) => ({ ...s, id: `${slug}:sb:${label.toLowerCase()}`, label });
  if (scope === "lend") {
    const a = w.hubAssets.find((x) => x.slug === slug);
    if (!a) return null;
    const live = lendSnapshot(a, null, "");
    return {
      supplied: make(await lendSeries(ctx, a, "supply", "1Y", live.suppliedUsd), "Supplied"),
      borrowed: make(await lendSeries(ctx, a, "borrow", "1Y", live.borrowedUsd), "Borrowed"),
      utilization: make(await lendSeries(ctx, a, "utilization", "1Y", live.utilizationPct), "Utilization"),
    };
  }
  const r = w.reserves.find((x) => x.slug === slug);
  const a = r ? w.assetsByKey.get(hubAssetKey(r)) : undefined;
  const s = r ? sliceOf(w, r) : undefined;
  if (!r || !a || !s) return null;
  const live = assetSnapshot(r, s, a, null, "", "");
  const hub = await days(ctx, "hubAsset", hubAssetKey(a));
  const slice = await days(ctx, "hubAssetSpoke", `${hubAssetKey(a)}:${r.spoke}`);
  const now = nowSeconds();
  const sliceJoined = list(slice).map(({ t, values }) => ({ t, values: { ...values, priceUsd8: hub.get(t)?.priceUsd8 ?? a.priceUsd8 } }));
  return {
    supplied: make(daySeries("", "", list(hub), hubMetric("supply", a.decimals), "1Y", now, live.suppliedUsd), "Supplied"),
    borrowed: make(daySeries("", "", sliceJoined, hubMetric("borrow", a.decimals), "1Y", now, live.borrowedUsd), "Borrowed"),
    utilization: make(daySeries("", "", list(hub), hubMetric("utilization", a.decimals), "1Y", now, live.utilizationPct), "Utilization"),
  };
}

export const getSupplyBorrow = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => supplyBorrow(ctx, await loadWorld(ctx), "asset", slug) });
export const getLendSupplyBorrow = query({ args: { slug: v.string() }, handler: async (ctx, { slug }) => supplyBorrow(ctx, await loadWorld(ctx), "lend", slug) });
export { supplyBorrow as readSupplyBorrow };

/** Price and symbol of the token a feed row is in: the debt asset at its Lend Spoke price, or the vault token. */
function pricing(w: World, log: IngestedLog, token: "asset" | "collateral"): Pricing | null {
  if (token === "collateral") {
    const m = w.markets.find((x) => `${x.chainId}:${x.marketId}` === log.marketKey);
    return m ? { symbol: m.symbol, decimals: m.vaultDecimals, priceUsd8: BigInt(m.acceptedPrice) } : null;
  }
  let assetKey = log.hubAssetKey;
  if (!assetKey && log.marketKey) {
    const m = w.markets.find((x) => `${x.chainId}:${x.marketId}` === log.marketKey);
    const reserveId = String(log.args.debtReserveId ?? (log.args.report as Record<string, unknown> | undefined)?.debtReserveId ?? "");
    const r = m ? w.reserves.find((x) => x.chainId === m.chainId && x.spoke === m.spoke && x.reserveId === reserveId) : undefined;
    if (r) assetKey = hubAssetKey(r);
  }
  const a = assetKey ? w.assetsByKey.get(assetKey) : undefined;
  return a ? { symbol: symbolOf(w, a.chainId, a.underlying), decimals: a.decimals, priceUsd8: BigInt(a.priceUsd8) } : null;
}

export async function readRecentTransactions(ctx: QueryCtx, w: World, scope: PageScope, slug: string, limit = 12): Promise<DetailTxRow[]> {
  const row = bySlug(w, scope, slug);
  if (!row) return [];
  const take = Math.min(Math.max(limit, 1), 100);
  const index = scope === "lend" ? "by_hub_asset" : scope === "asset" ? "by_spoke_reserve" : "by_market";
  const field = scope === "lend" ? "hubAssetKey" : scope === "asset" ? "spokeReserveKey" : "marketKey";
  const key =
    scope === "lend"
      ? hubAssetKey(row as HubAssetDoc)
      : scope === "asset"
        ? `${row.chainId}:${reserveKey(row as SpokeReserveDoc)}`
        : `${row.chainId}:${(row as MarketDoc).marketId}`;
  const logs = await ctx.db
    .query("ingestedLogs")
    .withIndex(index as "by_market", (q) => q.eq(field as "marketKey", key))
    .order("desc")
    .take(take * 4);
  const out: DetailTxRow[] = [];
  for (const log of logs) {
    const r = feedRow(log as unknown as IngestedLog, scope, (l, t) => pricing(w, l, t));
    if (r) out.push(r);
    if (out.length >= take) break;
  }
  return out;
}

export const getRecentTransactions = query({
  args: { scope: scopeArg, slug: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { scope, slug, limit }) => (scope === "multiply" ? [] : readRecentTransactions(ctx, await loadWorld(ctx), scope, slug, limit)),
});

