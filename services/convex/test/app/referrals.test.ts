// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Referrals: one code per wallet, one attribution per new wallet, credit to the owner at attribution and when three
// invited wallets are active.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "../../convex/_generated/api"
import { noteFirstSeen } from "../../convex/lib/membership"
import { activateReferral, isReferralCode, newReferralCode } from "../../convex/lib/referrals"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const OWNER = "0xAbC0000000000000000000000000000000000001"
const A = "0xAbC0000000000000000000000000000000000002"
const B = "0xAbC0000000000000000000000000000000000003"
const C = "0xAbC0000000000000000000000000000000000004"
const DAY = 86_400_000

const asWallet = (t: ReturnType<typeof convexTest>, wallet: string) => t.withIdentity({ subject: wallet })

async function ownerCode(t: ReturnType<typeof convexTest>) {
  return (await asWallet(t, OWNER).mutation(api.wallet.referrals.myCode, { wallet: OWNER })).code
}

describe("referral codes", () => {
  test("are 8 characters without look-alikes", () => {
    for (let i = 0; i < 50; i++) expect(isReferralCode(newReferralCode())).toBe(true)
    expect(isReferralCode("ABCD2345")).toBe(false)
    expect(isReferralCode("abcd2340")).toBe(false)
    expect(isReferralCode("abcd234")).toBe(false)
  })

  test("a wallet keeps one code, and each wallet's code differs", async () => {
    const t = convexTest(schema, modules)
    const code = await ownerCode(t)
    expect(await ownerCode(t)).toBe(code)
    const other = (await asWallet(t, A).mutation(api.wallet.referrals.myCode, { wallet: A })).code
    expect(other).not.toBe(code)
    await expect(t.mutation(api.wallet.referrals.myCode, { wallet: OWNER })).rejects.toThrow(/UNAUTHENTICATED/)
    await expect(asWallet(t, A).mutation(api.wallet.referrals.myCode, { wallet: OWNER })).rejects.toThrow(/WALLET_MISMATCH/)
  })
})

describe("attribution", () => {
  test("attributes a new wallet once and credits the owner's first invite once", async () => {
    const t = convexTest(schema, modules)
    const code = await ownerCode(t)
    expect(await asWallet(t, A).mutation(api.wallet.referrals.attribute, { wallet: A, code })).toEqual({ result: "attributed" })
    expect(await asWallet(t, A).mutation(api.wallet.referrals.attribute, { wallet: A, code })).toEqual({ result: "already" })
    expect(await asWallet(t, B).mutation(api.wallet.referrals.attribute, { wallet: B, code: code.toUpperCase() })).toEqual({ result: "attributed" })
    expect(await t.query(api.wallet.rewards.summary, { wallet: OWNER })).toMatchObject({ questPoints: 40, completedQuests: ["invite-first-wallet"] })
    expect(await asWallet(t, OWNER).query(api.wallet.referrals.summary, { wallet: OWNER })).toEqual({ code, invited: 2, active: 0 })
  })

  test("refuses the owner's own code, an unknown code, a malformed code and a wallet that is not new", async () => {
    const t = convexTest(schema, modules)
    const code = await ownerCode(t)
    expect(await asWallet(t, OWNER).mutation(api.wallet.referrals.attribute, { wallet: OWNER, code })).toEqual({ result: "self" })
    expect(await asWallet(t, A).mutation(api.wallet.referrals.attribute, { wallet: A, code: "abcdefgh" })).toEqual({ result: "unknown_code" })
    await expect(asWallet(t, A).mutation(api.wallet.referrals.attribute, { wallet: A, code: "x" })).rejects.toThrow(/INVALID_REFERRAL/)
    await t.run(async (ctx) => {
      await noteFirstSeen(ctx, B, Date.now() - 3 * DAY, "onchain")
      await noteFirstSeen(ctx, C, Date.now() - 1_000, "onchain")
    })
    expect(await asWallet(t, B).mutation(api.wallet.referrals.attribute, { wallet: B, code })).toEqual({ result: "not_new" })
    expect(await asWallet(t, C).mutation(api.wallet.referrals.attribute, { wallet: C, code })).toEqual({ result: "attributed" })
    expect(await t.query(api.wallet.rewards.summary, { wallet: OWNER })).toMatchObject({ questPoints: 40 })
  })
})

describe("activation", () => {
  test("three invited wallets that act earn the owner the third quest, once", async () => {
    const t = convexTest(schema, modules)
    const code = await ownerCode(t)
    for (const w of [A, B, C]) await asWallet(t, w).mutation(api.wallet.referrals.attribute, { wallet: w, code })
    await t.run(async (ctx) => {
      await activateReferral(ctx, A, { log: "AaveSpoke.Withdraw" }, 1_000)
      await activateReferral(ctx, OWNER, { log: "AaveAdapter.Borrowed" }, 1_000)
      await activateReferral(ctx, A, { log: "AaveAdapter.Borrowed" }, 2_000)
      await activateReferral(ctx, A, { log: "AaveAdapter.Borrowed" }, 3_000)
      await activateReferral(ctx, B, { intent: "supply" }, 4_000)
    })
    expect(await asWallet(t, OWNER).query(api.wallet.referrals.summary, { wallet: OWNER })).toMatchObject({ invited: 3, active: 2 })
    expect((await t.query(api.wallet.rewards.summary, { wallet: OWNER })).completedQuests).toEqual(["invite-first-wallet"])
    await t.run(async (ctx) => {
      await activateReferral(ctx, C, { log: "AaveAdapter.CollateralAdded" }, 5_000)
      await activateReferral(ctx, C, { log: "AaveAdapter.CollateralAdded" }, 6_000)
    })
    expect(await t.query(api.wallet.rewards.summary, { wallet: OWNER })).toMatchObject({
      questPoints: 190,
      completedQuests: ["invite-first-wallet", "bring-3-active-users"],
    })
  })
})
