import { spawn } from "node:child_process"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import process from "node:process"
import { URL } from "node:url"
import {
  CHROME_FLAGS,
  LIGHTHOUSE_CATEGORY_BUDGETS,
  LIGHTHOUSE_NUMERIC_BUDGETS,
  LIGHTHOUSE_ROUTE_MARKERS,
  LIGHTHOUSE_ROUTES,
} from "./lighthouse-config.mjs"

const baseUrl = process.env.LH_BASE_URL ?? "http://127.0.0.1:3001"
const chromeFlags = process.env.LH_ENABLE_GPU === "1" ? CHROME_FLAGS.replace(" --disable-gpu", "") : CHROME_FLAGS
const budgets = {
  performance: Number(process.env.LH_PERFORMANCE_MIN ?? LIGHTHOUSE_CATEGORY_BUDGETS.performance),
  accessibility: Number(process.env.LH_ACCESSIBILITY_MIN ?? LIGHTHOUSE_CATEGORY_BUDGETS.accessibility),
  "best-practices": Number(process.env.LH_BEST_PRACTICES_MIN ?? LIGHTHOUSE_CATEGORY_BUDGETS["best-practices"]),
  seo: Number(process.env.LH_SEO_MIN ?? LIGHTHOUSE_CATEGORY_BUDGETS.seo),
}
const runCount = Math.max(1, Number(process.env.LH_RUNS ?? 3))
const requestedRoutes = process.env.LH_ROUTES?.split(",")
  .map((route) => route.trim())
  .filter(Boolean)
const routes = requestedRoutes?.length ? requestedRoutes : LIGHTHOUSE_ROUTES
const unknownRoutes = routes.filter((route) => !LIGHTHOUSE_ROUTES.includes(route))
if (unknownRoutes.length > 0) {
  throw new Error(`Unknown Lighthouse routes: ${unknownRoutes.join(", ")}`)
}
const numericBudgets = {
  firstContentfulPaintMs: Number(process.env.LH_FCP_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.firstContentfulPaintMs),
  largestContentfulPaintMs: Number(process.env.LH_LCP_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.largestContentfulPaintMs),
  totalBlockingTimeMs: Number(process.env.LH_TBT_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.totalBlockingTimeMs),
  unusedJavaScriptBytes: Number(process.env.LH_UNUSED_JS_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.unusedJavaScriptBytes),
  totalByteWeightBytes: Number(process.env.LH_TOTAL_BYTES_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.totalByteWeightBytes),
  domNodes: Number(process.env.LH_DOM_NODES_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.domNodes),
  mainThreadWorkMs: Number(process.env.LH_MAIN_THREAD_MAX ?? LIGHTHOUSE_NUMERIC_BUDGETS.mainThreadWorkMs),
}

function runLighthouse(route, outputPath) {
  const url = new URL(route, baseUrl).toString()
  const args = [
    "lighthouse",
    url,
    "--output=json",
    `--output-path=${outputPath}`,
    `--chrome-flags=${chromeFlags}`,
    "--throttling-method=provided",
    "--quiet",
  ]

  return new Promise((resolve, reject) => {
    const child = spawn("npx", args, { stdio: "inherit" })
    child.on("error", reject)
    child.on("exit", (code) => {
      if (code === 0) {
        resolve()
        return
      }

      reject(new Error(`Lighthouse failed for ${route} with exit code ${code}`))
    })
  })
}

function score(report, category) {
  return Math.round((report.categories[category]?.score ?? 0) * 100)
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 0 ? Math.round((sorted[middle - 1] + sorted[middle]) / 2) : sorted[middle]
}

function numericAudit(report, id) {
  const audit = report.audits[id]
  if (id === "unused-javascript") return audit?.details?.overallSavingsBytes ?? 0
  return audit?.numericValue ?? 0
}

const numericAuditIds = {
  firstContentfulPaintMs: "first-contentful-paint",
  largestContentfulPaintMs: "largest-contentful-paint",
  totalBlockingTimeMs: "total-blocking-time",
  unusedJavaScriptBytes: "unused-javascript",
  totalByteWeightBytes: "total-byte-weight",
  domNodes: "dom-size",
  mainThreadWorkMs: "mainthread-work-breakdown",
}

async function assertRouteContent(route) {
  const response = await fetch(new URL(route, baseUrl))
  const html = await response.text()
  const expectedMarker = LIGHTHOUSE_ROUTE_MARKERS[route]

  if (!response.ok) {
    throw new Error(`${route} returned ${response.status} during the Lighthouse preflight`)
  }
  if (expectedMarker && !html.includes(expectedMarker)) {
    throw new Error(`${route} did not render its expected marker: ${expectedMarker}`)
  }
}

const requestedOutputDir = process.env.LH_OUTPUT_DIR
const outputDir = requestedOutputDir
  ? path.resolve(requestedOutputDir)
  : await fs.mkdtemp(path.join(os.tmpdir(), "avana-lighthouse-"))
await fs.mkdir(outputDir, { recursive: true })
process.stdout.write(
  `${JSON.stringify({ lighthouseOutputDir: outputDir, gpuEnabled: process.env.LH_ENABLE_GPU === "1" })}\n`,
)
const failures = []

for (const route of routes) {
  await assertRouteContent(route)
  const categoryScores = Object.fromEntries(Object.keys(budgets).map((category) => [category, []]))
  const numericScores = {
    firstContentfulPaintMs: [],
    largestContentfulPaintMs: [],
    totalBlockingTimeMs: [],
    unusedJavaScriptBytes: [],
    totalByteWeightBytes: [],
    domNodes: [],
    mainThreadWorkMs: [],
  }

  for (let run = 1; run <= runCount; run += 1) {
    const outputPath = path.join(outputDir, `${route.replaceAll("/", "_") || "home"}-${run}.json`)
    await runLighthouse(route, outputPath)
    const report = JSON.parse(await fs.readFile(outputPath, "utf8"))

    for (const category of Object.keys(budgets)) {
      categoryScores[category].push(score(report, category))
    }
    for (const [metric, auditId] of Object.entries(numericAuditIds)) {
      numericScores[metric].push(numericAudit(report, auditId))
    }
  }

  const row = { route, runs: runCount }

  for (const category of Object.keys(budgets)) {
    row[category] = median(categoryScores[category])
    if (row[category] < budgets[category]) {
      failures.push(`${route} ${category}: ${row[category]} < ${budgets[category]}`)
    }
  }

  for (const [metric, budget] of Object.entries(numericBudgets)) {
    row[metric] = median(numericScores[metric])
    if (row[metric] > budget) {
      failures.push(`${route} ${metric}: ${row[metric]} > ${budget}`)
    }
  }

  process.stdout.write(`${JSON.stringify(row)}\n`)
}

if (failures.length > 0) {
  process.stderr.write(`Lighthouse budgets failed:\n${failures.map((failure) => `- ${failure}`).join("\n")}\n`)
  process.exit(1)
}
