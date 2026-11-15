// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's older activity, fetched on request from the indexer's `/export/v1/history` (services/indexer/EXPORT.md,
// "Older history") and returned without being stored: Convex keeps only the recent window of activity. The request is
// signed like the scheduled pull, the page is checked before it is returned, and each wallet may ask a bounded number
// of times a minute. While the indexer rebuilds its tables after a release (a reindex), it answers 503 and the app is
// told the history is unavailable rather than shown an empty one.

import { v } from "convex/values";
import type { ExportRecord, HistoryPage } from "@avana/services-common/export";
import { requireEnv } from "@avana/services-common/env";
import { internal } from "../_generated/api";
import { action, internalMutation } from "../_generated/server";
import { HistoryRejected, validateHistoryPage } from "../lib/historyPage.ts";
import { signRequest } from "../lib/hmac.ts";

const PAGE_SIZE = 100;
const PER_WALLET_PER_MINUTE = 20;
const ALL_PER_MINUTE = 600;
const MINUTE_MS = 60_000;

/** One hit on a fixed one-minute bucket; false once the bucket is full. */
export const hit = internalMutation({
  args: { key: v.string(), limit: v.number() },
  handler: async (ctx, { key, limit }) => {
    const now = Date.now();
    const row = await ctx.db.query("rateLimitBuckets").withIndex("by_key", (q) => q.eq("key", key)).unique();
    if (!row || row.resetAt <= now) {
      if (row) await ctx.db.patch(row._id, { count: 1, resetAt: now + MINUTE_MS });
      else await ctx.db.insert("rateLimitBuckets", { key, count: 1, resetAt: now + MINUTE_MS });
      return true;
    }
    if (row.count >= limit) return false;
    await ctx.db.patch(row._id, { count: row.count + 1 });
    return true;
  },
});

export type OlderHistory =
  | { readonly status: "ok"; readonly proxies: readonly string[]; readonly records: readonly ExportRecord[]; readonly next: string | null }
  | { readonly status: "unavailable" | "rateLimited" };

export const older = action({
  args: { chainId: v.number(), wallet: v.string(), before: v.optional(v.string()) },
  handler: async (ctx, { chainId, wallet, before }): Promise<OlderHistory> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    if (before !== undefined && !/^\d+$/.test(before)) throw new Error("before is a decimal block number");
    if (!(await ctx.runQuery(internal.ingest.apply.state, { chainId })).deployment) throw new Error(`chain ${chainId} is not served`);
    const w = wallet.toLowerCase();
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: "history:*", limit: ALL_PER_MINUTE }))) return { status: "rateLimited" };
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: `history:${w}`, limit: PER_WALLET_PER_MINUTE }))) return { status: "rateLimited" };

    const path = `/export/v1/history?chainId=${chainId}&wallet=${w}${before === undefined ? "" : `&before=${before}`}&limit=${PAGE_SIZE}`;
    const base = requireEnv(process.env, "INDEXER_EXPORT_URL").replace(/\/$/, "");
    const headers = await signRequest(requireEnv(process.env, "INDEXER_EXPORT_SECRET"), requireEnv(process.env, "INDEXER_EXPORT_KEY_ID"), "GET", path, Math.floor(Date.now() / 1000));
    const res = await fetch(`${base}${path}`, { headers });
    if (res.status === 503) return { status: "unavailable" };
    if (!res.ok) throw new Error(`history answered ${res.status}`);
    const page = (await res.json()) as HistoryPage;
    try {
      validateHistoryPage(page, chainId, w, before === undefined ? null : BigInt(before));
    } catch (e) {
      if (e instanceof HistoryRejected) console.error(`history ${chainId} ${w}: ${e.message}`);
      throw e;
    }
    return { status: "ok", proxies: page.proxies, records: page.records, next: page.next?.before ?? null };
  },
});
