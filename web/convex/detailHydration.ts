/**
 * Batched server detail reads.
 *
 * The page still preloads hero, quick-stat, and cashflow data independently because those
 * values are handed to different UI surfaces. This module combines the remaining detail
 * fan-out into one product-scoped Convex query so a detail render does not open nine separate
 * Convex requests for the same slug.
 */

import { v } from "convex/values"
import { query } from "./_generated/server"
import { readMarketSnapshot, readRecentTransactions, readSupplyBorrow } from "./markets"
import { readAllocationForAsset } from "./allocation"
import { readAssetAddresses, readLendAddresses, readMultiplyAddresses, readPoolAddresses } from "./contractAddresses"
import * as borrowContent from "./borrow/content"
import * as borrowInterestRateModel from "./borrow/interestRateModel"
import * as borrowLiquidationRisk from "./borrow/liquidationRisk"
import * as borrowMarkets from "./borrow/markets"
import { readPoolBorrowables } from "./borrow/poolBorrowables"
import * as borrowRiskAssessment from "./borrow/riskAssessment"
import * as borrowRiskParameters from "./borrow/riskParameters"
import * as lendContent from "./lend/content"
import * as lendInterestRateModel from "./lend/interestRateModel"
import * as lendMarkets from "./lend/markets"
import * as lendRiskAssessment from "./lend/riskAssessment"
import * as lendRiskParameters from "./lend/riskParameters"
import * as multiplyContent from "./multiply/content"
import * as multiplyLiquidationRisk from "./multiply/liquidationRisk"
import * as multiplyMarkets from "./multiply/markets"
import * as multiplyRiskAssessment from "./multiply/riskAssessment"
import * as multiplyRiskParameters from "./multiply/riskParameters"

const detailArgs = { slug: v.string() }

export const getLendDetail = query({
  args: detailArgs,
  handler: async (ctx, { slug }) => {
    const [
      snapshot,
      transactions,
      risk,
      content,
      riskParameters,
      interestRateModel,
      siloedMarket,
      contractAddresses,
      supplyBorrow,
    ] = await Promise.all([
      readMarketSnapshot(ctx, "lend", slug),
      readRecentTransactions(ctx, "lend", slug),
      lendRiskAssessment.readRisk(ctx, slug),
      lendContent.readContent(ctx, slug),
      lendRiskParameters.readRiskParameters(ctx, slug),
      lendInterestRateModel.readInterestRateModel(ctx, slug),
      lendMarkets.readMarket(ctx, slug),
      readLendAddresses(ctx, slug),
      readSupplyBorrow(ctx, "lend", slug),
    ])
    return {
      snapshot,
      transactions,
      risk,
      content,
      riskParameters,
      interestRateModel,
      siloedMarket,
      contractAddresses,
      supplyBorrow,
    }
  },
})

export const getMultiplyDetail = query({
  args: detailArgs,
  handler: async (ctx, { slug }) => {
    const [
      transactions,
      risk,
      content,
      riskParameters,
      liquidationRisk,
      siloedMarket,
      snapshot,
      supplyBorrow,
      contractAddresses,
    ] = await Promise.all([
      readRecentTransactions(ctx, "multiply", slug),
      multiplyRiskAssessment.readRisk(ctx, slug),
      multiplyContent.readContent(ctx, slug),
      multiplyRiskParameters.readRiskParameters(ctx, slug),
      multiplyLiquidationRisk.readLiquidationRisk(ctx, slug),
      multiplyMarkets.readMarket(ctx, slug),
      readMarketSnapshot(ctx, "multiply", slug),
      readSupplyBorrow(ctx, "multiply", slug),
      readMultiplyAddresses(ctx, slug),
    ])
    return {
      transactions,
      risk,
      content,
      riskParameters,
      liquidationRisk,
      siloedMarket,
      snapshot,
      supplyBorrow,
      contractAddresses,
    }
  },
})

export const getBorrowPoolDetail = query({
  args: detailArgs,
  handler: async (ctx, { slug }) => {
    const [
      snapshot,
      transactions,
      risk,
      content,
      riskParameters,
      poolBorrowables,
      liquidationRisk,
      siloedMarket,
      contractAddresses,
    ] = await Promise.all([
      readMarketSnapshot(ctx, "pool", slug),
      readRecentTransactions(ctx, "pool", slug),
      borrowRiskAssessment.readRisk(ctx, slug),
      borrowContent.readContent(ctx, slug),
      borrowRiskParameters.readRiskParameters(ctx, slug),
      readPoolBorrowables(ctx, slug),
      borrowLiquidationRisk.readLiquidationRisk(ctx, slug),
      borrowMarkets.readMarket(ctx, slug),
      readPoolAddresses(ctx, slug),
    ])
    return {
      snapshot,
      transactions,
      risk,
      content,
      riskParameters,
      poolBorrowables,
      liquidationRisk,
      siloedMarket,
      contractAddresses,
    }
  },
})

export const getBorrowAssetDetail = query({
  args: detailArgs,
  handler: async (ctx, { slug }) => {
    const [
      snapshot,
      supplyBorrow,
      transactions,
      allocation,
      risk,
      content,
      riskParameters,
      interestRateModel,
      siloedMarket,
      contractAddresses,
    ] = await Promise.all([
      readMarketSnapshot(ctx, "asset", slug),
      readSupplyBorrow(ctx, "asset", slug),
      readRecentTransactions(ctx, "asset", slug),
      readAllocationForAsset(ctx, slug),
      borrowRiskAssessment.readRisk(ctx, slug),
      borrowContent.readContent(ctx, slug),
      borrowRiskParameters.readRiskParameters(ctx, slug),
      borrowInterestRateModel.readInterestRateModel(ctx, slug),
      borrowMarkets.readMarket(ctx, slug),
      readAssetAddresses(ctx, slug),
    ])
    const allocationRiskParameters = await borrowRiskParameters.readRiskParametersForSlugs(
      ctx,
      allocation.map((row) => row.poolSlug),
    )
    return {
      snapshot,
      supplyBorrow,
      transactions,
      allocation,
      allocationRiskParameters,
      risk,
      content,
      riskParameters,
      interestRateModel,
      siloedMarket,
      contractAddresses,
    }
  },
})
