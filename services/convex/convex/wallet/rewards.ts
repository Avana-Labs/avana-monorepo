// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's reward points for the dashboard (`wallet.rewards.summary`): quest and fee points from the ledger's running
// totals plus tenure points computed from the membership. Public like the membership it reads: every source is chain
// activity or the wallet's own first visit.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { tenurePoints } from "../lib/rewards.ts";
import { firstSeenOf } from "./membership.ts";

export interface RewardsSummary {
  readonly earnedPoints: number;
  readonly tenurePoints: number;
  readonly questPoints: number;
  readonly feePoints: number;
  /** Ids of the completed quests. */
  readonly completedQuests: readonly string[];
}

export const summary = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<RewardsSummary> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    const w = wallet.toLowerCase();
    const [totals, member] = await Promise.all([
      ctx.db.query("rewardTotals").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique(),
      firstSeenOf(ctx, w),
    ]);
    const tenure = member ? tenurePoints(member.sinceMs, Date.now()) : 0;
    const questPoints = totals?.questPoints ?? 0;
    const feePoints = totals?.feePoints ?? 0;
    return { earnedPoints: tenure + questPoints + feePoints, tenurePoints: tenure, questPoints, feePoints, completedQuests: totals?.questIds ?? [] };
  },
});
