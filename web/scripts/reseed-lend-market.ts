/**
 * Re-seed one lend market's daily stats on the shared Convex deployment, then rebuild the
 * market snapshot cache. Reads NEXT_PUBLIC_CONVEX_URL and CONVEX_SEED_SECRET from the env.
 *   npx tsx scripts/reseed-lend-market.ts <slug> [--dry-run]
 */
import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api"
import { buildBorrowSeed } from "../app/lib/convex-seed/build-seed"

async function main() {
  const [slug, flag] = process.argv.slice(2)
  if (!slug) throw new Error("usage: reseed-lend-market.ts <slug> [--dry-run]")
  // End at today: the daily rollup carries the latest row forward, so older rows would not change the live figures.
  const rows = buildBorrowSeed({ days: 365, asOf: Date.now() }).lendDailyStats.filter((row) => row.slug === slug)
  if (rows.length === 0) throw new Error(`no lend daily stats for ${slug}`)
  const tip = rows[rows.length - 1]!
  console.log(
    `${slug}: ${rows.length} rows; tip ${tip.day} supplied $${Math.round(tip.suppliedUsd)} util ${tip.utilizationPct.toFixed(1)}% supplyApy ${tip.supplyApyPct.toFixed(2)}%`,
  )
  if (flag === "--dry-run") return
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  const seedSecret = process.env.CONVEX_SEED_SECRET
  if (!url || !seedSecret) throw new Error("NEXT_PUBLIC_CONVEX_URL and CONVEX_SEED_SECRET are required")
  const client = new ConvexHttpClient(url)
  for (let i = 0; i < rows.length; i += 200) {
    await client.action(api.seedAdmin.upsertLendDailyStats, { seedSecret, rows: rows.slice(i, i + 200) })
  }
  console.log("rebuild:", JSON.stringify(await client.action(api.seedAdmin.rebuildMarketSnapshots, { seedSecret })))
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
