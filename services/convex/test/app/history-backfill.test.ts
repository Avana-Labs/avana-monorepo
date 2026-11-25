// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The rewards' history backfill: what older records show (first block, first block of each quest, supply in USD) and
// what is recorded once per wallet and chain, without awarding anything twice.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import type { ExportRecord } from "@avana/services-common/export"
import { api, internal } from "../../convex/_generated/api"
import { NO_FACTS, addRecords } from "../../convex/lib/backfill"
import { awardQuestForLog, raiseSupplyVolume } from "../../convex/lib/rewards"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const OTHER = "0x00000000000000000000000000000000000000e2"
const SPOKE = `0x${"11".repeat(20)}`
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}`

const rec = (kind: string, block: number, args: Record<string, unknown>, address = SPOKE): ExportRecord =>
  ({ key: `1:${H(block)}:${kind}`, kind, blockNumber: String(block), blockHash: H(block), txHash: H(block), logIndex: 0, address, args }) as ExportRecord

const price = (spoke: string, reserveId: string) => (spoke === SPOKE && reserveId === "3" ? { decimals: 6, priceUsd8: "100000000" } : null)

describe("older records", () => {
  test("finds the first block, the first block of each quest and the wallet's own supply in USD", () => {
    const records = [
      rec("AaveSpoke.Supply", 900, { user: WALLET, reserveId: "3", suppliedAmount: "200000000" }),
      rec("AaveAdapter.Borrowed", 800, { wallet: WALLET }),
      rec("AaveSpoke.Supply", 700, { user: WALLET, reserveId: "3", suppliedAmount: "400000000" }),
      rec("AaveSpoke.Supply", 650, { user: OTHER, reserveId: "3", suppliedAmount: "999000000" }),
      rec("AaveSpoke.Supply", 640, { user: WALLET, reserveId: "9", suppliedAmount: "5" }),
      rec("AaveAdapter.Repaid", 600, { borrower: WALLET }),
      rec("AaveAdapter.UserProxyCreated", 500, { wallet: WALLET }),
    ]
    const facts = addRecords(NO_FACTS, records, WALLET, price)
    expect(facts.firstBlock).toBe(500n)
    expect(facts.questBlocks).toEqual({ "first-lend-deposit": 640n, "first-borrow": 800n, "first-repay": 600n })
    expect(facts.supplyUsd).toBe(600)
  })

  test("adds page after page, keeping the earliest blocks, and is empty without records", () => {
    const first = addRecords(NO_FACTS, [rec("AaveAdapter.Borrowed", 800, { wallet: WALLET })], WALLET, price)
    const second = addRecords(first, [rec("AaveAdapter.Borrowed", 300, { wallet: WALLET })], WALLET, price)
    expect(second).toMatchObject({ firstBlock: 300n, questBlocks: { "first-borrow": 300n } })
    expect(addRecords(NO_FACTS, [], WALLET, price)).toEqual(NO_FACTS)
  })
})

const finishArgs = (over: Record<string, unknown> = {}) => ({
  wallet: WALLET,
  chainId: 1,
  truncated: false,
  firstAtMs: 1_000_000,
  quests: [{ questId: "first-borrow", atMs: 2_000_000 }],
  supplyUsd: 0,
  ...over,
})

describe("recording the history", () => {
  test("notes the first interaction and awards the quests, once per wallet and chain", async () => {
    const t = convexTest(schema, modules)
    expect(await t.mutation(internal.wallet.backfillStore.finish, finishArgs())).toBe(true)
    expect(await t.mutation(internal.wallet.backfillStore.finish, finishArgs({ quests: [{ questId: "first-repay", atMs: 1 }] }))).toBe(false)
    expect(await t.query(api.wallet.membership.get, { wallet: WALLET })).toMatchObject({ sinceMs: 1_000_000, source: "onchain" })
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ questPoints: 50, completedQuests: ["first-borrow"] })
  })

  test("a quest a live log already awarded is not awarded again", async () => {
    const t = convexTest(schema, modules)
    await t.run((ctx) => awardQuestForLog(ctx, WALLET, "AaveAdapter.Borrowed", 5_000))
    await t.mutation(internal.wallet.backfillStore.finish, finishArgs())
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ questPoints: 50 })
  })

  test("a truncated walk dates nothing and ignores an unknown quest, but still awards what it saw", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.wallet.backfillStore.finish, finishArgs({ truncated: true, quests: [{ questId: "first-borrow", atMs: 9 }, { questId: "nope", atMs: 9 }] }))
    expect(await t.query(api.wallet.membership.get, { wallet: WALLET })).toBeNull()
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ questPoints: 50, completedQuests: ["first-borrow"] })
  })

  test("the supply total rises to the history's and never counts the live supply twice", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("rewardTotals", { wallet: WALLET.toLowerCase(), questPoints: 0, feePoints: 0, questIds: [], supplyUsd: 300, updatedAt: 0 })
      await raiseSupplyVolume(ctx, WALLET, 300, 1)
    })
    expect((await t.query(api.wallet.rewards.summary, { wallet: WALLET })).completedQuests).toEqual([])
    await t.mutation(internal.wallet.backfillStore.finish, finishArgs({ quests: [], supplyUsd: 650 }))
    const totals = await t.run((ctx) => ctx.db.query("rewardTotals").collect())
    expect(totals[0]).toMatchObject({ supplyUsd: 650, questIds: ["supply-500-lend"] })
  })

  test("the summary says the history is checked only once every served chain was read", async () => {
    const t = convexTest(schema, modules)
    expect((await t.query(api.wallet.rewards.summary, { wallet: WALLET })).historyChecked).toBe(true)
    await t.run(async (ctx) => {
      await ctx.db.insert("deployments", { chainId: 1, chainSlug: "ethereum", hubs: [], lendSpokes: [], cdpSpokes: [], firstLossReserves: [], explorerUrl: "", nativeUsdFeed: SPOKE, release: "r" })
    })
    expect((await t.query(api.wallet.rewards.summary, { wallet: WALLET })).historyChecked).toBe(false)
    await t.mutation(internal.wallet.backfillStore.finish, finishArgs({ quests: [] }))
    expect((await t.query(api.wallet.rewards.summary, { wallet: WALLET })).historyChecked).toBe(true)
  })
})
