// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Pinning a market: a real market page, once per wallet, completing the quest of its kind once.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { fixtureHubAsset, fixtureMarkets } from "@avana/services-common/fixtures"
import { api } from "../../convex/_generated/api"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0xAbC0000000000000000000000000000000000002"

async function seeded() {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("hubAssets", { ...fixtureHubAsset, slug: "ethereum-usdc", updatedAt: 0, lendReserves: [...fixtureHubAsset.lendReserves] })
    await ctx.db.insert("markets", { ...fixtureMarkets[0]!, slug: "ethereum-usdc-usdt", updatedAt: 0 } as never)
  })
  return t
}

describe("pinned markets", () => {
  test("pins a pool and a Lend asset, awarding each quest once and storing each pin once", async () => {
    const t = await seeded()
    const asUser = t.withIdentity({ subject: WALLET })
    expect(await asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "pool", slug: "ethereum-usdc-usdt" })).toEqual({ pinned: true, awarded: true })
    expect(await asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "pool", slug: "ethereum-usdc-usdt" })).toEqual({ pinned: false, awarded: false })
    expect(await asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "lend", slug: "ethereum-usdc" })).toEqual({ pinned: true, awarded: true })
    expect((await asUser.query(api.wallet.pinnedMarkets.list, { wallet: WALLET })).map((p) => p.slug).sort()).toEqual(["ethereum-usdc", "ethereum-usdc-usdt"])
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ questPoints: 40, completedQuests: ["favorite-market", "favorite-lend-market"] })
  })

  test("refuses an unknown market, a bad slug, another wallet or no session", async () => {
    const t = await seeded()
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "pool", slug: "nope" })).rejects.toThrow(/INVALID_PIN/)
    await expect(asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "lend", slug: "ethereum-usdc-usdt" })).rejects.toThrow(/INVALID_PIN/)
    await expect(asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "pool", slug: "" })).rejects.toThrow(/INVALID_PIN/)
    await expect(asUser.mutation(api.wallet.pinnedMarkets.pin, { wallet: OTHER, scope: "pool", slug: "ethereum-usdc-usdt" })).rejects.toThrow(/WALLET_MISMATCH/)
    await expect(t.mutation(api.wallet.pinnedMarkets.pin, { wallet: WALLET, scope: "pool", slug: "ethereum-usdc-usdt" })).rejects.toThrow(/UNAUTHENTICATED/)
    await expect(t.query(api.wallet.pinnedMarkets.list, { wallet: WALLET })).rejects.toThrow(/UNAUTHENTICATED/)
  })
})
