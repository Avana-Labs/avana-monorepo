#!/usr/bin/env node
/**
 * Cheap idempotent reseed of ONLY the markets table + snapshot cache rebuild.
 *
 * Use this after a session that added new fields to build-seed.ts's market row
 * builders (e.g. multiply maxLtvPct, borrow reserveFactorPct) — everything else
 * stays as-is, but the markets table gets the new fields and the cache reflects
 * them within seconds.
 *
 *   npx tsx scripts/seed-convex.ts --markets-only
 *
 * Which:
 *   1. Rebuilds `buildBorrowSeed()` locally from the current build-seed.ts
 *   2. Upserts every market row (173) idempotently — new fields land, nothing else changes
 *   3. Calls `internal.markets.rebuildMarketSnapshots` to rebuild the aggregate cache
 *
 * Requires:
 *   - NEXT_PUBLIC_CONVEX_URL pointed at the target deployment
 *   - CONVEX_SEED_SECRET matching the target's env var
 *
 * NEVER run against prod without confirming both. This wrapper prints a preview.
 */
const url = process.env.NEXT_PUBLIC_CONVEX_URL || "(not set)"
const isPreview = url.includes("staging") || url.includes("dev") || url.includes("localhost")
const prefix = isPreview ? "  " : "⚠️  "
console.log(`${prefix}Target Convex deployment: ${url}`)
console.log(`${prefix}Command to run:`)
console.log(`${prefix}    npx tsx scripts/seed-convex.ts --markets-only`)
if (!isPreview) {
  console.log(`\n${prefix}This looks like a production URL. Confirm before running the command above.`)
}
