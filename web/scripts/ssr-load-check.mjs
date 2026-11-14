/**
 * SSR latency check under concurrent guests. Loads market list/detail pages N times at a fixed
 * concurrency and reports p50/p95/max; exits 1 when p95 exceeds the budget.
 *   node scripts/ssr-load-check.mjs [baseUrl] [--requests 100] [--concurrency 10] [--p95-budget-ms 2500]
 * Light on the machine running it (plain fetches). Re-run as traffic grows. 2026-09-23 on
 * app.avana.cc at 10 concurrent: first pass p95 3.2 s / max 3.5 s, an immediate second pass
 * p95 1.2 s / max 1.6 s, no failures, so the tail is cold function starts rather than load.
 * Run it twice; a warm pass over budget is the signal to act.
 */
const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? Number(args[i + 1]) : fallback
}
const base = (args.find((a) => !a.startsWith("--") && !/^\d+$/.test(a)) ?? "https://app.avana.cc").replace(/\/$/, "")
const requests = flag("requests", 100)
const concurrency = flag("concurrency", 10)
const budgetMs = flag("p95-budget-ms", 2500)
const pages = [
  "/",
  "/borrow",
  "/lend",
  "/multiply",
  "/borrow/markets/uni-v2-wbtc-usdc",
  "/lend/markets/usdc",
  "/multiply/markets/wsteth-eth",
  "/borrow/markets/uni-v3-bluechip-weth-usdc",
  "/lend/markets/gho",
  "/multiply/markets/eth-gho",
]

const latencies = []
const byPage = new Map()
let failures = 0
let next = 0
await Promise.all(
  Array.from({ length: concurrency }, async () => {
    while (next < requests) {
      const page = pages[next++ % pages.length]
      const started = performance.now()
      try {
        const response = await fetch(base + page, { headers: { "user-agent": "avana-ssr-load-check" } })
        await response.text()
        if (!response.ok) throw new Error(String(response.status))
        const ms = performance.now() - started
        latencies.push(ms)
        byPage.set(page, [...(byPage.get(page) ?? []), ms])
      } catch {
        failures++
      }
    }
  }),
)

const pct = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(p * (sorted.length - 1)))] ?? 0
}
const round = (ms) => Math.round(ms)
console.log(`${base}: ${latencies.length}/${requests} ok at ${concurrency} concurrent, ${failures} failed`)
console.log(
  `p50 ${round(pct(latencies, 0.5))} ms · p95 ${round(pct(latencies, 0.95))} ms · max ${round(Math.max(...latencies))} ms`,
)
for (const [page, values] of [...byPage].sort((a, b) => pct(b[1], 0.95) - pct(a[1], 0.95)).slice(0, 3)) {
  console.log(`  slowest: ${page} p95 ${round(pct(values, 0.95))} ms`)
}
const p95 = pct(latencies, 0.95)
if (failures > 0 || p95 > budgetMs) {
  console.error(`over budget: p95 ${round(p95)} ms (budget ${budgetMs} ms), ${failures} failures`)
  process.exit(1)
}
