// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// "Member since": the time a wallet first interacted with Avana. The server notes each first sign it sees (an
// on-chain event of the wallet's account, a submitted app transaction, a created profile) and the row keeps the
// earliest. A time of 0 or less (a block whose time is unknown) is never noted, so no date is ever invented.

import type { MutationCtx } from "../_generated/server";

export type MembershipSource = "onchain" | "intent" | "profile";

/** Keeps the earliest first-seen time of `wallet`; later or equal times change nothing. */
export async function noteFirstSeen(ctx: Pick<MutationCtx, "db">, wallet: string, at: number, source: MembershipSource): Promise<void> {
  if (!Number.isFinite(at) || at <= 0) return;
  const w = wallet.toLowerCase();
  const row = await ctx.db.query("memberships").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique();
  if (!row) {
    await ctx.db.insert("memberships", { wallet: w, firstSeenAt: at, source, updatedAt: Date.now() });
    return;
  }
  if (at < row.firstSeenAt) await ctx.db.patch(row._id, { firstSeenAt: at, source, updatedAt: Date.now() });
}
