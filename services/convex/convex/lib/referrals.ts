// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Referrals: a wallet has one invite code; a new wallet that arrives with it is attributed to the owner once; the owner
// earns points when the invited wallet connects (attribution) and when invited wallets complete a first action
// (activation). Points are small and fixed. One person can still control many wallets, so the rules limit attribution
// to wallets with no earlier activity and never to the owner's own wallet, but cannot prove that two wallets differ.

import type { MutationCtx } from "../_generated/server";
import { firstSeenOf } from "../wallet/membership.ts";
import { QUEST_OF_INTENT_KIND, QUEST_OF_LOG, awardPoints } from "./rewards.ts";

/** Points of the referral quests, by quest id. */
export const REFERRAL_QUEST_POINTS: Readonly<Record<string, number>> = {
  "invite-first-wallet": 40,
  "bring-3-active-users": 150,
};

/** Invited wallets that must be active for the third referral quest. */
export const ACTIVE_REFERRALS_FOR_QUEST = 3;

/** A wallet with activity older than this cannot be attributed: a referral is for a new wallet. */
export const ATTRIBUTION_WINDOW_MS = 24 * 60 * 60 * 1000;

const CODE_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz";
const CODE_LENGTH = 8;

/** A code of 8 characters from an alphabet without look-alikes (no 0, 1, i, l, o). */
export function newReferralCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

export function isReferralCode(code: string): boolean {
  return new RegExp(`^[${CODE_ALPHABET}]{${CODE_LENGTH}}$`).test(code);
}

/** The wallet's invite code, created on first use. */
export async function codeOf(ctx: Pick<MutationCtx, "db">, wallet: string): Promise<string> {
  const w = wallet.toLowerCase();
  const existing = await ctx.db.query("referralCodes").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique();
  if (existing) return existing.code;
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newReferralCode();
    if (await ctx.db.query("referralCodes").withIndex("by_code", (q) => q.eq("code", code)).first()) continue;
    await ctx.db.insert("referralCodes", { wallet: w, code });
    return code;
  }
  throw new Error("could not create a referral code");
}

export type AttributionResult = "attributed" | "already" | "self" | "unknown_code" | "not_new";

/**
 * Attributes `wallet` to the owner of `code`, once. Refused for an unknown code, the owner's own wallet, a wallet that
 * is already attributed and a wallet whose first activity is more than a day old. Awards the owner "invite-first-wallet".
 */
export async function attribute(ctx: Pick<MutationCtx, "db">, wallet: string, code: string, now: number): Promise<AttributionResult> {
  const w = wallet.toLowerCase();
  const owner = await ctx.db.query("referralCodes").withIndex("by_code", (q) => q.eq("code", code)).unique();
  if (!owner) return "unknown_code";
  if (owner.wallet === w) return "self";
  if (await ctx.db.query("referralAttributions").withIndex("by_referred", (q) => q.eq("referred", w)).unique()) return "already";
  const seen = await firstSeenOf(ctx, w);
  if (seen && seen.sinceMs < now - ATTRIBUTION_WINDOW_MS) return "not_new";
  await ctx.db.insert("referralAttributions", { referred: w, owner: owner.wallet, code, capturedAt: now });
  await awardPoints(ctx, { wallet: owner.wallet, kind: "quest", key: "quest:invite-first-wallet", points: REFERRAL_QUEST_POINTS["invite-first-wallet"]!, at: now, questId: "invite-first-wallet" });
  return "attributed";
}

/**
 * Marks an invited wallet active when it completes a first action (a log or an intent of the quest kinds), and awards
 * the owner "bring-3-active-users" once three of their invited wallets are active. Nothing for other wallets or kinds.
 */
export async function activateReferral(ctx: Pick<MutationCtx, "db">, wallet: string, source: { log?: string; intent?: string }, at: number): Promise<void> {
  const isAction = (source.log !== undefined && Object.hasOwn(QUEST_OF_LOG, source.log)) || (source.intent !== undefined && Object.hasOwn(QUEST_OF_INTENT_KIND, source.intent));
  if (!isAction || !Number.isFinite(at) || at <= 0) return;
  const row = await ctx.db.query("referralAttributions").withIndex("by_referred", (q) => q.eq("referred", wallet.toLowerCase())).unique();
  if (!row || row.activatedAt !== undefined) return;
  await ctx.db.patch(row._id, { activatedAt: at });
  const invited = await ctx.db.query("referralAttributions").withIndex("by_owner", (q) => q.eq("owner", row.owner)).take(1000);
  const active = invited.filter((r) => r._id === row._id || r.activatedAt !== undefined).length;
  if (active >= ACTIVE_REFERRALS_FOR_QUEST) {
    await awardPoints(ctx, { wallet: row.owner, kind: "quest", key: "quest:bring-3-active-users", points: REFERRAL_QUEST_POINTS["bring-3-active-users"]!, at, questId: "bring-3-active-users" });
  }
}
