// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signed-in wallet pins a market to its watchlist (`wallet.pinnedMarkets.pin`) and `list` returns its pins. A pin
// names a real market page (the pool of the Borrow markets or the asset of the Lend markets), is stored once per wallet
// and page, and completes the quest of its kind once.

import { v } from "convex/values";
import { mutation, query } from "../_generated/server";
import { codedError } from "../codedError";
import { awardClientQuest, PIN_QUEST_OF_SCOPE } from "../lib/clientQuests.ts";
import { consumeWriteBudget } from "../writeRateLimit";
import { requireWalletSession } from "../walletAuth";

/** Pins a wallet may hold; a spray of pins is refused. */
const MAX_PINS = 200;

const scope = v.union(v.literal("lend"), v.literal("pool"));

export const pin = mutation({
  args: { wallet: v.string(), scope, slug: v.string() },
  handler: async (ctx, { wallet, scope, slug }): Promise<{ pinned: boolean; awarded: boolean }> => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    if (slug.length === 0 || slug.length > 96) throw codedError("INVALID_PIN: market slug");
    const exists =
      scope === "pool"
        ? await ctx.db.query("markets").withIndex("by_slug", (q) => q.eq("slug", slug)).first()
        : await ctx.db.query("hubAssets").withIndex("by_slug", (q) => q.eq("slug", slug)).first();
    if (!exists) throw codedError("INVALID_PIN: unknown market");
    const already = await ctx.db.query("pinnedMarkets").withIndex("by_wallet_slug", (q) => q.eq("wallet", w).eq("slug", slug)).first();
    if (!already) {
      const pins = await ctx.db.query("pinnedMarkets").withIndex("by_wallet_slug", (q) => q.eq("wallet", w)).take(MAX_PINS + 1);
      if (pins.length >= MAX_PINS) throw codedError("INVALID_PIN: too many pins");
      await ctx.db.insert("pinnedMarkets", { wallet: w, scope, slug, pinnedAt: Date.now() });
    }
    return { pinned: !already, awarded: await awardClientQuest(ctx, w, PIN_QUEST_OF_SCOPE[scope], Date.now()) };
  },
});

/** The wallet's pinned markets, newest first. */
export const list = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const w = await requireWalletSession(ctx, wallet);
    const rows = await ctx.db.query("pinnedMarkets").withIndex("by_wallet_slug", (q) => q.eq("wallet", w)).take(200);
    return rows.map((r) => ({ scope: r.scope, slug: r.slug, pinnedAt: r.pinnedAt })).sort((a, b) => b.pinnedAt - a.pinnedAt);
  },
});
