#!/usr/bin/env node
/**
 * First-load JS budgets for the product routes. `check-home-bundle-budget.mjs` guards only `/`
 * (the guest entry); the signed-in routes had no ceiling at all.
 *
 * A route's first-load set = the route's shared Next runtime chunks (its build manifest) plus the
 * client entry chunks of every layout on its path and of the page itself (its client-reference
 * manifest). Caps sit ~15 KiB above the sizes measured on 2026-09-22 so a real regression fails
 * CI while normal churn does not; lower a cap when a route gets lighter.
 */
import fs from "node:fs"
import path from "node:path"
import process from "node:process"
import { pathToFileURL } from "node:url"
import { analyzeInitialBundles, parseClientReferenceManifest } from "./check-home-bundle-budget.mjs"

const KiB = 1024

/** Page entry (relative to app/) → max first-load gzip bytes. Measured value in the comment. */
export const ROUTE_BUDGETS = {
  "lend/page": 430 * KiB, // 414
  "borrow/page": 430 * KiB, // 416
  "dashboard/page": 460 * KiB, // 443
  "swap/page": 430 * KiB, // 414
  "ask/page": 245 * KiB, // 230
  "lend/markets/[marketId]/page": 485 * KiB, // 467
  "borrow/markets/[marketId]/page": 490 * KiB, // 475
  "borrow/assets/[assetId]/page": 495 * KiB, // 480
  "actions/[product]/[kind]/page": 465 * KiB, // 451
}

/** Runtime chunks + entry chunks of each layout on the route's path + the page's own chunks. */
export function collectRouteInitialFiles({ route, clientManifest, routeBuildManifest }) {
  const entries = clientManifest.entryJSFiles ?? {}
  const pageDir = route.replace(/\/?page$/, "")
  const files = new Set(routeBuildManifest.rootMainFiles ?? [])
  for (const [entry, chunks] of Object.entries(entries)) {
    const module = entry.replace(/^\[project\]\/app\//, "")
    const layoutDir = module === "layout" ? "" : module.endsWith("/layout") ? module.slice(0, -"/layout".length) : null
    const onPath =
      layoutDir !== null && (layoutDir === "" || pageDir === layoutDir || pageDir.startsWith(`${layoutDir}/`))
    if (onPath || module === route) for (const chunk of chunks) files.add(chunk)
  }
  return [...files]
}

function resolveDistDir() {
  if (process.env.AVANA_NEXT_DIST_DIR) return process.env.AVANA_NEXT_DIST_DIR
  return fs.existsSync(".next-prod") ? ".next-prod" : ".next"
}

export function runRouteBundleBudgets({ distDir = resolveDistDir(), budgets = ROUTE_BUDGETS } = {}) {
  const failures = []
  const results = []
  for (const [route, maxGzipBytes] of Object.entries(budgets)) {
    const clientManifestPath = path.join(distDir, "server/app", `${route}_client-reference-manifest.js`)
    const routeBuildManifestPath = path.join(distDir, "server/app", route, "build-manifest.json")
    for (const required of [clientManifestPath, routeBuildManifestPath]) {
      if (!fs.existsSync(required)) throw new Error(`missing ${required} — run \`npm run build\` first`)
    }
    const clientManifest = parseClientReferenceManifest(fs.readFileSync(clientManifestPath, "utf8"))
    const routeBuildManifest = JSON.parse(fs.readFileSync(routeBuildManifestPath, "utf8"))
    const files = collectRouteInitialFiles({ route, clientManifest, routeBuildManifest })
    if (files.length === 0) throw new Error(`${route}: resolved zero initial chunks — manifest shape may have changed`)
    const { gzipBytes } = analyzeInitialBundles({ distDir, files, forbiddenGroups: {} })
    results.push({ route, gzipBytes, maxGzipBytes })
    console.log(
      `[route-budget] ${String(Math.round(gzipBytes / KiB)).padStart(4)} / ${Math.round(maxGzipBytes / KiB)} KiB gzip  /${route.replace(/\/?page$/, "")}`,
    )
    if (gzipBytes > maxGzipBytes) failures.push(`${route}: ${gzipBytes} > ${maxGzipBytes} gzip bytes`)
  }
  if (failures.length > 0) throw new Error(`routes over budget:\n  ${failures.join("\n  ")}`)
  return results
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    runRouteBundleBudgets()
  } catch (error) {
    console.error(`[route-budget] ${error instanceof Error ? error.message : String(error)}`)
    process.exit(1)
  }
}
