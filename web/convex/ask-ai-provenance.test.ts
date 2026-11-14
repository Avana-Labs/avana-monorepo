// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { api } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")

// A non-guest subject is treated as an authed wallet (getAuthedWallet lowercases
// the subject); an "ask-guest:*" subject resolves to no wallet.
const WALLET = "0x00000000000000000000000000000000000000aa"
const GUEST = "ask-guest:provenance"

async function seedOwnedPosition(t: ReturnType<typeof convexTest>) {
  const positionId = await t.run((ctx) =>
    ctx.db.insert("positions", {
      wallet: WALLET,
      product: "multiply",
      marketSlug: "eth-usdc",
      assetId: "ETH",
      status: "open",
      collateralValueUsd: 10_000,
      debtValueUsd: 3_500,
      ltv: 0.35,
      healthFactor: 1.857,
      openedAt: 1,
      lastUpdatedAt: 2,
    }),
  )
  await t.run(async (ctx) => {
    await ctx.db.insert("borrowMarkets", {
      slug: "eth-usdc",
      kind: "pool",
      chainId: 1,
      name: "ETH / USDC",
      symbol: "ETH/USDC",
      maxLtvPct: 55,
      createdAt: 1,
    })
    await ctx.db.insert("markets", {
      scope: "pool",
      slug: "eth-usdc",
      chainId: 1,
      name: "ETH / USDC",
      symbol: "ETH/USDC",
      constituents: [{ symbol: "ETH", weight: 1 }],
      createdAt: 1,
    })
    await ctx.db.insert("multiplyTokenParameters", {
      symbol: "ETH",
      supplyApyPct: 3,
      borrowAprPct: 5,
      availableUsd: 1_000_000,
      collateralFactorPct: 55,
      liquidationThresholdPct: 65,
      iconUrl: "/eth.svg",
      updatedAt: 1,
    })
  })
  return positionId
}

// Provenance contract: every Ask AI financial reader that returns figures must
// stamp `dataProvenance` on its success branch (see ASK_AI_DATA_PROVENANCE in
// convex/askAITools.ts), so the UI can never render a number without its
// origin. Guests get `walletRequired` and NO figures / provenance at all.
describe("Ask AI financial-reader data provenance", () => {
  test("every reader stamps dataProvenance on the success branch", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seedOwnedPosition(t)
    const asWallet = t.withIdentity({ subject: WALLET })

    await expect(asWallet.query(api.askAITools.portfolio, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(asWallet.query(api.askAITools.engineSnapshot, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(asWallet.query(api.askAITools.borrowCapacity, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(asWallet.query(api.askAITools.positionRisk, {})).resolves.toMatchObject({
      walletRequired: false,
      dataProvenance: "sandbox",
    })
    await expect(
      asWallet.query(api.askAITools.simulateBorrow, {
        positionId,
        additionalBorrowAmount: 1_000,
        borrowAsset: "USDC",
      }),
    ).resolves.toMatchObject({ walletRequired: false, dataProvenance: "sandbox" })
    await expect(
      asWallet.query(api.askAITools.stressPosition, {
        positionId,
        assetPriceChanges: [{ symbol: "ETH", change: -0.2 }],
      }),
    ).resolves.toMatchObject({ walletRequired: false, dataProvenance: "sandbox" })
  })

  test("guests get walletRequired with no figures and no provenance", async () => {
    const t = convexTest(schema, modules)
    const asGuest = t.withIdentity({ subject: GUEST })

    for (const reader of ["portfolio", "engineSnapshot", "borrowCapacity", "positionRisk"] as const) {
      const result = (await asGuest.query(api.askAITools[reader], {})) as Record<string, unknown>
      expect(result.walletRequired).toBe(true)
      // A wallet-required response must not leak a provenance stamp or figures.
      expect(result.dataProvenance).toBeUndefined()
      expect(result.totals).toBeUndefined()
      expect(result.simulation).toBeUndefined()
    }
  })
})
