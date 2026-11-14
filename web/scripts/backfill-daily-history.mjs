#!/usr/bin/env node
/**
 * Backfill realistic daily history for every Lend, Multiply and Borrow market.
 *
 * The seeded history ends on the last seed day (2026-06-19). Since then the nightly rollup only
 * copies the previous row forward (plus live deltas), and some days are missing entirely, so
 * detail-page charts render flat lines. This fills every day strictly between each market's
 * last seed day and its latest stored row with a Brownian bridge pinned to both ends:
 *   - supplied follows a log-space bridge and utilization an additive bridge, each using that
 *     market's own day-to-day volatility measured from its seed history;
 *   - borrowed = supplied x utilization, TVL = supplied, the borrow APR moves with utilization,
 *     supply APY and fees are derived the way the seed derives them.
 * The latest row is never written, so live values, snapshot headlines and the rollup ledger
 * ("latest row + folded live delta = live value") are unchanged.
 *
 * Reads use public queries; writes go through the internal `*\/dailyStats:upsertDailyStats`
 * mutations (patch by slug + day). Dry run by default; `--apply` writes. Writes target whatever
 * deployment `npx convex` is configured for (.env.local), which in this repo is production.
 *
 *   node scripts/backfill-daily-history.mjs            # dry run: summary + out file
 *   node scripts/backfill-daily-history.mjs --apply    # write rows, then rebuild snapshots
 */
import { execFile } from "node:child_process"
import { writeFileSync } from "node:fs"
import { promisify } from "node:util"

const run = promisify(execFile)
const APPLY = process.argv.includes("--apply")
const SEED_END_DAY = "2026-06-19"
const VOLATILITY_WINDOW_DAYS = 120
const BRIDGE_DAMPING = 0.8
const BATCH_ROWS = 400
// Each call spawns a full Convex CLI (Node) process. Run them one at a time with a short pause:
// parallel calls (6 markets x 2 reads) saturated the CPU and froze the machine.
const CONCURRENCY = 1
const PAUSE_MS = 250
const CONVEX_BIN = "node_modules/.bin/convex"
const OUT_FILE = process.argv.find((arg) => arg.startsWith("--out="))?.slice(6) ?? "backfill-daily-history.json"

// Upserts patch by (slug, day), so retrying a failed call is safe for reads and writes alike.
async function convexRun(fn, args, attempts = 4) {
  for (let attempt = 1; ; attempt++) {
    try {
      const { stdout } = await run(CONVEX_BIN, ["run", fn, JSON.stringify(args)], { maxBuffer: 64 * 1024 * 1024 })
      await new Promise((resolve) => setTimeout(resolve, PAUSE_MS))
      return JSON.parse(stdout)
    } catch (error) {
      if (attempt >= attempts) throw error
      await new Promise((resolve) => setTimeout(resolve, 1000 * attempt))
    }
  }
}

async function convexData(table) {
  const { stdout } = await run(CONVEX_BIN, ["data", table, "--limit", "8191", "--format", "jsonLines"], {
    maxBuffer: 64 * 1024 * 1024,
  })
  return stdout
    .split("\n")
    .filter((line) => line.trim().startsWith("{"))
    .map((line) => JSON.parse(line))
}

async function mapLimit(items, limit, fn) {
  const out = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (next < items.length) {
        const index = next++
        out[index] = await fn(items[index], index)
      }
    }),
  )
  return out
}

/** Deterministic PRNG (mulberry32) seeded from the slug, so reruns produce the same history. */
function rngFor(key) {
  let h = 2166136261
  for (let i = 0; i < key.length; i++) h = Math.imul(h ^ key.charCodeAt(i), 16777619)
  let a = h >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function gaussian(rand) {
  const u = Math.max(rand(), 1e-12)
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rand())
}

/** Values at steps 1..n-1 of a bridge from `from` (step 0) to `to` (step n) with per-step sigma. */
function bridge(from, to, n, sigma, rand) {
  const walk = [0]
  for (let i = 1; i <= n; i++) walk.push(walk[i - 1] + sigma * gaussian(rand))
  const values = []
  for (let i = 1; i < n; i++) values.push(from + ((to - from) * i) / n + walk[i] - (walk[n] * i) / n)
  return values
}

function stdOfDiffs(values) {
  const diffs = values.slice(1).map((v, i) => v - values[i])
  if (diffs.length < 2) return 0
  const mean = diffs.reduce((a, b) => a + b, 0) / diffs.length
  return Math.sqrt(diffs.reduce((a, b) => a + (b - mean) ** 2, 0) / (diffs.length - 1))
}

const dayMs = 86_400_000
const addDays = (day, n) => new Date(Date.parse(`${day}T00:00:00Z`) + n * dayMs).toISOString().slice(0, 10)
const daysBetween = (a, b) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / dayMs)
const round2 = (value) => Math.round(value * 100) / 100

const PRODUCTS = {
  lend: { table: "lendMarkets", latest: "lend/dailyStats:getLatestStats", upsert: "lend/dailyStats:upsertDailyStats" },
  multiply: {
    table: "multiplyMarkets",
    latest: "multiply/dailyStats:getLatestStats",
    upsert: "multiply/dailyStats:upsertDailyStats",
  },
  borrow: {
    table: "borrowMarkets",
    latest: "borrow/dailyStats:getLatestStats",
    upsert: "borrow/dailyStats:upsertDailyStats",
  },
}

function heroQueries(product, kind) {
  if (product === "lend") return { fn: "markets:getLendHeroSeries", supply: "supply" }
  if (product === "multiply") return { fn: "markets:getMultiplyHeroSeries", supply: "supply" }
  return kind === "pool"
    ? { fn: "markets:getPoolHeroSeries", supply: "tvl" }
    : { fn: "markets:getAssetHeroSeries", supply: "supply" }
}

async function planMarket(product, market) {
  const latest = await convexRun(PRODUCTS[product].latest, { slug: market.slug })
  if (!latest) return { product, slug: market.slug, skipped: "no daily rows" }
  const hero = heroQueries(product, market.kind)
  const supplySeries = await convexRun(hero.fn, { slug: market.slug, metric: hero.supply, range: "ALL" })
  const utilSeries = await convexRun(hero.fn, { slug: market.slug, metric: "utilization", range: "ALL" })
  const seedSupply = (supplySeries?.points ?? []).filter((p) => p.t <= SEED_END_DAY)
  const seedUtil = (utilSeries?.points ?? []).filter((p) => p.t <= SEED_END_DAY)
  const start = seedSupply.at(-1)
  const startUtil = seedUtil.find((p) => p.t === start?.t)
  if (!start || !startUtil) return { product, slug: market.slug, skipped: "no seed history" }

  const n = daysBetween(start.t, latest.day)
  if (n < 2) return { product, slug: market.slug, skipped: "no gap to fill" }

  const window = (points) => points.slice(-VOLATILITY_WINDOW_DAYS).map((p) => p.v)
  const logSupply = window(seedSupply).map((v) => Math.log(Math.max(v, 1)))
  // The seed walk mean-reverts; a free bridge with the same step size wanders ~20% further, so
  // damp the step to keep the backfill's swings in line with the market's seed history.
  const sigmaLogSupply = BRIDGE_DAMPING * Math.min(0.05, Math.max(0.002, stdOfDiffs(logSupply)))
  const sigmaUtil = BRIDGE_DAMPING * Math.min(3, Math.max(0.05, stdOfDiffs(window(seedUtil))))

  const rand = rngFor(`${product}:${market.slug}:backfill`)
  const logS = bridge(
    Math.log(Math.max(start.v, 1)),
    Math.log(Math.max(latest.suppliedUsd, 1)),
    n,
    sigmaLogSupply,
    rand,
  )
  const util = bridge(startUtil.v, latest.utilizationPct, n, sigmaUtil, rand)

  // Rates: the APR leans with utilization around the latest APR; supply APY and fees follow it
  // with the same ratios the latest row has (the seed derives fees = borrowed x APR / 365).
  const aprPerUtil = (latest.borrowAprPct / Math.max(latest.utilizationPct, 1)) * 0.6
  const apyRatio =
    latest.borrowAprPct > 0 && latest.utilizationPct > 0
      ? latest.supplyApyPct / ((latest.borrowAprPct * latest.utilizationPct) / 100)
      : 0

  const rows = []
  for (let i = 1; i < n; i++) {
    const day = addDays(start.t, i)
    const suppliedUsd = Math.round(Math.exp(logS[i - 1]))
    const utilizationPct = round2(Math.min(98, Math.max(0.5, util[i - 1])))
    const utilTrend = startUtil.v + ((latest.utilizationPct - startUtil.v) * i) / n
    const borrowAprPct = round2(Math.max(0, latest.borrowAprPct + aprPerUtil * (utilizationPct - utilTrend)))
    const borrowedUsd = Math.round((suppliedUsd * utilizationPct) / 100)
    const row = {
      slug: market.slug,
      day,
      suppliedUsd,
      borrowedUsd,
      utilizationPct,
      supplyApyPct: round2(apyRatio > 0 ? ((borrowAprPct * utilizationPct) / 100) * apyRatio : latest.supplyApyPct),
      borrowAprPct,
      tvlUsd: suppliedUsd,
      volumeUsd: latest.volumeUsd,
      feesUsd: round2((borrowedUsd * borrowAprPct) / 100 / 365),
    }
    for (const field of ["priceUsd", "supplyCapUsd", "borrowCapUsd"]) {
      if (typeof latest[field] === "number") row[field] = latest[field]
    }
    if (product === "borrow") row.kind = latest.kind
    rows.push(row)
  }
  return { product, slug: market.slug, fromDay: start.t, toDay: latest.day, rows }
}

async function main() {
  const plans = []
  for (const product of Object.keys(PRODUCTS)) {
    const markets = await convexData(PRODUCTS[product].table)
    console.log(`${product}: ${markets.length} markets`)
    plans.push(
      ...(await mapLimit(markets, CONCURRENCY, (market, index) => {
        if (index % 10 === 0) console.log(`  ${product}: planning ${index + 1}/${markets.length}`)
        return planMarket(product, market)
      })),
    )
  }

  const planned = plans.filter((plan) => plan.rows)
  const skipped = plans.filter((plan) => plan.skipped)
  const totalRows = planned.reduce((sum, plan) => sum + plan.rows.length, 0)
  writeFileSync(OUT_FILE, JSON.stringify({ generatedAt: new Date().toISOString(), plans }, null, 2))
  console.log(`planned ${totalRows} rows across ${planned.length} markets; skipped ${skipped.length}`)
  for (const plan of skipped) console.log(`  skip ${plan.product}/${plan.slug}: ${plan.skipped}`)
  console.log(`wrote plan to ${OUT_FILE}`)
  if (!APPLY) {
    console.log("dry run: pass --apply to write")
    return
  }

  for (const product of Object.keys(PRODUCTS)) {
    const rows = planned.filter((plan) => plan.product === product).flatMap((plan) => plan.rows)
    const batches = []
    for (let i = 0; i < rows.length; i += BATCH_ROWS) batches.push(rows.slice(i, i + BATCH_ROWS))
    let written = 0
    await mapLimit(batches, CONCURRENCY, async (batch) => {
      const result = await convexRun(PRODUCTS[product].upsert, { rows: batch })
      written += result.written
      console.log(`  ${product}: ${written}/${rows.length} rows written`)
    })
    console.log(`${product}: wrote ${written} rows`)
  }
  // Quick-stat 24h deltas read the two most recent rows; refresh the snapshot cache.
  await convexRun("markets:rebuildMarketSnapshots", {})
  console.log("rebuilt market snapshots")
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
