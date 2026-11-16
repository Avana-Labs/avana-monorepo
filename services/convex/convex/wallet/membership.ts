// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's "Member since" for the dashboard (`wallet.membership.get`): the earliest of the stored membership row
// (lib/membership.ts), the wallet's first recorded on-chain log, its first submitted app transaction and its profile's
// creation. Null when none exists, and the tile then shows a dash. The query needs no sign-in: every source is a
// timestamp of public chain activity or of the wallet's own first visit.

import { v } from "convex/values";
import { query } from "../_generated/server";
import type { MembershipSource } from "../lib/membership.ts";

export const get = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<{ sinceMs: number; source: MembershipSource } | null> => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(wallet)) throw new Error("wallet is a 20-byte address");
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
  },
});
