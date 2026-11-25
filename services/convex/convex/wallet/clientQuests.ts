// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signed-in wallet records a quest the app saw (`wallet.clientQuests.record`): the wallet comes from the SIWE
// session, only the quests of lib/clientQuests.ts are accepted, and each earns its points once.

import { v } from "convex/values";
import { mutation } from "../_generated/server";
import { codedError } from "../codedError";
import { awardClientQuest, isClientQuest } from "../lib/clientQuests.ts";
import { consumeWriteBudget } from "../writeRateLimit";
import { requireWalletSession } from "../walletAuth";

export const record = mutation({
  args: { wallet: v.string(), questId: v.string() },
  handler: async (ctx, { wallet, questId }): Promise<{ awarded: boolean }> => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    if (!isClientQuest(questId)) throw codedError("INVALID_QUEST: unknown quest");
    return { awarded: await awardClientQuest(ctx, w, questId, Date.now()) };
  },
});
