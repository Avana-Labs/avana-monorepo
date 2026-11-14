/**
 * Push product-silo detail tables only (IRM, liquidation, risk params, content, …).
 * Skips legacy dailyStats/revenue bulk that can fail mid-seed.
 *
 *   npx tsx scripts/seed-convex-silos-only.ts
 */

import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api"
import { buildBorrowSeed } from "../app/lib/convex-seed/build-seed"

const BATCH = 200
const throttleMs = 80
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function chunk<T>(rows: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < rows.length; i += size) out.push(rows.slice(i, i + size))
  return out
}

async function main() {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  const seedSecret = process.env.CONVEX_SEED_SECRET
  if (!url || !seedSecret) {
    throw new Error("NEXT_PUBLIC_CONVEX_URL and CONVEX_SEED_SECRET are required")
  }

  const client = new ConvexHttpClient(url)
  const seed = buildBorrowSeed({ days: 2 })

  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- Convex action refs are opaque here
  const push = async (label: string, action: any, rows: unknown[]) => {
    let written = 0
    for (const batch of chunk(rows, BATCH)) {
      await client.action(action, { seedSecret, rows: batch })
      written += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed-silos] upserted ${written} ${label}`)
  }

  await push("borrow markets", api.seedAdmin.upsertBorrowMarkets, seed.borrowMarkets)
  await push("lend markets", api.seedAdmin.upsertLendMarkets, seed.lendMarkets)
  await push("multiply markets", api.seedAdmin.upsertMultiplyMarkets, seed.multiplyMarkets)
  await push("borrow market content", api.seedAdmin.upsertBorrowMarketContent, seed.borrowMarketContent)
  await push("lend market content", api.seedAdmin.upsertLendMarketContent, seed.lendMarketContent)
  await push("multiply market content", api.seedAdmin.upsertMultiplyMarketContent, seed.multiplyMarketContent)
  await push("borrow risk assessments", api.seedAdmin.upsertBorrowRiskAssessments, seed.borrowRiskAssessments)
  await push("lend risk assessments", api.seedAdmin.upsertLendRiskAssessments, seed.lendRiskAssessments)
  await push("multiply risk assessments", api.seedAdmin.upsertMultiplyRiskAssessments, seed.multiplyRiskAssessments)
  await push("borrow risk parameters", api.seedAdmin.upsertBorrowRiskParameters, seed.borrowRiskParameters)
  await push("lend risk parameters", api.seedAdmin.upsertLendRiskParameters, seed.lendRiskParameters)
  await push("multiply risk parameters", api.seedAdmin.upsertMultiplyRiskParameters, seed.multiplyRiskParameters)
  await push("borrow IRM", api.seedAdmin.upsertBorrowInterestRateModels, seed.borrowInterestRateModels)
  await push("lend IRM", api.seedAdmin.upsertLendInterestRateModels, seed.lendInterestRateModels)
  await push("borrow liquidation", api.seedAdmin.upsertBorrowLiquidationDaily, seed.borrowLiquidationDaily)
  await push("multiply liquidation", api.seedAdmin.upsertMultiplyLiquidationDaily, seed.multiplyLiquidationDaily)
  await push("borrow pool borrowables", api.seedAdmin.upsertBorrowPoolBorrowables, seed.borrowPoolBorrowables)
  await push("borrow daily stats", api.seedAdmin.upsertBorrowDailyStats, seed.borrowDailyStats)
  await push("lend daily stats", api.seedAdmin.upsertLendDailyStats, seed.lendDailyStats)
  await push("multiply daily stats", api.seedAdmin.upsertMultiplyDailyStats, seed.multiplyDailyStats)
  await push("borrow revenue", api.seedAdmin.upsertBorrowRevenueDaily, seed.borrowRevenueDaily)
  await push("lend revenue", api.seedAdmin.upsertLendRevenueDaily, seed.lendRevenueDaily)
  await push("multiply revenue", api.seedAdmin.upsertMultiplyRevenueDaily, seed.multiplyRevenueDaily)

  console.log("[seed-silos] done")
}

main().catch((err) => {
  console.error("[seed-silos] failed:", err)
  process.exit(1)
})
