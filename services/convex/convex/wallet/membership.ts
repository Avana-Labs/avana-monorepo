// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's "Member since" for the dashboard (`wallet.membership.get`): the earliest of the stored membership row
// (lib/membership.ts), the wallet's first recorded on-chain log, its first submitted app transaction and its profile's
// creation. Null when none exists, and the tile then shows a dash. The query needs no sign-in: every source is a
// timestamp of public chain activity or of the wallet's own first visit.

import { v } from "convex/values";
import { query, type QueryCtx } from "../_generated/server";
import { discountBpsOf } from "../lib/redemption.ts";
import type { MembershipSource } from "../lib/membership.ts";

/** The earliest first sign of a wallet, or null when none is recorded. */
export async function firstSeenOf(ctx: Pick<QueryCtx, "db">, wallet: string): Promise<{ sinceMs: number; source: MembershipSource } | null> {
  const w = wallet.toLowerCase();
  const [row, log, intent, profile] = await Promise.all([
    ctx.db.query("memberships").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique(),
    ctx.db.query("ingestedLogs").withIndex("by_wallet", (q) => q.eq("wallet", w)).order("asc").first(),
    ctx.db.query("intents").withIndex("by_wallet", (q) => q.eq("wallet", w)).order("asc").first(),
    ctx.db.query("walletProfiles").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique(),
  ]);
  const found: { sinceMs: number; source: MembershipSource }[] = [];
  if (row) found.push({ sinceMs: row.firstSeenAt, source: row.source });
  if (log && log.at > 0) found.push({ sinceMs: log.at, source: "onchain" });
  if (intent) found.push({ sinceMs: intent.submittedAt, source: "intent" });
  if (profile) found.push({ sinceMs: profile.createdAt, source: "profile" });
  if (found.length === 0) return null;
  return found.reduce((a, b) => (b.sinceMs < a.sinceMs ? b : a));
}

/**
 * The wallet's membership and the fee discount it holds (tenure: 0 under 30 days, 1 bps from 30, 2 from 90, 3 from 180;
 * plus its active redemptions), or null when no first interaction is recorded. The discount is computed here, so a client never decides it.
 */
export const get = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<{ sinceMs: number; source: MembershipSource; discountBps: number } | null> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
    const m = await firstSeenOf(ctx, wallet);
    return m ? { ...m, discountBps: await discountBpsOf(ctx, wallet, Date.now()) } : null;
  },
});
