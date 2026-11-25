// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Typed stubs of features the app keeps but this backend does not serve yet: rewards, referrals, swap quotes from
// an aggregator and the in-app assistant. Each returns the app's "nothing yet" value, so the screens render their empty state.

import { v } from "convex/values";
import { query } from "./_generated/server";

/** Rewards state of a wallet (claims, campaigns): none until a rewards source is connected. */
export const rewardsState = query({ args: { wallet: v.string() }, handler: async (): Promise<null> => null });

/** Referral summary of a wallet. */
export const referrals = query({
  args: { wallet: v.string() },
  handler: async (): Promise<{ code: string | null; referred: number; earnedUsd: number }> => ({ code: null, referred: 0, earnedUsd: 0 }),
});

export interface SwapQuote {
  readonly id: string;
  readonly provider: string;
  readonly chainId: number;
  readonly inputAssetId: string;
  readonly outputAssetId: string;
  readonly inputAmount: number;
  readonly slippageBps: number;
  readonly status: "valid" | "unsupported" | "error";
  readonly rejectionReason?: string;
}

/** Swap quote: answered "unsupported" until the aggregator integration lands. */
export const swapQuote = query({
  args: { chainId: v.number(), inputAssetId: v.string(), outputAssetId: v.string(), inputAmount: v.number(), slippageBps: v.optional(v.number()) },
  handler: async (_ctx, a): Promise<SwapQuote> => ({
    id: `${a.chainId}:${a.inputAssetId}:${a.outputAssetId}`,
    provider: "aggregator",
    chainId: a.chainId,
    inputAssetId: a.inputAssetId,
    outputAssetId: a.outputAssetId,
    inputAmount: a.inputAmount,
    slippageBps: a.slippageBps ?? 50,
    status: "unsupported",
    rejectionReason: "Swap quotes are not available yet.",
  }),
});

/** The in-app assistant's quota for a viewer: off. */
export const assistantQuota = query({ args: {}, handler: async (): Promise<{ enabled: false; remaining: 0 }> => ({ enabled: false, remaining: 0 }) });
