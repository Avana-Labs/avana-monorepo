// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The /onboarding flow's state per wallet, as the reference app keeps it: wallet → analyzing → eligible → (xPending →
// xConfirmed) → claimPending → done, or waitlisted when the seats run out. The funds themselves are real: the page asks
// the local faucet (`/api/faucet/grant`) on each chain before `claim` records the step, so this module never writes
// balances or positions (the chain and the indexer own those).

import { v } from "convex/values";
import { codedError } from "./codedError";
import type { MutationCtx, QueryCtx } from "./_generated/server";
import { mutation, query } from "./_generated/server";
import { getAuthedWallet } from "./walletAuth";

/** The starting equity the reference grant gives each wallet (USD). */
export const STARTER_EQUITY_USD = 1_000_000;

const DEFAULT_ECONOMY = {
  userCap: 10_000,
  totalGrantedUsdCap: 10_000_000_000,
  perUserTargetUsd: 1_000_000,
  minMultiplier: 0.8,
  maxMultiplier: 1.2,
};

const DEFAULT_BASKET = [
  { tokenId: "usdc", weight: 0.4 },
  { tokenId: "eth", weight: 0.25 },
  { tokenId: "dai", weight: 0.1 },
  { tokenId: "wbtc", weight: 0.1 },
  { tokenId: "aave", weight: 0.1 },
  { tokenId: "uni", weight: 0.05 },
];

const SEED_VERSION = 1;

export const DEFAULT_CONFIG = {
  basket: DEFAULT_BASKET,
  seedVersion: SEED_VERSION,
  tweetTemplate:
    "I'm practicing DeFi risk-free on Avana — borrowing against LP, lending, and looping positions with $1M of test funds.",
  xHandle: "AvanaFinance",
  resourcesLinks: [
    { label: "Read the docs", href: "/docs" },
    { label: "Explore markets", href: "/borrow" },
  ],
};

export type OnboardingStep = "wallet" | "analyzing" | "eligible" | "xPending" | "xConfirmed" | "claimPending" | "done" | "waitlisted";

/** Deterministic pseudo-tier in [min, max] from the wallet (FNV-1a), as the reference derives it. */
export function deriveTier(wallet: string, min: number, max: number): { tier: number; seed: string } {
  let hash = 2166136261;
  for (let i = 0; i < wallet.length; i++) {
    hash ^= wallet.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  const unit = ((hash >>> 0) % 1000) / 1000;
  return { tier: Number((min + unit * (max - min)).toFixed(4)), seed: (hash >>> 0).toString(16) };
}

/** The signed-in wallet, which must be the one the call names. */
async function requireWallet(ctx: QueryCtx | MutationCtx, wallet: string): Promise<string> {
  const authed = await getAuthedWallet(ctx);
  if (!authed || authed !== wallet.toLowerCase()) throw codedError("UNAUTHENTICATED: connect this wallet and sign in to continue.");
  return authed;
}

function profileForWallet(ctx: QueryCtx | MutationCtx, wallet: string) {
  return ctx.db
    .query("onboardingProfiles")
    .withIndex("by_wallet", (q) => q.eq("wallet", wallet))
    .unique();
}

async function economyCounts(ctx: QueryCtx | MutationCtx) {
  const row = await ctx.db.query("onboardingEconomy").first();
  return { row, userCount: row?.userCount ?? 0, totalGrantedUsd: row?.totalGrantedUsd ?? 0, status: row?.status ?? ("open" as const) };
}

type Profile = NonNullable<Awaited<ReturnType<typeof profileForWallet>>>;

function profileView(profile: Profile | null) {
  if (!profile) return null;
  return {
    wallet: profile.wallet,
    createdAt: profile.createdAt,
    seedVersion: profile.seedVersion,
    onboardingStep: profile.onboardingStep,
    onboardedAt: profile.onboardedAt,
    eligibilityTier: profile.eligibilityTier,
    tierSeed: profile.tierSeed,
    allocatedUsd: profile.allocatedUsd,
    basketSnapshot: profile.basketSnapshot,
    xHandle: profile.xHandle,
    tweetUrl: profile.tweetUrl,
    tweetedAt: profile.tweetedAt,
    claimTxSynthetic: profile.claimTxSynthetic,
  };
}

/**
 * The signed-in gate in one read: the wallet's step and profile always, the seats only while onboarding (a finished
 * wallet stops reading the shared counter, so other wallets' claims never invalidate it).
 */
export const getOnboardingGateState = query({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    const profile = await profileForWallet(ctx, wallet);
    const view = { onboardingStep: (profile?.onboardingStep ?? "wallet") as OnboardingStep, profile: profileView(profile), config: DEFAULT_CONFIG };
    if (view.onboardingStep === "done") return { ...view, economy: null };
    const counts = await economyCounts(ctx);
    return {
      ...view,
      economy: { status: counts.status, userCount: counts.userCount, userCap: DEFAULT_ECONOMY.userCap, perUserTargetUsd: DEFAULT_ECONOMY.perUserTargetUsd },
    };
  },
});

const FINAL = new Set<OnboardingStep>(["done", "waitlisted"]);

/** Moves the profile to `step` (creating it), unless it is finished. */
async function advance(ctx: MutationCtx, wallet: string, step: OnboardingStep, patch: Partial<Profile> = {}): Promise<OnboardingStep> {
  const existing = await profileForWallet(ctx, wallet);
  if (existing) {
    if (FINAL.has(existing.onboardingStep as OnboardingStep)) return existing.onboardingStep as OnboardingStep;
    await ctx.db.patch(existing._id, { onboardingStep: step, ...patch });
    return step;
  }
  await ctx.db.insert("onboardingProfiles", { wallet, createdAt: Date.now(), seedVersion: SEED_VERSION, onboardingStep: step, ...patch });
  return step;
}

async function requireProfile(ctx: MutationCtx, wallet: string, what: string): Promise<Profile> {
  const profile = await profileForWallet(ctx, wallet);
  if (!profile) throw codedError(`NO_PROFILE: start onboarding before ${what}.`);
  return profile;
}

/** Step 1: the analysis loading state. */
export const beginAnalysis = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => advance(ctx, await requireWallet(ctx, args.wallet), "analyzing"),
});

/** Step 2: the eligibility tier, and on to "eligible". */
export const startAnalysis = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    const { tier, seed } = deriveTier(wallet, DEFAULT_ECONOMY.minMultiplier, DEFAULT_ECONOMY.maxMultiplier);
    return advance(ctx, wallet, "eligible", { eligibilityTier: tier, tierSeed: seed });
  },
});

/** The optional share on X (eligible → xPending). */
export const startTweet = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    const profile = await requireProfile(ctx, wallet, "sharing");
    if (profile.onboardingStep === "xConfirmed") return "xConfirmed" as const;
    return advance(ctx, wallet, "xPending");
  },
});

/** Confirms the share with the handle and tweet URL (an attestation; nothing is verified on X). */
export const confirmTweet = mutation({
  args: { wallet: v.string(), xHandle: v.optional(v.string()), tweetUrl: v.optional(v.string()) },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    await requireProfile(ctx, wallet, "sharing");
    const xHandle = args.xHandle?.trim().replace(/^@/, "").slice(0, 32) || undefined;
    const tweetUrl = args.tweetUrl?.trim().slice(0, 280) || undefined;
    return advance(ctx, wallet, "xConfirmed", { ...(xHandle ? { xHandle } : {}), ...(tweetUrl ? { tweetUrl } : {}), tweetedAt: Date.now() });
  },
});

/** Skips the share. */
export const skipTweet = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    await requireProfile(ctx, wallet, "continuing");
    return advance(ctx, wallet, "xConfirmed");
  },
});

/** The claim loading state, while the page asks the faucet for the wallet's funds. */
export const beginClaim = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    await requireProfile(ctx, wallet, "claiming");
    return advance(ctx, wallet, "claimPending");
  },
});

/** The last step, once the faucet funded the wallet: takes a seat and marks the wallet done, or waitlists it. */
export const claim = mutation({
  args: { wallet: v.string() },
  handler: async (ctx, args) => {
    const wallet = await requireWallet(ctx, args.wallet);
    const profile = await requireProfile(ctx, wallet, "claiming");
    if (profile.onboardingStep === "done") return { status: "done" as const, allocatedUsd: profile.allocatedUsd ?? 0 };
    if (profile.onboardingStep === "waitlisted") return { status: "waitlisted" as const, allocatedUsd: 0 };

    const allocatedUsd = STARTER_EQUITY_USD;
    const counts = await economyCounts(ctx);
    if (counts.status !== "open" || counts.userCount >= DEFAULT_ECONOMY.userCap || counts.totalGrantedUsd + allocatedUsd > DEFAULT_ECONOMY.totalGrantedUsdCap) {
      await ctx.db.patch(profile._id, { onboardingStep: "waitlisted" });
      return { status: "waitlisted" as const, allocatedUsd: 0 };
    }

    const now = Date.now();
    await ctx.db.patch(profile._id, { onboardingStep: "done", onboardedAt: now, allocatedUsd });
    const next = { userCount: counts.userCount + 1, totalGrantedUsd: counts.totalGrantedUsd + allocatedUsd };
    const closed = next.userCount >= DEFAULT_ECONOMY.userCap || next.totalGrantedUsd >= DEFAULT_ECONOMY.totalGrantedUsdCap;
    if (counts.row) await ctx.db.patch(counts.row._id, { ...next, ...(closed ? { status: "closed" as const } : {}) });
    else await ctx.db.insert("onboardingEconomy", { ...next, status: closed ? "closed" : "open" });
    return { status: "done" as const, allocatedUsd };
  },
});
