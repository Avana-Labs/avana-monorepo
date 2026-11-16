// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes a chain's deployment row from its verified release manifest (`aave.hubs`, `aave.lendSpokes`,
// `aave.borrowSpokes`, `avana.firstLossReserves`, and optionally `avana.lpVaults`, `avana.riskModule` and each Spoke's
// oracle for the About card); run by an operator with each release (internal: no client can call it).

import { v } from "convex/values";
import { internalMutation, query } from "./_generated/server";
import { explorerLinks } from "./lib/explorer.ts";
import { swapContracts } from "./lib/swapContracts.ts";
import { chainSlug } from "./lib/format.ts";

export const setDeployment = internalMutation({
  args: {
    chainId: v.number(),
    lens: v.string(),
    hubs: v.array(v.object({ address: v.string(), label: v.string(), tier: v.number() })),
    lendSpokes: v.array(v.string()),
    cdpSpokes: v.array(v.string()),
    firstLossReserves: v.array(v.object({ address: v.string(), asset: v.string(), hub: v.optional(v.string()) })),
    marketRegistry: v.string(),
    timelock: v.string(),
    explorerUrl: v.string(),
    nativeUsdFeed: v.string(),
    release: v.string(),
    // The About card's contracts, from the manifest (`avana.lpVaults[]`, `avana.riskModule`, each Spoke's `ORACLE()`).
    lpVaults: v.optional(v.array(v.object({ integrationId: v.number(), address: v.string() }))),
    riskModule: v.optional(v.string()),
    spokeOracles: v.optional(v.array(v.object({ spoke: v.string(), oracle: v.string() }))),
    // The manifest's `external` list as is ({ group, name, address, standIn }); the swap provider reads it.
    external: v.optional(v.array(v.object({ group: v.string(), name: v.string(), address: v.string(), standIn: v.boolean() }))),
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
      firstLossReserves: a.firstLossReserves.map((c) => ({ address: lower(c.address), asset: lower(c.asset), ...(c.hub ? { hub: lower(c.hub) } : {}) })),
      marketRegistry: lower(a.marketRegistry),
      timelock: lower(a.timelock),
      nativeUsdFeed: lower(a.nativeUsdFeed),
      ...(a.lpVaults ? { lpVaults: a.lpVaults.map((x) => ({ integrationId: x.integrationId, address: lower(x.address) })) } : {}),
      ...(a.riskModule ? { riskModule: lower(a.riskModule) } : {}),
      ...(a.spokeOracles ? { spokeOracles: a.spokeOracles.map((x) => ({ spoke: lower(x.spoke), oracle: lower(x.oracle) })) } : {}),
      ...(a.external ? { external: a.external.map((x) => ({ group: x.group, name: x.name, address: lower(x.address), standIn: x.standIn })) } : {}),
    };
    const existing = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
    if (existing) await ctx.db.replace(existing._id, row);
    else await ctx.db.insert("deployments", row);
  },
});

/**
 * The block explorer of every served chain, for links the app builds itself (a receipt, the dashboard's activity):
 * `{ chainId, chainSlug, explorerUrl }`, with `explorerUrl` null for a chain that has no explorer (anvil).
 */
export const explorers = query({
  args: {},
  handler: async (ctx) =>
    (await ctx.db.query("deployments").collect()).map((d) => ({ chainId: d.chainId, chainSlug: d.chainSlug, explorerUrl: explorerLinks(d.explorerUrl)?.base ?? null })),
});

/**
 * The swap provider's contracts on a chain (lib/swapContracts.ts): each venue's router and quoter and the tokens by
 * symbol, from the manifest's `external` list; null for a chain with no deployment.
 */
export const swapContractsOf = query({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const d = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    return d ? swapContracts(d.chainId, d.nativeUsdFeed, d.external ?? []) : null;
  },
});
