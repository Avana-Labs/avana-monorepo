// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Hubs by scope key (chain, Hub). `list` gives every Hub with its totals, the sum of its Hub assets; `get` and
// `getBySlug` one Hub with its lend assets, Spokes and the Hub-to-Hub credit lines it funds and draws on. A Hub the
// MarketRegistry records after start-up is listed from the sampler's next run.

import { v } from "convex/values";
import { query } from "./_generated/server";
import { hubSummary, lendTotals } from "./lib/hubViews.ts";
import { type HubDoc, type World, creditLineViews, hubLabelOf, loadWorld, snapshotRows, symbolOf } from "./model.ts";

function summary(w: World, h: HubDoc) {
  const lines = creditLineViews(w, (l) => l.chainId === h.chainId && (l.fundingHub === h.hub || l.homeHub === h.hub));
  return hubSummary(
    h,
    hubLabelOf(w, h.chainId, h.hub),
    w.hubAssets,
    lines.filter((l) => l.fundingHub === h.hub),
    lines.filter((l) => l.homeHub === h.hub),
  );
}

async function page(ctx: Parameters<typeof snapshotRows>[0], w: World, h: HubDoc | undefined) {
  if (!h) return null;
  const lend = (await snapshotRows(ctx, w, Math.floor(Date.now() / 1000), "lend")).filter((r) => r.chainId === h.chainId && r.hubId === h.hub);
  return { ...summary(w, h), assets: lend };
}

export const list = query({
  args: { chainId: v.optional(v.number()) },
  handler: async (ctx, { chainId }) => {
    const w = await loadWorld(ctx);
    const hubs = w.hubs.filter((h) => chainId === undefined || h.chainId === chainId);
    return lendTotals(hubs, w.hubAssets, (h) => hubLabelOf(w, h.chainId, h.hub), (c, t) => symbolOf(w, c, t)).byHub;
  },
});

export const get = query({
  args: { chainId: v.number(), hub: v.string() },
  handler: async (ctx, { chainId, hub }) => {
    const w = await loadWorld(ctx);
    return page(ctx, w, w.hubsByKey.get(`${chainId}:${hub.toLowerCase()}`));
  },
});

export const getBySlug = query({
  args: { slug: v.string() },
  handler: async (ctx, { slug }) => {
    const w = await loadWorld(ctx);
    return page(ctx, w, w.hubs.find((h) => h.slug === slug));
  },
});
