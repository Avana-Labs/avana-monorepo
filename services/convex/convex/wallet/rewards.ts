// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's reward points for the dashboard (`wallet.rewards.summary`): quest and fee points from the ledger's running
// totals plus tenure points computed from the membership. Public like the membership it reads: every source is chain
// activity or the wallet's own first visit.

import { v } from "convex/values";
import { query } from "../_generated/server";
import { activeRedemptions, pointBalance, redemptionRules, type RedemptionRules } from "../lib/redemption.ts";

export interface RewardsSummary {
  readonly earnedPoints: number;
  readonly tenurePoints: number;
  readonly questPoints: number;
  readonly feePoints: number;
  /** Ids of the completed quests. */
  readonly completedQuests: readonly string[];
  /** Whether the wallet's older history was read on every served chain (`wallet.backfill.run`). */
  readonly historyChecked: boolean;
  /** Points spent on redemptions, and points left to redeem (earned less spent). */
  readonly redeemedPoints: number;
  readonly availablePoints: number;
  /** The redemption rules, and the discounts the wallet holds now. */
  readonly redemption: RedemptionRules;
  readonly activeRedemptions: readonly { readonly bps: number; readonly endsAt: number }[];
}

export const summary = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<RewardsSummary> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    const w = wallet.toLowerCase();
    const now = Date.now();
    const [balance, deployments, backfills, redemption, active] = await Promise.all([
      pointBalance(ctx, w, now),
      ctx.db.query("deployments").collect(),
      ctx.db.query("historyBackfills").withIndex("by_wallet", (q) => q.eq("wallet", w)).collect(),
      redemptionRules(ctx),
      activeRedemptions(ctx, w, now),
    ]);
    const historyChecked = deployments.every((d) => backfills.some((b) => b.chainId === d.chainId));
    return {
      earnedPoints: balance.earned,
      tenurePoints: balance.tenure,
      questPoints: balance.questPoints,
      feePoints: balance.feePoints,
      completedQuests: balance.totals?.questIds ?? [],
      historyChecked,
      redeemedPoints: balance.redeemed,
      availablePoints: balance.available,
      redemption,
      activeRedemptions: active.map((r) => ({ bps: r.bps, endsAt: r.endsAt })).sort((a, b) => a.endsAt - b.endsAt),
    };
  },
});
