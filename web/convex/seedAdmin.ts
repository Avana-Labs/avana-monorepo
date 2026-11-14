import { assertSeedDeployment } from "../lib/deployment-safety.mjs"
import { v } from "convex/values"
import { action } from "./_generated/server"
import { internal } from "./_generated/api"

const MAX_SEED_ROWS = 2_000
const MAX_SEED_PAYLOAD_BYTES = 1_000_000
const MAX_CLEAR_WALLET_EVENTS = 10_000

/** Constant-time string compare (no early exit) to avoid a timing side-channel on the secret. */
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

function requireSeedSecret(seedSecret: string) {
  const expected = process.env.CONVEX_SEED_SECRET
  if (!expected || !safeEqual(seedSecret, expected)) {
    throw new Error("Unauthorized seed write")
  }
  assertSeedDeployment()
}

function requireSafeSeedRows(rows: unknown[]) {
  if (rows.length > MAX_SEED_ROWS) {
    throw new Error(`Seed batch too large: max ${MAX_SEED_ROWS} rows.`)
  }
  const bytes = JSON.stringify(rows).length
  if (bytes > MAX_SEED_PAYLOAD_BYTES) {
    throw new Error(`Seed batch payload too large: max ${MAX_SEED_PAYLOAD_BYTES} bytes.`)
  }
}

function safeClearLimit(limit: number | undefined) {
  if (limit == null) return undefined
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_CLEAR_WALLET_EVENTS) {
    throw new Error(`Invalid clear limit: must be 1-${MAX_CLEAR_WALLET_EVENTS}.`)
  }
  return limit
}

const rowsArgs = {
  seedSecret: v.string(),
  rows: v.array(v.any()),
}

export const upsertMarkets = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.seed.upsertMarkets, { rows })
  },
})

export const upsertBorrowMarkets = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.markets.upsertMarkets, { rows })
  },
})

export const upsertLendMarkets = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.markets.upsertMarkets, { rows })
  },
})

export const upsertMultiplyMarkets = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.markets.upsertMarkets, { rows })
  },
})

export const upsertDailyStats = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.seed.upsertDailyStats, { rows })
  },
})

export const upsertBorrowDailyStats = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.dailyStats.upsertDailyStats, { rows })
  },
})

export const upsertLendDailyStats = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.dailyStats.upsertDailyStats, { rows })
  },
})

export const upsertMultiplyDailyStats = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.dailyStats.upsertDailyStats, { rows })
  },
})

/**
 * Rebuild the `listMarketSnapshots` cache. Call ONCE after landing markets +
 * daily stats (the recompute is expensive; running it per-batch would waste work).
 */
export const rebuildMarketSnapshots = action({
  args: { seedSecret: v.string() },
  handler: async (ctx, { seedSecret }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    return ctx.runMutation(internal.markets.rebuildMarketSnapshots, {})
  },
})

export const upsertBorrowRevenueDaily = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.cashflow.upsertRevenueDaily, { rows })
  },
})

export const upsertLendRevenueDaily = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.cashflow.upsertRevenueDaily, { rows })
  },
})

export const upsertMultiplyRevenueDaily = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.cashflow.upsertRevenueDaily, { rows })
  },
})

export const upsertBorrowRiskAssessments = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.riskAssessment.upsertRiskAssessments, { rows })
  },
})

export const upsertLendRiskAssessments = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.riskAssessment.upsertRiskAssessments, { rows })
  },
})

export const upsertMultiplyRiskAssessments = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.riskAssessment.upsertRiskAssessments, { rows })
  },
})

export const upsertAllocation = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.seed.upsertAllocation, { rows })
  },
})

export const upsertBorrowMarketContent = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.content.upsertContent, { rows })
  },
})

export const upsertLendMarketContent = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.content.upsertContent, { rows })
  },
})

export const upsertMultiplyMarketContent = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.content.upsertContent, { rows })
  },
})

export const upsertParameterChanges = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.parameterChanges.upsertChanges, { rows })
  },
})

export const clearWalletEvents = action({
  args: { seedSecret: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { seedSecret, limit }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    return ctx.runMutation(internal.seed.clearWalletEvents, { limit: safeClearLimit(limit) })
  },
})

export const insertWalletEvents = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.seed.insertWalletEvents, { rows })
  },
})

export const upsertBorrowRiskParameters = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.riskParameters.upsertRiskParameters, { rows })
  },
})

export const upsertBorrowInterestRateModels = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.interestRateModel.upsertInterestRateModels, { rows })
  },
})

export const upsertBorrowLiquidationDaily = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.liquidationRisk.upsertLiquidationDaily, { rows })
  },
})

export const upsertBorrowPoolBorrowables = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.poolBorrowables.upsertPoolBorrowables, { rows })
  },
})

export const upsertLendRiskParameters = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.riskParameters.upsertRiskParameters, { rows })
  },
})

export const upsertLendInterestRateModels = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.lend.interestRateModel.upsertInterestRateModels, { rows })
  },
})

export const upsertMultiplyRiskParameters = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.riskParameters.upsertRiskParameters, { rows })
  },
})

export const upsertMultiplyLiquidationDaily = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.liquidationRisk.upsertLiquidationDaily, { rows })
  },
})

// -----------------------------------------------------------------------------
// Phase C additions — action wrappers for every new upsert mutation. Follow the
// same secret-gated + size-bounded pattern as the existing wrappers so the
// build-seed pipeline can populate every new Convex table via one entrypoint.
// -----------------------------------------------------------------------------

export const upsertSpokes = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.spokes.upsertSpokes, { rows })
  },
})

export const upsertDexes = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.dexes.upsertDexes, { rows })
  },
})

export const upsertBorrowAssets = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.borrow.assets.upsertAssets, { rows })
  },
})

export const upsertMultiplyInterestRateModels = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.interestRateModel.upsertInterestRateModels, { rows })
  },
})

export const upsertMultiplyAllocation = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.allocation.upsertAllocation, { rows })
  },
})

export const upsertMultiplyTokenParameters = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.multiply.tokenParameters.upsertTokens, { rows })
  },
})

export const upsertPoolContractAddresses = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.contractAddresses.upsertPoolAddresses, { rows })
  },
})

export const upsertAssetContractAddresses = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.contractAddresses.upsertAssetAddresses, { rows })
  },
})

export const upsertMultiplyContractAddresses = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.contractAddresses.upsertMultiplyAddresses, { rows })
  },
})

export const upsertLendContractAddresses = action({
  args: rowsArgs,
  handler: async (ctx, { seedSecret, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.contractAddresses.upsertLendAddresses, { rows })
  },
})

/**
 * Per-wallet portfolio upserts take a wallet arg alongside rows[]. Rows use
 * the same size caps to keep any single seed batch small.
 */
const perWalletRowsArgs = {
  seedSecret: v.string(),
  wallet: v.string(),
  rows: v.array(v.any()),
}

export const upsertWalletCollateralPositions = action({
  args: perWalletRowsArgs,
  handler: async (ctx, { seedSecret, wallet, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.wallet.collateralPositions.upsertForWallet, { wallet, rows })
  },
})

export const upsertWalletDebts = action({
  args: perWalletRowsArgs,
  handler: async (ctx, { seedSecret, wallet, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.wallet.debts.upsertForWallet, { wallet, rows })
  },
})

export const upsertWalletClaimPositions = action({
  args: perWalletRowsArgs,
  handler: async (ctx, { seedSecret, wallet, rows }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    requireSafeSeedRows(rows)
    return ctx.runMutation(internal.wallet.claimPositions.upsertForWallet, { wallet, rows })
  },
})

/** Secret-gated seed-verification counts (the internal getCounts, but not anon-callable). */
export const getCounts = action({
  args: { seedSecret: v.string() },
  handler: async (ctx, { seedSecret }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    return ctx.runQuery(internal.seed.getCounts, {})
  },
})

/** Secret-gated: clear stale portfolio-history snapshots (batched; loop until done=true). */
export const clearPortfolioSnapshots = action({
  args: { seedSecret: v.string(), limit: v.optional(v.number()) },
  handler: async (ctx, { seedSecret, limit }): Promise<unknown> => {
    requireSeedSecret(seedSecret)
    return ctx.runMutation(internal.seed.clearPortfolioSnapshots, { limit: safeClearLimit(limit) })
  },
})
