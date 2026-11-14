// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000012"
const POOL = "test-solvency-pool"

/** Seed a pool with a max-LTV (collateral factor) but NO explicit liquidation threshold, so
 *  the server must derive one — the exact case #12 is about. maxLtv 76.5% → LT 86.5%. */
async function seedPool(t: ReturnType<typeof convexTest>, overrides: Record<string, unknown> = {}) {
  await t.run(async (ctx) => {
    await ctx.db.insert("pools", {
      slug: POOL,
      name: "Test Pool",
      venue: "Uniswap v3",
      category: "v3",
      visuals: [
        { symbol: "WETH", shortLabel: "WETH", bgClassName: "", textClassName: "" },
        { symbol: "USDC", shortLabel: "USDC", bgClassName: "", textClassName: "" },
      ],
      maxLtvPct: 76.5,
      pairAprPct: 4,
      createdAt: 0,
      ...overrides,
    })
    await ctx.db.insert("walletBorrowBalances", {
      wallet: WALLET.toLowerCase(),
      marketId: POOL,
      poolId: POOL,
      symbol: "WETH/USDC",
      amount: 1000,
      valueUsd: 1000,
      state: "collateral",
      updatedAt: 0,
    })
  })
}

function borrowWithDebt(debtUsd6: string, intentId: string) {
  return {
    wallet: WALLET,
    intentId,
    product: "borrow" as const,
    kind: "borrow",
    marketSlug: POOL,
    assetId: "usdc",
    requestedAmountUsd6: debtUsd6,
    executedAmountUsd6: debtUsd6,
    amountUsd: Number(BigInt(debtUsd6)) / 1_000_000,
    simulated: true,
    position: {
      status: "open" as const,
      marketSlug: POOL,
      debtValueUsd6: debtUsd6,
      // usd6 collateral (raw < 1e12) → server values it at $1,000 without needing an LP price,
      // isolating the liquidation-THRESHOLD behavior under test.
      collateral: [
        {
          marketSlug: POOL,
          collateralShares: "1000000000",
          principalTokenAmount: "1000000000",
          collateralEnabled: true,
        },
      ],
    },
  }
}

describe("assertBorrowSolvent — preview↔persist parity (#12)", () => {
  test("accepts a borrow solvent at the real liquidation threshold (would reject under the old CF fallback)", async () => {
    const t = convexTest(schema, modules)
    await seedPool(t)
    const asUser = t.withIdentity({ subject: WALLET })
    // $1,000 collateral, maxLtv 76.5% → LT 86.5% → liquidation value $865.
    // Debt $820: solvent at LT ($820 ≤ $865) but "underwater" at the old CF fallback ($820 > $765).
    const res = await asUser.mutation(api.sandbox.transactions.recordTransaction, borrowWithDebt("820000000", "p1"))
    expect(res.receipt.status).toBe("success")
  })

  test("still rejects a genuinely underwater borrow (debt above the liquidation value)", async () => {
    const t = convexTest(schema, modules)
    await seedPool(t)
    const asUser = t.withIdentity({ subject: WALLET })
    // Debt $900 > $865 liquidation value → HF < 1 → rejected.
    await expect(
      asUser.mutation(api.sandbox.transactions.recordTransaction, borrowWithDebt("900000000", "p2")),
    ).rejects.toThrow(/undercollateralized|health factor/i)
  })

  test("honors an explicit pool liquidationThresholdPct when present", async () => {
    const t = convexTest(schema, modules)
    await seedPool(t, { liquidationThresholdPct: 90 })
    const asUser = t.withIdentity({ subject: WALLET })
    // LT 90% → liquidation value $900; debt $880 accepted.
    const res = await asUser.mutation(api.sandbox.transactions.recordTransaction, borrowWithDebt("880000000", "p3"))
    expect(res.receipt.status).toBe("success")
  })
})
