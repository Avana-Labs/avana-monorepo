// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000001"

function liquidityReader(t: ReturnType<typeof convexTest>) {
  return t.withIdentity({ subject: WALLET })
}

async function seedLiquidUsdc(t: ReturnType<typeof convexTest>, valueUsd = 5000) {
  await t.run(async (ctx) => {
    await ctx.db.insert("walletLiquidBalances", {
      wallet: WALLET.toLowerCase(),
      assetId: "usdc",
      symbol: "USDC",
      amount: valueUsd,
      valueUsd,
      state: "available",
      updatedAt: 1,
    })
  })
}

/**
 * H20 — wallet actions are idempotent across tabs and never alter protocol liquidity.
 *
 * The client "tabs" differ only in that each replays the SAME intentId; the intent is
 * the idempotency key, so the second call returns the existing row without re-applying
 * the ledger delta.
 */
describe("wallet actions do not alter protocol liquidity across tabs (H20)", () => {
  test("borrow: two tabs replaying one intent leave protocol liquidity unchanged", async () => {
    const t = convexTest(schema, modules)
    const tabA = t.withIdentity({ subject: WALLET })
    const tabB = t.withIdentity({ subject: WALLET })
    const intent = {
      wallet: WALLET,
      intentId: "borrow-shared-intent",
      product: "borrow" as const,
      kind: "borrow",
      marketSlug: "uni-v3-bluechip-weth-usdc",
      assetId: "uni-v2:usdc",
      requestedAmountUsd6: "1000000000",
      executedAmountUsd6: "1000000000",
      amountUsd: 1000,
    }
    const a = await tabA.mutation(api.sandbox.transactions.recordTransaction, intent)
    const b = await tabB.mutation(api.sandbox.transactions.recordTransaction, intent)
    expect(a.idempotent).toBe(false)
    expect(b.idempotent).toBe(true)

    const ledger = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(ledger).toEqual([])
  })

  test("supply: two tabs replaying one deposit leave protocol liquidity unchanged", async () => {
    const t = convexTest(schema, modules)
    await seedLiquidUsdc(t)
    const tabA = t.withIdentity({ subject: WALLET })
    const tabB = t.withIdentity({ subject: WALLET })
    const intent = {
      wallet: WALLET,
      intentId: "deposit-shared-intent",
      product: "lend" as const,
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open" as const, marketSlug: "usdc", suppliedUsd6: "500000000" },
    }
    await tabA.mutation(api.sandbox.transactions.recordTransaction, intent)
    await tabB.mutation(api.sandbox.transactions.recordTransaction, intent)

    const ledger = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(ledger).toEqual([])
  })

  test("multiply: two tabs replaying one open leave protocol liquidity unchanged", async () => {
    const t = convexTest(schema, modules)
    await t.run(async (ctx) => {
      await ctx.db.insert("walletLiquidBalances", {
        wallet: WALLET.toLowerCase(),
        assetId: "eth",
        symbol: "ETH",
        amount: 1,
        valueUsd: 1000,
        state: "available",
        updatedAt: 1,
      })
    })
    const tabA = t.withIdentity({ subject: WALLET })
    const tabB = t.withIdentity({ subject: WALLET })
    const intent = {
      wallet: WALLET,
      intentId: "multiply-shared-intent",
      product: "multiply" as const,
      kind: "multiply",
      marketSlug: "eth-usdt",
      requestedAmountUsd6: "3000000000",
      executedAmountUsd6: "3000000000",
      amountUsd: 3000,
      position: {
        status: "open" as const,
        marketSlug: "eth-usdt",
        assetId: "eth",
        collateralValueUsd: 3000,
        debtValueUsd: 2000, // equity 1000 → multiplier 3x (within ceiling)
        multiplier: 3,
        ltv: 2000 / 3000,
      },
    }
    await tabA.mutation(api.sandbox.transactions.recordTransaction, intent)
    await tabB.mutation(api.sandbox.transactions.recordTransaction, intent)

    const ledger = await liquidityReader(t).query(api.liquidity.listDeltas)
    expect(ledger).toEqual([])
  })
})

/**
 * Optimistic concurrency: two tabs each make a DIFFERENT change (distinct intentId) from
 * the SAME base revision. The first wins; the second — computed from a now-stale read —
 * must be rejected instead of silently clobbering the first (lost update).
 */
describe("optimistic concurrency — stale write is rejected (not a silent overwrite)", () => {
  test("existing positions reject revisionless updates", async () => {
    const t = convexTest(schema, modules)
    await seedLiquidUsdc(t)
    const tab = t.withIdentity({ subject: WALLET })
    await tab.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "revision-required-seed",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "500000000" },
    })

    await expect(
      tab.mutation(api.sandbox.transactions.recordTransaction, {
        wallet: WALLET,
        intentId: "revision-required-update",
        product: "lend",
        kind: "deposit",
        marketSlug: "usdc",
        requestedAmountUsd6: "100000000",
        executedAmountUsd6: "100000000",
        amountUsd: 100,
        position: { status: "open", marketSlug: "usdc", suppliedUsd6: "600000000" },
      }),
    ).rejects.toThrow(/REVISION_REQUIRED/)
  })

  test("lend: second tab writing from a stale revision is rejected, matching revision succeeds", async () => {
    const t = convexTest(schema, modules)
    await seedLiquidUsdc(t)
    const tab = t.withIdentity({ subject: WALLET })

    // Seed the position (first write → revision 0).
    await tab.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "cas-seed",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "500000000",
      executedAmountUsd6: "500000000",
      amountUsd: 500,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "500000000" },
    })

    const seeded = await tab.query(api.sandbox.transactions.getSessionState, { wallet: WALLET })
    const position = seeded.positions.find((p) => p.product === "lend" && p.marketSlug === "usdc")
    expect(position?.revision).toBe(0) // revision is exposed to clients

    // Tab A advances revision 0 → 1.
    await tab.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "cas-tabA",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "100000000",
      executedAmountUsd6: "100000000",
      amountUsd: 100,
      expectedRevision: 0,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "600000000" },
    })

    // Tab B still thinks it's on revision 0 → must be rejected, not applied.
    await expect(
      tab.mutation(api.sandbox.transactions.recordTransaction, {
        wallet: WALLET,
        intentId: "cas-tabB",
        product: "lend",
        kind: "deposit",
        marketSlug: "usdc",
        requestedAmountUsd6: "100000000",
        executedAmountUsd6: "100000000",
        amountUsd: 100,
        expectedRevision: 0,
        position: { status: "open", marketSlug: "usdc", suppliedUsd6: "600000000" },
      }),
    ).rejects.toThrow(/STALE_WRITE/)

    // Tab B re-reads (now revision 1) and its write succeeds.
    const reread = await tab.query(api.sandbox.transactions.getSessionState, { wallet: WALLET })
    const fresh = reread.positions.find((p) => p.product === "lend" && p.marketSlug === "usdc")
    expect(fresh?.revision).toBe(1)
    await tab.mutation(api.sandbox.transactions.recordTransaction, {
      wallet: WALLET,
      intentId: "cas-tabB2",
      product: "lend",
      kind: "deposit",
      marketSlug: "usdc",
      requestedAmountUsd6: "100000000",
      executedAmountUsd6: "100000000",
      amountUsd: 100,
      expectedRevision: 1,
      position: { status: "open", marketSlug: "usdc", suppliedUsd6: "700000000" },
    })

    const final = await tab.query(api.sandbox.transactions.getSessionState, { wallet: WALLET })
    const finalPosition = final.positions.find((p) => p.product === "lend" && p.marketSlug === "usdc")
    expect(finalPosition?.revision).toBe(2)
    expect(finalPosition?.suppliedUsd6).toBe("700000000") // tab A's write survived; not clobbered
  })
})
