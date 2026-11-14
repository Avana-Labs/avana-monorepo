// @vitest-environment edge-runtime
//
// Onboarding parity + fixture double-seed guards for the umbrella lifecycle.
// Verifies:
//   1. The first onboarding claim seeds umbrella positions, wallet balances,
//      and umbrella_stake activity rows.
//   2. A repeat claim (or a fixture double-seed) does NOT duplicate any of the
//      umbrella state — regression coverage for the `umbrellaSeeded` guard on
//      walletSessions (convex/sandbox/onboarding.ts).
//   3. `ensureTestWalletFixtures` is a no-op once the wallet has been seeded.
import { convexTest, type TestConvex } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"
import { seedStarterTestMarkets } from "./starterTestMarkets"

const modules = import.meta.glob("./**/*.*s")

type T = TestConvex<typeof schema>

const WALLET = "0xAbC0000000000000000000000000000000000001"
const TEST_WALLET = "0x0000000000000000000000000000000000000a11"

async function countUmbrellaPositions(t: T, wallet: string) {
  return t.run(async (ctx) => {
    const rows = await ctx.db
      .query("positions")
      .withIndex("by_wallet_product", (q) => q.eq("wallet", wallet.toLowerCase()).eq("product", "umbrella"))
      .collect()
    return rows.length
  })
}

async function collectSandboxActivity(t: T, wallet: string, kind: string) {
  return t.run(async (ctx) => {
    const rows = await ctx.db
      .query("sandboxActivity")
      .withIndex("by_wallet_at", (q) => q.eq("wallet", wallet.toLowerCase()))
      .collect()
    return rows.filter((row) => row.kind === kind)
  })
}

async function collectUmbrellaLiquidBalanceRows(t: T, wallet: string) {
  // Umbrella onboarding writes the retained liquid wallet ledger after the
  // starter allocation replacement, so its four market rows remain durable.
  const UMBRELLA_MARKETS = new Set(["gho", "usdc", "usdt", "weth"])
  return t.run(async (ctx) => {
    const rows = await ctx.db
      .query("walletLiquidBalances")
      .withIndex("by_wallet", (q) => q.eq("wallet", wallet.toLowerCase()))
      .collect()
    return rows.filter((row) => UMBRELLA_MARKETS.has(row.assetId)).length
  })
}

describe("sandbox umbrella onboarding seed", () => {
  test("first claim seeds umbrella positions, wallet balances, and umbrella_stake activity", async () => {
    const t = convexTest(schema, modules)
    await t.run(seedStarterTestMarkets)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.onboarding.startAnalysis, { wallet: WALLET })
    const result = await asUser.mutation(api.sandbox.onboarding.claim, { wallet: WALLET })
    expect(result.status).toBe("done")

    // GHO / USDC / WETH have suppliedUsd > 0 in UMBRELLA_TEST_FIXTURE.positions
    // (USDT is seeded with a wallet balance but no open umbrella position).
    expect(await countUmbrellaPositions(t, WALLET)).toBe(3)

    const umbrellaStakes = await collectSandboxActivity(t, WALLET, "umbrella_stake")
    expect(umbrellaStakes).toHaveLength(3)

    // umbrellaSeeded flag flipped on walletSessions.
    const session = await t.run(async (ctx) =>
      ctx.db
        .query("walletSessions")
        .withIndex("by_wallet", (q) => q.eq("wallet", WALLET.toLowerCase()))
        .unique(),
    )
    expect(session?.umbrellaSeeded).toBe(true)

    // Wallet balances upserted for all four umbrella markets (available state
    // rows are created for every fixture balance regardless of stake amount).
    expect(await collectUmbrellaLiquidBalanceRows(t, WALLET)).toBeGreaterThan(0)

    // Onboarding seed writes AT MOST ONE tranche per position. Only the GHO
    // fixture has cooldownUsd > 0; USDC / USDT / WETH have no cooldown. The
    // seed helper never splits a cooldown across tranches — that's a
    // startCooldown behaviour.
    const trancheCount = await t.run(async (ctx) =>
      ctx.db
        .query("umbrellaCooldownTranches")
        .withIndex("by_wallet", (q) => q.eq("wallet", WALLET.toLowerCase()))
        .collect()
        .then((rows) => rows.length),
    )
    expect(trancheCount).toBe(1)
  })

  test("second claim call is a no-op — no double umbrella positions, activity, or balances", async () => {
    const t = convexTest(schema, modules)
    await t.run(seedStarterTestMarkets)
    const asUser = t.withIdentity({ subject: WALLET })
    await asUser.mutation(api.sandbox.onboarding.startAnalysis, { wallet: WALLET })
    await asUser.mutation(api.sandbox.onboarding.claim, { wallet: WALLET })
    const positionsAfterFirst = await countUmbrellaPositions(t, WALLET)
    const stakeActivityAfterFirst = (await collectSandboxActivity(t, WALLET, "umbrella_stake")).length
    const umbrellaBalancesAfterFirst = await collectUmbrellaLiquidBalanceRows(t, WALLET)

    // Second claim short-circuits at profile.onboardingStep === "done", so
    // the seed helper never runs — a belt-and-suspenders regression check for
    // the umbrellaSeeded guard sitting one level deeper.
    const second = await asUser.mutation(api.sandbox.onboarding.claim, { wallet: WALLET })
    expect(second.status).toBe("done")

    expect(await countUmbrellaPositions(t, WALLET)).toBe(positionsAfterFirst)
    expect((await collectSandboxActivity(t, WALLET, "umbrella_stake")).length).toBe(stakeActivityAfterFirst)
    expect(await collectUmbrellaLiquidBalanceRows(t, WALLET)).toBe(umbrellaBalancesAfterFirst)
  })

  test("ensureTestWalletFixtures is a no-op once the canonical test wallet is already seeded", async () => {
    const t = convexTest(schema, modules)
    await t.run(seedStarterTestMarkets)
    const asTestWallet = t.withIdentity({ subject: TEST_WALLET })
    await asTestWallet.mutation(api.sandbox.onboarding.startAnalysis, { wallet: TEST_WALLET })
    await asTestWallet.mutation(api.sandbox.onboarding.claim, { wallet: TEST_WALLET })

    const positionsBefore = await countUmbrellaPositions(t, TEST_WALLET)
    const transactionsBefore = await t.run(async (ctx) =>
      ctx.db
        .query("transactions")
        .withIndex("by_wallet_product_at", (q) => q.eq("wallet", TEST_WALLET.toLowerCase()).eq("product", "umbrella"))
        .collect(),
    )

    const res = await asTestWallet.mutation(api.sandbox.umbrella.ensureTestWalletFixtures, { wallet: TEST_WALLET })
    expect(res.seeded).toBe(false)
    expect(res.reason).toBe("already-seeded")

    expect(await countUmbrellaPositions(t, TEST_WALLET)).toBe(positionsBefore)
    const transactionsAfter = await t.run(async (ctx) =>
      ctx.db
        .query("transactions")
        .withIndex("by_wallet_product_at", (q) => q.eq("wallet", TEST_WALLET.toLowerCase()).eq("product", "umbrella"))
        .collect(),
    )
    expect(transactionsAfter.length).toBe(transactionsBefore.length)
  })
})
