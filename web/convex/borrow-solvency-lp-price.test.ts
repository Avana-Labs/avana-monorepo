// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")

const WALLET = "0xAbC0000000000000000000000000000000000034"
const POOL = "test-lp-price-pool"

/**
 * Regression for the LP-token-price solvency bug: a normally seeded deployment never
 * writes the `pools` table, so assertBorrowSolvent revalues an engine pledge (an
 * 18-decimal LP-TOKEN amount) using the pool MARKET's priceUsd. That price must be the
 * real LP token price (seeded via poolLpTokenPriceUsd), not a nominal $1 — otherwise a
 * few-token, multi-thousand-dollar pledge values at a few dollars and every ordinary
 * borrow is rejected as undercollateralized.
 */
async function seedPoolMarket(t: ReturnType<typeof convexTest>, priceUsd: number | undefined) {
  await t.run(async (ctx) => {
    // NOTE: deliberately NO `pools` row — this is the normal deployment shape.
    await ctx.db.insert("markets", {
      scope: "pool",
      slug: POOL,
      chainId: 1,
      name: "ETH / USDC",
      symbol: "WETH/USDC",
      ...(priceUsd === undefined ? {} : { priceUsd }),
      createdAt: 0,
    })
    if (priceUsd !== undefined) {
      await ctx.db.insert("walletBorrowBalances", {
        wallet: WALLET.toLowerCase(),
        marketId: POOL,
        poolId: POOL,
        symbol: "WETH/USDC",
        amount: 2.5,
        valueUsd: 2000,
        state: "collateral",
        updatedAt: 0,
      })
    }
  })
}

/** A pledge held as `tokens` LP tokens (18-decimal), backing `debtUsd` of borrow. */
function borrowAgainstLpTokens(tokens: string, debtUsd6: string, intentId: string) {
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
      collateral: [
        {
          marketSlug: POOL,
          collateralShares: tokens,
          principalTokenAmount: tokens,
          collateralEnabled: true,
        },
      ],
    },
  }
}

// 2.5 LP tokens (18-decimal). At the seeded $800/token that is $2,000 of collateral; at
// the old nominal $1/token it would be $2.50, so the two prices diverge by ~800×.
const TWO_AND_A_HALF_LP_TOKENS = "2500000000000000000"

describe("assertBorrowSolvent — LP token price for engine pledges", () => {
  test("values an 18-decimal LP pledge at the seeded market LP price (would reject at nominal $1)", async () => {
    const t = convexTest(schema, modules)
    await seedPoolMarket(t, 800)
    const asUser = t.withIdentity({ subject: WALLET })
    // $2,000 collateral × 85% fallback LT = $1,700 liquidation value. Debt $1,500 is solvent
    // ($1,500 ≤ $1,700). Under the old $1/token price the collateral was ~$2.50 → rejected.
    const res = await asUser.mutation(
      api.sandbox.transactions.recordTransaction,
      borrowAgainstLpTokens(TWO_AND_A_HALF_LP_TOKENS, "1500000000", "lp1"),
    )
    expect(res.receipt.status).toBe("success")
  })

  test("still rejects a genuinely underwater borrow at the real LP price", async () => {
    const t = convexTest(schema, modules)
    await seedPoolMarket(t, 800)
    const asUser = t.withIdentity({ subject: WALLET })
    // Debt $1,800 > $1,700 liquidation value → HF < 1 → rejected even at the real price.
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowAgainstLpTokens(TWO_AND_A_HALF_LP_TOKENS, "1800000000", "lp2"),
      ),
    ).rejects.toThrow(/undercollateralized|health factor/i)
  })

  test("rejects when neither a pool nor a market price can value the LP pledge", async () => {
    const t = convexTest(schema, modules)
    await seedPoolMarket(t, undefined)
    const asUser = t.withIdentity({ subject: WALLET })
    await expect(
      asUser.mutation(
        api.sandbox.transactions.recordTransaction,
        borrowAgainstLpTokens(TWO_AND_A_HALF_LP_TOKENS, "1500000000", "lp3"),
      ),
    ).rejects.toThrow(/no server-verifiable value/i)
  })
})
