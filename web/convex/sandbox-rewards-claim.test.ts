// @vitest-environment edge-runtime
//
// Wave-4 F guardrail: `recordRewardsClaim` is server-authoritative. The mutation
// derives the payout from the on-server quest catalog and refuses to trust the
// client's `amountUsd`, so an inflated or forged claim can't be persisted. This
// suite pins down: (1) catalog-derived amount, (2) unknown-task rejection,
// (3) durable single-claim guard across intent ids.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

const WALLET = "0x0000000000000000000000000000000000000abc"

async function seedRewardEvents(t: ReturnType<typeof convexTest>, types: string[]) {
  await t.run(async (ctx) => {
    await ctx.db.insert("sandboxRewards", {
      wallet: WALLET,
      stateJson: JSON.stringify({
        events: types.map((type, index) => ({ id: `event-${index}`, wallet: WALLET, type })),
        claims: [],
      }),
      updatedAt: 1,
      revision: 0,
    })
  })
}

describe("recordRewardsClaim — server-authoritative payout", () => {
  test("payout is derived from the on-server catalog, not the client", async () => {
    const t = convexTest(schema, modules)
    await seedRewardEvents(t, ["education_completed"])
    const asUser = t.withIdentity({ subject: WALLET })

    // connect-wallet = 25 AVA, review-risk-basics = 15 AVA → 40 AVA at 1:1 USD.
    const result = await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:1",
      taskIds: ["connect-wallet", "review-risk-basics"],
      syntheticTxHash: "0xdeadbeef1",
    })
    expect(result.idempotent).toBe(false)
    expect(result.amountUsd).toBe(40)

    // The persisted transaction matches the derived amount, not any client input.
    const rows = await t.run(async (ctx) => await ctx.db.query("transactions").collect())
    const rewardRow = rows.find((r) => r.intentId === "rewards:test:1")
    expect(rewardRow?.amountUsd).toBe(40)
    expect(rewardRow?.claimedTaskIds).toEqual(["connect-wallet", "review-risk-basics"])
  })

  test("forged unknown task ids are rejected", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:forged",
        taskIds: ["totally-made-up-task"],
        syntheticTxHash: "0xdeadbeef2",
      }),
    ).rejects.toThrow(/UNKNOWN_TASK_ID/)

    const rows = await t.run(async (ctx) => await ctx.db.query("transactions").collect())
    expect(rows.filter((r) => r.product === "rewards")).toHaveLength(0)
  })

  test("rejects oversized identifiers and claim arrays before reads or writes", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "x".repeat(100_000),
        taskIds: ["connect-wallet"],
        syntheticTxHash: "0xhash",
      }),
    ).rejects.toThrow(/intentId must contain 1 to 200 characters/)
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:too-many",
        taskIds: Array.from({ length: 33 }, (_, index) => `task-${index}`),
        syntheticTxHash: "0xhash",
      }),
    ).rejects.toThrow(/at most 32 task ids/)

    const rows = await t.run(async (ctx) => await ctx.db.query("transactions").collect())
    expect(rows).toHaveLength(0)
  })

  test("rejects an active financial quest without a matching server transaction", async () => {
    const t = convexTest(schema, modules)
    await expect(
      t.withIdentity({ subject: WALLET }).mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:not-eligible",
        taskIds: ["first-borrow"],
        syntheticTxHash: "0xnoteligible",
      }),
    ).rejects.toThrow(/TASK_NOT_ELIGIBLE/)
  })

  test("claiming an already-paid task on a fresh intent id is rejected", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:first",
      taskIds: ["connect-wallet"],
      syntheticTxHash: "0xhash1",
    })

    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:double-dip",
        taskIds: ["connect-wallet"],
        syntheticTxHash: "0xhash2",
      }),
    ).rejects.toThrow(/TASK_ALREADY_CLAIMED/)
  })

  test("empty taskIds are rejected", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:empty",
        taskIds: [],
        syntheticTxHash: "0xhash-empty",
      }),
    ).rejects.toThrow(/EMPTY_CLAIM/)
  })

  test("rejects retired tasks that remain in the historical payout catalog", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:retired",
        taskIds: ["create-profile"],
        syntheticTxHash: "0xhash-retired",
      }),
    ).rejects.toThrow(/INACTIVE_TASK_ID/)
  })

  test("rejects a duplicated task id inside one claim", async () => {
    const t = convexTest(schema, modules)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
        wallet: WALLET,
        intentId: "rewards:test:duplicate",
        taskIds: ["connect-wallet", "connect-wallet"],
        syntheticTxHash: "0xhash-duplicate",
      }),
    ).rejects.toThrow(/DUPLICATE_TASK_ID/)
  })

  test("per-task hashes write one row per quest for a claim-all", async () => {
    const t = convexTest(schema, modules)
    await seedRewardEvents(t, ["education_completed"])
    const asUser = t.withIdentity({ subject: WALLET })

    // connect-wallet = 25 AVA, review-risk-basics = 15 AVA.
    const result = await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:claim-all",
      taskIds: ["connect-wallet", "review-risk-basics"],
      syntheticTxHash: "0xrewardsconnect",
      syntheticTxHashes: ["0xrewardsconnect", "0xrewardsreview"],
    })
    expect(result.idempotent).toBe(false)
    expect(result.amountUsd).toBe(40) // summed total, unchanged contract

    const rows = await t.run(async (ctx) =>
      (await ctx.db.query("transactions").collect()).filter((r) => r.intentId === "rewards:test:claim-all"),
    )
    // One row per quest, each with a single task id, catalog-derived amount, and
    // its own synthetic receipt hash (the payout is never trusted from the client).
    expect(rows).toHaveLength(2)
    expect(rows.map((r) => r.amountUsd).sort((a, b) => a - b)).toEqual([15, 25])
    expect(rows.every((r) => r.claimedTaskIds?.length === 1)).toBe(true)
    expect(rows.map((r) => r.syntheticTxHash).sort()).toEqual(["0xrewardsconnect", "0xrewardsreview"])
  })

  test("mismatched per-task hash length falls back to the legacy summed row", async () => {
    const t = convexTest(schema, modules)
    await seedRewardEvents(t, ["education_completed"])
    const asUser = t.withIdentity({ subject: WALLET })

    await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:mismatch",
      taskIds: ["connect-wallet", "review-risk-basics"],
      syntheticTxHash: "0xrewardssummed",
      syntheticTxHashes: ["0xonly-one"], // length 1 ≠ 2 tasks → legacy path
    })

    const rows = await t.run(async (ctx) =>
      (await ctx.db.query("transactions").collect()).filter((r) => r.intentId === "rewards:test:mismatch"),
    )
    expect(rows).toHaveLength(1)
    expect(rows[0]?.amountUsd).toBe(40)
    expect(rows[0]?.claimedTaskIds).toEqual(["connect-wallet", "review-risk-basics"])
  })

  test("prior intent id still short-circuits idempotently", async () => {
    const t = convexTest(schema, modules)
    await seedRewardEvents(t, ["market_favorited"])
    const asUser = t.withIdentity({ subject: WALLET })

    const first = await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:idem",
      taskIds: ["favorite-market"],
      syntheticTxHash: "0xhash-idem",
    })
    const second = await asUser.mutation(api.sandbox.transactions.recordRewardsClaim, {
      wallet: WALLET,
      intentId: "rewards:test:idem",
      taskIds: ["favorite-market"],
      syntheticTxHash: "0xhash-idem",
    })
    expect(second.idempotent).toBe(true)
    expect(second.transactionId).toEqual(first.transactionId)
  })
})
