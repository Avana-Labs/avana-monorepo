// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's older activity, fetched on request from the indexer's `/export/v1/history` (services/indexer/EXPORT.md,
// "Older history") and returned without being stored: Convex keeps only the recent window of activity. The request is
// signed like the scheduled pull, the page is checked before it is returned, and each wallet may ask a bounded number
// of times a minute. While the indexer rebuilds its tables after a release (a reindex), it answers 503 and the app is
// told the history is unavailable rather than shown an empty one.
//
// Asked with `rows`, the page also comes back as the dashboard's activity rows: each record decoded as the import
// decodes it, the events Convex still holds left out (`wallet.activity.listForWallet` shows them), dated by its
// block's time (read from Convex's RPC once per block and kept in `blockTimestamps`) and without a USD value.

import { v } from "convex/values";
import type { ExportRecord, HistoryPage } from "@avana/services-common/export";
import { ExportUnavailable, PageRejected } from "@avana/export";
import { internal } from "../_generated/api";
import { type ActionCtx, action, internalMutation, internalQuery } from "../_generated/server";
import { lendSpokesOf, resolver } from "../ingest/apply.ts";
import { decodeRecord } from "../lib/activity.ts";
import { type BlockRef, type BlockTime, resolveBlockTimes } from "../lib/exportPage.ts";
import { exportClient } from "../lib/exportClient.ts";
import { rpcClient } from "../lib/rpc.ts";
import { loadWorld } from "../model.ts";
import { type WalletActivityRow, olderActivityRow } from "./activity.ts";

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

/** Stored block times of a chain, by block number. */
export const cachedBlockTimes = internalQuery({
  args: { chainId: v.number(), numbers: v.array(v.string()) },
  handler: async (ctx, { chainId, numbers }): Promise<BlockTime[]> => {
    const out: BlockTime[] = [];
    for (const n of numbers) {
      const row = await ctx.db.query("blockTimestamps").withIndex("by_block", (q) => q.eq("chainId", chainId).eq("blockNumber", n)).unique();
      if (row) out.push({ number: row.blockNumber, hash: row.blockHash, timestampMs: row.timestampMs });
    }
    return out;
  },
});

/** Stores block times read from the chain; a row of the same number with another hash is replaced. */
export const storeBlockTimes = internalMutation({
  args: { chainId: v.number(), rows: v.array(v.object({ number: v.string(), hash: v.string(), timestampMs: v.number() })) },
  handler: async (ctx, { chainId, rows }) => {
    for (const r of rows) {
      const row = { chainId, blockNumber: r.number, blockHash: r.hash, timestampMs: r.timestampMs };
      const existing = await ctx.db.query("blockTimestamps").withIndex("by_block", (q) => q.eq("chainId", chainId).eq("blockNumber", r.number)).unique();
      if (!existing) await ctx.db.insert("blockTimestamps", row);
      else if (existing.blockHash !== r.hash || existing.timestampMs !== r.timestampMs) await ctx.db.replace(existing._id, row);
    }
  },
});

/** The time of each block, from `blockTimestamps` or else from Convex's RPC (read by hash). */
async function blockTimesOf(ctx: ActionCtx, chainId: number, blocks: readonly BlockRef[]): Promise<Map<string, number>> {
  let client: ReturnType<typeof rpcClient> | null = null;
  return resolveBlockTimes(blocks, {
    cached: (numbers) => ctx.runQuery(internal.wallet.history.cachedBlockTimes, { chainId, numbers: [...numbers] }),
    async fetch(b) {
      client ??= rpcClient(chainId);
      const block = await client.getBlock({ blockHash: b.hash as `0x${string}` });
      return { number: b.number, hash: b.hash, timestampMs: Number(block.timestamp) * 1000 };
    },
    store: async (rows) => {
      await ctx.runMutation(internal.wallet.history.storeBlockTimes, { chainId, rows: [...rows] });
    },
  });
}

export interface OlderRowCandidate {
  readonly row: WalletActivityRow;
  readonly blockNumber: string;
  readonly blockHash: string;
}

/**
 * The records' dashboard rows, undated: each decoded as the import decodes it (lib/activity.ts), only the wallet's own
 * events, and none Convex still holds.
 */
export const olderRows = internalQuery({
  args: { chainId: v.number(), wallet: v.string(), records: v.any() },
  handler: async (ctx, { chainId, wallet, records }): Promise<OlderRowCandidate[]> => {
    const dep = await ctx.db.query("deployments").withIndex("by_chain", (q) => q.eq("chainId", chainId)).unique();
    if (!dep) return [];
    const res = resolver(ctx, dep, await lendSpokesOf(ctx, dep));
    const w = await loadWorld(ctx);
    const out: OlderRowCandidate[] = [];
    for (const r of records as readonly ExportRecord[]) {
      if (await ctx.db.query("ingestedLogs").withIndex("by_key", (q) => q.eq("key", r.key)).unique()) continue;
      const { log } = await decodeRecord(r, 0, res);
      if (log.wallet !== wallet) continue;
      const row = olderActivityRow(w, log, () => dep.explorerUrl);
      if (row) out.push({ row, blockNumber: r.blockNumber, blockHash: r.blockHash });
    }
    return out;
  },
});

/** Undated candidates dated by their block's time; a candidate whose block has no time is left out. */
export function datedRows(candidates: readonly OlderRowCandidate[], times: ReadonlyMap<string, number>): WalletActivityRow[] {
  const out: WalletActivityRow[] = [];
  for (const c of candidates) {
    const ms = times.get(c.blockNumber);
    if (ms !== undefined) out.push({ ...c.row, at: new Date(ms).toISOString() });
  }
  return out;
}

export type OlderHistory =
  | {
      readonly status: "ok";
      readonly proxies: readonly string[];
      readonly records: readonly ExportRecord[];
      readonly next: string | null;
      /** With `rows`: the page's dashboard rows, newest first, without a USD value. */
      readonly rows?: readonly WalletActivityRow[];
    }
  | { readonly status: "unavailable" | "rateLimited" };

export const older = action({
  args: { chainId: v.number(), wallet: v.string(), before: v.optional(v.string()), rows: v.optional(v.boolean()) },
  handler: async (ctx, { chainId, wallet, before, rows }): Promise<OlderHistory> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    if (before !== undefined && !/^\d+$/.test(before)) throw new Error("before is a decimal block number");
    if (!(await ctx.runQuery(internal.ingest.apply.state, { chainId })).deployment) throw new Error(`chain ${chainId} is not served`);
    const w = wallet.toLowerCase();
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: "history:*", limit: ALL_PER_MINUTE }))) return { status: "rateLimited" };
    if (!(await ctx.runMutation(internal.wallet.history.hit, { key: `history:${w}`, limit: PER_WALLET_PER_MINUTE }))) return { status: "rateLimited" };

    let page: HistoryPage;
    try {
      page = await exportClient().history(chainId, w, before === undefined ? null : BigInt(before), PAGE_SIZE);
    } catch (e) {
      if (e instanceof ExportUnavailable) return { status: "unavailable" };
      if (e instanceof PageRejected) console.error(`history ${chainId} ${w}: ${e.message}`);
      throw e;
    }
    const result = { status: "ok" as const, proxies: page.proxies, records: page.records, next: page.next?.before ?? null };
    if (!rows) return result;

    const candidates = await ctx.runQuery(internal.wallet.history.olderRows, { chainId, wallet: w, records: page.records });
    let times: Map<string, number>;
    try {
      times = await blockTimesOf(ctx, chainId, candidates.map((c) => ({ number: c.blockNumber, hash: c.blockHash })));
    } catch (e) {
      console.error(`history ${chainId} ${w}: block times: ${e instanceof Error ? e.message : String(e)}`);
      return { status: "unavailable" };
    }
    return { ...result, rows: datedRows(candidates, times) };
  },
});
