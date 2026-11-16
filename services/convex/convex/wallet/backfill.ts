// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The one-time read of a wallet's older on-chain history for the rewards (`wallet.backfill.run`). Convex keeps 30 days
// of logs, so a wallet that began earlier has no "Member since" and no first-action quests until this reads the indexer's
// history (the same endpoint as `wallet.history.older`), once per wallet and chain, and records what it shows (lib/
// backfill.ts, backfillStore.ts). It awards only what the wallet's own on-chain activity earned, under the same keys as
// the live logs, and is public like the history it reads: its cost is bounded by the history rate limits.

import { v } from "convex/values";
import type { HistoryPage } from "@avana/services-common/export";
import { ExportUnavailable } from "@avana/export";
import { internal } from "../_generated/api";
import { action } from "../_generated/server";
import { NO_FACTS, addRecords } from "../lib/backfill.ts";
import { exportClient } from "../lib/exportClient.ts";
import { rpcClient } from "../lib/rpc.ts";

const PAGE_SIZE = 100;
/** Pages read per chain (the newest 3,000 records); a longer history is read as far as this and flagged truncated. */
export const MAX_PAGES = 30;

export type BackfillStatus = "done" | "unavailable" | "rateLimited" | "error";

export const run = action({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<{ status: BackfillStatus }> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    const w = wallet.toLowerCase();
    const chains = await ctx.runQuery(internal.wallet.backfillStore.plan, { wallet: w });
    for (const c of chains) {
      if (c.done) continue;
      const prices = new Map(c.reserves.map((r) => [`${r.spoke}:${r.reserveId}`, { decimals: r.decimals, priceUsd8: r.priceUsd8 }]));
      let facts = NO_FACTS;
      let before: bigint | null = null;
      let pages = 0;
      let truncated = false;
      try {
        for (;;) {
          if (!(await ctx.runMutation(internal.wallet.history.hit, { key: "history:*", limit: 600 }))) return { status: "rateLimited" };
          if (!(await ctx.runMutation(internal.wallet.history.hit, { key: `history:${w}`, limit: 20 }))) return { status: "rateLimited" };
          const page: HistoryPage = await exportClient().history(c.chainId, w, before, PAGE_SIZE);
          facts = addRecords(facts, page.records, w, (spoke, reserveId) => prices.get(`${spoke}:${reserveId}`) ?? null);
          pages += 1;
          if (!page.next) break;
          if (pages >= MAX_PAGES) {
            truncated = true;
            break;
          }
          before = BigInt(page.next.before);
        }
        const client = rpcClient(c.chainId);
        const timeOf = async (block: bigint) => Number((await client.getBlock({ blockNumber: block })).timestamp) * 1000;
        const firstAtMs = !truncated && facts.firstBlock !== null ? await timeOf(facts.firstBlock) : null;
        const quests: { questId: string; atMs: number }[] = [];
        for (const [questId, block] of Object.entries(facts.questBlocks)) quests.push({ questId, atMs: await timeOf(block) });
        await ctx.runMutation(internal.wallet.backfillStore.finish, { wallet: w, chainId: c.chainId, truncated, firstAtMs, quests, supplyUsd: facts.supplyUsd });
      } catch (e) {
        if (e instanceof ExportUnavailable) return { status: "unavailable" };
        console.error(`history backfill ${c.chainId} ${w}: ${e instanceof Error ? e.message : String(e)}`);
        return { status: "error" };
      }
    }
    return { status: "done" };
  },
});
