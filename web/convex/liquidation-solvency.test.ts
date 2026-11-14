// @vitest-environment edge-runtime
//
// P1-2 regression: `recordLiquidation` must recompute the victim's health factor
// SERVER-SIDE (from stored collateral/debt + the pool oracle) rather than trusting
// the client-supplied `healthFactorWadBefore`. A solvent victim can never be
// liquidated, and an underwater victim's repay/seize are capped by a real close
// factor × liquidation bonus.
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "./schema"
import { api } from "./_generated/api"

// Rooted at the convex directory so convex-test can resolve "sandbox/*".
const modules = import.meta.glob("./**/*.*s")

const VICTIM = "0xAbC0000000000000000000000000000000000001"
const KEEPER = "0xDdD0000000000000000000000000000000000002"
const MARKET = "uni-v3-bluechip-weth-usdc"

/**
 * Seed a borrow position for the victim with `collateralUsd6` of collateral and
 * `debtUsd6` of debt (both usd6 microdollar strings). No pool row → the 85%
 * fallback liquidation threshold applies.
 */
async function seedVictim(t: ReturnType<typeof convexTest>, collateralUsd6: string, debtUsd6: string) {
  return await t.run(async (ctx) => {
    await ctx.db.insert("tokenPrices", {
      symbol: "usdc",
      llamaId: "coingecko:usd-coin",
      priceUsd: 1,
      source: "test",
      confidence: 1,
      fetchedAt: Date.now(),
      updatedAt: Date.now(),
    })
    await ctx.db.insert("walletLiquidBalances", {
      wallet: KEEPER.toLowerCase(),
      assetId: "usdc",
      symbol: "USDC",
      amount: 10_000,
      valueUsd: 10_000,
      state: "available",
      updatedAt: Date.now(),
    })
    await ctx.db.insert("markets", {
      scope: "pool",
      slug: MARKET,
      chainId: 1,
      name: "Test LP",
      symbol: "TEST-LP",
      priceUsd: 1,
      createdAt: Date.now(),
    })
    const positionId = await ctx.db.insert("positions", {
      wallet: VICTIM.toLowerCase(),
      product: "borrow",
      marketSlug: MARKET,
      status: "open",
      collateralValueUsd6: collateralUsd6,
      debtValueUsd6: debtUsd6,
      openedAt: 1,
      lastUpdatedAt: 1,
    })
    await ctx.db.insert("positionCollateral", {
      wallet: VICTIM.toLowerCase(),
      positionId,
      marketSlug: MARKET,
      collateralShares: collateralUsd6,
      principalTokenAmount: collateralUsd6,
      collateralEnabled: true,
      collateralValueUsd6: collateralUsd6,
      updatedAt: 1,
    })
    const debtPositionId = await ctx.db.insert("positionDebt", {
      wallet: VICTIM.toLowerCase(),
      positionId,
      assetId: "uni-v2:usdc",
      baseAssetId: "usdc",
      debtSharesUsd6: debtUsd6,
      debtIndexRay: "1000000000000000000000000000",
      borrowRateWad: "50000000000000000",
      principalBorrowedUsd6: debtUsd6,
      updatedAt: 1,
    })
    return { positionId, debtPositionId }
  })
}

describe("recordLiquidation — server-side solvency gate (P1-2)", () => {
  test("rejects oversized fixed-point input before BigInt parsing", async () => {
    const t = convexTest(schema, modules)
    const ids = await seedVictim(t, "2000000000", "2000000000")
    await expect(
      t.withIdentity({ subject: KEEPER }).mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: VICTIM,
        liquidatorWallet: KEEPER,
        intentId: "oversized-liquidation",
        positionId: ids.positionId,
        debtPositionId: ids.debtPositionId,
        marketSlug: MARKET,
        repaidUsd6: "9".repeat(100_000),
        seizedCollateralUsd6: "1",
        healthFactorWadBefore: "0",
        healthFactorWadAfter: "0",
      }),
    ).rejects.toThrow(/positive usd6 integer/)
  })

  test("rejects liquidating a SOLVENT victim even when the client claims HF=0", async () => {
    const t = convexTest(schema, modules)
    // $2000 collateral @ 85% LT = $1700 > $1000 debt → HF ≈ 1.7, solvent.
    const ids = await seedVictim(t, "2000000000", "1000000000")
    const asKeeper = t.withIdentity({ subject: KEEPER })
    await expect(
      asKeeper.mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: VICTIM,
        liquidatorWallet: KEEPER,
        intentId: "solvent-rejected",
        positionId: ids.positionId,
        debtPositionId: ids.debtPositionId,
        marketSlug: MARKET,
        repaidUsd6: "500000000",
        seizedCollateralUsd6: "550000000",
        // Spoofed: client claims deeply underwater. Server must ignore it.
        healthFactorWadBefore: "0",
        healthFactorWadAfter: "0",
      }),
    ).rejects.toThrow(/not underwater/)

    // Nothing was seized: the victim's debt/collateral are untouched.
    const after = await t.run(async (ctx) => ctx.db.get(ids.positionId))
    expect(after?.debtValueUsd6).toBe("1000000000")
    expect(after?.collateralValueUsd6).toBe("2000000000")
  })

  test("allows liquidating a genuinely UNDERWATER victim and seizes within the cap", async () => {
    const t = convexTest(schema, modules)
    // $2000 collateral @ 85% LT = $1700 < $2000 debt → underwater.
    const ids = await seedVictim(t, "2000000000", "2000000000")
    const asKeeper = t.withIdentity({ subject: KEEPER })
    const intent = {
      wallet: VICTIM,
      liquidatorWallet: KEEPER,
      intentId: "underwater-success",
      positionId: ids.positionId,
      debtPositionId: ids.debtPositionId,
      marketSlug: MARKET,
      repaidUsd6: "500000000", // 25% of $2000 debt → within the 50% close factor.
      seizedCollateralUsd6: "550000000", // repay × 1.10 default bonus → exactly the cap.
      liquidationBonusBps: 1000,
      healthFactorWadBefore: "850000000000000000",
      healthFactorWadAfter: "900000000000000000",
    } as const
    const first = await asKeeper.mutation(api.sandbox.liquidation.recordLiquidation, intent)
    const replay = await asKeeper.mutation(api.sandbox.liquidation.recordLiquidation, intent)
    expect(first.idempotent).toBe(false)
    expect(replay).toMatchObject({ id: first.id, hash: first.hash, idempotent: true })
    const state = await t.run(async (ctx) => ({
      position: await ctx.db.get(ids.positionId),
      debt: await ctx.db.get(ids.debtPositionId),
      keeperLiquid: await ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", KEEPER.toLowerCase()))
        .unique(),
      keeperCollateral: await ctx.db
        .query("walletBorrowBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", KEEPER.toLowerCase()))
        .unique(),
      actions: await ctx.db.query("liquidationActions").collect(),
    }))
    expect(state.position?.debtValueUsd6).toBe("1500000000")
    expect(state.position?.collateralValueUsd6).toBe("1450000000")
    expect(state.debt?.principalBorrowedUsd6).toBe("1500000000")
    expect(state.keeperLiquid).toMatchObject({ amount: 9500, valueUsd: 9500 })
    expect(state.keeperCollateral).toMatchObject({ marketId: MARKET, amount: 550, valueUsd: 550 })
    expect(state.actions).toHaveLength(1)
  })

  test("rejects an underwater liquidation the keeper cannot fund", async () => {
    const t = convexTest(schema, modules)
    const ids = await seedVictim(t, "2000000000", "2000000000")
    await t.run(async (ctx) => {
      const balance = await ctx.db
        .query("walletLiquidBalances")
        .withIndex("by_wallet", (q) => q.eq("wallet", KEEPER.toLowerCase()))
        .unique()
      await ctx.db.patch(balance!._id, { amount: 1, valueUsd: 1 })
    })
    await expect(
      t.withIdentity({ subject: KEEPER }).mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: VICTIM,
        liquidatorWallet: KEEPER,
        intentId: "unfunded-keeper",
        positionId: ids.positionId,
        debtPositionId: ids.debtPositionId,
        marketSlug: MARKET,
        repaidUsd6: "500000000",
        seizedCollateralUsd6: "550000000",
        healthFactorWadBefore: "850000000000000000",
        healthFactorWadAfter: "900000000000000000",
      }),
    ).rejects.toThrow(/INSUFFICIENT_LIQUIDATOR_BALANCE/)
    const unchanged = await t.run(async (ctx) => ctx.db.get(ids.positionId))
    expect(unchanged).toMatchObject({ collateralValueUsd6: "2000000000", debtValueUsd6: "2000000000" })
  })

  test("rejects a repay above the 50% close factor", async () => {
    const t = convexTest(schema, modules)
    const ids = await seedVictim(t, "2000000000", "2000000000")
    const asKeeper = t.withIdentity({ subject: KEEPER })
    await expect(
      asKeeper.mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: VICTIM,
        liquidatorWallet: KEEPER,
        intentId: "close-factor-rejected",
        positionId: ids.positionId,
        debtPositionId: ids.debtPositionId,
        marketSlug: MARKET,
        repaidUsd6: "1500000000", // 75% of debt > 50% close factor.
        seizedCollateralUsd6: "1600000000",
        healthFactorWadBefore: "850000000000000000",
        healthFactorWadAfter: "900000000000000000",
      }),
    ).rejects.toThrow(/close factor/)
  })

  test("rejects seizing more than repay × (1 + bonus)", async () => {
    const t = convexTest(schema, modules)
    const ids = await seedVictim(t, "2000000000", "2000000000")
    const asKeeper = t.withIdentity({ subject: KEEPER })
    await expect(
      asKeeper.mutation(api.sandbox.liquidation.recordLiquidation, {
        wallet: VICTIM,
        liquidatorWallet: KEEPER,
        intentId: "bonus-rejected",
        positionId: ids.positionId,
        debtPositionId: ids.debtPositionId,
        marketSlug: MARKET,
        repaidUsd6: "500000000",
        seizedCollateralUsd6: "900000000", // 1.8× repay > 1.10 cap (default bonus).
        healthFactorWadBefore: "850000000000000000",
        healthFactorWadAfter: "900000000000000000",
      }),
    ).rejects.toThrow(/bonus cap/)
  })
})
