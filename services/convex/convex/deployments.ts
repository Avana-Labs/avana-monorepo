// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes a chain's deployment row from its verified release manifest; run by an operator with each release
// (internal: no client can call it).

import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { chainSlug } from "./lib/format.ts";

export const setDeployment = internalMutation({
  args: {
    chainId: v.number(),
    lens: v.string(),
    lendSpoke: v.string(),
    cdpSpokes: v.array(v.string()),
    coverageSpokes: v.array(v.object({ address: v.string(), asset: v.string() })),
    marketRegistry: v.string(),
    timelock: v.string(),
    explorerUrl: v.string(),
    nativeUsdFeed: v.string(),
    release: v.string(),
  },
  handler: async (ctx, a) => {
    const lower = (x: string) => x.toLowerCase();
    const row = {
      ...a,
      chainSlug: chainSlug(a.chainId),
      lens: lower(a.lens),
      lendSpoke: lower(a.lendSpoke),
      cdpSpokes: a.cdpSpokes.map(lower),
      coverageSpokes: a.coverageSpokes.map((c) => ({ address: lower(c.address), asset: lower(c.asset) })),
      marketRegistry: lower(a.marketRegistry),
      timelock: lower(a.timelock),
      nativeUsdFeed: lower(a.nativeUsdFeed),
    };
    const existing = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("deployments", row);
  },
});
