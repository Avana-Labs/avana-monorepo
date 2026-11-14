/**
 * Seed the Convex market data layer for all borrow markets.
 *
 *   npx tsx scripts/seed-convex.ts --dry-run     # build rows + print counts, no network
 *   npx tsx scripts/seed-convex.ts               # push to NEXT_PUBLIC_CONVEX_URL (idempotent)
 *   npx tsx scripts/seed-convex.ts --days 90     # shorter daily window (fewer rows)
 *
 * Requires the Convex functions to be deployed first (`npx convex deploy`). Some operations replace history. Production maintenance must use reviewed internal functions.
 */

import { assertNonProductionTarget } from "../lib/deployment-safety.mjs"
import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api"
import type { Id } from "../convex/_generated/dataModel"
import { buildBorrowSeed } from "../app/lib/convex-seed/build-seed"

const BATCH = 400

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}
const dryRun = process.argv.includes("--dry-run")
// Push ONLY the `markets` table (173 rows) and stop — for cheap idempotent updates to
// market-level fields (e.g. the onboarding `priceUsd`) without re-pushing the 46k+ daily
// rows. All other tables are unchanged by such updates.
const marketsOnly = process.argv.includes("--markets-only")
// Skip the pre-existing daily-stats / wallet-events steps and jump
// straight to the Phase C additions. Useful when the legacy daily-stats
// mutation is misbehaving (it stalls out on some prod deployments due to a
// downstream index rebuild) and you just need the new tables populated.
const phaseCOnly = process.argv.includes("--phase-c-only")
const days = Number(arg("days") ?? 365)

function chunk<T>(rows: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < rows.length; i += size) out.push(rows.slice(i, i + size))
  return out
}

// Throttle between batches to stay under Convex's write-rate cap (4 MiB/s on the
// dev/local deployment). Tunable via --throttle <ms>.
const throttleMs = Number(arg("throttle") ?? 70)
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

async function main() {
  if (!dryRun) assertNonProductionTarget(process.env)
  const seed = buildBorrowSeed({ days })
  console.log(
    `[seed] built ${seed.markets.length} markets · ${seed.dailyStats.length} daily stats · ${seed.borrowRevenueDaily.length + seed.lendRevenueDaily.length + seed.multiplyRevenueDaily.length} product revenue · ${seed.borrowRiskAssessments.length + seed.lendRiskAssessments.length + seed.multiplyRiskAssessments.length} product risk (days=${days})`,
  )
  if (dryRun) {
    console.log("[seed] --dry-run: not writing. Sample market:", JSON.stringify(seed.markets[0]))
    return
  }

  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) {
    throw new Error("NEXT_PUBLIC_CONVEX_URL is not set to a reachable deployment (check .env.local).")
  }
  const seedSecret = process.env.CONVEX_SEED_SECRET
  if (!seedSecret) {
    throw new Error("CONVEX_SEED_SECRET is not set. Set it locally and in the Convex deployment.")
  }
  const client = new ConvexHttpClient(url)

  // 1) Markets → collect slug → _id
  const idsBySlug: Record<string, Id<"markets">> = {}
  for (const batch of chunk(seed.markets, BATCH)) {
    const res = (await client.action(api.seedAdmin.upsertMarkets, { seedSecret, rows: batch })) as {
      idsBySlug: Record<string, Id<"markets">>
    }
    Object.assign(idsBySlug, res.idsBySlug)
  }
  console.log(`[seed] upserted ${Object.keys(idsBySlug).length} markets`)

  // 1b) Product-siloed market identity (display metadata; legacy markets keep FKs)
  for (const batch of chunk(seed.borrowMarkets, BATCH)) {
    await client.action(api.seedAdmin.upsertBorrowMarkets, { seedSecret, rows: batch })
    await sleep(throttleMs)
  }
  for (const batch of chunk(seed.lendMarkets, BATCH)) {
    await client.action(api.seedAdmin.upsertLendMarkets, { seedSecret, rows: batch })
    await sleep(throttleMs)
  }
  for (const batch of chunk(seed.multiplyMarkets, BATCH)) {
    await client.action(api.seedAdmin.upsertMultiplyMarkets, { seedSecret, rows: batch })
    await sleep(throttleMs)
  }
  console.log(
    `[seed] upserted siloed markets: borrow=${seed.borrowMarkets.length} lend=${seed.lendMarkets.length} multiply=${seed.multiplyMarkets.length}`,
  )

  if (marketsOnly) {
    const counts = await client.action(api.seedAdmin.getCounts, { seedSecret })
    console.log("[seed] --markets-only: done. Convex counts:", JSON.stringify(counts))
    return
  }

  const withMarketId = <T extends { slug: string }>(rows: T[]) =>
    rows
      .map(({ slug, ...rest }) => {
        const marketId = idsBySlug[slug]
        return marketId ? { marketId, ...rest } : null
      })
      .filter((r): r is NonNullable<typeof r> => r !== null)

  let n = 0
  if (!phaseCOnly) {
    // 2) Daily stats
    for (const batch of chunk(withMarketId(seed.dailyStats), BATCH)) {
      await client.action(api.seedAdmin.upsertDailyStats, { seedSecret, rows: batch })
      n += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] upserted ${n} daily stats`)

    // 2b) Rebuild the listMarketSnapshots cache once from the freshly-landed markets +
    // daily stats (the subscribed hot query reads this single doc, not ~173 rows).
    await client.action(api.seedAdmin.rebuildMarketSnapshots, { seedSecret })
    console.log("[seed] rebuilt market snapshots cache")
  } else {
    console.log("[seed] --phase-c-only: skipping shared daily-stats/rebuild.")
    // Still push the MULTIPLY subset of daily stats to the unified marketDailyStats table
    // so the multiply detail queries (supplyBorrow, historicalUtilization) return data on
    // prod. Borrow/lend daily stats stay skipped — the legacy full push is the failing
    // step this flag exists to work around, and the multiply queries are the only ones
    // that consumers wanted resolved from marketDailyStats via phase-c-only.
    // SeedDailyStatRow itself carries no `scope`; join through seed.markets by slug.
    const multiplySlugs = new Set(seed.markets.filter((m) => m.scope === "multiply").map((m) => m.slug))
    const multiplyDailyStats = withMarketId(seed.dailyStats.filter((row) => multiplySlugs.has(row.slug)))
    let multiplyN = 0
    for (const batch of chunk(multiplyDailyStats, BATCH)) {
      await client.action(api.seedAdmin.upsertDailyStats, { seedSecret, rows: batch })
      multiplyN += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] upserted ${multiplyN} multiply daily stats (--phase-c-only)`)
  }

  const pushSilo = async (
    label: string,
    action: typeof api.seedAdmin.upsertBorrowRiskParameters,
    rows: unknown[],
    batchSize: number = BATCH,
  ) => {
    let written = 0
    for (const batch of chunk(rows, batchSize)) {
      await client.action(action, { seedSecret, rows: batch })
      written += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] upserted ${written} ${label}`)
  }

  if (!phaseCOnly) {
    // 4) Wallet events (engagement) — clear then insert so re-seeds stay idempotent.
    let cleared = 0
    for (;;) {
      const res = (await client.action(api.seedAdmin.clearWalletEvents, { seedSecret })) as { deleted: number }
      cleared += res.deleted
      if (res.deleted === 0) break
      await sleep(throttleMs)
    }
    let events = 0
    for (const batch of chunk(withMarketId(seed.walletEvents), BATCH)) {
      await client.action(api.seedAdmin.insertWalletEvents, { seedSecret, rows: batch })
      events += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] wallet events: cleared ${cleared}, inserted ${events}`)

    // 5) Allocation (per-asset → pool split) — maps BOTH slugs to market ids.
    const allocationRows = seed.allocation
      .map(({ assetSlug, poolSlug, ...rest }) => {
        const assetId = idsBySlug[assetSlug]
        const poolId = idsBySlug[poolSlug]
        return assetId && poolId ? { assetId, poolId, ...rest } : null
      })
      .filter((r): r is NonNullable<typeof r> => r !== null)
    let alloc = 0
    for (const batch of chunk(allocationRows, BATCH)) {
      await client.action(api.seedAdmin.upsertAllocation, { seedSecret, rows: batch })
      alloc += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] upserted ${alloc} allocation rows`)

    // 6) Product-siloed detail params (borrow / lend / multiply — separate tables)
    await pushSilo("borrow market content", api.seedAdmin.upsertBorrowMarketContent, seed.borrowMarketContent)
    await pushSilo("lend market content", api.seedAdmin.upsertLendMarketContent, seed.lendMarketContent)
    await pushSilo("multiply market content", api.seedAdmin.upsertMultiplyMarketContent, seed.multiplyMarketContent)
    await pushSilo("borrow daily stats", api.seedAdmin.upsertBorrowDailyStats, seed.borrowDailyStats)
    await pushSilo("lend daily stats", api.seedAdmin.upsertLendDailyStats, seed.lendDailyStats)
    await pushSilo("multiply daily stats", api.seedAdmin.upsertMultiplyDailyStats, seed.multiplyDailyStats)
    await pushSilo("borrow revenue daily", api.seedAdmin.upsertBorrowRevenueDaily, seed.borrowRevenueDaily)
    await pushSilo("lend revenue daily", api.seedAdmin.upsertLendRevenueDaily, seed.lendRevenueDaily)
    await pushSilo("multiply revenue daily", api.seedAdmin.upsertMultiplyRevenueDaily, seed.multiplyRevenueDaily)
    await pushSilo("borrow risk assessments", api.seedAdmin.upsertBorrowRiskAssessments, seed.borrowRiskAssessments)
    await pushSilo("lend risk assessments", api.seedAdmin.upsertLendRiskAssessments, seed.lendRiskAssessments)
    await pushSilo(
      "multiply risk assessments",
      api.seedAdmin.upsertMultiplyRiskAssessments,
      seed.multiplyRiskAssessments,
    )
    await pushSilo("borrow risk parameters", api.seedAdmin.upsertBorrowRiskParameters, seed.borrowRiskParameters)
    await pushSilo(
      "borrow interest rate models",
      api.seedAdmin.upsertBorrowInterestRateModels,
      seed.borrowInterestRateModels,
    )
    await pushSilo("borrow liquidation daily", api.seedAdmin.upsertBorrowLiquidationDaily, seed.borrowLiquidationDaily)
    await pushSilo("borrow pool borrowables", api.seedAdmin.upsertBorrowPoolBorrowables, seed.borrowPoolBorrowables)
    await pushSilo("lend risk parameters", api.seedAdmin.upsertLendRiskParameters, seed.lendRiskParameters)
    await pushSilo("lend interest rate models", api.seedAdmin.upsertLendInterestRateModels, seed.lendInterestRateModels)
    await pushSilo("multiply risk parameters", api.seedAdmin.upsertMultiplyRiskParameters, seed.multiplyRiskParameters)
    await pushSilo(
      "multiply liquidation daily",
      api.seedAdmin.upsertMultiplyLiquidationDaily,
      seed.multiplyLiquidationDaily,
    )
    // Governance parameter changelog — each row holds a whole market's change list, so
    // use a small batch to stay well under the seed payload cap.
    await pushSilo("parameter changes", api.seedAdmin.upsertParameterChanges, seed.parameterChanges ?? [], 50)
  } // end !phaseCOnly

  // ---------------------------------------------------------------------------
  // Phase C additions — global reference + rewards catalog + multiply
  // silent-mock closures + contract addresses. Each array is optional on
  // SeedData, so guard with (?? []) to keep the runner backward-compatible
  // with older seeds that pre-date these fields.
  // ---------------------------------------------------------------------------
  await pushSilo("spokes", api.seedAdmin.upsertSpokes, seed.spokes ?? [])
  await pushSilo("dexes", api.seedAdmin.upsertDexes, seed.dexes ?? [])
  await pushSilo("borrow assets", api.seedAdmin.upsertBorrowAssets, seed.borrowAssets ?? [])
  await pushSilo(
    "multiply interest rate models",
    api.seedAdmin.upsertMultiplyInterestRateModels,
    seed.multiplyInterestRateModels ?? [],
  )
  await pushSilo(
    "multiply market allocations",
    api.seedAdmin.upsertMultiplyAllocation,
    seed.multiplyMarketAllocations ?? [],
  )
  await pushSilo(
    "multiply token parameters",
    api.seedAdmin.upsertMultiplyTokenParameters,
    seed.multiplyTokenParameters ?? [],
  )
  // Contract-address seed rows use a generic `slug` field; the mutations expect
  // scope-specific keys. Remap here so the extractors don't need to know about
  // the three separate tables.
  const remap = <K extends string>(key: K, rows: Array<{ slug: string } & Record<string, unknown>>) =>
    rows.map(({ slug, ...rest }) => ({ [key]: slug, ...rest }))
  await pushSilo(
    "pool contract addresses",
    api.seedAdmin.upsertPoolContractAddresses,
    remap("poolSlug", seed.poolContractAddresses ?? []),
  )
  await pushSilo(
    "asset contract addresses",
    api.seedAdmin.upsertAssetContractAddresses,
    remap("assetSlug", seed.assetContractAddresses ?? []),
  )
  await pushSilo(
    "multiply contract addresses",
    api.seedAdmin.upsertMultiplyContractAddresses,
    remap("marketSlug", seed.multiplyContractAddresses ?? []),
  )
  await pushSilo(
    "lend contract addresses",
    api.seedAdmin.upsertLendContractAddresses,
    remap("marketSlug", seed.lendContractAddresses ?? []),
  )

  // ---------------------------------------------------------------------------
  // Per-wallet portfolio for the seeded test wallet. Every row shares the same
  // `wallet` field (TEST_WALLET_ADDRESS in build-seed.ts); the runner batches
  // per wallet so mutation args stay small.
  // ---------------------------------------------------------------------------
  const pushWalletRows = async (
    label: string,
    action:
      | typeof api.seedAdmin.upsertWalletCollateralPositions
      | typeof api.seedAdmin.upsertWalletDebts
      | typeof api.seedAdmin.upsertWalletClaimPositions,
    rows: Array<{ wallet: string }> | undefined,
  ) => {
    if (!rows || rows.length === 0) {
      console.log(`[seed] ${label}: no rows`)
      return
    }
    const byWallet = new Map<string, Array<{ wallet: string }>>()
    for (const row of rows) {
      const list = byWallet.get(row.wallet) ?? []
      list.push(row)
      byWallet.set(row.wallet, list)
    }
    let total = 0
    for (const [wallet, walletRows] of byWallet) {
      const res = (await client.action(action, {
        seedSecret,
        wallet,
        rows: walletRows.map(({ wallet: _w, ...rest }) => rest),
      })) as { written: number }
      total += res.written ?? walletRows.length
    }
    console.log(`[seed] upserted ${total} ${label} across ${byWallet.size} wallet(s)`)
  }
  await pushWalletRows(
    "wallet collateral positions",
    api.seedAdmin.upsertWalletCollateralPositions,
    seed.walletCollateralPositions,
  )
  await pushWalletRows("wallet debts", api.seedAdmin.upsertWalletDebts, seed.walletDebts)
  await pushWalletRows("wallet claim positions", api.seedAdmin.upsertWalletClaimPositions, seed.walletClaimPositions)

  const counts = await client.action(api.seedAdmin.getCounts, { seedSecret })
  console.log("[seed] done. Convex counts:", JSON.stringify(counts))
}

main().catch((err) => {
  console.error("[seed] failed:", err)
  process.exit(1)
})
