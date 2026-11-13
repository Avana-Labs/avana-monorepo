// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The scheduled pull (README, "Scheduled pull"): checks the checkpoint hash over Convex's own RPC, requests signed
// export pages after it, validates each, checks `toBlockHash` over the same RPC and applies it in one mutation, up
// to 20 pages a run; then the series pages after the series cursor. A hash mismatch stops the chain's import and
// rewinds to the newest stored checkpoint that still matches.

import { v } from "convex/values";
import type { ExportPage } from "@avana/services-common/export";
import type { SeriesExportPage } from "@avana/services-common/series";
import { requireEnv } from "@avana/services-common/env";
import { internal } from "../_generated/api";
import { type ActionCtx, internalAction, internalQuery } from "../_generated/server";
import { validatePage, validateSeriesPage } from "../lib/exportPage.ts";
import { signRequest } from "../lib/hmac.ts";
import { rpcClient } from "../lib/rpc.ts";

const PAGES_PER_RUN = 20;

/** GET on the indexer's export, signed; null on 204. */
export async function exportGet<T>(pathAndQuery: string): Promise<T | null> {
  const base = requireEnv(process.env, "INDEXER_EXPORT_URL").replace(/\/$/, "");
  const headers = await signRequest(requireEnv(process.env, "INDEXER_EXPORT_SECRET"), requireEnv(process.env, "INDEXER_EXPORT_KEY_ID"), "GET", pathAndQuery, Math.floor(Date.now() / 1000));
  const res = await fetch(`${base}${pathAndQuery}`, { headers });
  if (res.status === 204) return null;
  if (!res.ok) throw new Error(`export ${pathAndQuery} answered ${res.status}`);
  return (await res.json()) as T;
}

export const history = internalQuery({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => (await ctx.db.query("ingestCheckpointHistory").withIndex("by_chain_block", (q) => q.eq("chainId", chainId)).collect()).reverse(),
});

async function rebuild(ctx: ActionCtx, chainId: number) {
  console.error(`ingest ${chainId}: checkpoint hash no longer matches RPC, rewinding`);
  const client = rpcClient(chainId);
  for (const h of await ctx.runQuery(internal.ingest.pull.history, { chainId })) {
    const block = await client.getBlock({ blockNumber: BigInt(h.throughBlock) });
    if (block.hash !== h.throughBlockHash) continue;
    for (;;) {
      const r = await ctx.runMutation(internal.ingest.apply.rewind, { chainId, throughBlock: h.throughBlock, throughBlockHash: h.throughBlockHash, batch: 200 });
      if (r.done) return;
    }
  }
  throw new Error(`ingest ${chainId}: no stored checkpoint matches RPC; rebuild from block 0 needed`);
}

export const pull = internalAction({
  args: { chainId: v.number() },
  handler: async (ctx, { chainId }) => {
    const client = rpcClient(chainId);
    for (let i = 0; i < PAGES_PER_RUN; i++) {
      const { checkpoint } = await ctx.runQuery(internal.ingest.apply.state, { chainId });
      if (checkpoint) {
        const block = await client.getBlock({ blockNumber: BigInt(checkpoint.throughBlock) });
        if (block.hash !== checkpoint.throughBlockHash) return rebuild(ctx, chainId);
      }
      const after = checkpoint ? `&after=${checkpoint.throughBlock}` : "";
      const page = await exportGet<ExportPage>(`/export/v1/pages?chainId=${chainId}${after}&limit=500`);
      if (!page) break;
      validatePage(page, chainId, checkpoint ? BigInt(checkpoint.throughBlock) : null);
      const tip = await client.getBlock({ blockNumber: BigInt(page.toBlock) });
      if (tip.hash !== page.toBlockHash) throw new Error(`ingest ${chainId}: toBlock ${page.toBlock} hash differs from RPC`);
      const { applied } = await ctx.runMutation(internal.ingest.apply.applyPage, { chainId, page });
      if (!applied) break; // another run moved the checkpoint
    }
    for (let i = 0; i < PAGES_PER_RUN; i++) {
      const { checkpoint } = await ctx.runQuery(internal.ingest.apply.state, { chainId });
      if (!checkpoint) return;
      const after = checkpoint.seriesThroughTime >= 0 ? `&after=${checkpoint.seriesThroughTime}` : "";
      const page = await exportGet<SeriesExportPage>(`/export/v1/series?chainId=${chainId}${after}&limit=2000`);
      if (!page) return;
      validateSeriesPage(page, chainId, checkpoint.seriesThroughTime);
      const { applied } = await ctx.runMutation(internal.ingest.apply.applySeriesPage, { chainId, page });
      if (!applied) return;
    }
  },
});
