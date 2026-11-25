// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Merkl incentives (lib/incentives.ts). Hourly per chain, `refresh` reads Merkl's live opportunities (paged, at most
// 10 pages of 100) and stores one match per page; `forPage` tells the app "rewards" with the APR or "none" (checked,
// no campaign), each with `asOf` (the last successful check) and `stale` (Merkl unreachable since, or that check
// older than 3 hours), or "unknown" when no check has succeeded yet. `MERKL_API_URL` overrides https://api.merkl.xyz.

import { v } from "convex/values";
import { optionalEnv } from "@avana/services-common/env";
import { internal } from "./_generated/api";
import { internalAction, internalMutation, internalQuery, query } from "./_generated/server";
import { type IncentiveTarget, type MerklOpportunity, incentiveStatus, matchIncentives } from "./lib/incentives.ts";
import { bySlug, loadWorld } from "./model.ts";

const PAGE_SIZE = 100;
const MAX_PAGES = 10;
const scopeArg = v.union(v.literal("lend"), v.literal("asset"), v.literal("pool"));

export const targets = internalQuery({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }): Promise<IncentiveTarget[]> => {
    const w = await loadWorld(ctx);
    const dep = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if (!dep) return [];
    const out: IncentiveTarget[] = [];
    for (const m of w.markets.filter((x) => x.chainId === chainId)) out.push({ scope: "pool", slug: m.slug, addresses: [m.pool, m.vaultToken].map((a) => a.toLowerCase()) });
    for (const a of w.hubAssets.filter((x) => x.chainId === chainId)) out.push({ scope: "lend", slug: a.slug, addresses: dep.lendSpokes.map((s) => s.toLowerCase()), token: a.underlying.toLowerCase() });
    for (const r of w.reserves.filter((x) => x.chainId === chainId)) out.push({ scope: "asset", slug: r.slug, addresses: [r.spoke.toLowerCase()], token: r.asset.toLowerCase() });
    return out;
  },
});

export const store = internalMutation({
  args: {
    chainId: v.number(),
    ok: v.boolean(),
    error: v.optional(v.string()),
    matches: v.array(v.object({ scope: scopeArg, slug: v.string(), aprPct: v.number(), rewardTokens: v.array(v.string()), opportunities: v.number() })),
  },
  handler: async (ctx, { chainId, ok, error, matches }) => {
    const now = Date.now();
    const run = await ctx.db.query("incentiveRuns").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    const runRow = { chainId, lastRunAt: now, lastOkAt: ok ? now : (run?.lastOkAt ?? null), ...(error ? { error } : {}) };
    if (run) await ctx.db.replace(run._id, runRow);
    else await ctx.db.insert("incentiveRuns", runRow);
    if (!ok) return;
    for (const old of await ctx.db.query("incentives").withIndex("by_page", (q) => q.eq("chainId", chainId)).collect()) await ctx.db.delete(old._id);
    for (const m of matches) await ctx.db.insert("incentives", { chainId, ...m, updatedAt: now });
  },
});

export const refresh = internalAction({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const targets = await ctx.runQuery(internal.incentives.targets, { chainId });
    if (targets.length === 0) return;
    const base = (optionalEnv(process.env, "MERKL_API_URL") ?? "https://api.merkl.xyz").replace(/\/$/, "");
    const opps: MerklOpportunity[] = [];
    try {
      for (let page = 0; page < MAX_PAGES; page++) {
        const res = await fetch(`${base}/v4/opportunities?chainId=${chainId}&status=LIVE&items=${PAGE_SIZE}&page=${page}`);
        if (!res.ok) throw new Error(`merkl answered ${res.status}`);
        const body = (await res.json()) as unknown;
        if (!Array.isArray(body)) throw new Error("merkl answered a non-list");
        opps.push(...(body as MerklOpportunity[]));
        if (body.length < PAGE_SIZE) break;
      }
    } catch (e) {
      await ctx.runMutation(internal.incentives.store, { chainId, ok: false, error: String(e instanceof Error ? e.message : e).slice(0, 300), matches: [] });
      return;
    }
    const matches = matchIncentives(opps, chainId, targets).map((m) => ({ ...m, rewardTokens: [...m.rewardTokens] }));
    await ctx.runMutation(internal.incentives.store, { chainId, ok: true, matches });
  },
});

export const forPage = query({
  args: { scope: scopeArg, slug: v.string() },
  handler: async (ctx, { scope, slug }) => {
    const row = bySlug(await loadWorld(ctx), scope, slug);
    if (!row) return null;
    const run = await ctx.db.query("incentiveRuns").withIndex("by_chain", (q) => q.eq("chainId", row.chainId)).unique();
    const match = await ctx.db.query("incentives").withIndex("by_page", (q) => q.eq("chainId", row.chainId).eq("scope", scope).eq("slug", slug)).unique();
    return { slug, source: "merkl" as const, ...incentiveStatus(match, run?.lastOkAt ?? null, Date.now()) };
  },
});
