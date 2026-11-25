// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes a chain's deployment row from its verified release manifest: `setFromManifest` takes the manifest itself
// (schema 2: Hubs, Spokes, loss layers, each integration's core stack, the markets, two per pool, and the debt
// reserves); `setDeployment` takes the same fields one by one. Run by an operator with each release (internal: no
// client can call either).

import { v } from "convex/values";
import { internalMutation, type MutationCtx, query } from "./_generated/server";
import { explorerLinks } from "./lib/explorer.ts";
import { swapContracts } from "./lib/swapContracts.ts";
import { chainSlug } from "./lib/format.ts";

const lower = (x: string) => x.toLowerCase();
const addr = v.string();
const integration = v.object({ integrationId: v.number(), kind: v.string(), lpVault: addr, riskModule: addr, liquidationModule: addr, aaveAdapter: addr, flashloanRepay: addr });
const market = v.object({
  marketId: v.string(),
  integrationId: v.number(),
  kind: v.union(v.literal("full-range"), v.literal("custom-range")),
  name: v.string(),
  pool: v.string(),
  spoke: addr,
  hub: addr,
  vaultToken: addr,
  lpOracle: addr,
  reserveId: v.string(),
  tokens: v.array(addr),
});

const deploymentArgs = {
  chainId: v.number(),
  hubs: v.array(v.object({ address: addr, label: v.string(), tier: v.number() })),
  lendSpokes: v.array(addr),
  /** A Spoke with its home Hub; a bare address (an older caller) has no home Hub recorded. */
  cdpSpokes: v.array(v.union(addr, v.object({ address: addr, hub: v.optional(addr) }))),
  firstLossReserves: v.array(v.object({ address: addr, asset: addr, hub: v.optional(addr) })),
  deficitOffsets: v.optional(v.array(v.object({ address: addr, asset: addr, hub: addr }))),
  accessManager: v.optional(addr),
  integrations: v.optional(v.array(integration)),
  markets: v.optional(v.array(market)),
  debtReserves: v.optional(v.array(v.object({ spoke: addr, reserveId: v.string(), fixedPrice: v.boolean() }))),
  feeRecipient: v.optional(addr),
  explorerUrl: v.string(),
  nativeUsdFeed: addr,
  release: v.string(),
  spokeOracles: v.optional(v.array(v.object({ spoke: addr, oracle: addr }))),
  // The manifest's `external` list as is ({ group, name, address, standIn }); the swap provider reads it.
  external: v.optional(v.array(v.object({ group: v.string(), name: v.string(), address: addr, standIn: v.boolean() }))),
  // The replaced core's addresses, which older callers (the web app's local seed) still pass; accepted and not stored.
  lens: v.optional(addr),
  marketRegistry: v.optional(addr),
  timelock: v.optional(addr),
};

type DeploymentArgs = {
  chainId: number;
  hubs: { address: string; label: string; tier: number }[];
  lendSpokes: string[];
  cdpSpokes: (string | { address: string; hub?: string })[];
  firstLossReserves: { address: string; asset: string; hub?: string }[];
  deficitOffsets?: { address: string; asset: string; hub: string }[];
  accessManager?: string;
  integrations?: { integrationId: number; kind: string; lpVault: string; riskModule: string; liquidationModule: string; aaveAdapter: string; flashloanRepay: string }[];
  markets?: { marketId: string; integrationId: number; kind: "full-range" | "custom-range"; name: string; pool: string; spoke: string; hub: string; vaultToken: string; lpOracle: string; reserveId: string; tokens: string[] }[];
  debtReserves?: { spoke: string; reserveId: string; fixedPrice: boolean }[];
  feeRecipient?: string;
  explorerUrl: string;
  nativeUsdFeed: string;
  release: string;
  spokeOracles?: { spoke: string; oracle: string }[];
  external?: { group: string; name: string; address: string; standIn: boolean }[];
};

async function write(ctx: MutationCtx, a: DeploymentArgs) {
  if (a.hubs.length === 0 || a.lendSpokes.length === 0) throw new Error(`deployment of chain ${a.chainId} needs at least one Hub and one Lend Spoke`);
  const home = new Map((a.markets ?? []).map((m) => [lower(m.spoke), lower(m.hub)]));
  const row = {
    chainId: a.chainId,
    chainSlug: chainSlug(a.chainId),
    hubs: a.hubs.map((h) => ({ ...h, address: lower(h.address) })),
    lendSpokes: a.lendSpokes.map(lower),
    cdpSpokes: a.cdpSpokes.map((s) => {
      const address = lower(typeof s === "string" ? s : s.address);
      const hub = typeof s === "string" ? home.get(address) : s.hub ? lower(s.hub) : home.get(address);
      return { address, ...(hub ? { hub } : {}) };
    }),
    firstLossReserves: a.firstLossReserves.map((c) => ({ address: lower(c.address), asset: lower(c.asset), ...(c.hub ? { hub: lower(c.hub) } : {}) })),
    ...(a.deficitOffsets ? { deficitOffsets: a.deficitOffsets.map((c) => ({ address: lower(c.address), asset: lower(c.asset), hub: lower(c.hub) })) } : {}),
    ...(a.accessManager ? { accessManager: lower(a.accessManager) } : {}),
    ...(a.integrations
      ? { integrations: a.integrations.map((x) => ({ integrationId: x.integrationId, kind: x.kind, lpVault: lower(x.lpVault), riskModule: lower(x.riskModule), liquidationModule: lower(x.liquidationModule), aaveAdapter: lower(x.aaveAdapter), flashloanRepay: lower(x.flashloanRepay) })) }
      : {}),
    ...(a.markets
      ? { markets: a.markets.map((m) => ({ ...m, pool: lower(m.pool), spoke: lower(m.spoke), hub: lower(m.hub), vaultToken: lower(m.vaultToken), lpOracle: lower(m.lpOracle), tokens: m.tokens.map(lower) })) }
      : {}),
    ...(a.debtReserves ? { debtReserves: a.debtReserves.map((r) => ({ ...r, spoke: lower(r.spoke) })) } : {}),
    ...(a.feeRecipient ? { feeRecipient: lower(a.feeRecipient) } : {}),
    explorerUrl: a.explorerUrl,
    nativeUsdFeed: lower(a.nativeUsdFeed),
    release: a.release,
    ...(a.spokeOracles ? { spokeOracles: a.spokeOracles.map((x) => ({ spoke: lower(x.spoke), oracle: lower(x.oracle) })) } : {}),
    ...(a.external ? { external: a.external.map((x) => ({ group: x.group, name: x.name, address: lower(x.address), standIn: x.standIn })) } : {}),
  };
  const existing = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", a.chainId)).unique();
  if (existing) await ctx.db.replace(existing._id, row);
  else await ctx.db.insert("deployments", row);
}

export const setDeployment = internalMutation({
  args: deploymentArgs,
  handler: async (ctx, { lens: _l, marketRegistry: _m, timelock: _t, ...a }) => write(ctx, a),
});

type Json = Record<string, any>;

/** The deployment row of one release manifest (schema 2), as the services read it (`chainDeploymentOf`). */
export function deploymentOfManifest(m: Json, settings: { explorerUrl: string; nativeUsdFeed: string; spokeOracles?: { spoke: string; oracle: string }[] }): DeploymentArgs {
  if (m.schemaVersion !== 2) throw new Error(`release manifest schema ${m.schemaVersion}: this deployment reads schema 2`);
  return {
    chainId: m.chainId,
    hubs: m.aave.hubs.map((h: Json) => ({ address: h.address, label: h.label, tier: h.tier })),
    lendSpokes: m.aave.lendSpokes.map((s: Json) => s.address),
    cdpSpokes: m.aave.borrowSpokes.map((s: Json) => s.address),
    firstLossReserves: m.coverage.firstLossReserves.map((f: Json) => ({ address: f.address, asset: f.asset, hub: f.hub })),
    deficitOffsets: m.coverage.daoDeficitOffsets.map((f: Json) => ({ address: f.address, asset: f.asset, hub: f.hub })),
    accessManager: m.avana.accessManager.address,
    integrations: m.avana.integrations.map((x: Json) => ({
      integrationId: x.integrationId,
      kind: x.kind,
      lpVault: x.lpVault.address,
      riskModule: x.riskModule.address,
      liquidationModule: x.liquidationModule.address,
      aaveAdapter: x.aaveAdapter.address,
      flashloanRepay: x.flashloanRepay.address,
    })),
    markets: m.markets.map((k: Json) => ({
      marketId: String(k.marketId),
      integrationId: k.integrationId,
      kind: k.kind,
      name: k.name,
      pool: k.pool,
      spoke: k.spoke,
      hub: k.hub,
      vaultToken: k.vaultToken.address,
      lpOracle: k.lpOracle.address,
      reserveId: String(k.reserveId),
      tokens: [...k.tokens],
    })),
    debtReserves: m.debtReserves.map((r: Json) => ({ spoke: r.spoke, reserveId: String(r.debtReserveId), fixedPrice: r.isGho === true })),
    feeRecipient: m.feeRecipient,
    explorerUrl: settings.explorerUrl,
    nativeUsdFeed: settings.nativeUsdFeed,
    release: m.release,
    ...(settings.spokeOracles ? { spokeOracles: settings.spokeOracles } : {}),
    external: m.external.map((e: Json) => ({ group: e.group, name: e.name, address: e.address, standIn: e.standIn })),
  };
}

export const setFromManifest = internalMutation({
  args: { manifest: v.any(), explorerUrl: v.string(), nativeUsdFeed: v.string(), spokeOracles: v.optional(v.array(v.object({ spoke: addr, oracle: addr }))) },
  handler: async (ctx, { manifest, ...settings }) => write(ctx, deploymentOfManifest(manifest as Json, settings)),
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
    // The swap's front-end fee goes to the manifest's feeRecipient.
    return d ? { ...swapContracts(d.chainId, d.nativeUsdFeed, d.external ?? []), feeRecipient: d.feeRecipient ?? null } : null;
  },
});
