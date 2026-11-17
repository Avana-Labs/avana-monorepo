// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Redeeming points for a temporary fee discount: spent for good, within the balance and the cap, counted in the wallet's
// discount only while it lasts, with the rules in one config value.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api, internal } from "../../convex/_generated/api"
import { DEFAULT_REDEMPTION, checkRedemptionRules, discountBpsOf } from "../../convex/lib/redemption"
import { noteFirstSeen } from "../../convex/lib/membership"
import { awardPoints } from "../../convex/lib/rewards"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xAbC0000000000000000000000000000000000002"
const DAY = 86_400_000

/** A member of 400 days: 1,300 tenure points and the full 3 bps tenure discount, plus `extra` quest points. */
async function member(extra = 0) {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await noteFirstSeen(ctx, WALLET, Date.now() - 400 * DAY, "onchain")
    if (extra > 0) await awardPoints(ctx, { wallet: WALLET, kind: "quest", key: "quest:x", points: extra, at: 1 })
  })
  return { t, asUser: t.withIdentity({ subject: WALLET }) }
}

describe("redemption rules", () => {
  test("default to 1,000 points for 2 bps over 30 days, at most 4 bps at once", () => {
    expect(DEFAULT_REDEMPTION).toEqual({ pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 4 })
    expect(() => checkRedemptionRules(DEFAULT_REDEMPTION)).not.toThrow()
    expect(() => checkRedemptionRules({ ...DEFAULT_REDEMPTION, maxBps: 23 })).toThrow()
    expect(() => checkRedemptionRules({ ...DEFAULT_REDEMPTION, days: 0 })).toThrow()
    expect(() => checkRedemptionRules({ ...DEFAULT_REDEMPTION, bpsPerStep: 1.5 })).toThrow()
  })
})

describe("redeeming points", () => {
  test("spends the points, starts the discount and counts it with the tenure discount", async () => {
    const { t, asUser } = await member()
    const before = Date.now()
    const r = await asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 1 })
    expect(r).toMatchObject({ points: 1000, bps: 2 })
    expect(r.endsAt).toBeGreaterThanOrEqual(before + 30 * DAY)
    const summary = await t.query(api.wallet.rewards.summary, { wallet: WALLET })
    expect(summary).toMatchObject({ earnedPoints: 1300, redeemedPoints: 1000, availablePoints: 300, activeRedemptions: [{ bps: 2, endsAt: r.endsAt }] })
    expect(summary.redemption).toEqual(DEFAULT_REDEMPTION)
    expect(await t.query(api.wallet.membership.get, { wallet: WALLET })).toMatchObject({ discountBps: 3 + 2 })
  })

  test("refuses more than the balance, more than the cap, a bad step count, a wallet without membership", async () => {
    const { t, asUser } = await member(3_000)
    await expect(asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 5 })).rejects.toThrow(/INSUFFICIENT_POINTS/)
    await asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 2 })
    await expect(asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 1 })).rejects.toThrow(/REDEMPTION_CAP/)
    for (const steps of [0, 101, 1.5]) await expect(asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps })).rejects.toThrow(/INVALID_REDEMPTION/)
    await t.run((ctx) => awardPoints(ctx, { wallet: OTHER, kind: "quest", key: "quest:y", points: 5_000, at: 1 }))
    await expect(t.withIdentity({ subject: OTHER }).mutation(api.wallet.redemptions.redeem, { wallet: OTHER, steps: 1 })).rejects.toThrow(/NO_MEMBERSHIP/)
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ redeemedPoints: 2000 })
  })

  test("needs the signed-in wallet", async () => {
    const { t } = await member()
    await expect(t.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 1 })).rejects.toThrow(/UNAUTHENTICATED/)
    await expect(t.withIdentity({ subject: OTHER }).mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 1 })).rejects.toThrow(/WALLET_MISMATCH/)
  })

  test("an ended redemption no longer counts in the discount or the cap, and its points stay spent", async () => {
    const { t, asUser } = await member(3_000)
    await t.run(async (ctx) => {
      await ctx.db.insert("rewardRedemptions", { wallet: WALLET.toLowerCase(), points: 1000, bps: 2, startsAt: 1, endsAt: Date.now() - 1 })
      await ctx.db.insert("rewardTotals", { wallet: "0xdead", questPoints: 0, feePoints: 0, questIds: [], updatedAt: 0 })
    })
    expect(await t.run((ctx) => discountBpsOf(ctx, WALLET, Date.now()))).toBe(3)
    await asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 2 })
    expect(await t.run((ctx) => discountBpsOf(ctx, WALLET, Date.now()))).toBe(3 + 4)
    expect(await t.run((ctx) => discountBpsOf(ctx, WALLET, Date.now() + 31 * DAY))).toBe(3)
    expect(await t.run((ctx) => discountBpsOf(ctx, OTHER, Date.now()))).toBe(0)
  })

  test("follows the rules set in feeConfig", async () => {
    const { t, asUser } = await member(10_000)
    const fee = { enabled: true, defaultBps: 10, actionBps: {}, exemptActions: [], maxFeeUsd: null }
    await t.mutation(internal.frontendFee.setConfig, { ...fee, redemption: { pointsPerStep: 500, bpsPerStep: 1, days: 7, maxBps: 2 } })
    const r = await asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 2 })
    expect(r).toMatchObject({ points: 1000, bps: 2 })
    expect(r.endsAt - Date.now()).toBeLessThanOrEqual(7 * DAY)
    await expect(asUser.mutation(api.wallet.redemptions.redeem, { wallet: WALLET, steps: 1 })).rejects.toThrow(/REDEMPTION_CAP/)
    await expect(t.mutation(internal.frontendFee.setConfig, { ...fee, redemption: { pointsPerStep: 500, bpsPerStep: 1, days: 7, maxBps: 30 } })).rejects.toThrow()
  })
})
