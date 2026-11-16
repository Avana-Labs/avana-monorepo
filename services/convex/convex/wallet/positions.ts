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
 * What the app needs to read a wallet's Borrow accounts from the chain and show them on its pages: each account's
 * market (with the Borrow list's pool slug), the Lens of each chain to read it with (`getAccounts`), and the debt
 * reserves of those accounts' Spokes (with the Borrow list's asset slug, decimals and USD price) to value each debt.
 */
export const borrowAccounts = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const owner = wallet.toLowerCase();
    const rows = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", owner)).collect();
    if (rows.length === 0) return { lenses: [], accounts: [], debtReserves: [] };
    const w = await loadWorld(ctx);
    const chainIds = [...new Set(rows.map((a) => a.chainId))];
    const lenses = (
      await Promise.all(
        chainIds.map(async (chainId) => {
          const lens = (await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique())?.lens;
          return lens ? { chainId, lens } : null;
        }),
      )
    ).filter((l) => l !== null);
    return { lenses, ...borrowAccountRefs(w, rows) };
  },
});

type AccountRow = { readonly chainId: number; readonly marketId: string; readonly spoke: string; readonly proxy: string };

/** Each account with its market's pool slug, and the debt reserves of the accounts' Spokes with their slug and USD price. */
export function borrowAccountRefs(w: World, rows: readonly AccountRow[]) {
  const accounts = rows.map((a) => ({
    chainId: a.chainId,
    marketId: a.marketId,
    spoke: a.spoke,
    proxy: a.proxy,
    poolSlug: w.markets.find((m) => m.chainId === a.chainId && m.marketId === a.marketId)?.slug ?? null,
  }));
  const spokes = new Set(rows.map((a) => `${a.chainId}:${a.spoke}`));
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
  return { accounts, debtReserves };
}
