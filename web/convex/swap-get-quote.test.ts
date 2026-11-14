// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

const modules = import.meta.glob("./**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"

async function seedPrices(t: ReturnType<typeof convexTest>) {
  await t.run(async (ctx) => {
    const now = Date.now()
    await ctx.db.insert("tokenPrices", {
      symbol: "eth",
      llamaId: "coingecko:ethereum",
      priceUsd: 2000,
      source: "test",
      updatedAt: now,
    })
    await ctx.db.insert("tokenPrices", {
      symbol: "usdc",
      llamaId: "coingecko:usd-coin",
      priceUsd: 1,
      source: "test",
      updatedAt: now,
    })
  })
}

describe("sandbox.swap.getQuote", () => {
  test("computes an authoritative quote from the live oracle prices", async () => {
    const t = convexTest(schema, modules)
    await seedPrices(t)
    const asUser = t.withIdentity({ subject: WALLET })
    const quote = await asUser.query(api.sandbox.swap.getQuote, {
      wallet: WALLET,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
      slippageBps: 50,
    })
    expect(quote.status).toBe("valid")
    // 1 ETH @ $2000 → gross 2000 USDC, minus 0.30% fee and 1.5% impact ($2000 tier).
    // 2000 × (1 − 0.003 − 0.015) = 1964. minOutput = 1964 × (1 − 0.005) = 1954.18.
    expect(quote.estimatedOutputAmount).toBeCloseTo(1964, 6)
    expect(quote.minimumOutputAmount).toBeCloseTo(1954.18, 4)
    expect(quote.route).toEqual(["ETH", "USDC"])
  })

  test("rejects an LP / unsupported pair", async () => {
    const t = convexTest(schema, modules)
    await seedPrices(t)
    const asUser = t.withIdentity({ subject: WALLET })
    const quote = await asUser.query(api.sandbox.swap.getQuote, {
      wallet: WALLET,
      inputAssetId: "eth-usdc-lp",
      outputAssetId: "usdc",
      inputAmount: 1,
    })
    expect(quote.status).toBe("unsupported")
    expect((quote as { rejectionReason?: string }).rejectionReason).toBe("ineligible_lp_token")
  })

  test("returns error when a leg is unpriced (no oracle, no held price)", async () => {
    const t = convexTest(schema, modules)
    // Only seed ETH; USDC has no price anywhere.
    await t.run(async (ctx) => {
      await ctx.db.insert("tokenPrices", {
        symbol: "eth",
        llamaId: "coingecko:ethereum",
        priceUsd: 2000,
        source: "test",
        updatedAt: Date.now(),
      })
    })
    const asUser = t.withIdentity({ subject: WALLET })
    const quote = await asUser.query(api.sandbox.swap.getQuote, {
      wallet: WALLET,
      inputAssetId: "eth",
      outputAssetId: "usdc",
      inputAmount: 1,
    })
    expect(quote.status).toBe("error")
  })
})
