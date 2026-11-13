// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A wallet's accounts (one per market) with their last daily sample, for the dashboard's position list and the
// "Your position" chart history. Current values are read live by the app; these rows only say which accounts exist
// and what they held at the last sample.

import { v } from "convex/values";
import { query } from "../_generated/server";

export const listForWallet = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }) => {
    const w = wallet.toLowerCase();
    const accounts = await ctx.db.query("accounts").withIndex("by_wallet", (q) => q.eq("wallet", w)).collect();
    return Promise.all(
      accounts.map(async (a) => ({
        account: a,
        lastSample: await ctx.db.query("positions").withIndex("by_key", (q) => q.eq("chainId", a.chainId).eq("spoke", a.spoke).eq("proxy", a.proxy)).unique(),
      })),
    );
  },
});
