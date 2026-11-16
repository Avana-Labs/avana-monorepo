// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signed-in wallet's referrals: `myCode` gives its invite code (created on first use), `attribute` records that it
// arrived with someone's code (once, only while it is new), and `summary` counts the wallets it invited. Credit for the
// owner is awarded in lib/referrals.ts.

import { v } from "convex/values";
import { mutation, query } from "../_generated/server";
import { codedError } from "../codedError";
import { attribute as attributeWallet, codeOf, isReferralCode, type AttributionResult } from "../lib/referrals.ts";
import { consumeWriteBudget } from "../writeRateLimit";
import { requireWalletSession } from "../walletAuth";

export const myCode = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<{ code: string }> => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    return { code: await codeOf(ctx, w) };
  },
});

export const attribute = mutation({
  args: { wallet: v.string(), code: v.string() },
  handler: async (ctx, { wallet, code }): Promise<{ result: AttributionResult }> => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    const c = code.toLowerCase();
    if (!isReferralCode(c)) throw codedError("INVALID_REFERRAL: malformed code");
    return { result: await attributeWallet(ctx, w, c, Date.now()) };
  },
});

/** The wallet's code (null until it asks for one) and how many wallets it invited and how many of them are active. */
export const summary = query({
  args: { wallet: v.string() },
  handler: async (ctx, { wallet }): Promise<{ code: string | null; invited: number; active: number }> => {
    const w = await requireWalletSession(ctx, wallet);
    const [code, invited] = await Promise.all([
      ctx.db.query("referralCodes").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique(),
      ctx.db.query("referralAttributions").withIndex("by_owner", (q) => q.eq("owner", w)).take(1000),
    ]);
    return { code: code?.code ?? null, invited: invited.length, active: invited.filter((r) => r.activatedAt !== undefined).length };
  },
});
