#!/usr/bin/env node
/**
 * First-load JS budget for `/` (root layout + page).
 *
 * Next 16/Turbopack no longer emits the root `app-build-manifest.json` this
 * script used to read. The route client-reference manifest is the authoritative
 * list of layout/page entry chunks, while the route build manifest supplies the
 * shared Next runtime chunks.
 */
import fs from "node:fs"
import path from "node:path"
import process from "node:process"
import { pathToFileURL } from "node:url"
import { gzipSync } from "node:zlib"

const DEFAULT_MAX_GZIP_BYTES = 250 * 1024
const FORBIDDEN_GROUPS = {
  convex: ["ConvexReactClient", "BaseConvexClient"],
  connectkit: ["ConnectKitProvider", "connectkit"],
  wagmi: ["WagmiProvider", "wagmi"],
  viem: ["viem/_esm", "viem/actions"],
}

export function parseClientReferenceManifest(source) {
  const assignment = source.lastIndexOf("= {")
  if (assignment < 0) throw new Error("client-reference manifest has no assignment")
  return JSON.parse(
    source
      .slice(assignment + 2)
      .trim()
      .replace(/;$/, ""),
  )
}

export function collectInitialFiles({ clientManifest, routeBuildManifest }) {
  const entries = clientManifest.entryJSFiles ?? {}
  const files = new Set(routeBuildManifest.rootMainFiles ?? [])
  for (const entry of ["[project]/app/layout", "[project]/app/page"]) {
    for (const file of entries[entry] ?? []) files.add(file)
  }
  return [...files]
}

export function analyzeInitialBundles({ distDir, files, forbiddenGroups = FORBIDDEN_GROUPS }) {
  let rawBytes = 0
  let gzipBytes = 0
  const rows = []
  const forbidden = new Map()

  for (const file of files) {
    const absolute = path.join(distDir, file.replace(/^\/_next\//, ""))
    if (!fs.existsSync(absolute)) throw new Error(`missing initial chunk ${absolute}`)
    const contents = fs.readFileSync(absolute)
    const raw = contents.byteLength
    const gzip = gzipSync(contents, { level: 9 }).byteLength
    rawBytes += raw
    gzipBytes += gzip
    rows.push({ file, raw, gzip })

    const text = contents.toString("utf8")
    for (const [group, markers] of Object.entries(forbiddenGroups)) {
      if (markers.some((marker) => text.includes(marker))) {
        const hits = forbidden.get(group) ?? []
        hits.push(file)
        forbidden.set(group, hits)
      }
    }
  }

  rows.sort((a, b) => b.gzip - a.gzip)
  return { rawBytes, gzipBytes, rows, forbidden }
}

function resolveDistDir() {
  if (process.env.AVANA_NEXT_DIST_DIR) return process.env.AVANA_NEXT_DIST_DIR
  return fs.existsSync(".next-prod") ? ".next-prod" : ".next"
}

export function runBundleBudget({
  distDir = resolveDistDir(),
  maxGzipBytes = Number(process.env.HOME_BUNDLE_MAX_GZIP_BYTES ?? DEFAULT_MAX_GZIP_BYTES),
  // Default ON so CI fails when Convex/wallet SDKs leak into the guest `/` entry.
  // Set HOME_BUNDLE_ENFORCE_FORBIDDEN=0 only while diagnosing a known leak.
  enforceForbidden = process.env.HOME_BUNDLE_ENFORCE_FORBIDDEN !== "0",
} = {}) {
  const clientManifestPath = path.join(distDir, "server/app/page_client-reference-manifest.js")
  const routeBuildManifestPath = path.join(distDir, "server/app/page/build-manifest.json")

  for (const required of [clientManifestPath, routeBuildManifestPath]) {
    if (!fs.existsSync(required)) throw new Error(`missing ${required} — run \`npm run build\` first`)
  }

  const clientManifest = parseClientReferenceManifest(fs.readFileSync(clientManifestPath, "utf8"))
  const routeBuildManifest = JSON.parse(fs.readFileSync(routeBuildManifestPath, "utf8"))
  const files = collectInitialFiles({ clientManifest, routeBuildManifest })
  if (files.length === 0) throw new Error("resolved zero initial chunks — manifest shape may have changed")

  const result = analyzeInitialBundles({ distDir, files })
  console.log(
    `[bundle-budget] ${files.length} initial files: ${Math.round(result.gzipBytes / 1024)} KiB gzip, ${Math.round(result.rawBytes / 1024)} KiB raw (max ${Math.round(maxGzipBytes / 1024)} KiB gzip)`,
  )
  for (const row of result.rows.slice(0, 12)) {
    console.log(
      `  ${String(Math.round(row.gzip / 1024)).padStart(4)} KiB gzip  ${String(Math.round(row.raw / 1024)).padStart(5)} KiB raw  ${row.file}`,
    )
  }

  for (const [group, chunks] of result.forbidden) {
    console.warn(`[bundle-budget] initial ${group} runtime: ${chunks.join(", ")}`)
  }

  if (result.gzipBytes > maxGzipBytes) {
    throw new Error(`home bundle is over budget: ${result.gzipBytes} > ${maxGzipBytes} gzip bytes`)
  }
  if (enforceForbidden && result.forbidden.size > 0) {
    throw new Error(`forbidden initial runtime groups: ${[...result.forbidden.keys()].join(", ")}`)
  }
  return result
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    runBundleBudget()
  } catch (error) {
    console.error(`[bundle-budget] ${error instanceof Error ? error.message : String(error)}`)
    process.exit(1)
  }
}
