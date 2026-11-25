// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The 1D, 30D and 90D windows of a detail page (`windows.getRateWindows`). Lend and Borrow asset pages: the Hub
// asset's average supply APY, borrow APR and utilization over each window's daily buckets (1D: the last 24 hourly
// buckets). Pool pages: the LP fee APR of the market's range over each window (lib/windows.ts) and the market's
// average borrow APR (base rate × (1 + collateral risk)). A window with no buckets yet is null.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { type Values, combineSources } from "./lib/charts.ts";
import { hubAssetKey, headlineReserve } from "./lib/pages.ts";
import { WINDOWS, type WindowId, lpFeeAprPct, rateAverages } from "./lib/windows.ts";
import { type HubAssetDoc, type MarketDoc, type SpokeReserveDoc, bySlug, lastPoolState, loadWorld, poolPricing, scopePoints } from "./model.ts";

const HOUR = 3_600;
const DAY = 86_400;

export interface RateWindow {
  readonly id: WindowId;
  readonly supplyApyPct: number | null;
  readonly borrowAprPct: number | null;
  readonly utilizationPct: number | null;
  /** Pool pages only. */
  readonly lpFeeAprPct?: number | null;
}

async function buckets(ctx: Parameters<typeof scopePoints>[0], kind: string, key: string, days: number, now: number): Promise<Values[]> {
  const resolution = days === 1 ? "hour" : "day";
  const step = resolution === "hour" ? HOUR : DAY;
  const from = Math.floor(now / step) * step - days * DAY;
  const merged = combineSources(kind as never, await scopePoints(ctx, kind, key, resolution, from));
  return [...merged.entries()].filter(([t]) => t >= from).sort(([a], [b]) => a - b).map(([, v]) => v);
}

export const getRateWindows = query({
  args: { scope: v.union(v.literal("lend"), v.literal("asset"), v.literal("pool")), slug: v.string() },
  handler: async (ctx, { scope, slug }): Promise<{ slug: string; windows: RateWindow[] } | null> => {
    const w = await loadWorld(ctx);
    const row = bySlug(w, scope, slug);
    if (!row) return null;
    const now = Math.floor(Date.now() / 1000);
    const out: RateWindow[] = [];
    if (scope !== "pool") {
      const asset = scope === "lend" ? (row as HubAssetDoc) : w.assetsByKey.get(hubAssetKey(row as SpokeReserveDoc));
      if (!asset) return null;
      for (const [id, days] of Object.entries(WINDOWS) as [WindowId, number][]) {
        const avg = rateAverages(await buckets(ctx, "hubAsset", hubAssetKey(asset), days, now));
        out.push({ id, supplyApyPct: avg?.supplyApyPct ?? null, borrowAprPct: avg?.borrowAprPct ?? null, utilizationPct: avg?.utilizationPct ?? null });
      }
      return { slug, windows: out };
    }
    const m = row as MarketDoc;
    const pricing = poolPricing(w, m);
    const head = headlineReserve(w.reserves.filter((r) => r.chainId === m.chainId), m.spoke);
    const asset = head ? w.assetsByKey.get(hubAssetKey(head)) : undefined;
    const latest = await buckets(ctx, "pool", `${m.chainId}:${m.pool}`, 1, now);
    const state = lastPoolState(new Map(latest.map((v, i) => [i, v])));
    for (const [id, days] of Object.entries(WINDOWS) as [WindowId, number][]) {
      const pool = await buckets(ctx, "pool", `${m.chainId}:${m.pool}`, days, now);
      const hub = asset ? rateAverages(await buckets(ctx, "hubAsset", hubAssetKey(asset), days, now)) : null;
      const lp = pricing && state && pool.length > 0 ? lpFeeAprPct(pool, days, { sqrtPriceX96: state.sqrtPriceX96, tickLower: m.bandLower, tickUpper: m.bandUpper }, pricing) : null;
      // The market's borrowers pay the base rate × (1 + collateral risk) (REQ-LENS-057).
      const borrow = hub ? (hub.borrowAprPct * (10_000 + m.collateralRiskBps)) / 10_000 : null;
      out.push({ id, supplyApyPct: null, borrowAprPct: borrow, utilizationPct: null, lpFeeAprPct: lp });
    }
    return { slug, windows: out };
  },
});
