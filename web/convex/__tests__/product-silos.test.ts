// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api, internal } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

describe("product-siloed borrow detail tables", () => {
  test("getRiskParameters / getInterestRateModel / getLiquidationRisk / getPoolBorrowables", async () => {
    const t = convexTest(schema, modules)

    await t.mutation(internal.borrow.riskParameters.upsertRiskParameters, {
      rows: [
        {
          slug: "uni-v3-bluechip-weth-usdc",
          kind: "pool",
          parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "78.00%" }],
          updatedAt: 1,
          source: "seed",
        },
      ],
    })

    await t.mutation(internal.borrow.interestRateModel.upsertInterestRateModels, {
      rows: [
        {
          slug: "uni-v2:usdc",
          optimalUtilizationPct: 80,
          slopeBelowOptimalPct: 3.8,
          slopeAboveOptimalPct: 51,
          baseBorrowRatePct: 2.19,
          updatedAt: 1,
          source: "seed",
        },
      ],
    })

    await t.mutation(internal.borrow.liquidationRisk.upsertLiquidationDaily, {
      rows: [
        {
          slug: "uni-v3-bluechip-weth-usdc",
          day: "2026-08-10",
          liquidationsCount: 10,
          collateralSeizedUsd: 1_000_000,
          debtRepaidUsd: 900_000,
          liquidationBonusUsd: 50_000,
          collateralAtRiskUsd: 9_000_000,
          walletsAtRisk: 45,
          walletsEligibleForLiquidation: 8,
          badDebtUsd: 1500,
          walletsWithBadDebt: 3,
        },
        {
          slug: "uni-v3-bluechip-weth-usdc",
          day: "2026-08-11",
          liquidationsCount: 12,
          collateralSeizedUsd: 1_500_000,
          debtRepaidUsd: 1_400_000,
          liquidationBonusUsd: 75_000,
          collateralAtRiskUsd: 8_000_000,
          walletsAtRisk: 40,
          walletsEligibleForLiquidation: 6,
          badDebtUsd: 1200,
          walletsWithBadDebt: 2,
        },
      ],
    })

    await t.mutation(internal.borrow.poolBorrowables.upsertPoolBorrowables, {
      rows: [
        {
          poolSlug: "uni-v3-bluechip-weth-usdc",
          assetSlug: "uni-v3-bluechip:usdc",
          name: "USD Coin",
          symbol: "USDC",
          borrowAprPct: 4.2,
        },
      ],
    })

    // Lend/multiply tables stay empty — prove borrow reads do not depend on them.
    const risk = await t.query(api.borrow.riskParameters.getRiskParameters, {
      slug: "uni-v3-bluechip-weth-usdc",
    })
    expect(risk?.parameters[0]?.value).toBe("78.00%")

    const irm = await t.query(api.borrow.interestRateModel.getInterestRateModel, { slug: "uni-v2:usdc" })
    expect(irm?.optimalUtilizationPct).toBe(80)
    expect(irm?.slopeAboveOptimalPct).toBe(51)

    const liq = await t.query(api.borrow.liquidationRisk.getLiquidationRisk, {
      slug: "uni-v3-bluechip-weth-usdc",
    })
    expect(liq?.day).toBe("2026-08-11")
    expect(liq?.stats.find((s) => s.id === "liquidations")?.deltaValue).toBe(2)
    expect(liq?.stats.find((s) => s.id === "collateralAtRisk")?.deltaValue).toBe(-1_000_000)

    const borrowables = await t.query(api.borrow.poolBorrowables.getPoolBorrowables, {
      poolSlug: "uni-v3-bluechip-weth-usdc",
    })
    expect(borrowables).toEqual([{ id: "uni-v3-bluechip:usdc", name: "USD Coin", symbol: "USDC", borrowAprPct: 4.2 }])

    const lendRisk = await t.query(api.lend.riskParameters.getRiskParameters, { slug: "uni-v3-bluechip-weth-usdc" })
    expect(lendRisk).toBeNull()
  })

  test("lend risk parameters and IRM are product-siloed", async () => {
    const t = convexTest(schema, modules)

    await t.mutation(internal.lend.riskParameters.upsertRiskParameters, {
      rows: [
        {
          slug: "usdc",
          parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "80.00%" }],
          updatedAt: 1,
          source: "seed",
        },
      ],
    })
    await t.mutation(internal.lend.interestRateModel.upsertInterestRateModels, {
      rows: [
        {
          slug: "usdc",
          optimalUtilizationPct: 85,
          slopeBelowOptimalPct: 4,
          slopeAboveOptimalPct: 55,
          baseBorrowRatePct: 1.2,
          updatedAt: 1,
          source: "seed",
        },
      ],
    })

    const risk = await t.query(api.lend.riskParameters.getRiskParameters, { slug: "usdc" })
    expect(risk?.parameters[0]?.value).toBe("80.00%")

    const irm = await t.query(api.lend.interestRateModel.getInterestRateModel, { slug: "usdc" })
    expect(irm?.optimalUtilizationPct).toBe(85)

    const borrowIrm = await t.query(api.borrow.interestRateModel.getInterestRateModel, { slug: "usdc" })
    expect(borrowIrm).toBeNull()
  })

  test("market content is product-siloed (borrow/lend/multiply)", async () => {
    const t = convexTest(schema, modules)
    const faqs = [{ question: "Q?", answer: "A." }]

    await t.mutation(internal.borrow.content.upsertContent, {
      rows: [
        {
          slug: "uni-v2:usdc",
          kind: "asset",
          description: "Borrow about",
          stats: [],
          history: [],
          faqs,
        },
      ],
    })
    await t.mutation(internal.lend.content.upsertContent, {
      rows: [{ slug: "usdc", description: "Lend about", stats: [], history: [], faqs }],
    })
    await t.mutation(internal.multiply.content.upsertContent, {
      rows: [{ slug: "aave-gho", description: "Multiply about", stats: [], history: [], faqs }],
    })

    expect((await t.query(api.borrow.content.getContent, { slug: "uni-v2:usdc" }))?.description).toBe("Borrow about")
    expect((await t.query(api.lend.content.getContent, { slug: "usdc" }))?.description).toBe("Lend about")
    expect((await t.query(api.multiply.content.getContent, { slug: "aave-gho" }))?.description).toBe("Multiply about")

    // Cross-product reads miss — silos do not share rows.
    expect(await t.query(api.borrow.content.getContent, { slug: "usdc" })).toBeNull()
    expect(await t.query(api.lend.content.getContent, { slug: "uni-v2:usdc" })).toBeNull()
    expect(await t.query(api.multiply.content.getContent, { slug: "usdc" })).toBeNull()
  })

  test("risk assessments are product-siloed (borrow/lend/multiply)", async () => {
    const t = convexTest(schema, modules)
    const base = {
      assessedAt: 1,
      premiumBps: 120,
      level: "moderate" as const,
      score: 55,
      headline: "Moderate risk",
      summary: "Summary",
      breakdown: [{ id: "liquidity", label: "Liquidity", bps: 40, level: "moderate" as const, description: "d" }],
      metrics: [{ id: "util", label: "Utilization", value: "70%" }],
    }

    await t.mutation(internal.borrow.riskAssessment.upsertRiskAssessments, {
      rows: [{ slug: "uni-v2:usdc", kind: "asset", ...base, headline: "Borrow risk" }],
    })
    await t.mutation(internal.lend.riskAssessment.upsertRiskAssessments, {
      rows: [{ slug: "usdc", ...base, headline: "Lend risk" }],
    })
    await t.mutation(internal.multiply.riskAssessment.upsertRiskAssessments, {
      rows: [{ slug: "aave-gho", ...base, headline: "Multiply risk" }],
    })

    expect((await t.query(api.borrow.riskAssessment.getRisk, { slug: "uni-v2:usdc" }))?.headline).toBe("Borrow risk")
    expect((await t.query(api.lend.riskAssessment.getRisk, { slug: "usdc" }))?.headline).toBe("Lend risk")
    expect((await t.query(api.multiply.riskAssessment.getRisk, { slug: "aave-gho" }))?.headline).toBe("Multiply risk")

    expect(await t.query(api.borrow.riskAssessment.getRisk, { slug: "usdc" })).toBeNull()
    expect(await t.query(api.lend.riskAssessment.getRisk, { slug: "uni-v2:usdc" })).toBeNull()
    expect(await t.query(api.multiply.riskAssessment.getRisk, { slug: "usdc" })).toBeNull()
  })

  test("revenue daily is product-siloed (borrow/lend/multiply)", async () => {
    const t = convexTest(schema, modules)
    const amounts = {
      day: "2026-08-01",
      interestFromBorrowersUsd: 100,
      interestToSuppliersUsd: 80,
      reserveTakeUsd: 20,
      rewardsDistributedUsd: 5,
      swapFeesUsd: 10,
    }

    await t.mutation(internal.borrow.cashflow.upsertRevenueDaily, {
      rows: [{ slug: "uni-v2:usdc", kind: "asset", ...amounts }],
    })
    await t.mutation(internal.lend.cashflow.upsertRevenueDaily, {
      rows: [{ slug: "usdc", ...amounts, interestFromBorrowersUsd: 50 }],
    })
    await t.mutation(internal.multiply.cashflow.upsertRevenueDaily, {
      rows: [{ slug: "aave-gho", ...amounts, interestFromBorrowersUsd: 25 }],
    })

    const borrow = await t.query(api.borrow.cashflow.getBreakdownForAsset, { slug: "uni-v2:usdc" })
    const lend = await t.query(api.lend.cashflow.getBreakdown, { slug: "usdc" })
    const multiply = await t.query(api.multiply.cashflow.getBreakdown, { slug: "aave-gho" })
    expect(borrow).not.toBeNull()
    expect(lend).not.toBeNull()
    expect(multiply).not.toBeNull()

    expect(await t.query(api.borrow.cashflow.getBreakdownForAsset, { slug: "usdc" })).toBeNull()
    expect(await t.query(api.lend.cashflow.getBreakdown, { slug: "uni-v2:usdc" })).toBeNull()
    expect(await t.query(api.multiply.cashflow.getBreakdown, { slug: "usdc" })).toBeNull()
  })

  test("daily stats are product-siloed (borrow/lend/multiply)", async () => {
    const t = convexTest(schema, modules)
    const amounts = {
      day: "2026-08-11",
      suppliedUsd: 1_000_000,
      borrowedUsd: 700_000,
      utilizationPct: 70,
      supplyApyPct: 3,
      borrowAprPct: 5,
      tvlUsd: 1_000_000,
      volumeUsd: 0,
      feesUsd: 10,
    }

    await t.mutation(internal.borrow.dailyStats.upsertDailyStats, {
      rows: [{ slug: "uni-v2:usdc", kind: "asset", ...amounts }],
    })
    await t.mutation(internal.lend.dailyStats.upsertDailyStats, {
      rows: [{ slug: "usdc", ...amounts, utilizationPct: 55 }],
    })
    await t.mutation(internal.multiply.dailyStats.upsertDailyStats, {
      rows: [{ slug: "aave-gho", ...amounts, utilizationPct: 40 }],
    })

    expect((await t.query(api.borrow.dailyStats.getLatestStats, { slug: "uni-v2:usdc" }))?.utilizationPct).toBe(70)
    expect((await t.query(api.lend.dailyStats.getLatestStats, { slug: "usdc" }))?.utilizationPct).toBe(55)
    expect((await t.query(api.multiply.dailyStats.getLatestStats, { slug: "aave-gho" }))?.utilizationPct).toBe(40)

    expect(await t.query(api.borrow.dailyStats.getLatestStats, { slug: "usdc" })).toBeNull()
    expect(await t.query(api.lend.dailyStats.getLatestStats, { slug: "uni-v2:usdc" })).toBeNull()
    expect(await t.query(api.multiply.dailyStats.getLatestStats, { slug: "usdc" })).toBeNull()
  })

  test("getQuickStats prefers siloed daily stats without markets row", async () => {
    const t = convexTest(schema, modules)
    // getQuickStats reads a "1W" window (Date.now() - 7d), so the seed days must be
    // derived relative to now — hardcoded dates silently expire out of the window.
    // The later day carries the 45% tip the assertions below expect.
    const isoDaysAgo = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10)
    await t.mutation(internal.borrow.dailyStats.upsertDailyStats, {
      rows: [
        {
          slug: "uni-v2:usdc",
          kind: "asset",
          day: isoDaysAgo(3),
          suppliedUsd: 100,
          borrowedUsd: 40,
          utilizationPct: 40,
          supplyApyPct: 2,
          borrowAprPct: 4,
          tvlUsd: 100,
          volumeUsd: 0,
          feesUsd: 0,
        },
        {
          slug: "uni-v2:usdc",
          kind: "asset",
          day: isoDaysAgo(2),
          suppliedUsd: 100,
          borrowedUsd: 45,
          utilizationPct: 45,
          supplyApyPct: 2.1,
          borrowAprPct: 4.2,
          tvlUsd: 100,
          volumeUsd: 0,
          feesUsd: 0,
        },
      ],
    })

    const stats = await t.query(api.markets.getQuickStats, { scope: "asset", slug: "uni-v2:usdc" })
    // Utilization is recomputed from live tip (+ delta), not the stored tip pct.
    expect(stats?.find((s) => s.id === "utilization")?.value).toBe("45.00%")
    expect(stats?.find((s) => s.id === "borrowApy")?.value).toBe("4.20%")
  })

  test("product market identity is siloed", async () => {
    const t = convexTest(schema, modules)
    await t.mutation(internal.borrow.markets.upsertMarkets, {
      rows: [
        {
          slug: "uni-v2:usdc",
          kind: "asset",
          chainId: 1,
          name: "USD Coin",
          symbol: "USDC",
          createdAt: 1,
        },
      ],
    })
    await t.mutation(internal.lend.markets.upsertMarkets, {
      rows: [{ slug: "usdc", chainId: 1, name: "USDC Lend", symbol: "USDC", createdAt: 1 }],
    })

    expect((await t.query(api.borrow.markets.getMarket, { slug: "uni-v2:usdc" }))?.name).toBe("USD Coin")
    expect((await t.query(api.lend.markets.getMarket, { slug: "usdc" }))?.name).toBe("USDC Lend")
    expect(await t.query(api.borrow.markets.getMarket, { slug: "usdc" })).toBeNull()
    expect(await t.query(api.lend.markets.getMarket, { slug: "uni-v2:usdc" })).toBeNull()
  })
})
