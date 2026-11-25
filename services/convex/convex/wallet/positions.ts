// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's accounts (one per market) with their last daily sample, for the dashboard's position list and the
// "Your position" chart history. Current values are read live by the app; these rows only say which accounts exist
// and what they held at the last sample.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { type World, loadWorld, priceAsset } from "../model.ts";

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const w = wallet.toLowerCase();
    const accounts = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", w)).collect();
    return Promise.all(
      accounts.map(async (a) => ({
        account: a,
        lastSample: await ctx.db.query("positions").withIndex("by_key", (q) => q.eq("chainId", a.chainId).eq("spoke", a.spoke).eq("proxy", a.proxy)).unique(),
      })),
    );
  },
});

/**
 * What the app needs to read a wallet's Borrow accounts from the chain and act on them: each account's market (with
 * the Borrow list's pool slug), every listed market with its Spoke (a first pledge opens an account), the Lens of each
 * chain (`getAccounts`, `ADAPTER`), and the debt reserves of the markets' Spokes (with the Borrow list's asset slug,
 * decimals and USD price) to value each debt and pay the fee.
 */
export const borrowAccounts = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const owner = wallet.toLowerCase();
    const rows = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", owner)).collect();
    const w = await loadWorld(ctx);
    const deployments = await ctx.db.query("deployments").collect();
    // The replaced core's Lens is gone: `lenses` stays empty for the web app until it reads `adapters`, each chain's
    // AaveAdapters (one per integration; `accountOf(wallet, marketId)` gives the account).
    const adapters = deployments.flatMap((d) => (d.integrations ?? []).map((x) => ({ chainId: d.chainId, integrationId: x.integrationId, aaveAdapter: x.aaveAdapter })));
    return { lenses: [] as { chainId: number; lens: string }[], adapters, ...borrowAccountRefs(w, rows) };
  },
});

type AccountRow = { readonly chainId: number; readonly integrationId: number; readonly marketId: string; readonly spoke: string; readonly proxy: string };

/**
 * Each account with its market's pool slug, every listed market with its Spoke, and the debt reserves of those
 * Spokes with their slug and USD price.
 */
export function borrowAccountRefs(w: World, rows: readonly AccountRow[]) {
  const accounts = rows.map((a) => ({
    chainId: a.chainId,
    integrationId: a.integrationId,
    marketId: a.marketId,
    spoke: a.spoke,
    proxy: a.proxy,
    poolSlug: w.markets.find((m) => m.chainId === a.chainId && m.integrationId === a.integrationId && m.marketId === a.marketId)?.slug ?? null,
  }));
  const markets = w.markets.map((m) => ({
    chainId: m.chainId,
    integrationId: m.integrationId,
    marketId: m.marketId,
    spoke: m.spoke,
    poolSlug: m.slug,
    tokens: m.tokens,
    tokenDecimals: m.tokenDecimals,
  }));
  // USD prices of the markets' pool tokens, to value the accounts' uncollected LP fees.
  const tokenPrices = [...new Map(w.markets.flatMap((m) => m.tokens.map((t) => [`${m.chainId}:${t}`, { chainId: m.chainId, token: t, hub: m.hub }] as const))).values()]
    .map(({ chainId, token, hub }) => ({ chainId, token, priceUsd8: priceAsset(w, chainId, token, hub)?.priceUsd8 ?? null }))
    .filter((p) => p.priceUsd8 !== null);
  const spokes = new Set([...rows, ...markets].map((a) => `${a.chainId}:${a.spoke}`));
  const debtReserves = w.reserves
    .filter((r) => spokes.has(`${r.chainId}:${r.spoke}`))
    .map((r) => ({
      chainId: r.chainId,
      spoke: r.spoke,
      reserveId: r.reserveId,
      asset: r.asset,
      assetSlug: r.slug,
      decimals: r.decimals,
      priceUsd8: priceAsset(w, r.chainId, r.asset, r.hub)?.priceUsd8 ?? null,
    }));
  return { accounts, markets, debtReserves, tokenPrices };
}
