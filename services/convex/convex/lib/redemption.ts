// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Redeeming reward points for a temporary fee discount: `pointsPerStep` points buy `bpsPerStep` bps off every fee for
// `days` days, and the discounts a wallet holds at once never exceed `maxBps`. The numbers live in `feeConfig.redemption`
// (one place to change them) and default to the values below. A redemption is a lower fee, never a payment: nothing is
// paid out and nothing moves on chain. Points are spent for good: a redemption cannot be undone.

import type { MutationCtx, QueryCtx } from "../_generated/server";
import { firstSeenOf } from "../wallet/membership.ts";
import { MAX_FEE_BPS, tenureDiscountBps } from "./fees.ts";
import { tenurePoints } from "./rewards.ts";

export interface RedemptionRules {
  readonly pointsPerStep: number;
  readonly bpsPerStep: number;
  readonly days: number;
  /** The most bps off that redemptions may give a wallet at once, on top of its tenure discount. */
  readonly maxBps: number;
}

/** 1,000 points = 2 bps off for 30 days; at most 4 bps of redeemed discount at once. */
export const DEFAULT_REDEMPTION: RedemptionRules = { pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 4 };

const DAY_MS = 86_400_000;
const isPositiveInt = (n: number) => Number.isInteger(n) && n > 0;

/** Throws when a redemption rule is not a positive whole number, or when a full discount could pass the fee ceiling. */
export function checkRedemptionRules(r: RedemptionRules): void {
  for (const [name, value] of Object.entries(r)) if (!isPositiveInt(value)) throw new Error(`redemption ${name} must be a positive whole number`);
  if (r.maxBps + 3 > MAX_FEE_BPS) throw new Error(`redemption maxBps ${r.maxBps} with the tenure discount would pass ${MAX_FEE_BPS} bps`);
}

export async function redemptionRules(ctx: Pick<QueryCtx, "db">): Promise<RedemptionRules> {
  const row = await ctx.db.query("feeConfig").withIndex("by_key", (q) => q.eq("key", "default")).unique();
  return row?.redemption ?? DEFAULT_REDEMPTION;
}

/** The wallet's redemptions that have not ended at `now`. */
export async function activeRedemptions(ctx: Pick<QueryCtx, "db">, wallet: string, now: number) {
  return ctx.db.query("rewardRedemptions").withIndex("by_wallet_ends", (q) => q.eq("wallet", wallet.toLowerCase()).gt("endsAt", now)).collect();
}

/** The bps off a wallet's fees now: its tenure discount and its active redemptions; 0 for a wallet with no membership. */
export async function discountBpsOf(ctx: Pick<QueryCtx, "db">, wallet: string, now: number): Promise<number> {
  const member = await firstSeenOf(ctx, wallet);
  if (!member) return 0;
  const redeemed = (await activeRedemptions(ctx, wallet, now)).reduce((sum, r) => sum + r.bps, 0);
  return tenureDiscountBps(member.sinceMs, now) + redeemed;
}

/** Points earned in total (tenure, quests, fees) and spent so far. */
export async function pointBalance(ctx: Pick<QueryCtx, "db">, wallet: string, now: number) {
  const w = wallet.toLowerCase();
  const [totals, member] = await Promise.all([
    ctx.db.query("rewardTotals").withIndex("by_wallet", (q) => q.eq("wallet", w)).unique(),
    firstSeenOf(ctx, w),
  ]);
  const tenure = member ? tenurePoints(member.sinceMs, now) : 0;
  const questPoints = totals?.questPoints ?? 0;
  const feePoints = totals?.feePoints ?? 0;
  const earned = tenure + questPoints + feePoints;
  const redeemed = totals?.redeemedPoints ?? 0;
  return { tenure, questPoints, feePoints, earned, redeemed, available: Math.max(0, earned - redeemed), member, totals };
}

export type RedeemResult = { points: number; bps: number; endsAt: number };

/** Spends `steps` steps of points for a discount, within the wallet's balance and the cap on redeemed discount. */
export async function redeemSteps(ctx: Pick<MutationCtx, "db">, wallet: string, steps: number, now: number): Promise<RedeemResult> {
  const w = wallet.toLowerCase();
  if (!Number.isInteger(steps) || steps < 1 || steps > 100) throw new Error("INVALID_REDEMPTION: steps");
  const [rules, balance, active] = await Promise.all([redemptionRules(ctx), pointBalance(ctx, w, now), activeRedemptions(ctx, w, now)]);
  if (!balance.member) throw new Error("NO_MEMBERSHIP: a first action is needed before points can be redeemed");
  const points = steps * rules.pointsPerStep;
  const bps = steps * rules.bpsPerStep;
  if (points > balance.available) throw new Error("INSUFFICIENT_POINTS: not enough points");
  if (active.reduce((sum, r) => sum + r.bps, 0) + bps > rules.maxBps) throw new Error("REDEMPTION_CAP: the discount limit is reached");
  const endsAt = now + rules.days * DAY_MS;
  await ctx.db.insert("rewardRedemptions", { wallet: w, points, bps, startsAt: now, endsAt });
  if (balance.totals) await ctx.db.patch(balance.totals._id, { redeemedPoints: balance.redeemed + points, updatedAt: now });
  else await ctx.db.insert("rewardTotals", { wallet: w, questPoints: 0, feePoints: 0, questIds: [], redeemedPoints: points, updatedAt: now });
  return { points, bps, endsAt };
}
