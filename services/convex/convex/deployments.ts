// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes a chain's deployment row from its verified release manifest (`aave.hubs`, `aave.lendSpokes`,
// `aave.borrowSpokes`, `avana.coverageSpokes`); run by an operator with each release (internal: no client can call it).

import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { chainSlug } from "./lib/format.ts";

export const setDeployment = internalMutation({
  args: {
    chainId: v.number(),
    lens: v.string(),
    hubs: v.array(v.object({ address: v.string(), label: v.string(), tier: v.number() })),
    lendSpokes: v.array(v.string()),
    cdpSpokes: v.array(v.string()),
    coverageSpokes: v.array(v.object({ address: v.string(), asset: v.string(), hub: v.optional(v.string()) })),
    marketRegistry: v.string(),
    timelock: v.string(),
    explorerUrl: v.string(),
    nativeUsdFeed: v.string(),
    release: v.string(),
  },
  handler: async (ctx, a) => {
    if (a.hubs.length === 0 || a.lendSpokes.length === 0) throw new Error(`deployment of chain ${a.chainId} needs at least one Hub and one Lend Spoke`);
    const lower = (x: string) => x.toLowerCase();
    const row = {
      ...a,
      chainSlug: chainSlug(a.chainId),
      lens: lower(a.lens),
      hubs: a.hubs.map((h) => ({ ...h, address: lower(h.address) })),
      lendSpokes: a.lendSpokes.map(lower),
      cdpSpokes: a.cdpSpokes.map(lower),
      coverageSpokes: a.coverageSpokes.map((c) => ({ address: lower(c.address), asset: lower(c.asset), ...(c.hub ? { hub: lower(c.hub) } : {}) })),
      marketRegistry: lower(a.marketRegistry),
      timelock: lower(a.timelock),
      nativeUsdFeed: lower(a.nativeUsdFeed),
    };
    const existing = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("deployments", row);
  },
});
