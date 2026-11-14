// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

const LEND = "usdc"
const MULTIPLY = "eth-usdt"
const POOL = "uni-v3-bluechip-weth-usdc"
const ASSET = "uni-v3-bluechip:usdc"
const DAY = new Date().toISOString().slice(0, 10)
const PREV_DAY = new Date(Date.now() - 86_400_000).toISOString().slice(0, 10)

const marketRow = (slug: string, name: string) => ({
  slug,
  chainId: 1,
  name,
  symbol: name.toUpperCase(),
  venueLabel: "Uniswap v3",
  category: "crypto" as const,
  reserveFactorPct: 10,
  rewardsApyPct: 1.5,
  maxLtvPct: 75,
  priceUsd: 1,
  resources: [{ label: "Docs", href: "https://example.com" }],
  createdAt: 1,
})

const contentRow = (slug: string) => ({
  slug,
  description: `About ${slug}`,
  stats: [{ label: "TVL", value: "$1M" }],
  history: [{ date: "2026-01-01", title: "Launched" }],
  faqs: [{ question: "What?", answer: "This." }],
})

const assessmentRow = (slug: string, premiumBps: number) => ({
  slug,
  assessedAt: 1,
  premiumBps,
  level: "moderate" as const,
  score: 55,
  headline: "Moderate",
  summary: "Summary",
  breakdown: [{ id: "oracle", label: "Oracle", bps: premiumBps, level: "low" as const, description: "d" }],
  metrics: [{ id: "tvl", label: "TVL", value: "$1M" }],
})

const parametersRow = (slug: string) => ({
  slug,
  parameters: [{ id: "collateralFactor", label: "Collateral factor", value: "78.00%" }],
  updatedAt: 1,
  source: "seed" as const,
})

const irmRow = (slug: string) => ({
  slug,
  optimalUtilizationPct: 80,
  slopeBelowOptimalPct: 3.8,
  slopeAboveOptimalPct: 51,
  baseBorrowRatePct: 2.19,
  updatedAt: 1,
  source: "seed" as const,
})

const dailyStatsRow = (slug: string, day: string, utilizationPct: number) => ({
  slug,
  day,
  suppliedUsd: 1_000_000,
  borrowedUsd: 600_000,
  utilizationPct,
  supplyApyPct: 3,
  borrowAprPct: 5,
  tvlUsd: 1_000_000,
  volumeUsd: 10_000,
  feesUsd: 100,
})

const liquidationRow = (slug: string, day: string, count: number) => ({
  slug,
  day,
  liquidationsCount: count,
  collateralSeizedUsd: 1_000_000 * count,
  debtRepaidUsd: 900_000,
  liquidationBonusUsd: 50_000,
  collateralAtRiskUsd: 9_000_000,
  walletsAtRisk: 45,
  walletsEligibleForLiquidation: 8,
  badDebtUsd: 1500,
  walletsWithBadDebt: 3,
})

const addressFields = {
  salt: "vault",
  address: "0x0000000000000000000000000000000000000001",
  label: "Vault",
  href: "https://etherscan.io/address/0x1",
  chain: "Ethereum",
  isSynthetic: true,
  updatedAt: 1,
}

const changelogRow = (product: "borrow" | "lend" | "multiply", slug: string) => ({
  product,
  slug,
  changes: [
    {
      id: `${slug}-1`,
      parameter: "LTV",
      previous: "70%",
      current: "75%",
      date: "2026-01-02",
      source: "governance",
      executor: "0xabc",
      category: "risk",
    },
  ],
  updatedAt: 1,
})

async function seedPopulatedDetailTables(t: ReturnType<typeof convexTest>) {
  await t.run(async (ctx) => {
    // Lend
    await ctx.db.insert("lendMarkets", marketRow(LEND, "usdc"))
    await ctx.db.insert("lendMarketContent", contentRow(LEND))
    await ctx.db.insert("lendRiskAssessments", assessmentRow(LEND, 40))
    await ctx.db.insert("lendRiskParameters", parametersRow(LEND))
    await ctx.db.insert("lendInterestRateModels", irmRow(LEND))
    await ctx.db.insert("lendDailyStats", dailyStatsRow(LEND, DAY, 61))
    await ctx.db.insert("lendContractAddresses", { marketSlug: LEND, ...addressFields })
    await ctx.db.insert("parameterChanges", changelogRow("lend", LEND))

    // Multiply
    await ctx.db.insert("multiplyMarkets", marketRow(MULTIPLY, "eth"))
    await ctx.db.insert("multiplyMarketContent", contentRow(MULTIPLY))
    await ctx.db.insert("multiplyRiskAssessments", assessmentRow(MULTIPLY, 55))
    await ctx.db.insert("multiplyRiskParameters", parametersRow(MULTIPLY))
    await ctx.db.insert("multiplyLiquidationDaily", liquidationRow(MULTIPLY, PREV_DAY, 3))
    await ctx.db.insert("multiplyLiquidationDaily", liquidationRow(MULTIPLY, DAY, 5))
    await ctx.db.insert("multiplyContractAddresses", { marketSlug: MULTIPLY, ...addressFields })
    await ctx.db.insert("parameterChanges", changelogRow("multiply", MULTIPLY))

    // Borrow pool
    await ctx.db.insert("borrowMarkets", { ...marketRow(POOL, "weth-usdc"), kind: "pool" })
    await ctx.db.insert("borrowMarketContent", { ...contentRow(POOL), kind: "pool" })
    await ctx.db.insert("borrowRiskAssessments", { ...assessmentRow(POOL, 70), kind: "pool" })
    await ctx.db.insert("borrowRiskParameters", { ...parametersRow(POOL), kind: "pool" })
    await ctx.db.insert("borrowLiquidationDaily", liquidationRow(POOL, PREV_DAY, 10))
    await ctx.db.insert("borrowLiquidationDaily", liquidationRow(POOL, DAY, 12))
    await ctx.db.insert("borrowPoolBorrowables", {
      poolSlug: POOL,
      assetSlug: ASSET,
      name: "USD Coin",
      symbol: "USDC",
      borrowAprPct: 4.2,
    })
    await ctx.db.insert("borrowPoolBorrowables", {
      poolSlug: POOL,
      assetSlug: "uni-v3-bluechip:dai",
      name: "Dai",
      symbol: "DAI",
      borrowAprPct: 4.8,
    })
    await ctx.db.insert("poolContractAddresses", { poolSlug: POOL, ...addressFields })
    await ctx.db.insert("parameterChanges", changelogRow("borrow", POOL))

    // Borrow asset (legacy IRM fallback + allocation both read the legacy `markets` hub)
    await ctx.db.insert("borrowMarkets", { ...marketRow(ASSET, "usdc"), kind: "asset" })
    await ctx.db.insert("borrowMarketContent", { ...contentRow(ASSET), kind: "asset" })
    await ctx.db.insert("borrowRiskAssessments", { ...assessmentRow(ASSET, 25), kind: "asset" })
    await ctx.db.insert("borrowRiskParameters", { ...parametersRow(ASSET), kind: "asset" })
    await ctx.db.insert("borrowInterestRateModels", irmRow(ASSET))
    await ctx.db.insert("assetContractAddresses", { assetSlug: ASSET, ...addressFields })
    const assetId = await ctx.db.insert("markets", { scope: "asset", ...marketRow(ASSET, "usdc") })
    const poolId = await ctx.db.insert("markets", { scope: "pool", ...marketRow(POOL, "weth-usdc") })
    const { slug: _slug, ...legacyStats } = dailyStatsRow(ASSET, DAY, 72)
    void _slug
    await ctx.db.insert("marketDailyStats", { marketId: assetId, ...legacyStats })
    await ctx.db.insert("assetPoolAllocationDaily", {
      assetId,
      poolId,
      day: DAY,
      valueUsd: 500_000,
      sharePct: 100,
      utilizationPct: 72,
      borrowAprPct: 5,
    })
  })
}

describe("batched detail hydration parity", () => {
  test("populated lend detail matches the per-section public queries", async () => {
    const t = convexTest(schema, modules)
    await seedPopulatedDetailTables(t)

    const batched = await t.query(api.detailHydration.getLendDetail, { slug: LEND })
    const expected = {
      snapshot: await t.query(api.markets.getMarketSnapshot, { scope: "lend", slug: LEND }),
      transactions: await t.query(api.markets.getRecentTransactions, { scope: "lend", slug: LEND }),
      risk: await t.query(api.lend.riskAssessment.getRisk, { slug: LEND }),
      content: await t.query(api.lend.content.getContent, { slug: LEND }),
      riskParameters: await t.query(api.lend.riskParameters.getRiskParameters, { slug: LEND }),
      interestRateModel: await t.query(api.lend.interestRateModel.getInterestRateModel, { slug: LEND }),
      siloedMarket: await t.query(api.lend.markets.getMarket, { slug: LEND }),
      contractAddresses: await t.query(api.contractAddresses.listLendAddresses, { marketSlug: LEND }),
      supplyBorrow: await t.query(api.markets.getLendSupplyBorrow, { slug: LEND }),
    }

    expect(batched).toEqual(expected)
    expect(batched.siloedMarket).not.toBeNull()
    expect(batched.content?.changelog.length).toBeGreaterThan(0)
    expect(batched.interestRateModel?.utilizationPct).toBe(61)
    expect(batched.interestRateModel?.borrowAprPct).toBeCloseTo(5.4)
    expect(batched.contractAddresses).toHaveLength(1)
  })

  test("populated multiply detail matches the per-section public queries", async () => {
    const t = convexTest(schema, modules)
    await seedPopulatedDetailTables(t)

    const batched = await t.query(api.detailHydration.getMultiplyDetail, { slug: MULTIPLY })
    const expected = {
      transactions: await t.query(api.markets.getRecentTransactions, { scope: "multiply", slug: MULTIPLY }),
      risk: await t.query(api.multiply.riskAssessment.getRisk, { slug: MULTIPLY }),
      content: await t.query(api.multiply.content.getContent, { slug: MULTIPLY }),
      riskParameters: await t.query(api.multiply.riskParameters.getRiskParameters, { slug: MULTIPLY }),
      liquidationRisk: await t.query(api.multiply.liquidationRisk.getLiquidationRisk, { slug: MULTIPLY }),
      siloedMarket: await t.query(api.multiply.markets.getMarket, { slug: MULTIPLY }),
      snapshot: await t.query(api.markets.getMarketSnapshot, { scope: "multiply", slug: MULTIPLY }),
      supplyBorrow: await t.query(api.markets.getMultiplySupplyBorrow, { slug: MULTIPLY }),
      contractAddresses: await t.query(api.contractAddresses.listMultiplyAddresses, { marketSlug: MULTIPLY }),
    }

    expect(batched).toEqual(expected)
    expect(batched.liquidationRisk?.stats[0]).toMatchObject({ id: "liquidations", value: "5", deltaValue: 2 })
    expect(batched.risk?.premiumBps).toBe(55)
  })

  test("populated borrow pool detail matches the per-section public queries", async () => {
    const t = convexTest(schema, modules)
    await seedPopulatedDetailTables(t)

    const batched = await t.query(api.detailHydration.getBorrowPoolDetail, { slug: POOL })
    const expected = {
      snapshot: await t.query(api.markets.getMarketSnapshot, { scope: "pool", slug: POOL }),
      transactions: await t.query(api.markets.getRecentTransactions, { scope: "pool", slug: POOL }),
      risk: await t.query(api.borrow.riskAssessment.getRisk, { slug: POOL }),
      content: await t.query(api.borrow.content.getContent, { slug: POOL }),
      riskParameters: await t.query(api.borrow.riskParameters.getRiskParameters, { slug: POOL }),
      poolBorrowables: await t.query(api.borrow.poolBorrowables.getPoolBorrowables, { poolSlug: POOL }),
      liquidationRisk: await t.query(api.borrow.liquidationRisk.getLiquidationRisk, { slug: POOL }),
      siloedMarket: await t.query(api.borrow.markets.getMarket, { slug: POOL }),
      contractAddresses: await t.query(api.contractAddresses.listPoolAddresses, { poolSlug: POOL }),
    }

    expect(batched).toEqual(expected)
    expect(batched.siloedMarket).toMatchObject({ kind: "pool", scope: "pool" })
    expect(batched.riskParameters).toMatchObject({ kind: "pool" })
    expect(batched.poolBorrowables.map((row) => row.symbol)).toEqual(["DAI", "USDC"])
  })

  test("populated borrow asset detail matches the per-section public queries", async () => {
    const t = convexTest(schema, modules)
    await seedPopulatedDetailTables(t)

    const batched = await t.query(api.detailHydration.getBorrowAssetDetail, { slug: ASSET })
    const allocation = await t.query(api.allocation.getForAsset, { slug: ASSET })
    const expected = {
      snapshot: await t.query(api.markets.getMarketSnapshot, { scope: "asset", slug: ASSET }),
      supplyBorrow: await t.query(api.markets.getSupplyBorrow, { slug: ASSET }),
      transactions: await t.query(api.markets.getRecentTransactions, { scope: "asset", slug: ASSET }),
      allocation,
      allocationRiskParameters: await t.query(api.borrow.riskParameters.getRiskParametersForSlugs, {
        slugs: allocation.map((row) => row.poolSlug),
      }),
      risk: await t.query(api.borrow.riskAssessment.getRisk, { slug: ASSET }),
      content: await t.query(api.borrow.content.getContent, { slug: ASSET }),
      riskParameters: await t.query(api.borrow.riskParameters.getRiskParameters, { slug: ASSET }),
      interestRateModel: await t.query(api.borrow.interestRateModel.getInterestRateModel, { slug: ASSET }),
      siloedMarket: await t.query(api.borrow.markets.getMarket, { slug: ASSET }),
      contractAddresses: await t.query(api.contractAddresses.listAssetAddresses, { assetSlug: ASSET }),
    }

    expect(batched).toEqual(expected)
    expect(batched.allocation).toHaveLength(1)
    expect(batched.allocationRiskParameters).toEqual([{ slug: POOL, parameters: parametersRow(POOL).parameters }])
    // No siloed borrow daily stats: the IRM falls back to legacy marketDailyStats.
    expect(batched.interestRateModel?.utilizationPct).toBe(72)
    expect(batched.interestRateModel?.borrowAprPct).toBeCloseTo(5.25)
  })
})
