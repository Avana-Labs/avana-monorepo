#!/usr/bin/env node
/**
 * Instant Paint baseline — warm-route timings against a running Next server.
 *
 * Prefer a production server for numbers that survive deploy:
 *   npm run build && npm run start
 *   BASE_URL=http://localhost:3000 npm run perf:instant-paint-baseline
 *
 * Dev (`npm run dev`) is OK for relative before/after during a session, but
 * includes Turbopack noise — label is written into the artifact as `serverMode`.
 *
 * Output: .artifacts/instant-paint/baseline.json (gitignored) + stdout summary.
 */
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { performance } from "node:perf_hooks"

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, "..")
const outDir = join(root, ".artifacts/instant-paint")
const outFile = join(outDir, "baseline.json")
const compareFile = process.env.COMPARE_BASELINE
  ? join(root, process.env.COMPARE_BASELINE)
  : existsSync(outFile)
    ? outFile
    : null

const BASE_URL = (process.env.BASE_URL || "http://localhost:3000").replace(/\/+$/, "")
const RUNS = Math.max(1, Number(process.env.RUNS || 2))
const WARMUP = process.env.WARMUP !== "0"

/** Routes Instant Paint cares about most (subset of config/performance-routes.json). */
const ROUTES = [
  { route: "/borrow", label: "borrow-catalog" },
  { route: "/borrow/markets/uni-v3-bluechip-weth-usdc", label: "borrow-market-detail" },
  { route: "/borrow/assets/usdc", label: "borrow-asset-detail" },
  { route: "/lend", label: "lend-catalog" },
  { route: "/lend/markets/usdc", label: "lend-market-detail" },
  { route: "/dashboard", label: "dashboard" },
]

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

async function probeServerMode() {
  try {
    await fetch(`${BASE_URL}/borrow`, { method: "HEAD", redirect: "follow" })
    // Next does not expose mode on HEAD reliably; infer from env hint or leave unknown.
    return process.env.SERVER_MODE || (process.env.NODE_ENV === "production" ? "production" : "unknown")
  } catch {
    return "unreachable"
  }
}

async function measureOnce(path) {
  const url = `${BASE_URL}${path}`
  const started = performance.now()
  const res = await fetch(url, {
    headers: {
      Accept: "text/html",
      // Avoid CDN/browser cache when hitting a proxy; local Next ignores this mostly.
      "Cache-Control": "no-cache",
    },
    redirect: "follow",
  })
  const ttfbMs = performance.now() - started
  const buf = Buffer.from(await res.arrayBuffer())
  const totalMs = performance.now() - started
  const html = buf.toString("utf8")
  const looksBlankShell =
    html.includes("Open-gate Convex auth failed") ||
    // Extremely small bodies usually mean blank/error shells
    buf.byteLength < 2_000
  return {
    status: res.status,
    ttfbMs: Math.round(ttfbMs),
    totalMs: Math.round(totalMs),
    bytes: buf.byteLength,
    looksBlankShell,
  }
}

async function measureRoute(entry) {
  if (WARMUP) {
    try {
      await measureOnce(entry.route)
    } catch {
      // warm-up failure handled on real runs
    }
  }

  const samples = []
  for (let i = 0; i < RUNS; i++) {
    samples.push(await measureOnce(entry.route))
  }

  const ok = samples.filter((s) => s.status >= 200 && s.status < 400)
  if (ok.length === 0) {
    return {
      ...entry,
      error: `all runs failed: ${samples.map((s) => s.status).join(",")}`,
      samples,
    }
  }

  return {
    ...entry,
    status: ok[ok.length - 1].status,
    ttfbMs: Math.round(median(ok.map((s) => s.ttfbMs))),
    totalMs: Math.round(median(ok.map((s) => s.totalMs))),
    bytes: Math.round(median(ok.map((s) => s.bytes))),
    looksBlankShell: ok.some((s) => s.looksBlankShell),
    samples,
  }
}

function pctDelta(next, prev) {
  if (!prev || prev === 0) return null
  return Math.round(((next - prev) / prev) * 1000) / 10
}

function printTable(rows, previousByRoute) {
  console.log("")
  console.log(
    [
      "label".padEnd(26),
      "ttfbMs".padStart(8),
      "totalMs".padStart(9),
      "bytes".padStart(10),
      "Δttfb%".padStart(8),
      "Δbytes%".padStart(8),
      "ok",
    ].join("  "),
  )
  for (const row of rows) {
    if (row.error) {
      console.log(`${row.label.padEnd(26)}  ERROR ${row.error}`)
      continue
    }
    const prev = previousByRoute?.get(row.route)
    const dT = prev ? pctDelta(row.ttfbMs, prev.ttfbMs) : null
    const dB = prev ? pctDelta(row.bytes, prev.bytes) : null
    console.log(
      [
        row.label.padEnd(26),
        String(row.ttfbMs).padStart(8),
        String(row.totalMs).padStart(9),
        String(row.bytes).padStart(10),
        (dT == null ? "—" : `${dT > 0 ? "+" : ""}${dT}`).padStart(8),
        (dB == null ? "—" : `${dB > 0 ? "+" : ""}${dB}`).padStart(8),
        row.status,
      ].join("  "),
    )
  }
  console.log("")
}

async function main() {
  const serverMode = await probeServerMode()
  if (serverMode === "unreachable") {
    console.error(`Server not reachable at ${BASE_URL}. Start next (prefer: npm run build && npm run start).`)
    process.exit(1)
  }

  console.log(`Instant Paint baseline → ${BASE_URL} (mode=${serverMode}, runs=${RUNS}, warmup=${WARMUP})`)

  const results = []
  for (const entry of ROUTES) {
    process.stdout.write(`  measuring ${entry.route} ... `)
    try {
      const row = await measureRoute(entry)
      results.push(row)
      console.log(row.error ? `FAIL ${row.error}` : `${row.ttfbMs}ms ttfb / ${row.bytes}B`)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      results.push({ ...entry, error: message })
      console.log(`FAIL ${message}`)
    }
  }

  let previousByRoute = null
  if (compareFile && existsSync(compareFile)) {
    try {
      const previous = JSON.parse(readFileSync(compareFile, "utf8"))
      previousByRoute = new Map((previous.routes || []).map((r) => [r.route, r]))
      console.log(`Comparing against ${compareFile} (${previous.capturedAt || "unknown time"})`)
    } catch {
      console.warn("Could not parse previous baseline; skipping delta.")
    }
  }

  printTable(results, previousByRoute)

  const artifact = {
    capturedAt: new Date().toISOString(),
    baseUrl: BASE_URL,
    serverMode,
    runs: RUNS,
    warmup: WARMUP,
    commit: process.env.GIT_COMMIT || null,
    note: "TTFB = time to first response headers+body start via fetch; totalMs includes full HTML download. Prefer production `next start` for deploy-relevant numbers.",
    routes: results.map((row) => {
      const { samples, ...rest } = row
      void samples
      return rest
    }),
  }

  mkdirSync(outDir, { recursive: true })
  writeFileSync(outFile, `${JSON.stringify(artifact, null, 2)}\n`)
  console.log(`Wrote ${outFile}`)

  const failed = results.filter((r) => r.error || (r.status && r.status >= 400))
  if (failed.length) {
    console.error(`${failed.length} route(s) failed.`)
    process.exit(1)
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
