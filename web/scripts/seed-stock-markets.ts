/**
 * TARGETED seed — push ONLY the new tokenized-stock markets (the two borrow stock spokes +
 * the lend "Coinbase & Robinhood Stocks" section) to the configured Convex deployment.
 *
 *   npx tsx scripts/seed-stock-markets.ts --dry-run   # filter + print counts, no network
 *   npx tsx scripts/seed-stock-markets.ts             # push to NEXT_PUBLIC_CONVEX_URL
 *   npx tsx scripts/seed-stock-markets.ts --no-events  # skip wallet-event inserts (re-run safe)
 *
 * Why this instead of scripts/seed-convex.ts: that runner rewrites all 173 existing markets and
 * pushes ~74k daily-stat rows (the legacy step that errors on this deployment). Here we filter
 * buildBorrowSeed() down to the 29 new markets + 2 new spokes and push only those — idempotent
 * per row (upserts), existing markets untouched. rebuildMarketSnapshots is global (one cache doc)
 * so the borrow/lend lists pick up the new markets.
 *
 * Auth: seedAdmin actions authenticate with CONVEX_SEED_SECRET and are gated server-side by
 * assertSeedDeployment — the same path prior targeted prod reseeds used. Wallet events are
 * insert-only (no per-market clear exists), so a re-run duplicates them — pass --no-events then.
 */
import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api"
import type { Id } from "../convex/_generated/dataModel"
import { buildBorrowSeed } from "../app/lib/convex-seed/build-seed"

const BATCH = 400
const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}
const dryRun = process.argv.includes("--dry-run")
const noEvents = process.argv.includes("--no-events")
const days = Number(arg("days") ?? 365)
const throttleMs = Number(arg("throttle") ?? 70)
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const chunk = <T>(arr: readonly T[], n: number): T[][] => {
  const out: T[][] = []
  for (let i = 0; i < arr.length; i += n) out.push(arr.slice(i, i + n))
  return out
}

const NEW_SPOKE_IDS = new Set(["aero-concentrated-stocks", "uni-robinhood-stocks"])
const NEW_LEND_SLUGS = new Set(["nvda", "spcx", "aapl", "meta", "googl", "tsla"])

async function main() {
  const seed = buildBorrowSeed({ days })

  // The new markets: borrow pools/assets under the two stock spokes, plus the lend stock section.
  const newMarkets = seed.markets.filter((m) => {
    const spokeId = (m as { spokeId?: string }).spokeId
    if (spokeId && NEW_SPOKE_IDS.has(spokeId)) return true
    return m.scope === "lend" && NEW_LEND_SLUGS.has(m.slug)
  })
  const NEW_SLUGS = new Set(newMarkets.map((m) => m.slug))
  const bySlug = <T extends { slug: string }>(rows: readonly T[]) => rows.filter((r) => NEW_SLUGS.has(r.slug))

  const newSpokes = (seed.spokes ?? []).filter((s) => NEW_SPOKE_IDS.has(s.id))
  const newBorrowAssets = (seed.borrowAssets ?? []).filter((a) => NEW_SPOKE_IDS.has(a.spokeId))
  const newPoolBorrowables = seed.borrowPoolBorrowables.filter((e) => NEW_SLUGS.has(e.poolSlug))
  const newAllocation = seed.allocation.filter((a) => NEW_SLUGS.has(a.assetSlug) || NEW_SLUGS.has(a.poolSlug))
  const newParamChanges = (seed.parameterChanges ?? []).filter((p) => NEW_SLUGS.has((p as { slug: string }).slug))
  const newWalletEvents = seed.walletEvents.filter((e) => NEW_SLUGS.has(e.slug))
  const newDailyStats = bySlug(seed.dailyStats)

  const filteredCounts = {
    markets: newMarkets.length,
    borrowMarkets: bySlug(seed.borrowMarkets).length,
    lendMarkets: bySlug(seed.lendMarkets).length,
    dailyStats: newDailyStats.length,
    walletEvents: newWalletEvents.length,
    allocation: newAllocation.length,
    borrowMarketContent: bySlug(seed.borrowMarketContent).length,
    lendMarketContent: bySlug(seed.lendMarketContent).length,
    borrowRiskParameters: bySlug(seed.borrowRiskParameters).length,
    borrowInterestRateModels: bySlug(seed.borrowInterestRateModels).length,
    borrowPoolBorrowables: newPoolBorrowables.length,
    lendRiskParameters: bySlug(seed.lendRiskParameters).length,
    lendInterestRateModels: bySlug(seed.lendInterestRateModels).length,
    parameterChanges: newParamChanges.length,
    spokes: newSpokes.length,
    borrowAssets: newBorrowAssets.length,
    poolContractAddresses: bySlug(seed.poolContractAddresses ?? []).length,
    assetContractAddresses: bySlug(seed.assetContractAddresses ?? []).length,
    lendContractAddresses: bySlug(seed.lendContractAddresses ?? []).length,
  }
  console.log(`[stock-seed] new market slugs (${NEW_SLUGS.size}):`, [...NEW_SLUGS].join(", "))
  console.log("[stock-seed] filtered row counts:", JSON.stringify(filteredCounts, null, 2))

  if (dryRun) {
    console.log("[stock-seed] --dry-run: not writing.")
    return
  }

  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) throw new Error("NEXT_PUBLIC_CONVEX_URL is not set (check .env.local).")
  const seedSecret = process.env.CONVEX_SEED_SECRET
  if (!seedSecret) throw new Error("CONVEX_SEED_SECRET is not set (needed for seedAdmin actions).")
  console.log(`[stock-seed] target: ${url.replace(/^https?:\/\//, "").split(".")[0]}.convex.cloud`)
  const client = new ConvexHttpClient(url)

  // 1) Markets → slug → _id (only the new markets are returned here).
  const idsBySlug: Record<string, Id<"markets">> = {}
  for (const batch of chunk(newMarkets, BATCH)) {
    const res = (await client.action(api.seedAdmin.upsertMarkets, { seedSecret, rows: batch })) as {
      idsBySlug: Record<string, Id<"markets">>
    }
    Object.assign(idsBySlug, res.idsBySlug)
  }
  console.log(`[stock-seed] upserted ${Object.keys(idsBySlug).length} markets`)

  const withMarketId = <T extends { slug: string }>(rows: readonly T[]) =>
    rows
      .map(({ slug, ...rest }) => {
        const marketId = idsBySlug[slug]
        return marketId ? ({ marketId, ...rest } as { marketId: Id<"markets"> } & Omit<T, "slug">) : null
      })
      .filter((r): r is { marketId: Id<"markets"> } & Omit<T, "slug"> => r !== null)

  // Resilient: log & continue on a per-table failure so ONE run surfaces every problem and still
  // seeds the tables that work. Failures are summarized (and exit non-zero) at the end.
  const failures: string[] = []
  const pushSilo = async (
    label: string,
    action: typeof api.seedAdmin.upsertBorrowRiskParameters,
    rows: unknown[],
    batchSize = BATCH,
  ) => {
    let written = 0
    try {
      for (const batch of chunk(rows, batchSize)) {
        await client.action(action, { seedSecret, rows: batch })
        written += batch.length
        await sleep(throttleMs)
      }
      console.log(`[stock-seed] upserted ${written} ${label}`)
    } catch (err) {
      failures.push(label)
      console.error(`[stock-seed] ✗ ${label} FAILED after ${written} rows: ${(err as Error).message}`)
    }
  }

  // 2) Siloed market identity
  await pushSilo("borrow markets", api.seedAdmin.upsertBorrowMarkets, bySlug(seed.borrowMarkets))
  await pushSilo("lend markets", api.seedAdmin.upsertLendMarkets, bySlug(seed.lendMarkets))

  // 3) Siloed daily stats FIRST, then rebuild the snapshot cache. The recompute
  // (computeMarketSnapshots → latestDailyStatForScope) PREFERS the siloed borrow/lend daily-stats
  // tables, so pushing them before the rebuild populates the list snapshots WITHOUT the unified
  // `upsertDailyStats` push — that legacy marketDailyStats step server-errors on this deployment,
  // and the borrow/lend detail pages read the siloed tables too.
  await pushSilo("borrow daily stats", api.seedAdmin.upsertBorrowDailyStats, bySlug(seed.borrowDailyStats))
  await pushSilo("lend daily stats", api.seedAdmin.upsertLendDailyStats, bySlug(seed.lendDailyStats))
  try {
    await client.action(api.seedAdmin.rebuildMarketSnapshots, { seedSecret })
    console.log("[stock-seed] rebuilt market snapshots cache")
  } catch (err) {
    failures.push("rebuildMarketSnapshots")
    console.error(`[stock-seed] ✗ rebuildMarketSnapshots FAILED: ${(err as Error).message}`)
  }

  // 4) Wallet events (community feed) — insert-only for the new markets.
  if (!noEvents) {
    await pushSilo("wallet events", api.seedAdmin.insertWalletEvents, withMarketId(newWalletEvents))
  } else {
    console.log("[stock-seed] --no-events: skipping wallet-event insert")
  }

  // 5) Allocation (asset → pool split)
  const allocationRows = newAllocation
    .map(({ assetSlug, poolSlug, ...rest }) => {
      const assetId = idsBySlug[assetSlug]
      const poolId = idsBySlug[poolSlug]
      return assetId && poolId ? { assetId, poolId, ...rest } : null
    })
    .filter((r): r is NonNullable<typeof r> => r !== null)
  await pushSilo("allocation", api.seedAdmin.upsertAllocation, allocationRows)

  // 6) Siloed detail params (borrow + lend only — no new multiply markets)
  await pushSilo("borrow market content", api.seedAdmin.upsertBorrowMarketContent, bySlug(seed.borrowMarketContent))
  await pushSilo("lend market content", api.seedAdmin.upsertLendMarketContent, bySlug(seed.lendMarketContent))
  await pushSilo("borrow revenue daily", api.seedAdmin.upsertBorrowRevenueDaily, bySlug(seed.borrowRevenueDaily))
  await pushSilo("lend revenue daily", api.seedAdmin.upsertLendRevenueDaily, bySlug(seed.lendRevenueDaily))
  await pushSilo(
    "borrow risk assessments",
    api.seedAdmin.upsertBorrowRiskAssessments,
    bySlug(seed.borrowRiskAssessments),
  )
  await pushSilo("lend risk assessments", api.seedAdmin.upsertLendRiskAssessments, bySlug(seed.lendRiskAssessments))
  await pushSilo("borrow risk parameters", api.seedAdmin.upsertBorrowRiskParameters, bySlug(seed.borrowRiskParameters))
  await pushSilo(
    "borrow interest rate models",
    api.seedAdmin.upsertBorrowInterestRateModels,
    bySlug(seed.borrowInterestRateModels),
  )
  await pushSilo(
    "borrow liquidation daily",
    api.seedAdmin.upsertBorrowLiquidationDaily,
    bySlug(seed.borrowLiquidationDaily),
  )
  await pushSilo("borrow pool borrowables", api.seedAdmin.upsertBorrowPoolBorrowables, newPoolBorrowables)
  await pushSilo("lend risk parameters", api.seedAdmin.upsertLendRiskParameters, bySlug(seed.lendRiskParameters))
  await pushSilo(
    "lend interest rate models",
    api.seedAdmin.upsertLendInterestRateModels,
    bySlug(seed.lendInterestRateModels),
  )
  await pushSilo("parameter changes", api.seedAdmin.upsertParameterChanges, newParamChanges, 50)

  // 7) Reference: the two new spokes + their borrowable registry rows (dexes already exist).
  await pushSilo("spokes", api.seedAdmin.upsertSpokes, newSpokes)
  await pushSilo("borrow assets", api.seedAdmin.upsertBorrowAssets, newBorrowAssets)

  // 8) Contract addresses (remap the generic `slug` to the scope-specific key each mutation wants).
  const remap = <K extends string>(key: K, rows: Array<{ slug: string } & Record<string, unknown>>) =>
    rows.map(({ slug, ...rest }) => ({ [key]: slug, ...rest }))
  await pushSilo(
    "pool contract addresses",
    api.seedAdmin.upsertPoolContractAddresses,
    remap("poolSlug", bySlug(seed.poolContractAddresses ?? [])),
  )
  await pushSilo(
    "asset contract addresses",
    api.seedAdmin.upsertAssetContractAddresses,
    remap("assetSlug", bySlug(seed.assetContractAddresses ?? [])),
  )
  await pushSilo(
    "lend contract addresses",
    api.seedAdmin.upsertLendContractAddresses,
    remap("marketSlug", bySlug(seed.lendContractAddresses ?? [])),
  )

  const counts = await client.action(api.seedAdmin.getCounts, { seedSecret })
  console.log("[stock-seed] done. Convex counts:", JSON.stringify(counts))
  if (failures.length > 0) {
    console.error(
      `[stock-seed] ⚠ ${failures.length} table(s) FAILED: ${failures.join(", ")} — paste this line and I'll fix them.`,
    )
    process.exitCode = 1
  }
}

main().catch((err) => {
  console.error("[stock-seed] failed:", err)
  process.exit(1)
})
