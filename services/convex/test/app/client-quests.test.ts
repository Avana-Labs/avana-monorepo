// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Client quests: recorded by the signed-in wallet only, from a fixed list, once each.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "../../convex/_generated/api"
import { CLIENT_QUEST_POINTS } from "../../convex/lib/clientQuests"
import { QUEST_POINTS } from "../../convex/lib/rewards"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xAbC0000000000000000000000000000000000002"

describe("client quests", () => {
  test("have their own points, apart from the action quests", () => {
    expect(Object.keys(CLIENT_QUEST_POINTS).sort()).toEqual([
      "connect-wallet",
      "favorite-lend-market",
      "favorite-market",
      "review-risk-basics",
      "share-referral-link",
    ])
    for (const id of Object.keys(CLIENT_QUEST_POINTS)) expect(QUEST_POINTS[id]).toBeUndefined()
  })

  test("the signed-in wallet earns the points once, however often it records the quest", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    expect(await asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "review-risk-basics" })).toEqual({ awarded: true })
    expect(await asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "review-risk-basics" })).toEqual({ awarded: false })
    await asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "connect-wallet" })
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({
      questPoints: 40,
      earnedPoints: 40,
      completedQuests: ["review-risk-basics", "connect-wallet"],
    })
  })

  test("refuses a call without a session, for another wallet, or for a quest that is not a client quest", async () => {
    const t = convexTest(schema, modules)
    await expect(t.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "connect-wallet" })).rejects.toThrow(/UNAUTHENTICATED/)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(asUser.mutation(api.wallet.clientQuests.record, { wallet: OTHER, questId: "connect-wallet" })).rejects.toThrow(/WALLET_MISMATCH/)
    await expect(asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "first-borrow" })).rejects.toThrow(/INVALID_QUEST/)
    await expect(asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "toString" })).rejects.toThrow(/INVALID_QUEST/)
    // Pin quests are earned by pinning a market, not by a bare call.
    await expect(asUser.mutation(api.wallet.clientQuests.record, { wallet: WALLET, questId: "favorite-market" })).rejects.toThrow(/INVALID_QUEST/)
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ earnedPoints: 0, completedQuests: [] })
  })
})
