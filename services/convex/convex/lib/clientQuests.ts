// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Quests the app records itself because no chain event shows them: signing in, reading the risk primer, pinning a
// market and copying the invite link. The signed-in wallet records each once (idempotent by wallet and quest), for
// small fixed points, so a repeated or scripted call earns nothing more.

import type { MutationCtx } from "../_generated/server";
import { awardPoints } from "./rewards.ts";

/** Points of each client quest, by quest id (the ids of the app's Rewards cards). */
export const CLIENT_QUEST_POINTS: Readonly<Record<string, number>> = {
  "connect-wallet": 25,
  "review-risk-basics": 15,
  "favorite-market": 20,
  "favorite-lend-market": 20,
  "share-referral-link": 15,
};

export function isClientQuest(questId: string): boolean {
  return Object.hasOwn(CLIENT_QUEST_POINTS, questId);
}

/** Completes a client quest once for the wallet; returns whether points were awarded now. Unknown ids award nothing. */
export async function awardClientQuest(ctx: Pick<MutationCtx, "db">, wallet: string, questId: string, at: number): Promise<boolean> {
  if (!isClientQuest(questId)) return false;
  return awardPoints(ctx, { wallet, kind: "quest", key: `quest:${questId}`, points: CLIENT_QUEST_POINTS[questId]!, at, questId });
}
