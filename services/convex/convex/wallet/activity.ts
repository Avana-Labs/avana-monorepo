// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's recent activity for the dashboard (`wallet.activity.listForWallet`): the logs of the last 30 days that
// name the wallet or one of its proxies (the import writes the owning wallet on each), newest first, one row per
// event with the page it belongs to and an explorer link. Older activity comes from `wallet/history:older`.
// Activity is public chain data, so the query needs no sign-in.

import { paginationOptsValidator } from "convex/server";
import { v } from "convex/values";
import { query } from "../_generated/server";
import { type IngestedLog, feedRow } from "../lib/activity.ts";
import { explorerLinks } from "../lib/explorer.ts";
import type { DetailTxRow, PageScope } from "../lib/uiTypes.ts";
import { pricing } from "../markets.ts";
import { type World, loadWorld } from "../model.ts";

export interface WalletActivityRow extends DetailTxRow {
  readonly chainId: number;
  /** The detail page the event belongs to, when that page exists. */
  readonly page?: { readonly scope: PageScope; readonly slug: string };
}

const MAX = 100;

/** The page a log belongs to: the pool page for market events, the Borrow asset page, else the Lend page. */
export function pageOf(w: World, log: IngestedLog): { scope: PageScope; slug: string } | null {
  if (log.marketKey) {
    const m = w.markets.find((x) => `${x.chainId}:${x.marketId}` === log.marketKey);
    if (m) return { scope: "pool", slug: m.slug };
  }
  if (log.spokeReserveKey) {
    const r = w.reserves.find((x) => `${x.chainId}:${x.spoke}:${x.reserveId}` === log.spokeReserveKey);
    if (r) return { scope: "asset", slug: r.slug };
  }
  if (log.hubAssetKey) {
    const a = w.assetsByKey.get(log.hubAssetKey);
    if (a) return { scope: "lend", slug: a.slug };
  }
  return null;
}

/** One dashboard row, or null for an event no page shows (configuration, proxy creation). */
export function walletActivityRow(w: World, log: IngestedLog, explorerOf: (chainId: number) => string | undefined): WalletActivityRow | null {
  const price = (l: IngestedLog, t: "asset" | "collateral") => pricing(w, l, t);
  const row = feedRow(log, "pool", price) ?? feedRow(log, "asset", price) ?? feedRow(log, "lend", price);
  if (!row) return null;
  const page = pageOf(w, log);
  const href = explorerLinks(explorerOf(log.chainId))?.tx(log.txHash);
  return { ...row, chainId: log.chainId, txHash: log.txHash, ...(href ? { href } : {}), ...(page ? { page } : {}) };
}

/**
 * One page of the wallet's logs in Convex's index order (exact cursor, no skipped or repeated log); events no page
 * shows are dropped, so a page may hold fewer rows than `numItems`. Pass `continueCursor` back until `isDone`.
 */
export const listForWallet = query({
  args: { wallet: v.string(), chainId: v.optional(v.number()), paginationOpts: paginationOptsValidator },
  handler: async (ctx, { wallet, chainId, paginationOpts }) => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    const numItems = Math.min(Math.max(Math.floor(paginationOpts.numItems), 1), MAX);
    const w = await loadWorld(ctx);
    const explorers = new Map((await ctx.db.query("deployments").collect()).map((d) => [d.chainId, d.explorerUrl]));
    const page = await ctx.db
      .query("ingestedLogs")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet.toLowerCase()))
      .order("desc")
      .paginate({ ...paginationOpts, numItems });
    const rows: WalletActivityRow[] = [];
    for (const log of page.page) {
      if (chainId !== undefined && log.chainId !== chainId) continue;
      const r = walletActivityRow(w, log as unknown as IngestedLog, (c) => explorers.get(c));
      if (r) rows.push(r);
    }
    return { page: rows, isDone: page.isDone, continueCursor: page.continueCursor };
  },
});
