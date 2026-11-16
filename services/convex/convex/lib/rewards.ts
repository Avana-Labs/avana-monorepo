// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reward points: earned from the wallet's first deposit, borrow, repay and pledge (quests), from the fee it pays
// (1 point per $1, verified on chain) and from tenure (100 points per 30 full days of membership). Points are
// redeemable for a temporary fee discount. They are not a token and move no funds.

import type { MutationCtx } from "../_generated/server";

/** Points of each quest, by quest id (the ids of the app's Rewards cards). */
export const QUEST_POINTS: Readonly<Record<string, number>> = {
  "first-lend-deposit": 40,
  "first-borrow": 50,
  "first-repay": 30,
  "pledge-uniswap-v3-position": 60,
};

/** The quest a recorded on-chain log completes: a Lend supply, a borrow, a repay or a pledge by the wallet. */
export const QUEST_OF_LOG: Readonly<Record<string, string>> = {
  "AaveSpoke.Supply": "first-lend-deposit",
  "AaveAdapter.Borrowed": "first-borrow",
  "AaveAdapter.Repaid": "first-repay",
  "AaveAdapter.RepaidWithCollateral": "first-repay",
  "AaveAdapter.CollateralAdded": "pledge-uniswap-v3-position",
};

export const TENURE_POINTS_PER_PERIOD = 100;
export const TENURE_PERIOD_DAYS = 30;
const DAY_MS = 86_400_000;

/** Points of tenure: 100 for each full 30 days since the wallet's first interaction; 0 before the first period. */
export function tenurePoints(sinceMs: number, nowMs: number): number {
  const periods = Math.floor((nowMs - sinceMs) / (TENURE_PERIOD_DAYS * DAY_MS));
  return periods > 0 ? periods * TENURE_POINTS_PER_PERIOD : 0;
}

/**
 * Awards `points` once for (wallet, key): a second call with the same key changes nothing. Updates the wallet's running
 * totals in the same mutation. Returns whether points were awarded.
 */
export async function awardPoints(
  ctx: Pick<MutationCtx, "db">,
  a: { wallet: string; kind: "quest" | "fee"; key: string; points: number; at: number; questId?: string },
): Promise<boolean> {
  if (!Number.isFinite(a.points) || a.points <= 0) return false;
  const wallet = a.wallet.toLowerCase();
  const seen = await ctx.db.query("rewardEvents").withIndex("by_wallet_key", (q) => q.eq("wallet", wallet).eq("key", a.key)).unique();
  if (seen) return false;
  await ctx.db.insert("rewardEvents", { wallet, kind: a.kind, key: a.key, points: a.points, at: a.at });
  const totals = await ctx.db.query("rewardTotals").withIndex("by_wallet", (q) => q.eq("wallet", wallet)).unique();
  const questIds = a.questId ? [...(totals?.questIds ?? []), a.questId] : (totals?.questIds ?? []);
  const next = {
    questPoints: (totals?.questPoints ?? 0) + (a.kind === "quest" ? a.points : 0),
    feePoints: (totals?.feePoints ?? 0) + (a.kind === "fee" ? a.points : 0),
    questIds,
    updatedAt: Date.now(),
  };
  if (totals) await ctx.db.patch(totals._id, next);
  else await ctx.db.insert("rewardTotals", { wallet, ...next });
  return true;
}

/** Completes the quest that a recorded log stands for, once per wallet; nothing for any other log. */
export async function awardQuestForLog(ctx: Pick<MutationCtx, "db">, wallet: string, kind: string, at: number): Promise<void> {
  const questId = QUEST_OF_LOG[kind];
  if (!questId || !Number.isFinite(at) || at <= 0) return;
  await awardPoints(ctx, { wallet, kind: "quest", key: `quest:${questId}`, points: QUEST_POINTS[questId]!, at, questId });
}
