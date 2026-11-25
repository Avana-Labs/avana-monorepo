// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signed-in wallet redeems reward points for a temporary fee discount (`wallet.redemptions.redeem`). The wallet comes
// from the SIWE session; the rules (points per step, bps per step, days, cap) come from lib/redemption.ts. The discount is
// part of `wallet.membership.get` and of the fee quote, so the fee row and the fee transfer follow it.

import { v } from "convex/values";
import { mutation } from "../_generated/server";
import { codedError } from "../codedError";
import { redeemSteps, type RedeemResult } from "../lib/redemption.ts";
import { consumeWriteBudget } from "../writeRateLimit";
import { requireWalletSession } from "../walletAuth";

export const redeem = mutation({
  args: { wallet: v.string(), steps: v.number() },
  handler: async (ctx, { wallet, steps }): Promise<RedeemResult> => {
    const w = await requireWalletSession(ctx, wallet);
    await consumeWriteBudget(ctx, `wallet:${w}`);
    try {
      return await redeemSteps(ctx, w, steps, Date.now());
    } catch (e) {
      const message = e instanceof Error ? e.message : "INVALID_REDEMPTION";
      throw codedError(/^[A-Z_]+:/.test(message) ? message : `INVALID_REDEMPTION: ${message}`);
    }
  },
});
