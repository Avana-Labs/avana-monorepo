// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The database side of the history backfill (wallet/backfill.ts): what to read for a wallet, and the one write that
// records what its older history showed. Kept apart from the action so the writes can be tested without the indexer client.

import { v } from "convex/values";
import { internalMutation, internalQuery } from "../_generated/server";
import { noteFirstSeen } from "../lib/membership.ts";
import { QUEST_POINTS, awardPoints, raiseSupplyVolume } from "../lib/rewards.ts";

/** Per served chain: whether the wallet's history was already read, and the Lend reserves with their Hub asset's price. */
export const plan = internalQuery({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const w = wallet.toLowerCase();
    const [deployments, done, assets] = await Promise.all([
      ctx.db.query("deployments").collect(),
      ctx.db.query("historyBackfills").withIndex("by_wallet", (q) => q.eq("wallet", w)).collect(),
      ctx.db.query("hubAssets").collect(),
    ]);
    return deployments.map((d) => ({
      chainId: d.chainId,
      done: done.some((b) => b.chainId === d.chainId),
      reserves: assets
        .filter((a) => a.chainId === d.chainId)
        .flatMap((a) => a.lendReserves.map((r) => ({ spoke: r.spoke.toLowerCase(), reserveId: r.reserveId, decimals: a.decimals, priceUsd8: a.priceUsd8 }))),
    }));
  },
});

/**
 * Records what a wallet's older history on one chain showed, once per wallet and chain. The first interaction is noted
 * only when the whole history was read (`truncated` false): a partial walk would date it too late. Quests are awarded
 * under the same keys as the live logs, so nothing is awarded twice; the supply total only ever rises to the history's.
 */
export const finish = internalMutation({
  args: {
    wallet: v.string(),
    chainId: v.number(),
    truncated: v.boolean(),
    firstAtMs: v.union(v.null(), v.number()),
    quests: v.array(v.object({ questId: v.string(), atMs: v.number() })),
    supplyUsd: v.number(),
  },
  handler: async (ctx, a) => {
    const w = a.wallet.toLowerCase();
    if (await ctx.db.query("historyBackfills").withIndex("by_wallet", (q) => q.eq("wallet", w)).filter((q) => q.eq(q.field("chainId"), a.chainId)).first()) return false;
    await ctx.db.insert("historyBackfills", { wallet: w, chainId: a.chainId, doneAt: Date.now(), truncated: a.truncated });
    if (!a.truncated && a.firstAtMs !== null) await noteFirstSeen(ctx, w, a.firstAtMs, "onchain");
    for (const q of a.quests) {
      const points = QUEST_POINTS[q.questId];
      if (points) await awardPoints(ctx, { wallet: w, kind: "quest", key: `quest:${q.questId}`, points, at: q.atMs, questId: q.questId });
    }
    await raiseSupplyVolume(ctx, w, a.supplyUsd, Date.now());
    return true;
  },
});
